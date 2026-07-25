-- =============================================================================
-- bsd_sentinel / server / exports.lua
-- =============================================================================
-- Public API surface. Every export other resources can call.
--
-- DESIGN NOTE (v1.0.0-dev fix): Module references are resolved LAZILY.
-- Previously this file captured module references at load time:
--     local Main = BSD.Sentinel.Main   -- BROKEN if Main hasn't loaded yet
-- That failed because exports.lua loads before main.lua in the fxmanifest
-- order, so BSD.Sentinel.Main was nil at capture time and stayed nil forever.
--
-- The fix: don't capture at load time. Reference BSD.Sentinel.ModuleName
-- directly inside each export function, so the lookup happens at CALL time
-- when everything is loaded.
--
-- Dependencies: every public-facing subsystem module (lazily resolved)
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Exports = {}

local Exports = BSD.Sentinel.Exports

-- Only Logger and Constants are safe to capture at load time because they
-- load before this file in the fxmanifest order. Everything else must be
-- resolved lazily.
local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants


-- =============================================================================
-- INTERNAL: READY CHECK
-- =============================================================================


--- Check that Sentinel is ready for traffic. Returns false safely if not.
-- Uses lazy lookup for Main to avoid load-order issues.
---@param exportName string
---@return boolean ready
local function ensureReady(exportName)
    local Main = BSD.Sentinel.Main
    if not Main or not Main.IsReady() then
        if Logger then
            Logger.Warning(
                'export %s called but Sentinel is not ready; no-op',
                exportName
            )
        end
        return false
    end
    return true
end


-- =============================================================================
-- DOMAIN & EVENT TYPE REGISTRATION
-- =============================================================================


--- Register a BSD domain.
function Exports.RegisterDomain(info)
    if not ensureReady('RegisterDomain') then
        return false, 'Sentinel not ready'
    end
    return BSD.Sentinel.Registry.RegisterDomain(info)
end


--- Register an event type under a domain.
function Exports.RegisterEventType(info)
    if not ensureReady('RegisterEventType') then
        return false, 'Sentinel not ready'
    end
    return BSD.Sentinel.Registry.RegisterEventType(info)
end


--- Register a reconciliation callback for a domain.
function Exports.RegisterReconciliation(info)
    if not ensureReady('RegisterReconciliation') then
        return false, 'Sentinel not ready'
    end
    return BSD.Sentinel.Registry.RegisterReconciliation(info)
end


-- =============================================================================
-- EVENT EMISSION
-- =============================================================================


--- Emit an event. The core export.
function Exports.Emit(emit)
    if not ensureReady('Emit') then
        return false, nil, 'Sentinel not ready'
    end
    return BSD.Sentinel.Ingestion.Emit(emit)
end


-- =============================================================================
-- CORRELATION HELPERS
-- =============================================================================


--- Generate a new correlation ID.
-- Does not require Sentinel to be fully ready — pure utility function.
function Exports.NewCorrelationId()
    if BSD.Sentinel.Correlation then
        return BSD.Sentinel.Correlation.NewCorrelationId()
    end
    if BSD.Sentinel.Utils then
        return BSD.Sentinel.Utils.GenerateUUIDv7()
    end
    return '00000000-0000-7000-8000-000000000000'
end


--- Execute a function with an automatic correlation ID in context.
function Exports.WithContext(fn, correlationId, inherit)
    if BSD.Sentinel.Correlation then
        return BSD.Sentinel.Correlation.WithContext(fn, correlationId, inherit)
    end
    if type(fn) == 'function' then return fn() end
end


--- Get the currently active correlation ID, if any.
function Exports.CurrentCorrelationId()
    if BSD.Sentinel.Correlation then
        return BSD.Sentinel.Correlation.Current()
    end
    return nil
end


-- =============================================================================
-- STATUS & DIAGNOSTICS
-- =============================================================================


--- Check whether Sentinel booted successfully and is operational.
-- Lazy lookup of Main because this is the one export most likely to be
-- called very early by other resources waiting for Sentinel to come up.
function Exports.IsReady()
    local Main = BSD.Sentinel.Main
    if not Main then return false end
    return Main.IsReady()
