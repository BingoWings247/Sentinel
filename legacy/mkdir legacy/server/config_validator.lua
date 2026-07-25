-- =============================================================================
-- bsd_sentinel / server / config_validator.lua
-- =============================================================================
-- Config validation and default application.
--
-- When Sentinel starts, it loads config.lua (written by the operator) and
-- then calls this module to:
--   1. Check every known config key's presence and type
--   2. Apply documented defaults for anything missing
--   3. Report every decision (use-provided vs use-default) to the log
--   4. In strict mode, refuse to start if config is fundamentally invalid
--   5. In lenient/dev mode, log warnings and continue with defaults
--
-- This implements BSD Rule #2: CONFIG defines behavior, never gatekeeps.
-- Bad or missing values fall back to documented defaults and log what
-- was used. The resource always runs (except in strict mode, by operator
-- choice).
--
-- DESIGN: Strict mode is OPT-IN via Config.StrictConfig = true. Default
-- behavior is lenient, so a brand-new operator installing Sentinel with
-- an empty config.lua still gets a working resource. Operators who want
-- the safety net of "refuse to start if misconfigured" can turn it on.
--
-- DESIGN: Schema is declared in this file, not in config.lua. Config.lua
-- is the operator's FILE; this validator is Sentinel's KNOWLEDGE of what
-- a valid config looks like. Keeping them separate lets us update schema
-- (in a forward-compatible way) without touching operator config files.
--
-- Dependencies: server/logger.lua, shared/constants.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.ConfigValidator = {}

local Validator = BSD.Sentinel.ConfigValidator
local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants
local Utils = BSD.Sentinel.Utils

-- Config is expected to be set globally by config.lua before this module's
-- Validate function is called. It may be nil on first run (no config file
-- present), which we handle as "use all defaults."


-- =============================================================================
-- SCHEMA DECLARATION
-- =============================================================================
-- Each entry describes one config key. Fields:
--   path        dot-separated path within the Config table (e.g. "Buffer.Size")
--   type        expected Lua type ('number', 'string', 'boolean', 'table')
--   default     default value if absent
--   validator   (optional) function(value) -> (ok, reason) for range checks
--   description (optional) human-readable note used in warning output
--
-- To add a new config key in a future version: add to this table, then
-- document it in docs/sentinel/CONFIG.md. No code changes elsewhere needed.
-- =============================================================================

-- Helper: build a validator that checks a number is within a range.
local function rangeValidator(minVal, maxVal)
    return function(v)
        if type(v) ~= 'number' then
            return false, 'not a number'
        end
        if v < minVal then
            return false, string.format('value %s below minimum %s', tostring(v), tostring(minVal))
        end
        if v > maxVal then
            return false, string.format('value %s above maximum %s', tostring(v), tostring(maxVal))
        end
        return true
    end
end

-- Helper: build a validator that checks a string is non-empty.
local function nonEmptyString(v)
    if type(v) ~= 'string' then return false, 'not a string' end
    if #v == 0 then return false, 'empty string' end
    return true
end


