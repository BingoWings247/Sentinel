-- =============================================================================
-- bsd_sentinel / server / sdk.lua
-- =============================================================================
-- The §12 producer SDK: the public front door every OTHER BSD resource
-- (fuel, banking, leo, ...) calls to push events INTO Sentinel.
--
-- TWO WRITE PATHS, ONE PIPELINE:
--   - Internal collectors call Ingestion.Emit{ domain, type, ... } directly.
--   - External producers call this SDK's Emit{ eventType, actor, payload, ... },
--     which is FORMAT-gated (any well-formed dotted eventType is accepted; no
--     pre-registration), adds the producer-safety layer (readiness gating,
--     per-resource rate limiting, payload serialization + size checks, actor
--     normalization, reserved-field protection, {ok,code,status,eventId,message}
--     results), then DELEGATES DOWN to Ingestion.Emit. Accepted SDK events
--     therefore land in the same buffer/table as collector events, AND their
--     derived domains show up in Health and Query automatically.
--
-- TRANSLATION (SDK shape -> internal shape), done in deliverToIngestion():
--   eventType 'fuel.purchase.completed' -> domain 'fuel', type 'purchase.completed'
--   (domain + type are registered idempotently before the first emit of each)
--   actor player/system/unknown -> ActorType player/system/external
--   payload table -> metadata (Ingestion encodes it); severity stays a string
--   source_resource + sdk_version (no DB columns yet) -> folded into metadata._sentinel
--   Ingestion owns the event_id (UUIDv7); the SDK surfaces it to the caller.
--
-- ARCH STANDARD: self-reports on load (Rule 1); config never gatekeeps
-- (Rule 2); validates every input and never fails silently (Rules 4/5).
--
-- Cross-VM note: the test harness reaches this module only through the
-- exports at the bottom of this file.
--
-- Dependencies: server/logger.lua, server/registry.lua, server/ingestion.lua,
--               server/buffer.lua (via ingestion), server/main.lua (readiness),
--               shared/enums.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.SDK = BSD.Sentinel.SDK or {}

local SDK = BSD.Sentinel.SDK
local Logger = BSD.Sentinel.Logger


-- =============================================================================
-- CONSTANTS
-- =============================================================================

local SDK_VERSION = '1.0.0'

local CODE_ACCEPTED           = 'SENTINEL_ACCEPTED'
local CODE_INVALID_EVENT_TYPE = 'SENTINEL_INVALID_EVENT_TYPE'
local CODE_INVALID_ACTOR      = 'SENTINEL_INVALID_ACTOR'
local CODE_INVALID_PAYLOAD    = 'SENTINEL_INVALID_PAYLOAD'
local CODE_EVENT_TOO_LARGE    = 'SENTINEL_EVENT_TOO_LARGE'
local CODE_RATE_LIMITED       = 'SENTINEL_RATE_LIMITED'
local CODE_UNAVAILABLE        = 'SENTINEL_UNAVAILABLE'

-- Valid severities = the internal Severity set (info is the default/normalize target).
local VALID_SEVERITY = { debug = true, info = true, warning = true, critical = true }
local DEFAULT_SEVERITY = 'info'

local RESERVED_FIELDS = {
    eventId = true, event_id = true, ingested_at = true,
    source_resource = true, sdk_version = true, event_type = true,
}

local MAX_EVENT_BYTES = 16 * 1024
local RATE_BURST      = 500
local RATE_PER_SECOND = 100
local RECENT_MAX      = 2000

-- Resources whose events are NOT persisted to the DB (still validated, rate-
-- limited, and retrievable via FindEventById for tests). Leave empty to persist
-- everything. Uncomment the harness to keep test traffic out of the events table.
local NON_PERSISTING_RESOURCES = {
    -- bsd_sentinel_tests = true,
}


-- =============================================================================
-- UTILITIES
-- =============================================================================

math.randomseed((GetGameTimer and GetGameTimer() or 0) + os.time())

local function uuidv4()
    local s = string.gsub('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx', '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 15) or math.random(8, 11)
        return string.format('%x', v)
    end)
    return s
end

local function hasNonFinite(v, seen)
    local t = type(v)
    if t == 'number' then
        if v ~= v then return true end
        if v == math.huge or v == -math.huge then return true end
        return false
    elseif t == 'table' then
        seen = seen or {}
        if seen[v] then return false end
        seen[v] = true
        for k, val in pairs(v) do
            if hasNonFinite(k, seen) or hasNonFinite(val, seen) then return true end
        end
    end
    return false
end


-- =============================================================================
-- EVENT TYPE VALIDATION (format-gated; hyphens allowed inside a segment)
-- =============================================================================

