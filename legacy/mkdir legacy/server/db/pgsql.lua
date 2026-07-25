-- =============================================================================
-- bsd_sentinel / server / db / pgsql.lua
-- =============================================================================
-- PostgreSQL backend STUB.
--
-- This file exists to reserve the 'pgsql' name in the driver registry
-- for future v1.1+ support. It is NOT a working backend. Attempting to
-- select pgsql as the driver in Config produces a clear, actionable
-- error message telling the operator to use mysql instead.
--
-- WHY WE HAVE A STUB:
-- 1. The driver abstraction (server/db/driver.lua) expects every
--    registered backend to implement the same contract. If 'pgsql' is
--    mentioned in config but no backend is registered under that name,
--    the error is generic ("unknown driver"). A stub gives a better
--    error ("pgsql support planned for v1.1; use mysql for now").
-- 2. Adding real pgsql support in v1.1 is then a single-file change:
--    rewrite this stub with the actual pg-connector wrapper. fxmanifest
--    already lists it, driver.lua already knows about it, nothing else
--    in Sentinel changes.
-- 3. Forces us to think about the driver interface as truly abstract
--    rather than mysql-specific from the start.
--
-- Dependencies: server/db/driver.lua, server/logger.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.DB = BSD.Sentinel.DB or {}
BSD.Sentinel.DB.PgSQL = {}

local PgSQL = BSD.Sentinel.DB.PgSQL
local Driver = BSD.Sentinel.DB.Driver
local Logger = BSD.Sentinel.Logger


-- =============================================================================
-- STUB IMPLEMENTATION
-- =============================================================================
-- Every function returns an error result. The initialize function is the
-- one operators will actually hit if they try to use pgsql — it produces
-- the clear, actionable error message.
-- =============================================================================

local STUB_MESSAGE =
    'PostgreSQL support is planned for v1.1 but not implemented in v1.0. ' ..
    'Set Config.Database.Driver = "mysql" and install oxmysql. ' ..
    'If you need pgsql support now, subscribe to release notes or file a feature request.'


local function notImplemented(funcName)
    Logger.Critical('pgsql backend: %s called but backend is not implemented', funcName)
end


local function initialize(cfg)
    return false, STUB_MESSAGE
end


local function query(sql, params, cb)
    notImplemented('query')
    if cb then cb({}) end
end


local function querySync(sql, params)
    notImplemented('querySync')
    return {}
end


local function execute(sql, params, cb)
    notImplemented('execute')
    if cb then cb(0) end
end


local function executeSync(sql, params)
    notImplemented('executeSync')
    return 0
end


local function transaction(queries, cb)
    notImplemented('transaction')
    if cb then cb(false) end
end


local function transactionSync(queries)
    notImplemented('transactionSync')
    return false
end


local function ping()
    return false
end


local function shutdown()
    -- Nothing to clean up; nothing was ever initialized.
end


-- =============================================================================
-- REGISTER WITH DRIVER MODULE
-- =============================================================================
-- Register so that Driver.Use('pgsql') produces our informative error
-- message instead of the generic "unknown driver" error.

PgSQL.implementation = {
    name = 'pgsql',
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

Driver.RegisterBackend('pgsql', PgSQL.implementation)


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Debug('PgSQL backend stub loaded (not implemented in v1.0)')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(PgSQL.implementation) == 'table', 'PgSQL.implementation not defined')