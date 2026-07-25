-- =============================================================================
-- bsd_sentinel / server / registry.lua
-- =============================================================================
-- Domain and event type registry.
--
-- Every BSD domain module (bsd_banking, bsd_fuel, bsd_medical, etc.)
-- declares itself to Sentinel at startup:
--
--   Sentinel.RegisterDomain({
--       name = 'banking',
--       display_name = 'Banking & Finance',
--       version = '2.0.0',
--   })
--
-- Then declares every event type it will emit:
--
--   Sentinel.RegisterEventType({
--       domain = 'banking',
--       type = 'transfer_completed',
--       category = 'mutation',
--       default_severity = 'info',
--       description = 'A successful transfer between two accounts',
--       required_fields = { 'from_account', 'to_account', 'amount' },
--   })
--
-- At event emission time, the ingestion layer (coming in a future batch)
-- checks the emitted event against these registrations. If the domain
-- or event_type is unknown:
--   - Strict mode (production): event REJECTED with a loud error log
--   - Dev mode: event auto-registered with a WARNING, allowed through
--
-- WHY THIS EXISTS:
-- 1. Catches typos at registration time, not at query time three weeks
--    later when staff is trying to investigate an incident.
-- 2. Enables discovery: Sentinel can tell operators "these domains are
--    declared, these event types exist, these are their schemas."
-- 3. Supports version compatibility checks: if banking v3 renames an
--    event type, Sentinel can detect and warn about the change.
-- 4. Prevents domain modules from silently colliding — two domains
--    can't register the same name.
--
-- DESIGN: Registry is in-memory, not persisted. Every domain re-registers
-- on every server start. This is correct: domains' registration is part
-- of their startup, and the DB shouldn't disagree with what's actually
-- loaded. The DB events table holds HISTORICAL events from domains
-- that may or may not still be loaded; the registry holds ACTIVE
-- registrations.
--
-- Dependencies: server/logger.lua, shared/enums.lua, shared/utils.lua,
--               shared/constants.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Registry = {}

local Registry = BSD.Sentinel.Registry
local Logger = BSD.Sentinel.Logger
local Enums = BSD.Sentinel.Enums
local Utils = BSD.Sentinel.Utils
local Constants = BSD.Sentinel.Constants


-- =============================================================================
-- INTERNAL STATE
-- =============================================================================

-- domain name -> domain record
--   {
--     name, display_name, version, registered_at,
--     event_types = { type -> event_type_record },
--     reconciliation = {...} | nil,
--   }
local domains = {}

-- Count of auto-registered event types (dev mode). Reported at startup
-- summary for operator visibility.
local autoRegisteredCount = 0


-- =============================================================================
-- INTERNAL: VALIDATION HELPERS
-- =============================================================================


