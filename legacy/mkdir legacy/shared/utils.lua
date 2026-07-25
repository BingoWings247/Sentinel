-- =============================================================================
-- bsd_sentinel / shared / utils.lua
-- =============================================================================
-- Shared utilities: UUID v7 generation, timestamps, type checks, hashing.
--
-- This file has no dependencies. It is loaded early in the shared context
-- so every other file can use it. It MUST NOT depend on any other Sentinel
-- module, on oxmysql, on ox_lib, or on any BSD resource.
--
-- Everything here is pure Lua or uses only FiveM-provided globals.
-- =============================================================================

-- Global namespace. Other Sentinel files extend this namespace; this file
-- creates it if it doesn't already exist.
BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Utils = {}

local Utils = BSD.Sentinel.Utils


-- =============================================================================
-- UUID v7 GENERATION
-- =============================================================================
-- UUID v7 is time-ordered: the first 48 bits are a Unix millisecond timestamp.
-- This makes UUIDs sortable in creation order, which matters for our use case:
-- events are inserted in roughly chronological order, so index B-trees stay
-- balanced instead of fragmenting (as happens with random UUID v4).
--
-- Format: xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx
--   - First 48 bits: Unix timestamp in milliseconds
--   - Next 4 bits: version (0111 = 7)
--   - Next 12 bits: random
--   - Next 2 bits: variant (10)
--   - Last 62 bits: random
--
-- Reference: RFC 9562 (replacing RFC 4122)
--
-- DESIGN: rolled in-house per scope decision §18. ~30 lines, no external
-- dependency, predictable behavior across Lua versions.
--
-- UNCERTAIN: we use math.random for the random bits. math.random in Lua is
-- seeded from os.time() by default, which is low entropy. We improve the
-- seeding at module load (see below), but this is not cryptographically
-- secure. UUID v7 does not require cryptographically secure randomness —
-- the random bits exist to disambiguate UUIDs generated in the same
-- millisecond, not to prevent guessing. If we ever need cryptographically
-- strong IDs, we'd use a separate function.
-- =============================================================================

-- Seed math.random once at module load with the best entropy we can find.
-- os.time() is second-precision (bad). We mix in os.clock() and a quick
-- loop to get microsecond-ish variation. Good enough for disambiguation.
do
    local seed = os.time()
    if os.clock then
        seed = seed + math.floor((os.clock() * 1000000) % 1000000)
    end
    -- Also mix in something per-run-unique if available
    if GetGameTimer then
        seed = seed + GetGameTimer()
    end
    math.randomseed(seed)
    -- Discard first few values; some Lua implementations have weak initial output
    for _ = 1, 10 do math.random() end
end


--- Generate the current time in milliseconds since Unix epoch.
-- Uses os.time() for seconds and GetGameTimer() for a fractional component.
-- This is not perfectly accurate against wall-clock milliseconds, but it's
-- monotonic within a server session and stable enough for UUID ordering.
---@return integer milliseconds since epoch
local function currentTimeMillis()
    local seconds = os.time()
    -- GetGameTimer() returns ms since server start. We only need its low
    -- bits to act as sub-second disambiguation, so we take it mod 1000.
    local millis = 0
    if GetGameTimer then
        millis = GetGameTimer() % 1000
    end
    return (seconds * 1000) + millis
end


--- Generate a UUID v7.
-- Time-ordered UUID suitable for use as a primary key in an indexed DB table
-- where rows are inserted in chronological order.
---@return string uuid the canonical dash-separated UUID string
function Utils.GenerateUUIDv7()
    local ms = currentTimeMillis()

    -- Extract the 48-bit timestamp into 6 bytes (big-endian).
    local b1 = math.floor(ms / 0x10000000000) % 0x100
    local b2 = math.floor(ms / 0x100000000) % 0x100
    local b3 = math.floor(ms / 0x1000000) % 0x100
    local b4 = math.floor(ms / 0x10000) % 0x100
    local b5 = math.floor(ms / 0x100) % 0x100
    local b6 = ms % 0x100

    -- Byte 7: top 4 bits = version (0111 = 7), bottom 4 bits = random
    local b7 = 0x70 + math.random(0, 0x0F)
    -- Byte 8: full random
    local b8 = math.random(0, 0xFF)

    -- Byte 9: top 2 bits = variant (10), bottom 6 bits = random
    local b9 = 0x80 + math.random(0, 0x3F)
    -- Byte 10: full random
    local b10 = math.random(0, 0xFF)

    -- Bytes 11-16: full random
    local b11 = math.random(0, 0xFF)
    local b12 = math.random(0, 0xFF)
    local b13 = math.random(0, 0xFF)
    local b14 = math.random(0, 0xFF)
    local b15 = math.random(0, 0xFF)
    local b16 = math.random(0, 0xFF)

    return string.format(
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16
    )
