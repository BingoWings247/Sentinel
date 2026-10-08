-- =============================================================================
-- bsd_sentinel_agent / server / collectors.lua
-- What the agent watches on any FiveM server, with no framework needed:
--   player.join / player.drop   who came and went (pseudonymous), and why
--   server.resource              resource starts and stops, crash-loop flag
--   server.hitch                 the server thread stalling
-- Ported from the legacy bsd_sentinel collectors. Observers only: nothing here
-- ever changes game state.
-- =============================================================================

SA = SA or {}

local sessions = {}   -- server id -> { name, pid, joinedAt }

-- ---- Players ---------------------------------------------------------------------

local function identityOf(src)
    local ids = GetPlayerIdentifiers(src) or {}
    local license = GetPlayerIdentifierByType(src, 'license')
    local stable = {}
    for _, id in ipairs(ids) do
        if not id:match('^ip:') then stable[#stable + 1] = id end
    end
    table.sort(stable)
    local primary = license or stable[1] or ('name:' .. tostring(GetPlayerName(src)))
    return SA.pseudonym(primary), (#stable > 0) and SA.pseudonym(table.concat(stable, '|')) or nil
end

local function onJoining()
    local src = source
    local name = GetPlayerName(src) or 'unknown'
    local pid, idsHash = identityOf(src)
    sessions[src] = { name = name, pid = pid, joinedAt = os.time() }
    SA.emit('player.join', { player = name, player_id = pid, identifiers_hash = idsHash })
end

local function onDropped(reason)
    local src = source
    local s = sessions[src]
    local name = (s and s.name) or GetPlayerName(src) or 'unknown'
    local pid = (s and s.pid) or select(1, identityOf(src))
    sessions[src] = nil
    SA.emit('player.drop', {
        player = name,
        player_id = pid,
        reason = tostring(reason or 'unknown'),
        session_s = s and (os.time() - s.joinedAt) or nil,
    })
end

--- Name and pseudonym for a player id, for adapters (cached per session).
function SA.playerRef(src)
    local s = sessions[src]
    if s then return s.name, s.pid end
    local name = GetPlayerName(src) or 'unknown'
    local pid = select(1, identityOf(src))
    sessions[src] = { name = name, pid = pid, joinedAt = os.time() }
    return name, pid
end

-- ---- Resources -------------------------------------------------------------------

local startedAt = {}
local CRASH_LOOP_S = 10

local function onResourceStart(res)
    if res == SA.RESOURCE then return end
    startedAt[res] = os.time()
    SA.emit('server.resource', { resource = res, action = 'start' })
end

local function onResourceStop(res)
    if res == SA.RESOURCE then return end
    local uptime = startedAt[res] and (os.time() - startedAt[res]) or nil
    startedAt[res] = nil
    SA.emit('server.resource', {
        resource = res,
        action = 'stop',
        uptime_s = uptime,
        suspected_crash_loop = (uptime ~= nil and uptime <= CRASH_LOOP_S) or nil,
    })
end

-- ---- Hitches ---------------------------------------------------------------------
-- A thread that should wake every second. When the server thread stalls it
-- wakes late; the lateness is the hitch. It can't name a culprit on its own:
-- the backend correlates it with what else happened in the same minute.

local HITCH_INTERVAL_MS = 1000
local HITCH_WARN_MS = 250

local function startHitchWatch()
    CreateThread(function()
        local last = GetGameTimer()
        while true do
            Wait(HITCH_INTERVAL_MS)
            local now = GetGameTimer()
            local actual = now - last
            last = now
            local drift = actual - HITCH_INTERVAL_MS
            if drift >= HITCH_WARN_MS then
                SA.emit('server.hitch', {
                    ms = actual,
                    drift_ms = drift,
                    players = SA.playerCount(),
                    active_resources = SA.countStartedResources(),
                })
            end
        end
    end)
end

-- ---- Start -----------------------------------------------------------------------

function SA.startCollectors()
    -- Players already online when the agent (re)starts get a session now, so
    -- their drop still carries a pseudonym. No join event: they joined earlier.
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local pid = select(1, identityOf(src))
        sessions[src] = { name = GetPlayerName(src) or 'unknown', pid = pid, joinedAt = os.time() }
    end

    AddEventHandler('playerJoining', onJoining)
    AddEventHandler('playerDropped', onDropped)
    AddEventHandler('onResourceStart', onResourceStart)
    AddEventHandler('onResourceStop', onResourceStop)
    startHitchWatch()
    return { 'players', 'resources', 'hitch' }
end
