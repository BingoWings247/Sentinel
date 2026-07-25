-- =============================================================================
-- bsd_sentinel / server / collectors / native_events.lua
-- =============================================================================
-- Native game-event collector (AGGREGATE model).
--
-- WHAT IT DOES: listens to high-volume CFX server events — explosionEvent,
-- weaponDamageEvent, entityCreated, entityRemoved — but does NOT emit a
-- Sentinel event per occurrence. weaponDamageEvent alone fires on every bullet
-- and would bury the event log. Instead the handlers do nothing but increment
-- in-memory counters, and a scheduler task emits ONE 'native_activity' summary
-- per window (default 60s), then resets. One row a minute, full picture, no
-- flood. Quiet windows emit nothing at all.
--
-- RELATIONSHIP TO pools.lua: pools measures the STOCK (how many entities are
-- live right now); this measures the FLOW (how many were created/destroyed in
-- the window). Together they distinguish "lots of churn, stable count" from
-- "count climbing toward exhaustion."
--
-- OBSERVER ONLY: these are cancelable events, but this collector never cancels
-- them. It counts and lets them through. It does not judge whether activity is
-- "abnormal" — that would be anti-cheat work. It reports volume; a human reads it.
--
-- Lua on the server is single-threaded/cooperative, so incrementing counters in
-- handlers and zeroing them in the flush task needs no locking.
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

local EVENT_TYPE = 'native_activity'
local TASK_NAME = 'sentinel_native_flush'


-- =============================================================================
-- CONFIG (ARCH Rule 2)
-- =============================================================================

local function readConfig()
    local c = (Config and Config.Collectors and Config.Collectors.NativeEvents) or {}
    local interval = tonumber(c.IntervalSeconds)
    if not interval or interval <= 0 then interval = 60 end
    return {
        enabled         = (c.Enabled ~= false),
        intervalSeconds = math.floor(interval),
    }
end

local settings = readConfig()
local running = false
local emitDomain = 'sentinel'

-- Rolling counters for the current window.
local counts = {
    explosions = 0,
    weapon_damage = 0,
    entities_created = 0,
    entities_removed = 0,
}

local function resetCounts()
    counts.explosions = 0
    counts.weapon_damage = 0
    counts.entities_created = 0
    counts.entities_removed = 0
end


-- =============================================================================
-- HANDLERS (count only — keep these as cheap as possible)
-- =============================================================================

local function onExplosion()
    if running then counts.explosions = counts.explosions + 1 end
    -- no return: never cancel; we observe only
end

local function onWeaponDamage()
    if running then counts.weapon_damage = counts.weapon_damage + 1 end
end

local function onEntityCreated()
    if running then counts.entities_created = counts.entities_created + 1 end
end

local function onEntityRemoved()
    if running then counts.entities_removed = counts.entities_removed + 1 end
end


-- =============================================================================
-- FLUSH (emit one summary per window)
-- =============================================================================

local function flush()
    if not running then return end

    local total = counts.explosions + counts.weapon_damage
        + counts.entities_created + counts.entities_removed

    -- Quiet window: nothing worth a row.
    if total == 0 then return end

    -- Snapshot then reset (single-threaded; safe).
    local snap = {
        window_seconds   = settings.intervalSeconds,
        explosions       = counts.explosions,
        weapon_damage    = counts.weapon_damage,
        entities_created = counts.entities_created,
        entities_removed = counts.entities_removed,
    }
    resetCounts()

    Ingestion.Emit({
        domain = emitDomain,
        type = EVENT_TYPE,
        category = Enums.EventCategory.SYSTEM,
        severity = Enums.Severity.INFO,
        status = Enums.EventStatus.COMPLETED,
        actor_type = Enums.ActorType.SCHEDULED,
        actor_identifier = 'sentinel_native_monitor',
        summary = string.format(
            'Last %ds: %d explosions, %d weapon-damage, %d created / %d removed entities',
            snap.window_seconds, snap.explosions, snap.weapon_damage,
            snap.entities_created, snap.entities_removed
        ),
        metadata = snap,
    })
end


-- =============================================================================
-- COLLECTOR
-- =============================================================================

local collector = { name = 'native_events', enabled = settings.enabled }

function collector.register(domain)
    emitDomain = domain or emitDomain
    local ok, err = Registry.RegisterEventType({
        domain = emitDomain,
        type = EVENT_TYPE,
        category = Enums.EventCategory.SYSTEM,
        default_severity = Enums.Severity.INFO,
        description = 'Per-window rollup of native game-event volume (explosions, weapon damage, entity churn).',
        required_fields = { 'window_seconds' },
    })
    if not ok then
        Logger.Critical('Collector "native_events": could not register event type: %s', tostring(err))
    end
end

function collector.start()
    running = true
    AddEventHandler('explosionEvent', onExplosion)
    AddEventHandler('weaponDamageEvent', onWeaponDamage)
    AddEventHandler('entityCreated', onEntityCreated)
    AddEventHandler('entityRemoved', onEntityRemoved)

    Scheduler.Register({
        name = TASK_NAME,
        intervalSeconds = settings.intervalSeconds,
        initialDelaySeconds = settings.intervalSeconds,
        handler = flush,
    })
    Logger.Info('Collector "native_events": aggregating every %ds', settings.intervalSeconds)
end

function collector.stop()
    running = false
    Logger.Info('Collector "native_events": stopped')
end

BSD.Sentinel.Collectors.list[#BSD.Sentinel.Collectors.list + 1] = collector

if Logger then
    Logger.Info('Collector "native_events" loaded (%s)', collector.enabled and 'enabled' or 'disabled')
end