end


--- Check whether a string looks like a UUID (any version).
-- Does NOT validate the version, only the format.
---@param s any the value to check
---@return boolean true if s is a string matching UUID format
function Utils.IsUUID(s)
    if type(s) ~= "string" then return false end
    -- 8-4-4-4-12 hex digits separated by dashes
    return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end


-- =============================================================================
-- TIMESTAMP HELPERS
-- =============================================================================
-- Sentinel uses TIMESTAMP(6) columns (microsecond precision) for created_at
-- and ingested_at. These helpers produce timestamp strings in the exact
-- format MySQL expects.
-- =============================================================================


--- Produce a MySQL-compatible TIMESTAMP(6) string for the current instant.
-- Format: 'YYYY-MM-DD HH:MM:SS.ffffff'
--
-- UNCERTAIN: Lua's os.date does not provide microsecond precision. We use
-- GetGameTimer() for sub-second data, which gives millisecond precision
-- (3 digits) padded to 6. This is good enough for event ordering within
-- a session. If we ever need true microsecond precision, we'd need to
-- call into a native FiveM function or use a C extension.
---@return string mysql-compatible timestamp string
function Utils.NowMysqlTimestamp()
    local secondsPart = os.date("%Y-%m-%d %H:%M:%S")
    local subseconds = 0
    if GetGameTimer then
        subseconds = GetGameTimer() % 1000
    end
    -- Pad to 6 digits: milliseconds × 1000 = microseconds
    return string.format("%s.%06d", secondsPart, subseconds * 1000)
end


--- Produce a MySQL-compatible TIMESTAMP(6) string for a given epoch time.
---@param epochSeconds integer|number Unix epoch time in seconds (may be fractional)
---@return string mysql-compatible timestamp string
function Utils.MysqlTimestampFromEpoch(epochSeconds)
    local whole = math.floor(epochSeconds)
    local fraction = epochSeconds - whole
    local micros = math.floor(fraction * 1000000 + 0.5)
    return string.format("%s.%06d", os.date("%Y-%m-%d %H:%M:%S", whole), micros)
end


--- Return the current Unix epoch time as a number of seconds.
-- Kept as a named helper for consistency; internal callers should use this
-- rather than os.time() directly so we have a single point to change.
---@return integer
function Utils.EpochSeconds()
    return os.time()
end


-- =============================================================================
-- TYPE VALIDATION
-- =============================================================================
-- Small helpers used throughout Sentinel for input validation.
-- Every public function in every Sentinel module validates its inputs at
-- the top; these helpers make those checks concise and consistent.
-- =============================================================================


--- Type check with a structured error return.
-- Returns (true) if value matches expected type, or (false, reason) if not.
---@param value any
---@param expectedType string Lua type name ('string', 'number', 'table', etc.)
---@param fieldName string human-readable name for error messages
---@return boolean ok
---@return string|nil reason
function Utils.CheckType(value, expectedType, fieldName)
    if type(value) == expectedType then
        return true, nil
    end
    return false, string.format(
        "%s must be %s, got %s",
        fieldName, expectedType, type(value)
    )
end


--- Validate that a value is a non-empty string.
---@param value any
---@param fieldName string
---@return boolean ok
---@return string|nil reason
function Utils.CheckNonEmptyString(value, fieldName)
    if type(value) ~= "string" then
        return false, string.format("%s must be a string, got %s", fieldName, type(value))
    end
    if #value == 0 then
        return false, string.format("%s must not be empty", fieldName)
    end
    return true, nil
