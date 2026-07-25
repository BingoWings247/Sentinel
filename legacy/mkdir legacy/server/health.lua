-- =============================================================================
-- bsd_sentinel / server / health.lua
-- =============================================================================
-- Domain module health evaluation.
--
-- Answers the question "are my registered BSD domains actually working?"
-- For each domain registered via RegisterDomain, health computes one of the
-- four DomainStatus values (see shared/enums.lua):
--
--   ALIVE       - emitting events recently, failure rate within tolerance.
--   SILENT      - registered, has emitted before, but nothing recently.
--                 Possibly broken, possibly just idle.
--   ERRORING    - emitting, but an elevated share of recent events are
--                 'failed' status. Something is going wrong inside it.
--   NEVER_SEEN  - registered (or expected) but has never emitted anything.
--                 Usually means it crashed at startup.
--
-- DESIGN: Status is computed ON DEMAND, never stored. Admin commands like
-- /bsdhealth call Health.Snapshot() and get a fresh evaluation. A persistent
-- status column would require constant updates as events arrive; computing
-- from the event log when asked is the correct tradeoff for a forensic system
-- whose source of truth is already the event log.
--
-- DESIGN: This module READS ONLY. It is a consumer of the query layer. It
-- does not emit events, does not write, does not act. (A future, optional
-- scheduled "health watch" that EMITS a sentinel event when a domain turns
-- unhealthy can be layered on top via the scheduler — deliberately kept out
-- of this module to preserve its read-only nature.)
--
-- NOTE ON EVENT-DRIVEN DOMAINS: Some domains only emit when something notable
-- happens (Sentinel's own 'sentinel' observability domain only emits on a
-- hitch, a pool spike, etc.). For those, silence is HEALTHY, not a fault, so
-- they are exempted from the silent/never_seen downgrade below.
--
-- Dependencies: server/logger.lua, server/registry.lua, server/query.lua,
--               shared/enums.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Health = {}

local Health = BSD.Sentinel.Health
local Logger = BSD.Sentinel.Logger
local Registry = BSD.Sentinel.Registry
local Enums = BSD.Sentinel.Enums


-- How many recent events to sample per domain when measuring failure rate.
-- Capped at the query layer's MAX_LIMIT (100). "Of this domain's last N
-- events, what fraction failed?" is the erroring signal.
local SAMPLE_SIZE = 100

-- Domains for which silence is normal (event-driven, not heartbeat-driven).
-- Status evaluation will not downgrade these to silent / never_seen.
local EVENT_DRIVEN = {
    sentinel = true,
}


-- =============================================================================
-- CONFIG (ARCH Rule 2: documented defaults fill in for missing/invalid)
-- =============================================================================


--- Read health thresholds, substituting defaults for missing/invalid values.
---@return table { silentThresholdSeconds, erroringThresholdPercent }
local function readConfig()
    local c = (Config and Config.Health) or {}

    local silent = tonumber(c.SilentThresholdSeconds)
    if not silent or silent <= 0 then silent = 900 end

    local erroring = tonumber(c.ErroringThresholdPercent)
    if not erroring or erroring < 0 or erroring > 100 then erroring = 20 end

    return {
        silentThresholdSeconds = math.floor(silent),
        erroringThresholdPercent = erroring,
    }
end


-- =============================================================================
-- INTERNAL: TIMESTAMP HELPERS
-- =============================================================================


--- Produce a "since" timestamp string for comparison against created_at.
-- created_at is a TIMESTAMP(6) the query layer returns as a string of the
-- form 'YYYY-MM-DD HH:MM:SS[.ffffff]'. That format is lexicographically
-- ordered, so a plain string comparison against this prefix is valid and
-- avoids parsing the DB value back into a number. Uses the same OS clock
-- that Utils.NowMysqlTimestamp() uses to write created_at, so they align.
---@param secondsAgo integer
---@return string
local function sinceTimestamp(secondsAgo)
    return os.date('%Y-%m-%d %H:%M:%S', os.time() - secondsAgo)
end


-- =============================================================================
-- INTERNAL: EVALUATE FAILURE RATE OVER A SAMPLE
-- =============================================================================


--- Count failed events in a sample and return (failedCount, failedPercent).
---@param events table list of shaped event tables
---@return integer failedCount
---@return number failedPercent
local function failureRate(events)
    local total = #events
    if total == 0 then return 0, 0 end

    local failed = 0
    for _, ev in ipairs(events) do
        if ev.status == Enums.EventStatus.FAILED then
            failed = failed + 1
        end
    end
    return failed, (failed / total) * 100
end


-- =============================================================================
-- PUBLIC: EVALUATE ONE DOMAIN
-- =============================================================================