local SCHEMA = {

    -- -------------------------------------------------------------------------
    -- CORE
    -- -------------------------------------------------------------------------

    {
        path = 'StrictConfig',
        type = 'boolean',
        default = false,
        description = 'If true, refuse to start when config is invalid. If false, apply defaults and continue.',
    },
    {
        path = 'DevMode',
        type = 'boolean',
        default = false,  -- mirrors Constants.DEFAULT_DEV_MODE
        description = 'Enables permissive behaviors useful during development (e.g., auto-register unknown event types).',
    },

    -- -------------------------------------------------------------------------
    -- DATABASE
    -- -------------------------------------------------------------------------

    {
        path = 'Database.Driver',
        type = 'string',
        default = 'mysql',
        validator = function(v)
            if v == 'mysql' then return true end
            if v == 'pgsql' then
                return false, 'pgsql driver is not implemented in v1.0 (stub only); use "mysql"'
            end
            return false, string.format('unknown driver "%s"; valid values are "mysql"', tostring(v))
        end,
        description = 'Which DB driver to use. v1.0 supports only mysql.',
    },
    {
        path = 'Database.HeartbeatIntervalMs',
        type = 'number',
        default = 30000,  -- Constants.DB_HEARTBEAT_INTERVAL_MS
        validator = rangeValidator(1000, 600000),
        description = 'Milliseconds between DB connection health checks.',
    },
    {
        path = 'Database.SlowQueryThresholdMs',
        type = 'number',
        default = 1000,  -- Constants.DB_SLOW_QUERY_THRESHOLD_MS
        validator = rangeValidator(50, 60000),
        description = 'Queries exceeding this duration are logged for review.',
    },

    -- -------------------------------------------------------------------------
    -- BUFFER AND SPILL
    -- -------------------------------------------------------------------------

    {
        path = 'Buffer.Size',
        type = 'number',
        default = 10000,  -- Constants.DEFAULT_BUFFER_SIZE
        validator = rangeValidator(100, 1000000),
        description = 'Max events held in memory before spill.',
    },
    {
        path = 'Buffer.FlushIntervalMs',
        type = 'number',
        default = 1000,  -- Constants.DEFAULT_FLUSH_INTERVAL_MS
        validator = rangeValidator(100, 60000),
        description = 'How often the buffer flushes to DB.',
    },
    {
        path = 'Buffer.FlushBatchSize',
        type = 'number',
        default = 500,  -- Constants.DEFAULT_FLUSH_BATCH_SIZE
        validator = rangeValidator(10, 10000),
        description = 'Max events per flush batch.',
    },
    {
        path = 'Spill.Directory',
        type = 'string',
        default = 'spill',  -- Constants.DEFAULT_SPILL_DIRECTORY
        validator = nonEmptyString,
        description = 'Directory (relative to resource) for spill-to-disk files during DB outage.',
    },
    {
        path = 'Spill.RetryIntervalMs',
        type = 'number',
        default = 5000,  -- Constants.DEFAULT_SPILL_RETRY_INTERVAL_MS
        validator = rangeValidator(1000, 600000),
        description = 'How often to retry DB connection while spilling.',
    },
    {
        path = 'Spill.MaxFileBytes',
        type = 'number',
        default = 52428800,  -- 50 MB, Constants.MAX_SPILL_FILE_BYTES
        validator = rangeValidator(1048576, 1073741824),  -- 1MB to 1GB
        description = 'Max spill file size before rolling to new file.',
    },

    -- -------------------------------------------------------------------------
    -- RETENTION
    -- -------------------------------------------------------------------------

    {
        path = 'Retention.CriticalDays',
        type = 'number',
        default = 0,  -- forever
        validator = rangeValidator(0, 36500),  -- 0 or up to 100 years
        description = 'Days to retain critical events. 0 = forever. Do not change without understanding.',
    },
    {
        path = 'Retention.WarningDays',
        type = 'number',
        default = 365,
        validator = rangeValidator(1, 36500),
        description = 'Days to retain warning events.',
    },
    {
        path = 'Retention.InfoDays',
        type = 'number',
        default = 90,
        validator = rangeValidator(1, 36500),
        description = 'Days to retain info events.',
    },
    {
        path = 'Retention.DebugDays',
        type = 'number',
        default = 7,
        validator = rangeValidator(1, 36500),
        description = 'Days to retain debug events.',
    },
    {
        path = 'Retention.PruneIntervalHours',
        type = 'number',
        default = 168,  -- 7 days
        validator = rangeValidator(1, 8760),
        description = 'How often retention pruning runs.',
    },
    {
        path = 'Retention.ArchiveEnabled',
        type = 'boolean',
        default = false,  -- opt-in per scope §13
        description = 'Whether to archive pruned events to monthly aggregates.',
    },

    -- -------------------------------------------------------------------------
    -- ALERTS
    -- -------------------------------------------------------------------------

    {
        path = 'Alerts.DedupWindowSeconds',
        type = 'number',
        default = 3600,
        validator = rangeValidator(0, 86400),
        description = 'Window within which duplicate alert signals are merged. 0 disables dedup.',
    },

    -- -------------------------------------------------------------------------
    -- DISCORD
    -- -------------------------------------------------------------------------

    {
        path = 'Discord.Enabled',
        type = 'boolean',
        default = false,  -- opt-in; no webhook calls until operator sets URL
        description = 'Enable Discord webhook notifications.',
    },
    {
        path = 'Discord.WebhookURL',
        type = 'string',
        default = '',  -- empty = disabled
        description = 'Discord webhook URL for alert notifications.',
    },
    {
        path = 'Discord.RateLimitPerMinute',
        type = 'number',
        default = 20,
        validator = rangeValidator(1, 120),
        description = 'Max Discord posts per minute.',
    },
    {
        path = 'Discord.DigestHour',
        type = 'number',
        default = 8,
        validator = rangeValidator(0, 23),
        description = 'Hour of day (0-23, server local time) for daily digest.',
    },

    -- -------------------------------------------------------------------------
    -- HEALTH
    -- -------------------------------------------------------------------------

    {
        path = 'Health.SilentThresholdSeconds',
        type = 'number',
        default = 900,
        validator = rangeValidator(60, 86400),
        description = 'Seconds without activity before a domain is marked silent.',
    },
    {
        path = 'Health.ErroringThresholdPercent',
        type = 'number',
        default = 20,
        validator = rangeValidator(1, 100),
        description = 'Percentage of failed events in recent window before a domain is marked erroring.',
    },

    -- -------------------------------------------------------------------------
    -- RECONCILIATION
    -- -------------------------------------------------------------------------

    {
        path = 'Reconciliation.IntervalHours',
        type = 'number',
        default = 6,
        validator = rangeValidator(1, 168),
        description = 'Hours between scheduled reconciliation runs (default per-domain).',
    },

    -- -------------------------------------------------------------------------
    -- PERMISSIONS
    -- -------------------------------------------------------------------------

    {
        path = 'Permissions.CommandPrefix',
        type = 'string',
        default = 'bsd',
        validator = nonEmptyString,
        description = 'Prefix for Sentinel admin commands (e.g. "bsd" -> /bsdquery).',
    },
}


