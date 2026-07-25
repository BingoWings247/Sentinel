-- =============================================================================
-- bsd_sentinel / server / collectors / pools.lua
-- =============================================================================
-- Entity-pool pressure collector.
--
-- WHAT IT DOES: on a periodic sweep (via the shared scheduler), counts live
-- vehicles, peds, and objects on the server and emits a 'pool_pressure' event
-- when a count crosses a tunable threshold. Pool exhaustion is one of the most
-- common crash classes, and it announces itself as a climbing count before it
-- crashes — so this turns "clear your cache" into "your vehicle pool is full."
--
-- HONEST LIMIT: the server cannot read the engine's true pool ceiling, so the
-- thresholds are operator-tuned starting points, NOT the hard limit. Treat a
-- warning as "getting crowded relative to what you told me to watch for."
--
-- This is an OBSERVER: it counts and reports. It never despawns anything.
--
-- Dependencies: server/logger.lua, server/registry.lua, server/ingestion.lua,
--               server/scheduler.lua, server/collectors/loader.lua,
--               shared/enums.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Collectors = BSD.Sentinel.Collectors or {}
BSD.Sentinel.Collectors.list = BSD.Sentinel.Collectors.list or {}

local Logger = BSD.Sentinel.Logger
local Enums = BSD.Sentinel.Enums
local Registry = BSD.Sentinel.Registry
local Ingestion = BSD.Sentinel.Ingestion
local Scheduler = BSD.Sentinel.Scheduler

local EVENT_TYPE = 'pool_pressure'
local TASK_NAME = 'sentinel_pool_sweep'


-- =============================================================================
-- CONFIG (ARCH Rule 2)
-- =============================================================================

local function pos(v, d)
    v = tonumber(v)
    if not v or v <= 0 then return d end
    return math.floor(v)
end

local function readConfig()
    local c = (Config and Config.Collectors and Config.Collectors.Pools) or {}
    return {
        enabled            = (c.Enabled ~= false),
        intervalSeconds    = pos(c.IntervalSeconds, 60),
        vehicleWarn        = pos(c.VehicleWarn, 300),
        pedWarn            = pos(c.PedWarn, 300),
        objectWarn         = pos(c.ObjectWarn, 800),
        criticalMultiplier = tonumber(c.CriticalMultiplier) or 1.5,
    }
end

local settings = readConfig()
local running = false
local emitDomain = 'sentinel'
local prev = { vehicle = 0, ped = 0, object = 0 }


-- =============================================================================
-- INTERNAL
-- =============================================================================

--- Count entities from a getter native, or nil if the native is unavailable.
local function countOf(getter)
    if type(getter) ~= 'function' then return nil end
    local ok, list = pcall(getter)
    if ok and type(list) == 'table' then return #list end
    return nil
end


--- Evaluate one pool and emit if it is over its warn threshold.
local function checkPool(label, current, warn)
    if current == nil then return end
    local delta = current - (prev[label] or 0)
    prev[label] = current

    if current < warn then return end

    local severity = Enums.Severity.WARNING
    if current >= math.floor(warn * settings.criticalMultiplier) then
        severity = Enums.Severity.CRITICAL
    end

    Ingestion.Emit({
        domain = emitDomain,
        type = EVENT_TYPE,
        category = Enums.EventCategory.SYSTEM,
        severity = severity,
        status = Enums.EventStatus.COMPLETED,
        actor_type = Enums.ActorType.SCHEDULED,
        actor_identifier = 'sentinel_pool_monitor',
        subject_type = 'pool',
        subject_id = label,
        amount = current,
        amount_unit = 'entities',
        summary = string.format(
            '%s pool pressure: %d live (warn %d, %+d since last sweep)',
            label, current, warn, delta
        ),
        metadata = {
            pool = label,
            count = current,
            warn_threshold = warn,
            delta = delta,
        },
    })
end


local function sweep()
    if not running then return end
    checkPool('vehicle', countOf(GetAllVehicles), settings.vehicleWarn)
    checkPool('ped',     countOf(GetAllPeds),     settings.pedWarn)
    checkPool('object',  countOf(GetAllObjects),  settings.objectWarn)
end


-- =============================================================================
-- COLLECTOR
-- =============================================================================

local collector = { name = 'pools', enabled = settings.enabled }

function collector.register(domain)
    emitDomain = domain or emitDomain
    local ok, err = Registry.RegisterEventType({
        domain = emitDomain,
        type = EVENT_TYPE,
        category = Enums.EventCategory.SYSTEM,
        default_severity = Enums.Severity.WARNING,
        description = 'Entity pool (vehicle/ped/object) count crossed a tunable pressure threshold.',
        required_fields = { 'pool', 'count', 'warn_threshold' },
    })
    if not ok then
        Logger.Critical('Collector "pools": could not register event type: %s', tostring(err))
    end
end

function collector.start()
    -- ARCH Rule 5: if the natives aren't present, say so loudly rather than
    -- silently watching nothing.
    if type(GetAllVehicles) ~= 'function' then
        Logger.Warning('Collector "pools": GetAllVehicles native unavailable; '
            .. 'pool counts may be incomplete on this artifact.')
    end

    running = true
    Scheduler.Register({
        name = TASK_NAME,
        intervalSeconds = settings.intervalSeconds,
        initialDelaySeconds = settings.intervalSeconds,
        handler = sweep,
    })
    Logger.Info('Collector "pools": sweeping every %ds (warn v=%d p=%d o=%d)',
        settings.intervalSeconds, settings.vehicleWarn, settings.pedWarn, settings.objectWarn)
end

function collector.stop()
    running = false
    Logger.Info('Collector "pools": stopped')
end

BSD.Sentinel.Collectors.list[#BSD.Sentinel.Collectors.list + 1] = collector

if Logger then
    Logger.Info('Collector "pools" loaded (%s)', collector.enabled and 'enabled' or 'disabled')
end