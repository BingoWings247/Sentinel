-- =============================================================================
-- bsd_sentinel / server / collectors / hitch.lua
-- =============================================================================
-- Server scheduler hitch detector.
--
-- WHAT IT DOES:
-- Runs a heartbeat thread that is supposed to wake every IntervalMs. It
-- measures how long the wake ACTUALLY took (via GetGameTimer, real wall time
-- on the server). When the main thread is hitching, the wake comes back late,
-- and the gap between expected and actual is the "drift." Drift past a
-- threshold means the server scheduler stalled — the leading indicator behind
-- a great many "the server froze / players rubber-banded" complaints.
--
-- WHAT IT DOES NOT DO:
-- It cannot, by itself, name which resource caused the hitch — FiveM does not
-- expose per-resource tick timing to another resource. This collector detects
-- the CONDITION reliably and timestamps it; attribution to a guilty resource
-- comes later, from correlating this event against what other collectors saw
-- in the same window (e.g. a pool-pressure spike at the same instant).
--
-- This is an OBSERVER. It records that a hitch happened. It does not, and must
-- not, try to "fix" anything.
--
-- EVENT EMITTED:
--   domain      'sentinel'
--   type        'hitch_detected'
--   category    system
--   severity    warning (drift >= WarnDriftMs) or critical (>= CriticalDriftMs)
--   actor_type  scheduled  (this is a timer, not an event-driven observation)
--   metadata    { expected_ms, actual_ms, drift_ms }
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


local EVENT_TYPE = 'hitch_detected'


-- =============================================================================
-- CONFIG (ARCH Rule 2: defaults fill in; resource always runs)
-- =============================================================================


--- Read this collector's config, substituting documented defaults for any
-- missing or invalid value. Never gatekeeps — bad input falls back and logs.
---@return table { enabled, intervalMs, warnDriftMs, criticalDriftMs }
local function readConfig()
    local c = (Config and Config.Collectors and Config.Collectors.Hitch) or {}

    local intervalMs = tonumber(c.IntervalMs)
    if not intervalMs or intervalMs < 100 then intervalMs = 1000 end

    local warnDriftMs = tonumber(c.WarnDriftMs)
    if not warnDriftMs or warnDriftMs <= 0 then warnDriftMs = 250 end

    local criticalDriftMs = tonumber(c.CriticalDriftMs)
    if not criticalDriftMs or criticalDriftMs <= 0 then criticalDriftMs = 1000 end

    -- Sanity: critical must be a worse condition than warning.
    if criticalDriftMs <= warnDriftMs then
        criticalDriftMs = warnDriftMs * 4
    end

    return {
        enabled         = (c.Enabled ~= false), -- default true
        intervalMs      = math.floor(intervalMs),
        warnDriftMs     = math.floor(warnDriftMs),
        criticalDriftMs = math.floor(criticalDriftMs),
    }
end


local settings = readConfig()
local running = false
local emitDomain = 'sentinel' -- set authoritatively by register(domain)


-- =============================================================================
-- COLLECTOR DEFINITION
-- =============================================================================

local collector = {
    name = 'hitch',
    enabled = settings.enabled,
}


--- Declare the event type this collector emits. Called once by the loader
-- before start(), after the shared domain is registered.
---@param domain string the collector domain ('sentinel')
function collector.register(domain)
    emitDomain = domain or emitDomain

    local ok, err = Registry.RegisterEventType({
        domain = emitDomain,
        type = EVENT_TYPE,
        category = Enums.EventCategory.SYSTEM,
        default_severity = Enums.Severity.WARNING,
        description = 'Server scheduler hitch: the main thread took materially '
            .. 'longer than expected between ticks.',
        required_fields = { 'expected_ms', 'actual_ms', 'drift_ms' },
    })
    if not ok then
        Logger.Critical('Collector "hitch": could not register event type %s.%s: %s',
            emitDomain, EVENT_TYPE, tostring(err))
    end
end


--- Begin watching. Spins the heartbeat thread.
function collector.start()
    -- ARCH Rule 1: report what configuration is actually in effect.
    Logger.Info(
        'Collector "hitch": monitoring (interval=%dms, warn>=%dms, critical>=%dms)',
        settings.intervalMs, settings.warnDriftMs, settings.criticalDriftMs
    )

    running = true
    Citizen.CreateThread(function()
        local last = GetGameTimer()
        while running do
            Citizen.Wait(settings.intervalMs)

            local now = GetGameTimer()
            local actual = now - last
            last = now

            local drift = actual - settings.intervalMs
            if drift >= settings.warnDriftMs then
                local severity = Enums.Severity.WARNING
                if drift >= settings.criticalDriftMs then
                    severity = Enums.Severity.CRITICAL
                end

                local ok, _, err = Ingestion.Emit({
                    domain = emitDomain,
                    type = EVENT_TYPE,
                    category = Enums.EventCategory.SYSTEM,
                    severity = severity,
                    status = Enums.EventStatus.COMPLETED,
                    actor_type = Enums.ActorType.SCHEDULED,
                    actor_identifier = 'sentinel_hitch_monitor',
                    summary = string.format(
                        'Server hitch: tick took %dms (expected ~%dms, drift %dms)',
                        actual, settings.intervalMs, drift
                    ),
                    metadata = {
                        expected_ms = settings.intervalMs,
                        actual_ms = actual,
                        drift_ms = drift,
                    },
                })

                -- ARCH Rule 5: never fail silently. If ingestion rejected the
                -- event, say so — but only at debug volume, because a hitch
                -- storm could otherwise spam the console with its own rejects.
                if not ok and err then
                    Logger.Debug('Collector "hitch": emit rejected: %s', err)
                end
            end
        end
    end)
end


--- Tear down. The heartbeat thread observes `running` and exits on next wake.
function collector.stop()
    running = false
    Logger.Info('Collector "hitch": stopped')
end


-- =============================================================================
-- SELF-REGISTER + SELF-ANNOUNCE
-- =============================================================================

BSD.Sentinel.Collectors.list[#BSD.Sentinel.Collectors.list + 1] = collector

if Logger then
    Logger.Info('Collector "hitch" loaded (%s)',
        collector.enabled and 'enabled' or 'disabled')
end