--- Compute the current health status of a single domain.
---@param domainName string
---@param displayName string|nil optional, for the result
---@return table result { domain, display_name, status, sample_size,
---                        failed_count, failed_percent, last_event_at, reason }
function Health.Evaluate(domainName, displayName)
    local Query = BSD.Sentinel.Query
    local cfg = readConfig()

    local result = {
        domain = domainName,
        display_name = displayName or domainName,
        status = Enums.DomainStatus.NEVER_SEEN,
        sample_size = 0,
        failed_count = 0,
        failed_percent = 0,
        last_event_at = nil,
        reason = '',
    }

    if not Query or type(Query.Find) ~= 'function' then
        result.reason = 'query layer unavailable'
        return result
    end

    -- Most recent events for this domain (newest first).
    local found = Query.Find(
        { domain = domainName },
        { limit = SAMPLE_SIZE, order = 'desc' }
    )
    local events = (type(found) == 'table' and found.events) or {}

    result.sample_size = #events

    -- NEVER_SEEN: nothing in the log at all.
    if #events == 0 then
        if EVENT_DRIVEN[domainName] then
            result.status = Enums.DomainStatus.ALIVE
            result.reason = 'event-driven domain; no events is normal'
        else
            result.status = Enums.DomainStatus.NEVER_SEEN
            result.reason = 'registered but has never emitted an event'
        end
        return result
    end

    local last = events[1]
    result.last_event_at = last and last.created_at or nil

    -- SILENT: has emitted historically, but nothing within the window.
    local since = sinceTimestamp(cfg.silentThresholdSeconds)
    local lastAt = result.last_event_at
    local isRecent = (type(lastAt) == 'string') and (lastAt >= since)

    if not isRecent then
        if EVENT_DRIVEN[domainName] then
            result.status = Enums.DomainStatus.ALIVE
            result.reason = 'event-driven domain; silence is normal'
        else
            result.status = Enums.DomainStatus.SILENT
            result.reason = string.format(
                'no events in the last %ds (last seen %s)',
                cfg.silentThresholdSeconds, tostring(lastAt)
            )
        end
        return result
    end

    -- ERRORING: emitting recently, but too many recent events failed.
    local failedCount, failedPercent = failureRate(events)
    result.failed_count = failedCount
    result.failed_percent = failedPercent

    if failedPercent > cfg.erroringThresholdPercent then
        result.status = Enums.DomainStatus.ERRORING
        result.reason = string.format(
            '%.0f%% of last %d events failed (threshold %d%%)',
            failedPercent, #events, cfg.erroringThresholdPercent
        )
        return result
    end

    -- ALIVE: recent activity, failure rate within tolerance.
    result.status = Enums.DomainStatus.ALIVE
    result.reason = string.format(
        'emitting normally (%d recent events, %.0f%% failed)',
        #events, failedPercent
    )
    return result
end


-- =============================================================================
-- PUBLIC: SNAPSHOT (ALL DOMAINS)
-- =============================================================================


--- Evaluate every registered domain. Used by /bsdhealth.
---@return table { evaluated_at, domains = {...}, summary = {...} }
function Health.Snapshot()
    local domains = Registry.ListDomains() or {}

    local list = {}
    local summary = {
        alive = 0,
        silent = 0,
        erroring = 0,
        never_seen = 0,
        total = 0,
    }

    for _, d in ipairs(domains) do
        local r = Health.Evaluate(d.name, d.display_name)
        list[#list + 1] = r
        summary.total = summary.total + 1

        if r.status == Enums.DomainStatus.ALIVE then
            summary.alive = summary.alive + 1
        elseif r.status == Enums.DomainStatus.SILENT then
            summary.silent = summary.silent + 1
        elseif r.status == Enums.DomainStatus.ERRORING then
            summary.erroring = summary.erroring + 1
        elseif r.status == Enums.DomainStatus.NEVER_SEEN then
            summary.never_seen = summary.never_seen + 1
        end
    end

    -- Stable ordering: unhealthy first (so /bsdhealth surfaces problems at
    -- the top), then alphabetical within each status.
    local rank = {
        [Enums.DomainStatus.ERRORING]   = 1,
        [Enums.DomainStatus.NEVER_SEEN] = 2,
        [Enums.DomainStatus.SILENT]     = 3,
        [Enums.DomainStatus.ALIVE]      = 4,
    }
    table.sort(list, function(a, b)
        local ra, rb = rank[a.status] or 9, rank[b.status] or 9
        if ra ~= rb then return ra < rb end
        return a.domain < b.domain
    end)

    return {
        evaluated_at = os.time(),
        domains = list,
        summary = summary,
    }
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

local cfg = readConfig()
Logger.Info('Health loaded (silent>%ds, erroring>%d%%)',
    cfg.silentThresholdSeconds, cfg.erroringThresholdPercent)


-- =============================================================================
-- MODULE VERIFICATION
-- =============================================================================

assert(type(Health.Evaluate) == 'function', 'Health.Evaluate not defined')
assert(type(Health.Snapshot) == 'function', 'Health.Snapshot not defined')