-- =============================================================================
-- bsd_sentinel_agent / server / transport.lua
-- Buffer, batch and send events to Sentinel (wire protocol v1).
--
--   * Every event is scrubbed, given a ULID and queued. Nothing blocks the game.
--   * Every 5 s (or at 100 queued events) one batch of up to 500 events/256 KB
--     goes out. An empty batch is a valid heartbeat.
--   * The queue holds 2,000 events. On overflow the oldest are dropped and the
--     drop is reported as an agent.error event: losing data is never silent.
--   * Failures back off 5 s → 60 s. Retries resend the same ids; the backend
--     dedupes them, so a retry can never double-count.
-- =============================================================================

SA = SA or {}

local MAX_QUEUE = 2000
local MAX_BATCH = 500
local MAX_BYTES = 250 * 1024   -- backend limit is 256 KB; keep headroom
local FLUSH_AT = 100

local T = {
    url = nil,
    token = nil,
    serverId = nil,
    serverName = nil,
    state = 'idle',            -- idle | linking | linked | auth_failed
    queue = {},
    dropped = 0,
    seq = 0,
    inFlight = false,
    flushIntervalMs = 5000,
    lastFlushAt = 0,
    backoffMs = 0,
    nextAttemptAt = 0,
    batchLimit = MAX_BATCH,
    sent = 0,
    lastOkAt = nil,
    lastError = nil,
    unreachable = false,
    onLinked = nil,
}
SA.transport = T

-- ---- Queue -------------------------------------------------------------------

