-- =============================================================================
-- bsd_sentinel / server / collectors / resources.lua
-- =============================================================================
-- Resource lifecycle collector.
--
-- WHAT IT DOES: listens for onResourceStart / onResourceStop and records each
-- as a Sentinel event. Low-volume and event-driven (resources rarely start or
-- stop), so per-event emission is safe. These events are the backbone of crash
-- correlation: when the diagnosis layer sees "resource X stopped two seconds
-- before a hitch and a pool spike," it can name a likely culprit.
--
-- HONEST LIMIT: the stop event cannot tell you WHY a resource stopped — FiveM
-- fires the same onResourceStop for an intentional /stop and for a crash. So
-- this records the fact, at info severity. The one inference it does make: a
-- resource that stops very soon after starting is likely crash-looping, which
-- is flagged at warning severity.
--
-- Catches resources that start/stop AFTER this collector is running. Resources
-- already up before Sentinel loaded won't have a recorded start (expected), but
-- their stop will still be caught.
--
-- Dependencies: server/logger.lua, server/registry.lua, server/ingestion.lua,
--               server/collectors/loader.lua, shared/enums.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Collectors = BSD.Sentinel.Collectors or {}
BSD.Sentinel.Collectors.list = BSD.Sentinel.Collectors.list or {}

local Logger = BSD.Sentinel.Logger
local Enums = BSD.Sentinel.Enums
local Registry = BSD.Sentinel.Registry
local Ingestion = BSD.Sentinel.Ingestion

local TYPE_STARTED = 'resource_started'
local TYPE_STOPPED = 'resource_stopped'


-- =============================================================================
-- CONFIG (ARCH Rule 2)
-- =============================================================================

local function readConfig()
    local c = (Config and Config.Collectors and Config.Collectors.Resources) or {}
    local flap = tonumber(c.FlapThresholdSeconds)
    if not flap or flap < 0 then flap = 10 end
    return {
        enabled            = (c.Enabled ~= false),
        flapThresholdSecs  = math.floor(flap),
    }
end

local settings = readConfig()
local running = false
local emitDomain = 'sentinel'
local startedAt = {}  -- resourceName -> epoch of last start


-- =============================================================================
-- INTERNAL
-- =============================================================================

local function emitLifecycle(eventType, resource, severity, summary, metadata)
    Ingestion.Emit({
        domain = emitDomain,
        type = eventType,
        category = Enums.EventCategory.SYSTEM,
        severity = severity,
        status = Enums.EventStatus.COMPLETED,
        actor_type = Enums.ActorType.SYSTEM,
        actor_identifier = 'sentinel_resource_monitor',
        subject_type = 'resource',
        subject_id = resource,
        summary = summary,
        metadata = metadata,
    })
end


local function onStart(resource)
    if not running then return end
    if resource == GetCurrentResourceName() then return end
    startedAt[resource] = os.time()
    emitLifecycle(TYPE_STARTED, resource, Enums.Severity.INFO,
        string.format('Resource "%s" started', resource),
        { resource = resource })
end


local function onStop(resource)
    if not running then return end
    if resource == GetCurrentResourceName() then return end

    local now = os.time()
    local uptime = startedAt[resource] and (now - startedAt[resource]) or nil
    startedAt[resource] = nil

    -- Rapid stop after start => likely a crash loop.
    local flapping = uptime ~= nil and uptime <= settings.flapThresholdSecs
    local severity = flapping and Enums.Severity.WARNING or Enums.Severity.INFO
    local summary = flapping
        and string.format('Resource "%s" stopped %ds after starting (possible crash loop)', resource, uptime)
        or  string.format('Resource "%s" stopped%s', resource,
                uptime and string.format(' after %ds uptime', uptime) or '')

    emitLifecycle(TYPE_STOPPED, resource, severity, summary, {
        resource = resource,
        uptime_seconds = uptime,
        suspected_crash_loop = flapping or nil,
    })
end


-- =============================================================================
-- COLLECTOR
-- =============================================================================

local collector = { name = 'resources', enabled = settings.enabled }

function collector.register(domain)
    emitDomain = domain or emitDomain
    local defs = {
        { TYPE_STARTED, 'A resource started.' },
        { TYPE_STOPPED, 'A resource stopped (intentional or crash; cannot be distinguished from the event alone).' },
    }
    for _, d in ipairs(defs) do
        local ok, err = Registry.RegisterEventType({
            domain = emitDomain,
            type = d[1],
            category = Enums.EventCategory.SYSTEM,
            default_severity = Enums.Severity.INFO,
            description = d[2],
            required_fields = { 'resource' },
        })
        if not ok then
            Logger.Critical('Collector "resources": could not register %s: %s', d[1], tostring(err))
        end
    end
end

function collector.start()
    running = true
    -- Handlers are registered once; they no-op when `running` is false, which
    -- is how stop() disables them (FiveM has no clean per-handler removal).
    AddEventHandler('onResourceStart', onStart)
    AddEventHandler('onResourceStop', onStop)
    Logger.Info('Collector "resources": watching lifecycle (flap threshold %ds)',
        settings.flapThresholdSecs)
end

function collector.stop()
    running = false
    Logger.Info('Collector "resources": stopped')
end

BSD.Sentinel.Collectors.list[#BSD.Sentinel.Collectors.list + 1] = collector

if Logger then
    Logger.Info('Collector "resources" loaded (%s)', collector.enabled and 'enabled' or 'disabled')
end