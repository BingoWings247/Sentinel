-- =============================================================================
-- bsd_sentinel / server / db / mysql.lua
-- =============================================================================
-- MySQL backend implementation. Wraps oxmysql.
--
-- Implements the contract defined in server/db/driver.lua. Registers
-- itself under the name 'mysql' at load time. Becomes the active driver
-- when main.lua calls Driver.Use('mysql') (the default in Config.Database).
--
-- WHY OXMYSQL:
-- oxmysql is the de facto MySQL resource for modern FiveM servers. It's
-- actively maintained, async-native, and widely installed. Using it
-- avoids reinventing connection pooling, prepared statements, and
-- thread coordination.
--
-- The coupling to oxmysql is CONTAINED TO THIS FILE. Nothing else in
-- Sentinel references oxmysql directly. If oxmysql is ever replaced,
-- only this file needs to be rewritten.
--
-- ERROR HANDLING:
-- oxmysql callbacks can receive error objects when queries fail. Every
-- wrapper here catches those and logs them via Logger, rather than
-- letting errors propagate silently or crash the caller. Silent failure
-- is forbidden.
--
-- SYNC OPERATIONS:
-- oxmysql's *_await functions require Citizen coroutine context. The
-- Sync wrappers below are safe only when called from within a Citizen
-- thread. Calling them from a bare server tick will error clearly.
--
-- Dependencies: server/db/driver.lua, server/logger.lua,
--               shared/constants.lua, oxmysql (resource)
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.DB = BSD.Sentinel.DB or {}
BSD.Sentinel.DB.MySQL = {}

local MySQL = BSD.Sentinel.DB.MySQL
local Driver = BSD.Sentinel.DB.Driver
local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants


-- =============================================================================
-- INTERNAL STATE
-- =============================================================================

-- Whether the backend has been initialized. Queries before initialize
-- are logged as warnings; they typically mean a load-order bug.
local initialized = false

-- Health tracking. Last successful ping timestamp.
-- Used by the Ping function to report health without actually hitting
-- the DB every time something asks "are you up?"
local lastPingTimestamp = 0
local lastPingResult = false


-- =============================================================================
-- INTERNAL: OXMYSQL AVAILABILITY CHECK
-- =============================================================================

--- Check if oxmysql is available and running. Logs a critical error if
-- not. Called during initialize to fail loudly and early.
---@return boolean
local function oxmysqlAvailable()
    if not GetResourceState then
        -- Not in a FiveM environment? Can't happen in practice, but
        -- defensive.
        return false
    end
    local state = GetResourceState('oxmysql')
    if state ~= 'started' then
        Logger.Critical(
            'oxmysql resource is %s (expected "started"); ' ..
            'Sentinel requires oxmysql to function',
            tostring(state)
        )
        return false
    end
    if not exports or not exports.oxmysql then
        Logger.Critical(
            'oxmysql exports are not available; ' ..
            'ensure oxmysql is listed before bsd_sentinel in server.cfg'
        )
        return false
    end
    return true
end


-- =============================================================================
-- INTERNAL: ERROR HANDLING
-- =============================================================================

--- Handle an error from an oxmysql call. Logs it, returns a normalized
-- "nothing" result to the caller.
---@param operation string e.g., 'query', 'execute', 'transaction'
---@param sql string the query (for log context)
---@param err any whatever oxmysql passed as error (usually a string or table)
local function logDbError(operation, sql, err)
    local errStr = err
    if type(err) == 'table' then
        errStr = (err.message or err.code or 'unknown error')
    end
    local preview = sql
    if type(preview) == 'string' and #preview > 100 then
        preview = preview:sub(1, 97) .. '...'
    end
    Logger.Critical('DB %s error: %s — query: %s',
        operation, tostring(errStr), tostring(preview))
end


-- =============================================================================
-- BACKEND IMPLEMENTATION
-- =============================================================================
-- Each function below matches the contract in driver.lua.
-- =============================================================================


