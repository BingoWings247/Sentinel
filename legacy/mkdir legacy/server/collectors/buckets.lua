-- =============================================================================
-- bsd_sentinel / server / collectors / buckets.lua
-- =============================================================================
-- Routing-bucket collector.
--
-- WHAT IT DOES: on a periodic sweep, reads every connected player's routing
-- bucket and flags players STRANDED in a non-zero bucket past a threshold.
-- This is the classic orphaned-instance bug — a mission/apartment script moved
-- a player into bucket N, then errored or stopped before moving them back to 0,
-- leaving them alone in an empty world wondering why the server looks dead.
--
-- WHAT IT DOES NOT DO: it does not know the *intended* bucket logic of a
-- foreign script (it can't tell that bucket 5 was "supposed" to be a 10-minute
-- heist), so detection is threshold-based. And it never moves a player itself —
-- it reports the stranding; pulling them back to bucket 0 is the operator's or
-- another resource's call. Observe, don't act.
--
-- ONLY EMITS ON A PROBLEM: a routine "bucket population" event every sweep
-- would be high-volume, low-value noise. So this collector stays silent until
-- it actually finds a stranded player.
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

local EVENT_TYPE = 'bucket_stranded'
local TASK_NAME = 'sentinel_bucket_sweep'


-- =============================================================================
-- CONFIG (ARCH Rule 2)
-- =============================================================================

local function pos(v, d)
    v = tonumber(v)
    if not v or v <= 0 then return d end
    return math.floor(v)
end

local function readConfig()
    local c = (Config and Config.Collectors and Config.Collectors.Buckets) or {}
    return {
        enabled                = (c.Enabled ~= false),
        intervalSeconds        = pos(c.IntervalSeconds, 60),
        strandedThresholdSecs  = pos(c.StrandedThresholdSeconds, 600),  -- 10 min
        reEmitCooldownSecs     = pos(c.ReEmitCooldownSeconds, 1800),    -- 30 min
    }
end

local settings = readConfig()
local running = false
local emitDomain = 'sentinel'

-- Per-player tracking, keyed by source id.
local strandedSince = {}  -- src -> epoch when first seen in current non-zero bucket
local lastEmitAt = {}     -- src -> epoch of last stranded emit (cooldown)


-- =============================================================================
-- INTERNAL
-- =============================================================================

--- Best-effort stable identifier for the player (license, else source tag).
local function playerSubjectId(src)
    if type(GetPlayerIdentifierByType) == 'function' then
        local lic = GetPlayerIdentifierByType(src, 'license')
        if type(lic) == 'string' and #lic > 0 then return lic end
    end
    return 'source:' .. tostring(src)
end


local function sweep()
    if not running then return end
    if type(GetPlayers) ~= 'function' or type(GetPlayerRoutingBucket) ~= 'function' then
        return
    end

    local now = os.time()
    local present = {}

    for _, idStr in ipairs(GetPlayers()) do
        local src = tonumber(idStr)
        if src then
            present[src] = true
            local bucket = GetPlayerRoutingBucket(src)

            if bucket and bucket ~= 0 then
                if not strandedSince[src] then
                    strandedSince[src] = now
                end

                local duration = now - strandedSince[src]
                local cooledDown = (now - (lastEmitAt[src] or 0)) >= settings.reEmitCooldownSecs

                if duration >= settings.strandedThresholdSecs and cooledDown then
                    local name = (type(GetPlayerName) == 'function' and GetPlayerName(src)) or ('player ' .. src)
                    Ingestion.Emit({
                        domain = emitDomain,
                        type = EVENT_TYPE,
                        category = Enums.EventCategory.SYSTEM,
                        severity = Enums.Severity.WARNING,
                        status = Enums.EventStatus.COMPLETED,
                        actor_type = Enums.ActorType.SCHEDULED,
                        actor_identifier = 'sentinel_bucket_monitor',
                        subject_type = 'player',
                        subject_id = playerSubjectId(src),
                        amount = duration,
                        amount_unit = 'seconds',
                        summary = string.format(
                            'Player "%s" stranded in routing bucket %d for %ds (likely orphaned instance)',
                            name, bucket, duration
                        ),
                        metadata = {
                            player_name = name,
                            source = src,
                            bucket = bucket,
                            seconds_in_bucket = duration,
                        },
                    })
                    lastEmitAt[src] = now
                end
            else
                -- Back in the default bucket: clear tracking.
                strandedSince[src] = nil
                lastEmitAt[src] = nil
            end
        end
    end

    -- Forget players who have since disconnected.
    for src in pairs(strandedSince) do
        if not present[src] then strandedSince[src] = nil; lastEmitAt[src] = nil end
    end
end


-- =============================================================================
-- COLLECTOR
-- =============================================================================

local collector = { name = 'buckets', enabled = settings.enabled }

function collector.register(domain)
    emitDomain = domain or emitDomain
    local ok, err = Registry.RegisterEventType({
        domain = emitDomain,
        type = EVENT_TYPE,
        category = Enums.EventCategory.SYSTEM,
        default_severity = Enums.Severity.WARNING,
        description = 'A player has been stranded in a non-zero routing bucket past the threshold (likely orphaned instance).',
        required_fields = { 'bucket', 'seconds_in_bucket' },
    })
    if not ok then
        Logger.Critical('Collector "buckets": could not register event type: %s', tostring(err))
    end
end

function collector.start()
    running = true
    Scheduler.Register({
        name = TASK_NAME,
        intervalSeconds = settings.intervalSeconds,
        initialDelaySeconds = settings.intervalSeconds,
        handler = sweep,
    })
    Logger.Info('Collector "buckets": sweeping every %ds (stranded after %ds)',
        settings.intervalSeconds, settings.strandedThresholdSecs)
end

function collector.stop()
    running = false
    Logger.Info('Collector "buckets": stopped')
end

BSD.Sentinel.Collectors.list[#BSD.Sentinel.Collectors.list + 1] = collector

if Logger then
    Logger.Info('Collector "buckets" loaded (%s)', collector.enabled and 'enabled' or 'disabled')
end