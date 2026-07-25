-- =============================================================================
-- bsd_sentinel / server / buffer.lua
-- =============================================================================
-- In-memory event buffer with disk spill fallback.
--
-- Events flow through Sentinel like this:
--
--    domain emit
--        ↓
--    ingestion (validate, shape, assign IDs)
--        ↓
--    BUFFER (this module) ← we are here
--        ↓
--    periodic flush
--        ↓
--    DB (via Driver.Execute)
--
--    If DB is unavailable:
--        Buffer fills up
--        Buffer spills oldest events to JSONL file on disk
--        When DB recovers, spill files are replayed in order
--
-- WHY A BUFFER EXISTS:
-- 1. ABSORB SPIKES. An event storm (e.g., server startup, mass player
--    login) can produce hundreds of events in seconds. The buffer
--    smooths these into batched inserts.
-- 2. DB FAULT TOLERANCE. A MySQL blip shouldn't lose events or take
--    down Sentinel. The buffer holds events for up to its configured
--    size; if the DB doesn't come back, we spill to disk.
-- 3. ORDERED DELIVERY. Events are written to the DB in insertion order,
--    which matches creation-time order well enough for forensic
--    investigation. (event_id is UUID v7 for true time ordering.)
--
-- DESIGN: RING BUFFER
-- Circular buffer with fixed capacity. When full, push() returns a flag
-- indicating the caller should trigger a spill. The buffer does NOT
-- silently drop events — dropping data would violate the forensic
-- contract.
--
-- DESIGN: SPILL FORMAT
-- JSONL (one JSON object per line) to a file in the spill directory.
-- Simple, resumable after crash, human-inspectable. The spill format
-- is deliberately the same shape as the event row, so replay is just
-- parse-and-insert.
--
-- Dependencies: server/logger.lua, server/db/driver.lua,
--               shared/constants.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Buffer = {}

local Buffer = BSD.Sentinel.Buffer
local Logger = BSD.Sentinel.Logger
local Driver = BSD.Sentinel.DB.Driver
local Constants = BSD.Sentinel.Constants
local Utils = BSD.Sentinel.Utils


-- =============================================================================
-- INTERNAL STATE
-- =============================================================================

-- The ring buffer itself.
-- We use a plain array and two pointers (head = next-write, tail = next-read).
-- Size is tracked explicitly to distinguish empty (size=0) from full
-- (size=capacity).
local ring = {}
local head = 1         -- next write position (1-indexed)
local tail = 1         -- next read position
local size = 0         -- number of occupied slots
local capacity = 10000 -- set via Initialize

-- Statistics (exposed via Stats)
local stats = {
    pushed_total = 0,
    flushed_total = 0,
    spilled_total = 0,
    dropped_total = 0,  -- should always be 0; increment means a bug
    last_flush_at = nil,
    last_spill_at = nil,
    current_spill_file = nil,
}

-- Whether buffer is initialized. Prevents use-before-setup.
local initialized = false


-- =============================================================================
-- PUBLIC: INITIALIZE
-- =============================================================================


--- Initialize the buffer with configuration. Called from main.lua startup.
---@param bufferConfig table { Size, FlushIntervalMs, FlushBatchSize }
---@param spillConfig table  { Directory, RetryIntervalMs, MaxFileBytes }
function Buffer.Initialize(bufferConfig, spillConfig)
    if initialized then
        Logger.Warning('Buffer.Initialize called twice; ignoring second call')
        return
    end

    capacity = (bufferConfig and bufferConfig.Size)
        or Constants.DEFAULT_BUFFER_SIZE

    -- Pre-allocate the ring with nil slots. Using an array with explicit
    -- nil entries rather than an empty table so Lua doesn't rehash on
    -- every push.
    ring = {}
    for i = 1, capacity do ring[i] = false end  -- false sentinel for "empty"

    head = 1
    tail = 1
    size = 0

    initialized = true
    Logger.Info('Buffer initialized (capacity=%d)', capacity)
end


-- =============================================================================
-- PUBLIC: PUSH
-- =============================================================================