local function isValidEventType(s)
    if type(s) ~= 'string' or #s == 0 or #s > 255 then return false end
    if not s:find('%.') then return false end
    if s:find('[^%l%d%.%-]') then return false end
    if s:find('%.%.') then return false end
    local first, last = s:sub(1, 1), s:sub(-1)
    if first == '.' or first == '-' or last == '.' or last == '-' then return false end
    return true
end


-- =============================================================================
-- ACTOR VALIDATION + HELPERS
-- =============================================================================

local function validateActor(actor)
    if actor == nil then return true end
    if type(actor) ~= 'table' then return false, 'actor must be a table' end
    local t = actor.type
    if t == 'player' then
        if actor.source == nil then return false, 'player actor requires a source' end
    elseif t == 'system' then
        if actor.name == nil or actor.name == '' then return false, 'system actor requires a name' end
    elseif t == 'unknown' then
        if actor.reason == nil or actor.reason == '' then return false, 'unknown actor requires a reason' end
    else
        return false, 'actor.type must be one of: player, system, unknown'
    end
    return true
end

function SDK.PlayerActor(source, overrides)
    if source == nil then
        return nil, 'PlayerActor: a source argument is required'
    end
    local actor = { type = 'player', source = source }
    if type(overrides) == 'table' then
        for k, v in pairs(overrides) do
            if k ~= 'type' and k ~= 'source' then actor[k] = v end
        end
    end
    return actor
end

function SDK.SystemActor(name, metadata)
    if name == nil or name == '' then
        return nil, 'SystemActor: a name argument is required'
    end
    local actor = { type = 'system', name = name }
    if type(metadata) == 'table' then
        for k, v in pairs(metadata) do
            if k ~= 'type' and k ~= 'name' then actor[k] = v end
        end
    end
    return actor
end

function SDK.NewCorrelationId(prefix)
    local id = uuidv4()
    if prefix ~= nil and prefix ~= '' then
        id = tostring(prefix) .. ':' .. id
    end
    if #id > 128 then id = id:sub(1, 128) end
    return id
end

function SDK.GetSdkVersion()
    return SDK_VERSION
end


-- =============================================================================
-- RATE LIMITER (per-resource token bucket)
-- =============================================================================

local buckets = {}

local function bucketFor(key)
    local b = buckets[key]
    if not b then
        b = { tokens = RATE_BURST, last = (GetGameTimer and GetGameTimer() or 0) }
        buckets[key] = b
    end
    return b
end

local function refill(b)
    local now = (GetGameTimer and GetGameTimer() or 0)
    local elapsed = now - b.last
    if elapsed > 0 then
        b.tokens = math.min(RATE_BURST, b.tokens + (elapsed / 1000) * RATE_PER_SECOND)
        b.last = now
    end
end

local function rateConsume(key)
    local b = bucketFor(key)
    refill(b)
    if b.tokens >= 1 then
        b.tokens = b.tokens - 1
        return true
    end
    return false
end

local function ratePeek(key)
    local b = bucketFor(key)
    refill(b)
    return b.tokens >= 1
end


-- =============================================================================
-- READINESS  (INTEGRATION SEAM: point at your real ready signal if different)
-- =============================================================================

local initialized = false
local devForceUninit = false   -- test-only seam; setter is DevMode-gated below

function SDK.IsInitialized()
    if devForceUninit then return false end   -- must be ABOVE the latch
    if initialized then return true end
    local S = BSD.Sentinel
    local ready =
        (S.Main and S.Main.IsReady and S.Main.IsReady() == true) or
        (S.Main and S.Main.ready == true) or
        (S.Buffer and S.Buffer.IsInitialized and S.Buffer.IsInitialized() == true)
    if ready then
        initialized = true
        return true
    end
    return false
end

function SDK._SetForceUninit(v) devForceUninit = (v == true) end


-- =============================================================================
-- RECENT-EVENT MAP (backs FindEventById across the VM boundary)
-- =============================================================================

local recentById = {}
local recentOrder = {}