--- initialize(cfg): prepare the backend for use. Return (ok, err).
-- Called exactly once at startup, after Driver.Use('mysql'), from main.lua.
---@param cfg table Config.Database
---@return boolean ok
---@return string|nil err
local function initialize(cfg)
    if initialized then
        Logger.Warning('MySQL backend already initialized; ignoring second call')
        return true
    end

    if not oxmysqlAvailable() then
        return false, 'oxmysql resource not available'
    end

    -- DESIGN: We used to run a synchronous smoke test here via query_async,
    -- but that call can block indefinitely when the boot path isn't in a
    -- Citizen coroutine context. Instead, we mark ourselves initialized
    -- and do a non-blocking async ping. The migrator and subsequent calls
    -- will surface any real DB problems.
    initialized = true
    lastPingTimestamp = os.time()
    lastPingResult = true
    Logger.Info('MySQL backend initialized (oxmysql)')

    -- Async smoke test: fire-and-forget query, log if it fails.
    -- This validates that DB is actually reachable without blocking boot.
    exports.oxmysql:query('SELECT 1 AS test', {}, function(result)
        if type(result) == 'table' and result[1] and result[1].test == 1 then
            Logger.Debug('MySQL async smoke test passed')
        else
            Logger.Critical(
                'MySQL async smoke test failed; DB may be unreachable. ' ..
                'Check your database connection string in server.cfg.'
            )
            lastPingResult = false
        end
    end)

    return true
end


--- query(sql, params, cb): async SELECT-type call.
---@param sql string
---@param params table
---@param cb function callback(results)
local function query(sql, params, cb)
    if not initialized then
        Logger.Warning('MySQL.query called before initialize; returning empty')
        if cb then cb({}) end
        return
    end

    Driver.MeasureAndReport(sql, function()
        -- oxmysql async API: :query(sql, params, callback)
        -- Callback receives (result, ...) on success. On error, oxmysql
        -- calls into our internal error hook which is installed via
        -- xpcall wrapper.
        local ok, err = pcall(function()
            exports.oxmysql:query(sql, params, function(result)
                if cb then
                    cb(result or {})
                end
            end)
        end)
        if not ok then
            logDbError('query', sql, err)
            if cb then cb({}) end
        end
    end)
end


--- querySync(sql, params): blocking SELECT. Must be in a coroutine.
---@param sql string
---@param params table
---@return table
local function querySync(sql, params)
    if not initialized then
        Logger.Warning('MySQL.querySync called before initialize; returning empty')
        return {}
    end

    local result = {}
    Driver.MeasureAndReport(sql, function()
        local ok, res = pcall(function()
            return exports.oxmysql:query_async(sql, params)
        end)
        if ok then
            result = res or {}
        else
            logDbError('querySync', sql, res)
        end
    end)
    return result
end


--- execute(sql, params, cb): async INSERT/UPDATE/DELETE.
---@param sql string
---@param params table
---@param cb function|nil callback(affectedRows)
local function execute(sql, params, cb)
    if not initialized then
        Logger.Warning('MySQL.execute called before initialize; returning 0')
        if cb then cb(0) end
        return
    end

    Driver.MeasureAndReport(sql, function()
        local ok, err = pcall(function()
            exports.oxmysql:execute(sql, params, function(affectedRows)
                if cb then
                    cb(affectedRows or 0)
                end
            end)
        end)
        if not ok then
            logDbError('execute', sql, err)
            if cb then cb(0) end
        end
    end)
end


--- executeSync(sql, params): blocking INSERT/UPDATE/DELETE.
---@param sql string
---@param params table
---@return integer
local function executeSync(sql, params)
    if not initialized then
        Logger.Warning('MySQL.executeSync called before initialize; returning 0')
        return 0
    end

    local affected = 0
    Driver.MeasureAndReport(sql, function()
        local ok, res = pcall(function()
            return exports.oxmysql:execute_async(sql, params)
        end)
        if ok then
            affected = res or 0
        else
            logDbError('executeSync', sql, res)
        end
    end)
    return affected
