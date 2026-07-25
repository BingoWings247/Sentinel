-- =============================================================================
-- bsd_sentinel / server / logger.lua
-- =============================================================================
-- Sentinel's own console logger.
--
-- This is the FIRST server module to load. Every other module uses it to
-- write to the console, instead of calling print() directly. Consistent
-- prefix, consistent severity prefixes, consistent timestamps.
--
-- DESIGN: This logger is for Sentinel's own output to the SERVER CONSOLE —
-- the messages the operator sees when the resource starts, runs, and
-- encounters problems. It is NOT for domain module events (those are
-- forensic, go through the ingestion path, and end up in the DB).
--
-- Two completely different concerns:
--   - Console logging = "talk to the operator running the server"
--   - Event logging   = "record what happened for later investigation"
-- This file handles the first. Ingestion handles the second.
--
-- Requirements this module must meet:
--   1. CANNOT FAIL. If the logger breaks, Sentinel has lost its ability
--      to tell the operator what's wrong. Every code path here is
--      defensive and has a fallback to raw print().
--   2. MUST LOAD FIRST. Other modules depend on it at load time. It can
--      therefore depend on nothing except shared/ modules (which load
--      before all server modules via the shared_scripts path).
--   3. MUST BE CONSISTENT. Every line of output looks the same. Operators
--      and log-parsing tools rely on the format.
--
-- Output format:
--   [bsd_sentinel] [HH:MM:SS.mmm] [INFO   ] message
--   [bsd_sentinel] [HH:MM:SS.mmm] [WARNING] message
--   etc.
--
-- Dependencies: shared/constants.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Logger = {}

local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants
local Utils = BSD.Sentinel.Utils


-- =============================================================================
-- INTERNAL: DEFENSIVE FALLBACK
-- =============================================================================
-- If Constants or Utils didn't load (shouldn't happen, but belt and
-- suspenders), we still need to be able to print something. These
-- fallbacks are used only when the normal path can't produce output.

local FALLBACK_PREFIX = '[bsd_sentinel]'

local function safePrint(line)
    -- pcall wraps print because print can in theory fail (closed stdout,
    -- some exotic FiveM state). If it fails, there's nothing we can do —
    -- the operator is not going to see it either way.
    pcall(print, line)
end


-- =============================================================================
-- INTERNAL: FORMATTING
-- =============================================================================


--- Format the severity label for display. Right-padded to fixed width so
-- columns align across lines.
---@param level string severity string (lowercase)
---@return string
local function formatLevel(level)
    -- Fixed width of 7 covers 'WARNING' (longest). Padding on right.
    if level == 'debug' then
        return 'DEBUG  '
    elseif level == 'info' then
        return 'INFO   '
    elseif level == 'warning' then
        return 'WARNING'
    elseif level == 'critical' then
        return 'CRITIC.'   -- 'CRITICAL' is 8 chars; truncated here to stay at 7
    else
        return '?      '
    end
end


--- Build a timestamp string suitable for log lines.
-- Uses os.date plus a millisecond component from GetGameTimer if available.
-- Always returns a string; never errors.
---@return string
local function formatTimestamp()
    -- Defensive: if Constants isn't loaded, we just skip timestamps.
    if not Constants or not Constants.LOG_INCLUDE_TIMESTAMPS then
        return ''
    end

    local ok, timeStr = pcall(os.date, '%H:%M:%S')
    if not ok or type(timeStr) ~= 'string' then
        return ''
    end

    -- Append milliseconds if we can get them.
    local ms = 0
    if GetGameTimer then
        local okMs, result = pcall(GetGameTimer)
        if okMs and type(result) == 'number' then
            ms = result % 1000
        end
    end

    return string.format(' [%s.%03d]', timeStr, ms)
end


--- Get the prefix to use in log lines.
-- Uses Constants.LOG_PREFIX if available, FALLBACK_PREFIX otherwise.
---@return string
local function getPrefix()
    if Constants and type(Constants.LOG_PREFIX) == 'string' then
        return Constants.LOG_PREFIX
    end
    return FALLBACK_PREFIX
end


--- Core log formatter. Builds the full output line.
---@param level string
---@param message string
---@return string
local function formatLine(level, message)
    -- Defensive: stringify non-string messages rather than erroring.
    if type(message) ~= 'string' then
        message = tostring(message)
    end

    return string.format(
        '%s%s [%s] %s',
        getPrefix(),
        formatTimestamp(),
        formatLevel(level),
        message
    )
end


-- =============================================================================
-- PUBLIC LOGGING FUNCTIONS
-- =============================================================================
-- All four functions have the same signature: a message string, optionally
-- followed by substitution arguments (treated like string.format).
--
-- Safe to call at any time, including during load, including with nil or
-- non-string arguments. Defensive throughout.
-- =============================================================================


