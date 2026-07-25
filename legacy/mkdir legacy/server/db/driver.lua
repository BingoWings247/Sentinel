-- =============================================================================
-- bsd_sentinel / server / db / driver.lua
-- =============================================================================
-- Abstract database driver interface.
--
-- Every other module in Sentinel that touches the database goes through
-- this module — they call Driver.Query(...) rather than MySQL[...]() or
-- exports.oxmysql[...](). The driver module dispatches to whichever
-- backend is active (mysql, pgsql).
--
-- WHY THIS EXISTS:
-- 1. Decouples Sentinel from any specific DB library. If oxmysql is ever
--    replaced or abandoned, we change one module instead of fifty.
-- 2. Makes adding pgsql support in v1.1 a non-breaking addition: write
--    server/db/pgsql.lua implementing the same contract, register it,
--    nothing else in Sentinel changes.
-- 3. Provides a single place to add cross-cutting concerns: slow-query
--    logging, connection health tracking, retry logic. Every DB call
--    goes through here, so we can instrument once.
-- 4. Makes testing possible later: a mock driver can be registered for
--    unit tests without involving a real database.
--
-- USAGE FROM OTHER MODULES:
--   local Driver = BSD.Sentinel.DB.Driver
--
--   -- Async query with callback
--   Driver.Query('SELECT * FROM x WHERE y = ?', {yValue}, function(results)
--       -- process results
--   end)
--
--   -- Synchronous query (awaitable in a coroutine)
--   local results = Driver.QuerySync('SELECT COUNT(*) AS n FROM x')
--
--   -- Parameterized write
--   Driver.Execute('INSERT INTO x (a, b) VALUES (?, ?)', {1, 2}, function(affectedRows)
--       -- done
--   end)
--
--   -- Multi-statement transaction
--   Driver.Transaction({
--       {query = 'INSERT INTO a VALUES (?)', params = {1}},
--       {query = 'UPDATE b SET x = ? WHERE y = ?', params = {2, 3}},
--   }, function(success)
--       -- success is true if all queries committed, false if rolled back
--   end)
--
-- Dependencies: server/logger.lua, shared/constants.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.DB = BSD.Sentinel.DB or {}
BSD.Sentinel.DB.Driver = {}

local Driver = BSD.Sentinel.DB.Driver
local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants


-- =============================================================================
-- BACKEND REGISTRY
-- =============================================================================
-- Each backend (mysql.lua, pgsql.lua) registers itself at load time by
-- calling Driver.RegisterBackend(name, implementation). At startup,
-- main.lua calls Driver.Use(configuredName) to select which backend
-- is active.
--
-- A backend implementation is a table with these required fields:
--   name              string, lowercase, matches Config.Database.Driver
--   initialize        function(cfg) -> (ok, err) — called at startup
--   query             function(sql, params, cb)
--   querySync         function(sql, params) -> results
--   execute           function(sql, params, cb)
--   executeSync       function(sql, params) -> affectedRows
--   transaction       function(queries, cb)
--   transactionSync   function(queries) -> success
--   ping              function() -> ok (health check)
--   shutdown          function() — called on resource stop
-- =============================================================================

local backends = {}        -- name -> implementation table
local activeBackend = nil  -- currently selected implementation
local activeName = nil     -- name string of active backend


--- Register a database backend implementation.
-- Called by server/db/mysql.lua, server/db/pgsql.lua at their load time.
---@param name string e.g., 'mysql', 'pgsql'
---@param impl table implementation table with required fields
function Driver.RegisterBackend(name, impl)
    if type(name) ~= 'string' or #name == 0 then
        Logger.Critical('Driver.RegisterBackend called with invalid name')
        return
    end
    if type(impl) ~= 'table' then
        Logger.Critical('Driver.RegisterBackend called with non-table impl for "%s"', name)
        return
    end

    -- Validate required functions exist. Missing ones cause loud failure
    -- now rather than runtime crash later.
    local required = {
        'initialize', 'query', 'querySync', 'execute', 'executeSync',
        'transaction', 'transactionSync', 'ping', 'shutdown'
    }
    for _, fieldName in ipairs(required) do
        if type(impl[fieldName]) ~= 'function' then
            Logger.Critical(
                'Driver.RegisterBackend: backend "%s" missing required function "%s"',
                name, fieldName
            )
            return
        end
    end

    backends[name] = impl
    Logger.Debug('Driver.RegisterBackend: "%s" registered', name)