-- =============================================================================
-- INTERNAL: PATH WALKING
-- =============================================================================


--- Walk a dot-separated path into a table. Returns the value or nil if
-- any intermediate step is missing or not a table.
---@param root table
---@param path string
---@return any
local function getPath(root, path)
    if type(root) ~= 'table' then return nil end
    local current = root
    for segment in string.gmatch(path, '[^.]+') do
        if type(current) ~= 'table' then return nil end
        current = current[segment]
    end
    return current
end


--- Set a value at a dot-separated path, creating intermediate tables as needed.
---@param root table
---@param path string
---@param value any
local function setPath(root, path, value)
    if type(root) ~= 'table' then return end
    local segments = {}
    for segment in string.gmatch(path, '[^.]+') do
        segments[#segments + 1] = segment
    end

    if #segments == 0 then return end

    local current = root
    for i = 1, #segments - 1 do
        local seg = segments[i]
        if type(current[seg]) ~= 'table' then
            current[seg] = {}
        end
        current = current[seg]
    end
    current[segments[#segments]] = value
end


-- =============================================================================
-- INTERNAL: VALIDATE ONE ENTRY
-- =============================================================================


--- Validate a single schema entry against the operator's config.
-- Returns: { status, path, value, reason }
--   status: 'ok_provided' | 'ok_default' | 'invalid_type' | 'invalid_value'
---@param entry table schema entry
---@param config table operator's config (may be empty table)
---@return table result
local function validateEntry(entry, config)
    local value = getPath(config, entry.path)

    -- Key not present: use default.
    if value == nil then
        return {
            status = 'ok_default',
            path = entry.path,
            value = entry.default,
            reason = nil,
        }
    end

    -- Type mismatch.
    if type(value) ~= entry.type then
        return {
            status = 'invalid_type',
            path = entry.path,
            value = entry.default,  -- fall back to default
            provided = value,
            reason = string.format('expected %s, got %s', entry.type, type(value)),
        }
    end

    -- Custom validator (range, allowed values, etc).
    if entry.validator then
        local ok, reason = entry.validator(value)
        if not ok then
            return {
                status = 'invalid_value',
                path = entry.path,
                value = entry.default,  -- fall back to default
                provided = value,
                reason = reason or 'failed validation',
            }
        end
    end

    -- Passed all checks.
    return {
        status = 'ok_provided',
        path = entry.path,
        value = value,
        reason = nil,
    }
end


-- =============================================================================
-- PUBLIC API
-- =============================================================================


--- Validate the current Config table against the schema.
-- Applies defaults for missing or invalid entries. Reports every decision
-- to the log. Returns (ok, results) where results is a list of per-key
-- outcomes.
--
-- The returned Config is the SAME TABLE as the input Config, mutated in
-- place so that later code can just read Config.Buffer.Size etc. without
-- worrying about whether it was set by the operator or defaulted.
--
-- In strict mode (Config.StrictConfig = true): returns ok=false if any
-- entry had status 'invalid_type' or 'invalid_value'. The caller (main.lua)
-- should then halt startup.
--
-- In lenient mode (default): always returns ok=true; invalid values get
-- defaults applied and a warning logged.
---@return boolean ok
---@return table results list of {status, path, value, reason, provided}
function Validator.Validate()
    -- Ensure global Config exists so we can set defaults into it.
    -- Operators who didn't write a config.lua still get a working setup.
    Config = Config or {}

    local results = {}
    local invalidCount = 0

    Logger.Section('Validating configuration')

    for _, entry in ipairs(SCHEMA) do
        local result = validateEntry(entry, Config)
        results[#results + 1] = result

        -- Write the resolved value back into Config, so downstream code
        -- always sees a consistent value.
        setPath(Config, entry.path, result.value)

        -- Log per-entry outcome.
        if result.status == 'ok_provided' then
            -- Operator provided a valid value. Quiet log line.
            Logger.Debug('config: %s = %s (operator)',
                result.path, tostring(result.value))

        elseif result.status == 'ok_default' then
            -- Operator didn't provide a value. Apply default quietly.
            Logger.Debug('config: %s = %s (default)',
                result.path, tostring(result.value))

        elseif result.status == 'invalid_type' then
            invalidCount = invalidCount + 1
            Logger.Warning(
                'config: %s had invalid type (%s); using default %s',
                result.path, result.reason, tostring(result.value)
            )

        elseif result.status == 'invalid_value' then
            invalidCount = invalidCount + 1
            Logger.Warning(
                'config: %s had invalid value (%s; provided %s); using default %s',
                result.path, result.reason, tostring(result.provided),
                tostring(result.value)
            )
        end
    end

    -- Summary result
    if invalidCount == 0 then
        Logger.SectionDone('Validating configuration', 'all values valid')
        return true, results
    else
        -- Determine strictness based on what was just resolved into Config.
        local strict = Config.StrictConfig == true

        if strict then
            Logger.Result('Validating configuration', false,
                string.format('%d invalid value(s); strict mode active, refusing to start',
                    invalidCount)
            )
            return false, results
        else
            Logger.SectionDone('Validating configuration',
                string.format('%d invalid value(s) replaced with defaults', invalidCount)
            )
            return true, results
        end
    end
end


--- Get the full schema for inspection or documentation generation.
-- Returns a shallow copy so callers can't mutate the real schema.
---@return table
function Validator.GetSchema()
    local copy = {}
    for i, entry in ipairs(SCHEMA) do
        copy[i] = Utils.ShallowCopy(entry)
    end
    return copy
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Config validator loaded (%d schema entries)', #SCHEMA)

-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Validator.Validate) == 'function', 'Validator.Validate not defined')
assert(type(Validator.GetSchema) == 'function', 'Validator.GetSchema not defined')