--- Check that a domain name follows the convention.
-- Must be:
--   - non-empty string
--   - 2-50 characters
--   - lowercase letters, digits, underscores only
--   - starts with a letter
--   - no uppercase, no hyphens, no spaces
---@param name any
---@return boolean ok
---@return string|nil reason
local function validateDomainName(name)
    if type(name) ~= 'string' or #name == 0 then
        return false, 'must be a non-empty string'
    end
    if #name < 2 or #name > 50 then
        return false, string.format('must be 2-50 characters (got %d)', #name)
    end
    if not name:match('^[a-z][a-z0-9_]*$') then
        return false,
            'must start with a lowercase letter and contain only lowercase letters, ' ..
            'digits, and underscores (no hyphens, no uppercase, no spaces)'
    end
    return true
end


--- Check that an event type name follows the convention.
-- Same rules as domain name but may contain dots for namespacing, e.g.
-- 'transfer.completed' or 'pin.failed'.
---@param typeName any
---@return boolean ok
---@return string|nil reason
local function validateEventTypeName(typeName)
    if type(typeName) ~= 'string' or #typeName == 0 then
        return false, 'must be a non-empty string'
    end
    if #typeName > Constants.MAX_EVENT_TYPE_LENGTH then
        return false, string.format(
            'too long (max %d chars, got %d)',
            Constants.MAX_EVENT_TYPE_LENGTH, #typeName
        )
    end
    -- Allow letters, digits, underscores, dots. Must start with letter.
    if not typeName:match('^[a-z][a-z0-9_%.]*$') then
        return false,
            'must start with a lowercase letter and contain only lowercase letters, ' ..
            'digits, underscores, and dots'
    end
    -- No leading or trailing dots, no consecutive dots
    if typeName:find('%.%.') then
        return false, 'must not contain consecutive dots'
    end
    if typeName:sub(-1) == '.' then
        return false, 'must not end with a dot'
    end
    return true
end


-- =============================================================================
-- PUBLIC: REGISTER DOMAIN
-- =============================================================================


--- Register a BSD domain module with Sentinel.
-- Called once per domain, at the domain's resource startup.
-- Idempotent by name: re-registering the same domain name updates the
-- display name and version without clearing event type registrations.
---@param info table { name, display_name, version }
---@return boolean ok
---@return string|nil err
function Registry.RegisterDomain(info)
    if type(info) ~= 'table' then
        Logger.Critical('RegisterDomain: info must be a table')
        return false, 'info must be a table'
    end

    local ok, err = validateDomainName(info.name)
    if not ok then
        Logger.Critical('RegisterDomain: invalid name "%s" — %s',
            tostring(info.name), err)
        return false, err
    end

    ok, err = Utils.CheckStringLength(
        info.display_name or info.name, 100, 'display_name'
    )
    if not ok then
        Logger.Critical('RegisterDomain: %s', err)
        return false, err
    end

    ok, err = Utils.CheckNonEmptyString(
        info.version or 'unknown', 'version'
    )
    if not ok then
        Logger.Critical('RegisterDomain: %s', err)
        return false, err
    end

    local existing = domains[info.name]
    if existing then
        -- Re-registration: update metadata but preserve event types.
        existing.display_name = info.display_name or info.name
        existing.version = info.version or 'unknown'
        existing.registered_at = os.time()
        Logger.Debug('Domain "%s" re-registered (v%s)',
            info.name, existing.version)
        return true
    end

    domains[info.name] = {
        name = info.name,
        display_name = info.display_name or info.name,
        version = info.version or 'unknown',
        registered_at = os.time(),
        event_types = {},
        reconciliation = nil,
    }
    Logger.Info('Domain "%s" registered (v%s)',
        info.name, info.version or 'unknown')
    return true
end


-- =============================================================================
-- PUBLIC: REGISTER EVENT TYPE
-- =============================================================================


--- Register an event type under a domain.
-- Domain must already be registered via RegisterDomain, or the call fails.
-- Re-registering the same domain+type is idempotent: updates the metadata
-- without breaking anything that already referenced the type.
---@param info table { domain, type, category, default_severity, description, required_fields }
---@return boolean ok
---@return string|nil err
function Registry.RegisterEventType(info)
    if type(info) ~= 'table' then
        return false, 'info must be a table'
    end

    -- Domain must be registered.
    if not info.domain or not domains[info.domain] then
        local err = string.format(
            'RegisterEventType: domain "%s" is not registered. ' ..
            'Call RegisterDomain first.',
            tostring(info.domain)
        )
        Logger.Critical(err)
        return false, err
    end

    -- Event type name validation.
    local ok, err = validateEventTypeName(info.type)
    if not ok then
        Logger.Critical(
            'RegisterEventType: invalid type name "%s" for domain "%s" — %s',
            tostring(info.type), info.domain, err
        )
        return false, err
    end

    -- Category must be a valid event category.
    if not Enums.IsValidEventCategory(info.category) then
        local reason = string.format(
            'invalid category "%s"; must be one of mutation/query/auth/admin/system',
            tostring(info.category)
        )
        Logger.Critical(
            'RegisterEventType: %s.%s — %s',
            info.domain, info.type, reason
        )
        return false, reason
    end

    -- Default severity must be valid.
    if not Enums.IsValidSeverity(info.default_severity) then
        local reason = string.format(
            'invalid default_severity "%s"; must be one of debug/info/warning/critical',
            tostring(info.default_severity)
        )
        Logger.Critical(
            'RegisterEventType: %s.%s — %s',
            info.domain, info.type, reason
        )
        return false, reason
    end

    -- Description is optional but should be a string if provided.
    local description = info.description or ''
    if type(description) ~= 'string' then
        description = tostring(description)
    end
    if #description > 500 then
        description = description:sub(1, 497) .. '...'
    end

    -- required_fields is an optional array of strings.
    local requiredFields = {}
    if info.required_fields ~= nil then
        if type(info.required_fields) ~= 'table' then
            local reason = 'required_fields must be an array of strings'
            Logger.Critical('RegisterEventType: %s.%s — %s',
                info.domain, info.type, reason)
            return false, reason
        end
        for i, field in ipairs(info.required_fields) do
            if type(field) ~= 'string' or #field == 0 then
                local reason = string.format(
                    'required_fields[%d] must be a non-empty string', i
                )
                Logger.Critical('RegisterEventType: %s.%s — %s',
                    info.domain, info.type, reason)
                return false, reason
            end
            requiredFields[i] = field
        end
    end

    local domain = domains[info.domain]
    local existed = domain.event_types[info.type] ~= nil

    domain.event_types[info.type] = {
        type = info.type,
        category = info.category,
        default_severity = info.default_severity,
        description = description,
        required_fields = requiredFields,
        registered_at = os.time(),
        auto_registered = false,
    }

    if existed then
        Logger.Debug('Event type %s.%s re-registered',
            info.domain, info.type)
    else
        Logger.Debug('Event type %s.%s registered (category=%s, default_severity=%s)',
            info.domain, info.type, info.category, info.default_severity)
    end

    return true
end


-- =============================================================================
-- PUBLIC: REGISTER RECONCILIATION CALLBACK
-- =============================================================================


--- Register a reconciliation callback for a domain.
-- Sentinel's reconciliation system (coming in a later batch) invokes
-- this callback on a schedule (default every 6 hours, configurable) so
-- the domain can check its own data integrity.
---@param info table { domain, interval_hours (optional), handler }
---@return boolean ok
---@return string|nil err
function Registry.RegisterReconciliation(info)
    if type(info) ~= 'table' then
        return false, 'info must be a table'
    end
    if not info.domain or not domains[info.domain] then
        local err = string.format(
            'RegisterReconciliation: domain "%s" is not registered',
            tostring(info.domain)
        )
        Logger.Critical(err)
        return false, err
    end
    if type(info.handler) ~= 'function' then
        local err = 'RegisterReconciliation: handler must be a function'
        Logger.Critical(err)
        return false, err
    end
    if info.interval_hours ~= nil
        and (type(info.interval_hours) ~= 'number' or info.interval_hours <= 0) then
        local err = 'RegisterReconciliation: interval_hours must be a positive number'
        Logger.Critical(err)
        return false, err
    end

    domains[info.domain].reconciliation = {
        handler = info.handler,
        interval_hours = info.interval_hours
            or Constants.DEFAULT_RECONCILIATION_INTERVAL_HOURS,
        registered_at = os.time(),
        last_run_at = nil,
        last_success = nil,
    }

    Logger.Info('Reconciliation callback registered for domain "%s" (every %dh)',
        info.domain,
        domains[info.domain].reconciliation.interval_hours)
    return true
end


-- =============================================================================
-- PUBLIC: LOOKUP FUNCTIONS
-- =============================================================================


--- Check whether a domain is registered.
---@param domainName string
---@return boolean
function Registry.HasDomain(domainName)
    return domains[domainName] ~= nil
end


--- Check whether a specific event type is registered under a specific domain.
---@param domainName string
---@param eventType string
---@return boolean
function Registry.HasEventType(domainName, eventType)
    local d = domains[domainName]
    if not d then return false end
    return d.event_types[eventType] ~= nil
end


--- Get the full record for an event type, or nil if unknown.
-- Returns a shallow copy so callers can't mutate internal state.
---@param domainName string
---@param eventType string
---@return table|nil
function Registry.GetEventType(domainName, eventType)
    local d = domains[domainName]
    if not d then return nil end
    local et = d.event_types[eventType]
    if not et then return nil end
    return Utils.ShallowCopy(et)
end


--- Auto-register an event type. Called by the ingestion layer when it
-- encounters an unknown event type and dev mode is enabled. Logs a
-- warning so operators notice and can register properly.
---@param domainName string
---@param eventType string
---@param category string (from the incoming event)
---@param severity string (from the incoming event)
---@return boolean ok
function Registry.AutoRegisterEventType(domainName, eventType, category, severity)
    -- Ensure domain exists (auto-register it too)
    if not domains[domainName] then
        local ok, err = validateDomainName(domainName)
        if not ok then
            Logger.Critical(
                'AutoRegisterEventType: refusing to auto-register domain with invalid name "%s" — %s',
                tostring(domainName), err
            )
            return false
        end
        domains[domainName] = {
            name = domainName,
            display_name = domainName,
            version = 'auto',
            registered_at = os.time(),
            event_types = {},
            reconciliation = nil,
        }
        autoRegisteredCount = autoRegisteredCount + 1
        Logger.Warning(
            'Auto-registered domain "%s" (dev mode). Add explicit RegisterDomain call.',
            domainName
        )
    end

    local ok, err = validateEventTypeName(eventType)
    if not ok then
        Logger.Critical(
            'AutoRegisterEventType: refusing to auto-register invalid event type "%s.%s" — %s',
            domainName, tostring(eventType), err
        )
        return false
    end

    -- Use the incoming category/severity; fall back to defaults if invalid
    if not Enums.IsValidEventCategory(category) then
        category = Enums.EventCategory.SYSTEM
    end
    if not Enums.IsValidSeverity(severity) then
        severity = Enums.Severity.INFO
    end

    domains[domainName].event_types[eventType] = {
        type = eventType,
        category = category,
        default_severity = severity,
        description = '(auto-registered in dev mode)',
        required_fields = {},
        registered_at = os.time(),
        auto_registered = true,
    }
    autoRegisteredCount = autoRegisteredCount + 1

    Logger.Warning(
        'Auto-registered event type %s.%s (dev mode). ' ..
        'Add explicit RegisterEventType call for production.',
        domainName, eventType
    )
    return true
end


-- =============================================================================
-- PUBLIC: ENUMERATION
-- =============================================================================


--- List all registered domains with summary info.
-- Used by admin commands like /bsddomains.
---@return table
function Registry.ListDomains()
    local list = {}
    for _, d in pairs(domains) do
        list[#list + 1] = {
            name = d.name,
            display_name = d.display_name,
            version = d.version,
            registered_at = d.registered_at,
            event_type_count = Utils.Count(d.event_types),
            has_reconciliation = d.reconciliation ~= nil,
        }
    end
    -- Sort by name for stable output
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end


--- List all event types for a specific domain.
---@param domainName string
---@return table|nil
function Registry.ListEventTypes(domainName)
    local d = domains[domainName]
    if not d then return nil end
    local list = {}
    for _, et in pairs(d.event_types) do
        list[#list + 1] = Utils.ShallowCopy(et)
    end
    table.sort(list, function(a, b) return a.type < b.type end)
    return list
end


--- Get summary statistics for the registry.
-- Used by startup summary and /bsdhealth.
---@return table
function Registry.Stats()
    local totalEventTypes = 0
    local reconcilableCount = 0
    for _, d in pairs(domains) do
        totalEventTypes = totalEventTypes + Utils.Count(d.event_types)
        if d.reconciliation then
            reconcilableCount = reconcilableCount + 1
        end
    end
    return {
        domain_count = Utils.Count(domains),
        event_type_count = totalEventTypes,
        reconcilable_domain_count = reconcilableCount,
        auto_registered_count = autoRegisteredCount,
    }
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Registry loaded (awaiting domain registrations)')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Registry.RegisterDomain) == 'function', 'Registry.RegisterDomain not defined')
assert(type(Registry.RegisterEventType) == 'function', 'Registry.RegisterEventType not defined')
assert(type(Registry.HasDomain) == 'function', 'Registry.HasDomain not defined')
assert(type(Registry.Stats) == 'function', 'Registry.Stats not defined')