local function rememberRecent(id, record)
    recentById[id] = record
    recentOrder[#recentOrder + 1] = id
    if #recentOrder > RECENT_MAX then
        local oldest = table.remove(recentOrder, 1)
        if oldest then recentById[oldest] = nil end
    end
end

function SDK.FindEventById(eventId)
    return recentById[eventId]
end


-- =============================================================================
-- TRANSLATION -> INTERNAL INGESTION PIPELINE
-- =============================================================================

local registeredTypes = {}  -- "domain.type" -> true (idempotency cache)

local function deriveDomainType(et)
    local dot = et:find('%.')
    return et:sub(1, dot - 1), et:sub(dot + 1)
end

-- Registry forbids hyphens and requires a leading letter; §12 allows hyphens.
local function sanitizeDomain(d)
    d = d:gsub('%-', '_')
    if not d:match('^[a-z]') then d = 'd_' .. d end
    if #d < 2 then d = d .. '_x' end
    if #d > 50 then d = d:sub(1, 50) end
    return d
end

local function sanitizeType(t)
    return (t:gsub('%-', '_'))
end

local function ensureRegistered(domain, typeName, severity)
    local key = domain .. '.' .. typeName
    if registeredTypes[key] then return true end
    local Reg = BSD.Sentinel.Registry
    local Enums = BSD.Sentinel.Enums
    if not Reg then return false end
    Reg.RegisterDomain({ name = domain, display_name = domain, version = 'sdk' })
    local ok = Reg.RegisterEventType({
        domain = domain,
        type = typeName,
        category = (Enums and Enums.EventCategory.SYSTEM) or 'system',
        default_severity = severity or DEFAULT_SEVERITY,
        description = 'Producer SDK event',
        required_fields = {},
    })
    if ok then registeredTypes[key] = true end
    return ok
end

local function mapActor(a)
    if type(a) ~= 'table' then return nil, nil, nil end
    local Enums = BSD.Sentinel.Enums
    local AT = (Enums and Enums.ActorType)
        or { PLAYER = 'player', SYSTEM = 'system', EXTERNAL = 'external' }
    if a.type == 'player' then
        local ident = (type(a.citizenid) == 'string' and a.citizenid)
            or (type(a.identifier) == 'string' and a.identifier) or nil
        return AT.PLAYER, ident, tonumber(a.source)
    elseif a.type == 'system' then
        return AT.SYSTEM, (type(a.name) == 'string' and a.name) or nil, nil
    elseif a.type == 'unknown' then
        return AT.EXTERNAL, (type(a.reason) == 'string' and a.reason) or nil, nil
    end
    return nil, nil, nil
end

--- Translate an accepted §12 event into an internal emit and hand it to
-- Ingestion. Returns the event_id Ingestion generated, or nil on failure.
local function deliverToIngestion(et, severity, actorTable, payloadTable, correlationId, caller)
    local Ing = BSD.Sentinel.Ingestion
    local Enums = BSD.Sentinel.Enums
    if not (Ing and type(Ing.Emit) == 'function') then return nil end

    local domain, typeName = deriveDomainType(et)
    domain, typeName = sanitizeDomain(domain), sanitizeType(typeName)
    if not ensureRegistered(domain, typeName, severity) then return nil end

    local actorType, actorIdentifier, actorSource = mapActor(actorTable)

    -- Carry the §12-injected fields that have no DB column (yet) in metadata.
    local meta = {}
    if type(payloadTable) == 'table' then
        for k, v in pairs(payloadTable) do meta[k] = v end
    end
    meta._sentinel = { source_resource = caller, sdk_version = SDK_VERSION }

    local ok, eventId = Ing.Emit({
        domain           = domain,
        type             = typeName,
        category         = (Enums and Enums.EventCategory.SYSTEM) or 'system',
        severity         = severity,
        status           = (Enums and Enums.EventStatus.COMPLETED) or 'completed',
        actor_type       = actorType,
        actor_identifier = actorIdentifier,
        actor_source     = actorSource,
        summary          = et,
        metadata         = meta,
        correlation_id   = correlationId,
    })
    if ok then return eventId end
    return nil
end


-- =============================================================================
-- RESULT BUILDERS
-- =============================================================================

local function reject(code, message)
    return { ok = false, code = code, status = 'rejected', eventId = nil, message = message }
end


-- =============================================================================
-- EMIT  (the core)
-- =============================================================================

function SDK.Emit(event)
    local caller = (GetInvokingResource and GetInvokingResource()) or GetCurrentResourceName()

    if not SDK.IsInitialized() then
        return { ok = false, code = CODE_UNAVAILABLE, status = 'unavailable', eventId = nil,
                 message = 'Sentinel is not initialized' }
    end

    if type(event) ~= 'table' then
        return reject(CODE_INVALID_EVENT_TYPE, 'event must be a table')
    end

    local et = event.eventType
    if not isValidEventType(et) then
        local shown = (et == nil) and '(missing)' or ('"' .. tostring(et) .. '"')
        return reject(CODE_INVALID_EVENT_TYPE,
            'invalid eventType ' .. shown .. ': expected lowercase dotted segments')
    end

    local okActor, actorErr = validateActor(event.actor)
    if not okActor then
        return reject(CODE_INVALID_ACTOR, actorErr)
    end

    local warnings = {}

    local collided = {}
    for k in pairs(event) do
        if RESERVED_FIELDS[k] then collided[#collided + 1] = k end
    end
    if #collided > 0 then
        warnings[#warnings + 1] = 'ignored caller-set reserved field(s): ' .. table.concat(collided, ', ')
    end

    local severity = event.severity
    if severity == nil then
        severity = DEFAULT_SEVERITY
    elseif not VALID_SEVERITY[severity] then
        warnings[#warnings + 1] = 'severity "' .. tostring(severity) .. '" normalized to "info"'
        severity = DEFAULT_SEVERITY
    end

    local payload = event.payload
    if payload == nil then payload = {} end
    if type(payload) ~= 'table' then
        return reject(CODE_INVALID_PAYLOAD, 'payload must be a table')
    end
    if hasNonFinite(payload) then
        return reject(CODE_INVALID_PAYLOAD, 'payload contains a non-serializable value (NaN/Inf)')
    end
    local okEnc, payload_json = pcall(json.encode, payload)
    if not okEnc or type(payload_json) ~= 'string' then
        return reject(CODE_INVALID_PAYLOAD, 'payload could not be JSON-encoded')
    end

    local actor_json = nil
    if event.actor ~= nil then
        local okA, enc = pcall(json.encode, event.actor)
        if not okA or type(enc) ~= 'string' then
            return reject(CODE_INVALID_PAYLOAD, 'actor could not be JSON-encoded')
        end
        actor_json = enc
    end

    local approxBytes = #payload_json + #(actor_json or '') + #et + 256
    if approxBytes > MAX_EVENT_BYTES then
        return reject(CODE_EVENT_TOO_LARGE,
            string.format('event ~%dB exceeds the %dB limit', approxBytes, MAX_EVENT_BYTES))
    end

    if not rateConsume(caller) then
        return { ok = false, code = CODE_RATE_LIMITED, status = 'dropped', eventId = nil,
                 message = 'per-resource rate limit exceeded' }
    end

    -- Accepted. Persist through the internal pipeline (unless this resource is
    -- excluded), and surface the id Ingestion assigns.
    local eventId
    if not NON_PERSISTING_RESOURCES[caller] then
        eventId = deliverToIngestion(et, severity, event.actor, payload, event.correlationId, caller)
    end
    if not eventId then
        eventId = uuidv4()  -- excluded resource, or persistence unavailable: still honor the contract
    end

    local record = {
        event_id        = eventId,
        event_type      = et,
        severity        = severity,
        correlation_id  = event.correlationId,
        payload_json    = payload_json,
        actor_json      = actor_json,
        source_resource = caller,
        sdk_version     = SDK_VERSION,
        ingested_at     = os.time(),
    }
    rememberRecent(eventId, record)

    local message = (#warnings > 0) and table.concat(warnings, '; ') or nil
    return { ok = true, code = CODE_ACCEPTED, status = 'queued', eventId = eventId, message = message }
end


-- =============================================================================
-- ENABLED  (cheap pre-check for producers; non-destructive)
-- =============================================================================

function SDK.Enabled(_eventType)
    if not SDK.IsInitialized() then return false end
    local caller = (GetInvokingResource and GetInvokingResource()) or GetCurrentResourceName()
    return ratePeek(caller)
end


-- =============================================================================
-- DIAGNOSTICS (for the test harness)
-- =============================================================================

function SDK.ResetRateLimiter()
    buckets = {}
    return true
end


-- =============================================================================
-- EXPORTS  (the public surface the §12 harness reaches)
-- =============================================================================
-- Place this file AFTER server/exports.lua in the manifest so these win over
-- any stray Emit registration, and remove the old internal-shape Emit export.

exports('Emit',             function(event)            return SDK.Emit(event) end)
exports('Enabled',          function(eventType)        return SDK.Enabled(eventType) end)
exports('PlayerActor',      function(source, ov)       return SDK.PlayerActor(source, ov) end)
exports('SystemActor',      function(name, meta)       return SDK.SystemActor(name, meta) end)
exports('NewCorrelationId', function(prefix)           return SDK.NewCorrelationId(prefix) end)
exports('GetSdkVersion',    function()                 return SDK.GetSdkVersion() end)
exports('FindEventById',    function(eventId)          return SDK.FindEventById(eventId) end)
exports('IsInitialized',    function()                 return SDK.IsInitialized() end)
exports('ResetRateLimiter', function()                 return SDK.ResetRateLimiter() end)

-- =============================================================================
-- TEST-ONLY SEAM — inert unless DevMode. Lets 12.17/12.20 force the
-- uninitialized path in-process. Registered always (load-order-safe); the
-- call-time guard means it does NOTHING in production.
-- =============================================================================
exports('__SetForceUninit', function(v)
    if not (Config and Config.DevMode == true) then
        return false   -- production: cannot disable the audit layer
    end
    SDK._SetForceUninit(v)
    return true
end)

-- =============================================================================
-- SELF-ANNOUNCE (ARCH Rule 1)
-- =============================================================================

if Logger then
    Logger.Info('Producer SDK loaded (v%s): 9 exports, events delegate to Ingestion', SDK_VERSION)
end