end


--- Validate that a value is a string no longer than maxLength characters.
---@param value any
---@param maxLength integer
---@param fieldName string
---@return boolean ok
---@return string|nil reason
function Utils.CheckStringLength(value, maxLength, fieldName)
    if type(value) ~= "string" then
        return false, string.format("%s must be a string, got %s", fieldName, type(value))
    end
    if #value > maxLength then
        return false, string.format(
            "%s exceeds maximum length of %d (got %d)",
            fieldName, maxLength, #value
        )
    end
    return true, nil
end


--- Validate that a value is an integer (a number with no fractional part).
---@param value any
---@param fieldName string
---@return boolean ok
---@return string|nil reason
function Utils.CheckInteger(value, fieldName)
    if type(value) ~= "number" then
        return false, string.format("%s must be a number, got %s", fieldName, type(value))
    end
    if value ~= math.floor(value) then
        return false, string.format("%s must be an integer, got %s", fieldName, tostring(value))
    end
    return true, nil
end


--- Validate that a value is one of an allowed set.
-- allowed may be either an array (ipairs) or a set (key -> any truthy value).
---@param value any
---@param allowed table
---@param fieldName string
---@return boolean ok
---@return string|nil reason
function Utils.CheckEnum(value, allowed, fieldName)
    -- Array form
    for _, v in ipairs(allowed) do
        if v == value then return true, nil end
    end
    -- Set form (only checked if array didn't find it)
    if allowed[value] then return true, nil end

    -- Build a readable list of allowed values for the error message.
    local list = {}
    local seen = {}
    for _, v in ipairs(allowed) do
        if not seen[v] then
            list[#list + 1] = tostring(v)
            seen[v] = true
        end
    end
    for k, _ in pairs(allowed) do
        -- Only include hash keys we haven't already listed
        if type(k) ~= "number" and not seen[k] then
            list[#list + 1] = tostring(k)
            seen[k] = true
        end
    end

    return false, string.format(
        "%s must be one of [%s], got %s",
        fieldName, table.concat(list, ", "), tostring(value)
    )
end


-- =============================================================================
-- TABLE HELPERS
-- =============================================================================


--- Shallow-copy a table. Useful when passing context that should not be
-- mutated by the callee.
---@param t table|nil
---@return table copy (empty table if t was nil)
function Utils.ShallowCopy(t)
    local copy = {}
    if t == nil then return copy end
    for k, v in pairs(t) do copy[k] = v end
    return copy
end


--- Deep-copy a table. Recursively copies nested tables. Does not handle
-- cycles; callers must ensure the input has no cyclic references.
---@param t any
---@return any
function Utils.DeepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = Utils.DeepCopy(v)
    end
    return copy
end


--- Count entries in a table (works for hash tables where #t returns 0).
---@param t table
---@return integer
function Utils.Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end


--- Check whether a table is empty.
---@param t table|nil
---@return boolean
function Utils.IsEmpty(t)
    if t == nil then return true end
    return next(t) == nil
end


-- =============================================================================
-- STRING HELPERS
-- =============================================================================


--- Truncate a string to maxLength characters, appending "..." if truncated.
-- If the string is already shorter, returns it unchanged.
---@param s string
---@param maxLength integer
---@return string
function Utils.Truncate(s, maxLength)
    if type(s) ~= "string" then return "" end
    if #s <= maxLength then return s end
    if maxLength <= 3 then return string.sub(s, 1, maxLength) end
    return string.sub(s, 1, maxLength - 3) .. "..."
end


--- Trim leading and trailing whitespace from a string.
---@param s string
---@return string
function Utils.Trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================
-- Assigned to BSD.Sentinel.Utils at the top of this file. Nothing else to
-- do at load time.
-- =============================================================================

-- Sanity check: confirm we have everything we just defined. This catches
-- typos at load time rather than at first call.
assert(type(Utils.GenerateUUIDv7) == "function", "Utils.GenerateUUIDv7 not defined")
assert(type(Utils.NowMysqlTimestamp) == "function", "Utils.NowMysqlTimestamp not defined")
assert(type(Utils.CheckType) == "function", "Utils.CheckType not defined")