end


--- Get Sentinel's version string.
function Exports.Version()
    if Constants and Constants.VERSION then
        return Constants.VERSION
    end
    return 'unknown'
end


--- Get ingestion statistics.
function Exports.IngestionStats()
    if not ensureReady('IngestionStats') then return {} end
    return BSD.Sentinel.Ingestion.Stats()
end


--- Get buffer statistics.
function Exports.BufferStats()
    if not ensureReady('BufferStats') then return {} end
    return BSD.Sentinel.Buffer.Stats()
end


--- Get registry statistics.
function Exports.RegistryStats()
    if not ensureReady('RegistryStats') then return {} end
    return BSD.Sentinel.Registry.Stats()
end


--- List all registered domains.
function Exports.ListDomains()
    if not ensureReady('ListDomains') then return {} end
    return BSD.Sentinel.Registry.ListDomains()
end


--- List event types for a specific domain.
function Exports.ListEventTypes(domainName)
    if not ensureReady('ListEventTypes') then return nil end
    return BSD.Sentinel.Registry.ListEventTypes(domainName)
end

-- =============================================================================
-- READ: QUERY / HEALTH / SCHEDULER  (for admin commands and the future NUI)
-- =============================================================================

--- Find events by filter. See server/query.lua for filter/option shapes.
function Exports.Query(filters, options)
    if not ensureReady('Query') then return { events = {}, count = 0 } end
    return BSD.Sentinel.Query.Find(filters, options)
end

--- Fetch a single event by event_id (UUID).
function Exports.GetEvent(eventId)
    if not ensureReady('GetEvent') then return nil, 'Sentinel not ready' end
    return BSD.Sentinel.Query.GetById(eventId)
end

--- Fetch a full correlation chain (the investigation view).
function Exports.Trace(correlationId)
    if not ensureReady('Trace') then return { events = {}, count = 0 } end
    return BSD.Sentinel.Query.Correlation(correlationId)
end

--- Aggregate event statistics (by severity, by domain, totals).
function Exports.Stats(options)
    if not ensureReady('Stats') then return {} end
    return BSD.Sentinel.Query.Stats(options)
end

--- Recent events for one actor.
function Exports.RecentByActor(actorIdentifier, limit)
    if not ensureReady('RecentByActor') then return { events = {}, count = 0 } end
    return BSD.Sentinel.Query.RecentByActor(actorIdentifier, limit)
end

--- Recent events affecting one subject.
function Exports.RecentBySubject(subjectType, subjectId, limit)
    if not ensureReady('RecentBySubject') then return { events = {}, count = 0 } end
    return BSD.Sentinel.Query.RecentBySubject(subjectType, subjectId, limit)
end

--- Full domain health snapshot.
function Exports.Health()
    if not ensureReady('Health') then return { domains = {}, summary = {} } end
    return BSD.Sentinel.Health.Snapshot()
end

--- Health of a single domain.
function Exports.HealthDomain(domainName)
    if not ensureReady('HealthDomain') then return nil end
    return BSD.Sentinel.Health.Evaluate(domainName)
end

--- Scheduler task status (includes the collector sweeps).
function Exports.SchedulerStatus()
    if not ensureReady('SchedulerStatus') then return {} end
    return BSD.Sentinel.Scheduler.Status()
end
-- =============================================================================
-- REGISTER EXPORTS WITH FIVEM
-- =============================================================================

for name, fn in pairs(Exports) do
    if type(fn) == 'function' then
        exports(name, fn)
    end
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

local exportCount = 0
for name, fn in pairs(Exports) do
    if type(fn) == 'function' then
        exportCount = exportCount + 1
    end
end
if Logger then
    Logger.Info('Exports registered (%d functions)', exportCount)
end


-- =============================================================================
-- MODULE VERIFICATION
-- =============================================================================

assert(type(Exports.Emit) == 'function', 'Exports.Emit not defined')
assert(type(Exports.RegisterDomain) == 'function', 'Exports.RegisterDomain not defined')
assert(type(Exports.IsReady) == 'function', 'Exports.IsReady not defined')