--- Add an event to the buffer.
-- Returns true if accepted, false if full (caller should spill).
-- The buffer itself does NOT automatically spill on full — that's the
-- flusher's responsibility, so spill decisions are centralized.
---@param event table the event row (shape defined by ingestion)
---@return boolean accepted
function Buffer.Push(event)
    if not initialized then
        Logger.Critical('Buffer.Push called before Initialize')
        return false
    end
    if type(event) ~= 'table' then
        Logger.Critical('Buffer.Push called with non-table event')
        return false
    end

    if size >= capacity then
        -- Buffer full. Caller should trigger a spill.
        return false
    end

    ring[head] = event
    head = (head % capacity) + 1
    size = size + 1
    stats.pushed_total = stats.pushed_total + 1
    return true
end


-- =============================================================================
-- PUBLIC: DRAIN
-- =============================================================================


--- Remove up to N events from the buffer and return them as an array.
-- Used by the flusher: drain a batch, try to insert it, re-buffer on
-- failure. The returned array preserves insertion order.
---@param maxCount integer max events to drain
---@return table events (possibly empty)
function Buffer.Drain(maxCount)
    if not initialized then
        Logger.Critical('Buffer.Drain called before Initialize')
        return {}
    end
    if type(maxCount) ~= 'number' or maxCount < 1 then
        maxCount = Constants.DEFAULT_FLUSH_BATCH_SIZE
    end

    local drained = {}
    local count = math.min(maxCount, size)
    for i = 1, count do
        drained[i] = ring[tail]
        ring[tail] = false  -- clear slot
        tail = (tail % capacity) + 1
        size = size - 1
    end

    return drained
end


-- =============================================================================
-- PUBLIC: REBUFFER
-- =============================================================================