--- Log at DEBUG level.
-- Use for: verbose diagnostic output, function entry/exit traces,
-- internal state dumps during development.
--
-- DESIGN: DEBUG output is NOT filtered in v1.0. Every debug call produces
-- output to the console. If we need filtering later (and we probably
-- will), Logger.SetMinLevel or similar would be added without breaking
-- existing callers. For v1.0, keep it simple — operators can grep.
---@param message string format string or plain message
---@param ... any optional format arguments
function Logger.Debug(message, ...)
    local args = { ... }
    local formatted

    if #args > 0 then
        local ok, result = pcall(string.format, tostring(message), ...)
        formatted = ok and result or tostring(message)
    else
        formatted = tostring(message)
    end

    safePrint(formatLine('debug', formatted))
end


--- Log at INFO level.
-- Use for: normal operational output, 'resource started', 'flushed N events',
-- 'domain X registered'.
---@param message string
---@param ... any
function Logger.Info(message, ...)
    local args = { ... }
    local formatted

    if #args > 0 then
        local ok, result = pcall(string.format, tostring(message), ...)
        formatted = ok and result or tostring(message)
    else
        formatted = tostring(message)
    end

    safePrint(formatLine('info', formatted))
end


--- Log at WARNING level.
-- Use for: unexpected but recoverable conditions, 'config value missing,
-- using default', 'slow query', 'reconnection attempted'.
---@param message string
---@param ... any
function Logger.Warning(message, ...)
    local args = { ... }
    local formatted

    if #args > 0 then
        local ok, result = pcall(string.format, tostring(message), ...)
        formatted = ok and result or tostring(message)
    else
        formatted = tostring(message)
    end

    safePrint(formatLine('warning', formatted))
end


--- Log at CRITICAL level.
-- Use for: conditions requiring operator attention, 'migration failed',
-- 'database unreachable', 'ingestion halted'.
--
-- DESIGN: Every call to Logger.Critical should be accompanied by enough
-- detail for the operator to understand WHAT is wrong and WHAT to do
-- about it. 'Silent failure forbidden' applies to console output too:
-- if you're calling Critical, say something specific.
---@param message string
---@param ... any
function Logger.Critical(message, ...)
    local args = { ... }
    local formatted

    if #args > 0 then
        local ok, result = pcall(string.format, tostring(message), ...)
        formatted = ok and result or tostring(message)
    else
        formatted = tostring(message)
    end

    safePrint(formatLine('critical', formatted))
end


-- =============================================================================
-- CONVENIENCE: SECTION HEADERS
-- =============================================================================
-- For startup output, sometimes we want a visual separator to mark phase
-- transitions. 'Starting ingestion...', 'Loading config...', etc.
-- =============================================================================


--- Log a visual section header. Used during startup to mark phase transitions.
-- Produces output like:
--   [bsd_sentinel] [15:30:12.123] [INFO   ] === Loading configuration ===
---@param title string the section title
function Logger.Section(title)
    Logger.Info('=== %s ===', tostring(title))
end


--- Log a visual section completion. Paired with Logger.Section.
-- Used to confirm a phase finished, with optional result summary.
---@param title string
---@param result string|nil optional summary like 'OK' or '3 domains registered'
function Logger.SectionDone(title, result)
    if result then
        Logger.Info('    %s ✓ %s', tostring(title), tostring(result))
    else
        Logger.Info('    %s ✓', tostring(title))
    end
end


--- Log a structured startup result. Variant of SectionDone that handles
-- both success and failure cases explicitly, for self-reporting output.
---@param title string
---@param ok boolean
---@param detail string|nil optional additional info
function Logger.Result(title, ok, detail)
    if ok then
        if detail then
            Logger.Info('    %s ✓ %s', tostring(title), tostring(detail))
        else
            Logger.Info('    %s ✓', tostring(title))
        end
    else
        if detail then
            Logger.Critical('    %s ✗ %s', tostring(title), tostring(detail))
        else
            Logger.Critical('    %s ✗', tostring(title))
        end
    end
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================
-- The logger itself announces it's loaded. This is the first line of
-- output the operator sees from Sentinel. Confirms the resource is
-- actually starting.

Logger.Info('Logger loaded (v%s)',
    (Constants and Constants.VERSION) or 'unknown'
)

-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Logger.Debug) == 'function', 'Logger.Debug not defined')
assert(type(Logger.Info) == 'function', 'Logger.Info not defined')
assert(type(Logger.Warning) == 'function', 'Logger.Warning not defined')
assert(type(Logger.Critical) == 'function', 'Logger.Critical not defined')