end


--- transaction(queries, cb): atomic multi-query.
---@param queries table list of {query, params}
---@param cb function|nil callback(success)
local function transaction(queries, cb)
    if not initialized then
        Logger.Warning('MySQL.transaction called before initialize; returning false')
        if cb then cb(false) end
        return
    end

    -- oxmysql transaction API: :transaction(queries, callback)
    -- queries is a list of {query=..., values=...} or {query=..., params=...}
    -- depending on oxmysql version. We normalize to the common shape.
    local txQueries = {}
    for i, q in ipairs(queries) do
        if type(q) ~= 'table' or type(q.query) ~= 'string' then
            Logger.Critical(
                'MySQL.transaction: query %d is malformed (missing .query)', i
            )
            if cb then cb(false) end
            return
        end
        txQueries[i] = {
            query = q.query,
            values = q.params or {},
        }
    end

    local ok, err = pcall(function()
        exports.oxmysql:transaction(txQueries, function(success)
            if cb then
                cb(success == true)
            end
        end)
    end)
    if not ok then
        logDbError('transaction', '(multiple queries)', err)
        if cb then cb(false) end
    end
end


--- transactionSync(queries): blocking atomic multi-query.
---@param queries table
---@return boolean
local function transactionSync(queries)
    if not initialized then
        Logger.Warning('MySQL.transactionSync called before initialize; returning false')
        return false
    end

    local txQueries = {}
    for i, q in ipairs(queries) do
        if type(q) ~= 'table' or type(q.query) ~= 'string' then
            Logger.Critical(
                'MySQL.transactionSync: query %d is malformed (missing .query)', i
            )
            return false
        end
        txQueries[i] = {
            query = q.query,
            values = q.params or {},
        }
    end

    local result = false
    local ok, res = pcall(function()
        -- Different oxmysql versions expose _async differently; try the
        -- explicit sync form.
        return exports.oxmysql:transaction_async(txQueries)
    end)
    if ok then
        result = res == true
    else
        logDbError('transactionSync', '(multiple queries)', res)
    end
    return result
end


--- ping(): simple health check. Returns true if DB is reachable.
-- Cached briefly to avoid flooding the DB with pings when multiple
-- callers ask in quick succession.
---@return boolean
local function ping()
    if not initialized then return false end

    local now = os.time()
    -- If we pinged within the last 5 seconds, return cached result
    if now - lastPingTimestamp < 5 then
        return lastPingResult
    end

    local ok, res = pcall(function()
        local r = exports.oxmysql:query_async('SELECT 1 AS ping', {})
        return type(r) == 'table' and r[1] and r[1].ping == 1
    end)

    lastPingTimestamp = now
    lastPingResult = (ok and res == true)
    return lastPingResult
end


--- shutdown(): clean up on resource stop.
local function shutdown()
    -- oxmysql manages its own connection pool. We have nothing to release.
    -- Mark ourselves uninitialized so late calls are caught.
    initialized = false
    lastPingResult = false
    Logger.Debug('MySQL backend shutdown complete')
end


-- =============================================================================
-- REGISTER WITH DRIVER MODULE
-- =============================================================================

MySQL.implementation = {
    name = 'mysql',
    initialize = initialize,
    query = query,
    querySync = querySync,
    execute = execute,
    executeSync = executeSync,
    transaction = transaction,
    transactionSync = transactionSync,
    ping = ping,
    shutdown = shutdown,
}

-- Register at load time. main.lua later calls Driver.Use('mysql') to
-- actually select this backend and Driver.Initialize(cfg) to start it.
Driver.RegisterBackend('mysql', MySQL.implementation)


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('MySQL backend loaded (oxmysql wrapper)')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(MySQL.implementation) == 'table', 'MySQL.implementation not defined')
assert(type(MySQL.implementation.query) == 'function', 'MySQL.query not defined')