--- Put drained events back into the buffer (at the head).
-- Called when a flush fails: we drained events, tried to write them,
-- the write failed, so we put them back for retry.
---@param events table list of events to re-add
---@return integer accepted count of events successfully re-added
---@return integer rejected count that didn't fit (caller should spill them)
function Buffer.Rebuffer(events)
    if not initialized then
        Logger.Critical('Buffer.Rebuffer called before Initialize')
        return 0, #events
    end

    local accepted = 0
    local rejected = 0

    -- Push each event back; if the buffer is full, caller handles the rest
    for i = 1, #events do
        if Buffer.Push(events[i]) then
            accepted = accepted + 1
        else
            rejected = (#events) - i + 1
            break
        end
    end

    return accepted, rejected
end


-- =============================================================================
-- SPILL TO DISK
-- =============================================================================
-- When the buffer fills AND the DB is unavailable, events must not be
-- lost. We write them to a JSONL file in the spill directory. When the
-- DB recovers, a replay process re-ingests them.
--
-- DESIGN: The spill file is APPEND-ONLY during an outage. One file per
-- outage (rotated on size cap). Filename includes timestamp so multiple
-- outages produce distinct files.
-- =============================================================================


--- Serialize an event to a single JSON line.
-- Uses json.encode if available (FiveM provides one). Falls back to a
-- minimal safe encoder if not.
---@param event table
---@return string|nil json line (with trailing newline), nil on failure
local function serializeEvent(event)
    if json and type(json.encode) == 'function' then
        local ok, encoded = pcall(json.encode, event)
        if ok and type(encoded) == 'string' then
            return encoded .. '\n'
        end
    end
    -- Fallback: minimal serialization of the top-level keys
    -- This is less faithful than json.encode but still recoverable.
    local parts = { '{' }
    local first = true
    for k, v in pairs(event) do
        if not first then parts[#parts + 1] = ',' end
        first = false
        parts[#parts + 1] = string.format('%q:%q', tostring(k), tostring(v))
    end
    parts[#parts + 1] = '}\n'
    return table.concat(parts)
end


--- Write a list of events to a spill file.
-- Creates/opens the current spill file, appends all events, logs the action.
-- Called when the buffer is full and DB is down.
---@param events table
---@return integer bytesWritten, string|nil filename
function Buffer.Spill(events)
    if type(events) ~= 'table' or #events == 0 then
        return 0, nil
    end

    local dir = (Config and Config.Spill and Config.Spill.Directory)
        or Constants.DEFAULT_SPILL_DIRECTORY
    local maxBytes = (Config and Config.Spill and Config.Spill.MaxFileBytes)
        or Constants.MAX_SPILL_FILE_BYTES

    -- Pick a filename. Rotate when size cap is hit.
    local filename = stats.current_spill_file
    if not filename then
        local timestamp = os.date('%Y%m%d_%H%M%S')
        filename = string.format(Constants.SPILL_FILE_PATTERN, timestamp)
        stats.current_spill_file = filename
    end

    -- Resolve path. FiveM's SaveResourceFile writes into the resource dir.
    local relativePath = dir .. '/' .. filename

    -- Read existing contents (if any) to check size and preserve prior spills
    local existingContents = ''
    if LoadResourceFile then
        local resourceName = GetCurrentResourceName and GetCurrentResourceName()
            or 'bsd_sentinel'
        local content = LoadResourceFile(resourceName, relativePath)
        if type(content) == 'string' then
            existingContents = content
        end
    end

    -- Rotate if we're about to exceed the size cap
    if #existingContents > maxBytes then
        local timestamp = os.date('%Y%m%d_%H%M%S')
        filename = string.format(Constants.SPILL_FILE_PATTERN, timestamp)
        stats.current_spill_file = filename
        relativePath = dir .. '/' .. filename
        existingContents = ''
        Logger.Info('Spill file rotated (size cap reached): %s', filename)
    end

    -- Build the new contents: old + new lines
    local newLines = {}
    for i = 1, #events do
        local line = serializeEvent(events[i])
        if line then
            newLines[#newLines + 1] = line
        end
    end
    local newContents = existingContents .. table.concat(newLines)

    -- Write it
    if not SaveResourceFile then
        Logger.Critical(
            'Spill failed: SaveResourceFile not available. ' ..
            '%d events may be lost.',
            #events
        )
        stats.dropped_total = stats.dropped_total + #events
        return 0, nil
    end

    local resourceName = GetCurrentResourceName and GetCurrentResourceName()
        or 'bsd_sentinel'
    local ok = SaveResourceFile(resourceName, relativePath, newContents, -1)
    if not ok then
        Logger.Critical(
            'Spill write failed: %s. %d events may be lost.',
            relativePath, #events
        )
        stats.dropped_total = stats.dropped_total + #events
        return 0, nil
    end

    stats.spilled_total = stats.spilled_total + #events
    stats.last_spill_at = os.time()
    Logger.Warning(
        'Spilled %d events to %s (total spilled this outage: %d)',
        #events, filename, stats.spilled_total
    )
    return #newContents - #existingContents, filename
end


-- =============================================================================
-- PUBLIC: STATUS
-- =============================================================================


--- Current buffer size.
---@return integer
function Buffer.Size()
    return size
end


--- Buffer capacity.
---@return integer
function Buffer.Capacity()
    return capacity
end


--- Buffer utilization as percentage (0-100).
---@return number
function Buffer.Utilization()
    if capacity == 0 then return 0 end
    return (size / capacity) * 100
end


--- Get statistics snapshot.
---@return table
function Buffer.Stats()
    return {
        size = size,
        capacity = capacity,
        utilization_percent = Buffer.Utilization(),
        pushed_total = stats.pushed_total,
        flushed_total = stats.flushed_total,
        spilled_total = stats.spilled_total,
        dropped_total = stats.dropped_total,
        last_flush_at = stats.last_flush_at,
        last_spill_at = stats.last_spill_at,
        current_spill_file = stats.current_spill_file,
    }
end


--- Signal that the buffer's owner successfully flushed N events. Updates
-- the flush statistics. Called by the flusher after a successful DB write.
---@param count integer
function Buffer.RecordFlush(count)
    stats.flushed_total = stats.flushed_total + count
    stats.last_flush_at = os.time()
    -- If we had a current spill file and we just flushed successfully,
    -- it means the DB is back. Clear the current spill file pointer so
    -- future spills (if any) start a fresh file.
    stats.current_spill_file = nil
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Buffer loaded (awaiting Initialize)')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Buffer.Initialize) == 'function', 'Buffer.Initialize not defined')
assert(type(Buffer.Push) == 'function', 'Buffer.Push not defined')
assert(type(Buffer.Drain) == 'function', 'Buffer.Drain not defined')
assert(type(Buffer.Spill) == 'function', 'Buffer.Spill not defined')
assert(type(Buffer.Stats) == 'function', 'Buffer.Stats not defined')