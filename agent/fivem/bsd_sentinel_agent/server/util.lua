-- =============================================================================
-- bsd_sentinel_agent / server / util.lua
-- Logging, clocks and event ids shared by every other file.
-- =============================================================================

SA = SA or {}
SA.VERSION = '0.1.1'
SA.RESOURCE = GetCurrentResourceName()

-- ---- Logging (ARCH Rule 5: every fault says what happened and what to do) ----
local PREFIX = '^5[sentinel-agent]^7 '

function SA.info(fmt, ...)  print(PREFIX .. string.format(fmt, ...)) end
function SA.warn(fmt, ...)  print(PREFIX .. '^3WARNING:^7 ' .. string.format(fmt, ...)) end
function SA.error(fmt, ...) print(PREFIX .. '^1ERROR:^7 ' .. string.format(fmt, ...)) end
function SA.debug(fmt, ...)
    if SA.debugEnabled then print(PREFIX .. '^8debug:^7 ' .. string.format(fmt, ...)) end
end

-- ---- Clock -----------------------------------------------------------------
-- os.time() has 1-second resolution; GetGameTimer() is milliseconds since the
-- server started. Anchor once and add the elapsed timer for ms epoch time.
local bootEpochMs = math.floor(os.time() * 1000)
local bootTimer = GetGameTimer()

function SA.nowMs()
    return math.floor(bootEpochMs + (GetGameTimer() - bootTimer))
end

function SA.uptimeS()
    return math.floor((GetGameTimer() - bootTimer) / 1000)
end

-- ---- Event ids: ULIDs (time-ordered, the backend's idempotency key) ---------
local CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
math.randomseed(os.time() ~ GetGameTimer())

function SA.ulid()
    local t = SA.nowMs()
    local out = {}
    for i = 10, 1, -1 do
        local d = t % 32
        out[i] = CROCKFORD:sub(d + 1, d + 1)
        t = t // 32
    end
    for i = 11, 26 do
        local d = math.random(0, 31)
        out[i] = CROCKFORD:sub(d + 1, d + 1)
    end
    return table.concat(out)
end

-- ---- Misc ------------------------------------------------------------------
function SA.trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

function SA.countStartedResources()
    local n = 0
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name and GetResourceState(name) == 'started' then n = n + 1 end
    end
    return n
end

function SA.playerCount()
    return #GetPlayers()
end