--- Queue one event. data must be a table with at least one key (the backend
--- requires an object, and an empty Lua table encodes as an array).
function SA.emit(eventType, data, src)
    if type(data) ~= 'table' or next(data) == nil then
        SA.error('emit(%s) called without data; event not queued.', tostring(eventType))
        return
    end
    local event = {
        id = 'evt_' .. SA.ulid(),
        t = SA.nowMs(),
        type = eventType,
        src = src or 'server',
        data = SA.scrubData(data),
    }
    local q = T.queue
    q[#q + 1] = event
    if #q > MAX_QUEUE then
        table.remove(q, 1)
        T.dropped = T.dropped + 1
    end
end

-- ---- HTTP helpers ------------------------------------------------------------

local function decodeBody(body, errorData)
    local text = body
    if (not text or text == '') and type(errorData) == 'string' then
        -- Newer FXServer builds put the response body of a non-2xx answer here,
        -- sometimes prefixed with "HTTP 400: ".
        text = errorData:gsub('^HTTP %d+:%s*', '')
    end
    if not text or text == '' then return nil end
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == 'table' then return decoded end
    return nil
end

local function authHeaders()
    return {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. T.token,
        ['User-Agent'] = 'bsd_sentinel_agent/' .. SA.VERSION,
    }
end

local function scheduleRetry(reason)
    if T.backoffMs == 0 then T.backoffMs = 5000 else T.backoffMs = math.min(T.backoffMs * 2, 60000) end
    T.nextAttemptAt = GetGameTimer() + T.backoffMs
    if not T.unreachable then
        T.unreachable = true
        SA.warn('Sentinel backend unreachable (%s). Events are buffering (max %d); retrying with backoff up to 60s.', reason, MAX_QUEUE)
    else
        SA.debug('still unreachable (%s), next try in %ds', reason, T.backoffMs // 1000)
    end
    T.lastError = reason
end

local function markReachable()
    if T.unreachable then
        SA.info('Sentinel backend reachable again. Sending %d buffered event(s).', #T.queue)
    end
    T.unreachable = false
    T.backoffMs = 0
    T.nextAttemptAt = 0
end

-- ---- Linking: GET /v1/whoami turns the token into a server_id -----------------

function SA.link()
    T.state = 'linking'
    PerformHttpRequest(T.url .. '/v1/whoami', function(status, body, _, errorData)
        local res = decodeBody(body, errorData)
        if status == 200 and res and res.ok and type(res.server_id) == 'string' then
            markReachable()
            local first = T.serverId == nil
            T.serverId = res.server_id
            T.serverName = res.name
            T.state = 'linked'
            if first then
                SA.info('^2Linked^7 to Sentinel as "%s" (%s).', tostring(res.name), res.server_id)
                if T.onLinked then T.onLinked() end
            end
        elseif status == 401 then
            T.state = 'auth_failed'
            T.lastError = 'token rejected'
            SA.error('Sentinel rejected the token in sentinel_token (revoked, mistyped, or from another server). Create a new one in the portal console with: npm run server:create -- "Name". Retrying in 1 hour.')
            T.nextAttemptAt = GetGameTimer() + 3600000
        else
            T.state = 'idle'
            scheduleRetry(status == 0 and 'no response' or ('HTTP ' .. tostring(status) .. ' on whoami'))
        end
    end, 'GET', '', authHeaders())
end

-- ---- Commands piggybacked on responses ------------------------------------------

local function handleCommands(cmds)
    if type(cmds) ~= 'table' then return end
    for _, c in ipairs(cmds) do
        if c.cmd == 'set_flush_interval' and tonumber(c.value) then
            T.flushIntervalMs = math.max(2, math.min(60, tonumber(c.value))) * 1000
            SA.info('Backend set the flush interval to %ds.', T.flushIntervalMs // 1000)
        else
            SA.emit('agent.error', { code = 'unknown_command', detail = tostring(c.cmd) })
        end
    end
end

-- ---- Flush ---------------------------------------------------------------------

-- Remove events by id rather than position: the queue can shift while a batch
-- is in flight (new events append; an overflow trims the head).
local function removeIds(ids)
    local keep = {}
    for _, e in ipairs(T.queue) do
        if not ids[e.id] then keep[#keep + 1] = e end
    end
    T.queue = keep
end

local function idSet(list)
    local s = {}
    for _, e in ipairs(list) do s[e.id] = true end
    return s
end

function SA.flush()
    if T.state ~= 'linked' or T.inFlight then return end
    if GetGameTimer() < T.nextAttemptAt then return end

    if T.dropped > 0 then
        SA.emit('agent.error', { code = 'buffer_overflow', dropped = T.dropped,
            detail = 'queue full while the backend was unreachable; oldest events dropped' })
        SA.warn('%d event(s) were dropped because the buffer filled while Sentinel was unreachable.', T.dropped)
        T.dropped = 0
    end

    -- Take up to batchLimit events, shrinking until the encoded body fits.
    local n = math.min(#T.queue, T.batchLimit)
    local body, events
    while true do
        events = {}
        for i = 1, n do events[i] = T.queue[i] end
        local batch = {
            v = 1,
            server_id = T.serverId,
            seq = T.seq,
            sent_at = SA.nowMs(),
            agent = {
                version = SA.VERSION,
                artifact = GetConvar('version', 'unknown'):match('v1%.0%.0%.(%d+)') or 'unknown',
                resource_count = GetNumResources(),
                uptime_s = SA.uptimeS(),
            },
            events = events,
        }
        body = json.encode(batch)
        if #body <= MAX_BYTES or n <= 1 then break end
        n = math.max(1, n // 2)
    end

    T.inFlight = true
    T.lastFlushAt = GetGameTimer()
    local sentCount = n
    local sentEvents = events

    PerformHttpRequest(T.url .. '/v1/ingest', function(status, resBody, _, errorData)
        T.inFlight = false
        local res = decodeBody(resBody, errorData)
        local err = res and res.error or {}

        if status == 200 and res and res.ok then
            removeIds(idSet(sentEvents))
            T.seq = T.seq + 1
            T.sent = T.sent + (res.received or 0)
            T.lastOkAt = os.time()
            T.batchLimit = MAX_BATCH
            markReachable()
            handleCommands(res.commands)
            SA.debug('batch seq=%d sent=%d received=%s deduped=%s', T.seq - 1, sentCount,
                tostring(res.received), tostring(res.deduped))

        elseif status == 400 and err.code == 'invalid_event' and tonumber(err.index) then
            -- One bad event: drop it, say exactly which and why, keep the rest.
            local bad = sentEvents[tonumber(err.index) + 1]
            SA.warn('Sentinel refused a %s event (%s: %s). That one event was dropped; the rest will resend.',
                bad and bad.type or '?', tostring(err.field), tostring(err.detail))
            if bad then removeIds({ [bad.id] = true }) end

        elseif status == 400 and err.code == 'invalid_envelope' then
            local evIndex = tostring(err.field or ''):match('^events%.(%d+)')
            local bad = evIndex and sentEvents[tonumber(evIndex) + 1]
            if bad then
                SA.warn('Sentinel refused a %s event (field %s: %s). Dropped it; the rest will resend.',
                    bad.type, tostring(err.field), tostring(err.detail))
                removeIds({ [bad.id] = true })
            else
                SA.error('Sentinel refused a whole batch (field %s: %s). Dropped %d event(s). This is an agent bug; please report it with this line.',
                    tostring(err.field), tostring(err.detail), sentCount)
                removeIds(idSet(sentEvents))
            end

        elseif status == 401 then
            T.state = 'auth_failed'
            T.lastError = 'token rejected'
            SA.error('Sentinel stopped accepting this server\'s token (revoked, or the subscription lapsed). Buffering; retrying in 1 hour.')
            T.nextAttemptAt = GetGameTimer() + 3600000

        elseif status == 403 then
            SA.warn('Sentinel says this server_id does not match the token; looking it up again.')
            T.serverId = nil
            SA.link()

        elseif status == 413 then
            T.batchLimit = math.max(1, sentCount // 2)
            SA.warn('Batch too large for Sentinel; sending smaller batches (%d events).', T.batchLimit)

        elseif status == 429 then
            local wait = tonumber(err.retry_after_s) or 30
            T.nextAttemptAt = GetGameTimer() + wait * 1000
            SA.warn('Sentinel asked the agent to slow down; waiting %ds.', wait)

        else
            scheduleRetry(status == 0 and 'no response' or ('HTTP ' .. tostring(status)))
        end
    end, 'POST', body, authHeaders())
end

-- ---- Loop ----------------------------------------------------------------------

function SA.startTransport(url, token)
    T.url = url
    T.token = token
    SA.link()

    CreateThread(function()
        while true do
            Wait(1000)
            local now = GetGameTimer()
            if T.state == 'idle' and now >= T.nextAttemptAt then
                SA.link()
            elseif T.state == 'auth_failed' and now >= T.nextAttemptAt then
                SA.link()
            elseif T.state == 'linked' then
                if #T.queue >= FLUSH_AT or now - T.lastFlushAt >= T.flushIntervalMs then
                    SA.flush()
                end
            end
        end
    end)
end