end


--- Select which registered backend to use. Called by main.lua at startup.
---@param name string backend name (from Config.Database.Driver)
---@return boolean ok
---@return string|nil err human-readable error if selection failed
function Driver.Use(name)
    if type(name) ~= 'string' then
        return false, 'driver name must be a string'
    end

    local impl = backends[name]
    if not impl then
        local registered = {}
        for k, _ in pairs(backends) do registered[#registered + 1] = k end
        return false, string.format(
            'driver "%s" is not registered (registered: %s)',
            name,
            #registered > 0 and table.concat(registered, ', ') or 'none'
        )
    end

    activeBackend = impl
    activeName = name
    Logger.Info('DB driver selected: %s', name)
    return true
end


--- Initialize the active backend. Called by main.lua after Use().
---@param cfg table database config (Config.Database)
---@return boolean ok
---@return string|nil err
function Driver.Initialize(cfg)
    if not activeBackend then
        return false, 'no driver selected; call Driver.Use first'
    end
    local ok, err = activeBackend.initialize(cfg)
    if ok then
        Logger.Info('DB driver initialized: %s', activeName)
    else
        Logger.Critical('DB driver initialization failed: %s', tostring(err))
    end
    return ok, err
end


--- Get the name of the currently active backend.
---@return string|nil
function Driver.ActiveName()
    return activeName
end


-- =============================================================================
-- DISPATCH HELPERS
-- =============================================================================
-- Each public function below validates that a backend is active, then
-- delegates to it. If no backend is active, calls are logged and return
-- a safe "nothing" result (empty list, false, etc.) rather than crashing.
--
-- DESIGN: Failing loudly but safely is the right call. Crashing would
-- take down Sentinel and with it all observability, which is worse than
-- any individual failed query.
-- =============================================================================

local function noBackendWarning(funcName)
    Logger.Critical(
        'DB %s called but no driver is active; call Driver.Use first',
        funcName
    )
end


-- =============================================================================
-- QUERY (read, async with callback)
-- =============================================================================

--- Run a SELECT (or other read) query asynchronously.
-- Results are delivered via callback. Suitable for all "normal" reads
-- that don't block the caller.
---@param sql string SQL string with ? placeholders
---@param params table|nil array of parameters for ? placeholders
---@param cb function callback(results) where results is a list of rows
function Driver.Query(sql, params, cb)
    if not activeBackend then
        noBackendWarning('Query')
        if cb then cb({}) end
        return
    end
    activeBackend.query(sql, params or {}, cb)
end


-- =============================================================================
-- QUERY (read, synchronous)
-- =============================================================================

--- Run a SELECT query and block until results are available.
-- MUST be called from within a coroutine (via Citizen.CreateThread or
-- similar). Most Sentinel code uses the async Query() with a callback;
-- this exists for admin commands and scripts that need sequential logic.
---@param sql string
---@param params table|nil
---@return table results (empty table on error)
function Driver.QuerySync(sql, params)
    if not activeBackend then
        noBackendWarning('QuerySync')
        return {}
    end
    return activeBackend.querySync(sql, params or {})
end


-- =============================================================================
-- EXECUTE (write, async)
-- =============================================================================

--- Run an INSERT/UPDATE/DELETE asynchronously.
---@param sql string
---@param params table|nil
---@param cb function|nil callback(affectedRows)
function Driver.Execute(sql, params, cb)
    if not activeBackend then
        noBackendWarning('Execute')
        if cb then cb(0) end
        return
    end
    activeBackend.execute(sql, params or {}, cb)
end


-- =============================================================================
-- EXECUTE (write, synchronous)
-- =============================================================================

--- Run an INSERT/UPDATE/DELETE and block until done.
---@param sql string
---@param params table|nil
---@return integer affectedRows (0 on error)
function Driver.ExecuteSync(sql, params)
    if not activeBackend then
        noBackendWarning('ExecuteSync')
        return 0
    end
    return activeBackend.executeSync(sql, params or {})
end


-- =============================================================================
-- TRANSACTION (atomic multi-query)
-- =============================================================================

--- Run multiple queries in a single transaction.
-- All queries commit together, or none do. Essential for multi-step
-- writes where partial completion would corrupt state (the classic
-- example: debit account A, credit account B).
---@param queries table list of {query=string, params=table} items
---@param cb function|nil callback(success)
function Driver.Transaction(queries, cb)
    if not activeBackend then
        noBackendWarning('Transaction')
        if cb then cb(false) end
        return
    end
    if type(queries) ~= 'table' or #queries == 0 then
        Logger.Warning('Driver.Transaction called with empty query list')
        if cb then cb(true) end  -- vacuously successful
        return
    end
    activeBackend.transaction(queries, cb)
end


--- Run multiple queries in a single transaction synchronously.
---@param queries table
---@return boolean success
function Driver.TransactionSync(queries)
    if not activeBackend then
        noBackendWarning('TransactionSync')
        return false
    end
    if type(queries) ~= 'table' or #queries == 0 then
        Logger.Warning('Driver.TransactionSync called with empty query list')
        return true
    end
    return activeBackend.transactionSync(queries)
end


-- =============================================================================
-- HEALTH CHECK
-- =============================================================================

--- Check whether the database is reachable.
-- Used by server/health.lua and the DB heartbeat scheduler.
---@return boolean ok
function Driver.Ping()
    if not activeBackend then return false end
    local ok, result = pcall(activeBackend.ping)
    if not ok then
        Logger.Warning('DB ping threw error: %s', tostring(result))
        return false
    end
    return result == true
end


-- =============================================================================
-- SHUTDOWN
-- =============================================================================

--- Clean up DB connections on resource stop.
function Driver.Shutdown()
    if not activeBackend then return end
    local ok, err = pcall(activeBackend.shutdown)
    if not ok then
        Logger.Warning('DB shutdown threw error: %s', tostring(err))
    else
        Logger.Info('DB driver shut down: %s', activeName or 'unknown')
    end
    activeBackend = nil
    activeName = nil
end


-- =============================================================================
-- SLOW QUERY HELPER
-- =============================================================================
-- Wrap a query with duration measurement. Backends call this to enforce
-- the slow-query logging threshold uniformly. Rather than each backend
-- reimplementing timing, they delegate to this.
--
-- USAGE INSIDE A BACKEND:
--   local function runQuery(sql, params, cb)
--       Driver.MeasureAndReport(sql, function()
--           -- actual DB call here
--           exports.oxmysql:query(sql, params, cb)
--       end)
--   end
-- =============================================================================

--- Measure how long a call takes and log a warning if it exceeds threshold.
---@param sql string used only for the warning log line
---@param fn function the DB call to time
function Driver.MeasureAndReport(sql, fn)
    local threshold = (Constants and Constants.DB_SLOW_QUERY_THRESHOLD_MS) or 1000
    local started = 0
    if GetGameTimer then
        started = GetGameTimer()
    end

    fn()

    if GetGameTimer and started > 0 then
        local elapsed = GetGameTimer() - started
        if elapsed > threshold then
            -- Truncate SQL for readability in logs
            local preview = sql
            if #preview > 100 then
                preview = preview:sub(1, 97) .. '...'
            end
            Logger.Warning('Slow query: %dms — %s', elapsed, preview)
        end
    end
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('DB driver abstraction loaded')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Driver.RegisterBackend) == 'function', 'Driver.RegisterBackend not defined')
assert(type(Driver.Use) == 'function', 'Driver.Use not defined')
assert(type(Driver.Query) == 'function', 'Driver.Query not defined')
assert(type(Driver.Transaction) == 'function', 'Driver.Transaction not defined')