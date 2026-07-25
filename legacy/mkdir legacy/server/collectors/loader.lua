-- =============================================================================
-- bsd_sentinel / server / collectors / loader.lua
-- =============================================================================
-- Lifecycle manager for server-observability collectors.
--
-- A collector watches the server itself — scheduler hitches, entity pools,
-- routing buckets, resource lifecycle — and emits Sentinel events when it
-- sees something worth recording. Collectors OBSERVE and REPORT. They never
-- act on what they see (no kicks, no bans, no auto-correction). That line is
-- what keeps Sentinel an observability layer and not an anti-cheat.
--
-- DESIGN: every collector conforms to the same shape and self-registers into
-- BSD.Sentinel.Collectors.list at load time:
--
--   {
--     name      = 'hitch',          -- short identifier, used in logs
--     enabled   = true,             -- resolved from Config with a default
--     register  = function(domain)  -- declare event types (RegisterEventType)
--     start     = function()        -- begin watching
--     stop      = function()        -- tear down (threads, handlers)
--   }
--
-- DESIGN: all collector events share one domain ('sentinel') so they group
-- cleanly in queries and never collide with a real BSD domain module. The
-- domain is registered idempotently here, once, before any collector starts.
--
-- DESIGN: load order between this file and individual collector files does
-- not matter. Both guard the namespace and list with `or {}`, and Start()
-- defers its work into a thread that waits for readiness, by which point
-- every collector file has finished loading and self-registered.
--
-- Dependencies: server/logger.lua, server/registry.lua, server/ingestion.lua,
--               shared/constants.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Collectors = BSD.Sentinel.Collectors or {}

local Collectors = BSD.Sentinel.Collectors
Collectors.list = Collectors.list or {}

local Logger = BSD.Sentinel.Logger
local Registry = BSD.Sentinel.Registry


-- The single domain every collector emits under.
local COLLECTOR_DOMAIN = 'sentinel'

-- How long to wait for Sentinel to become ready before giving up.
local READY_TIMEOUT_MS = 30000
local READY_POLL_MS = 250


-- =============================================================================
-- PUBLIC: REGISTER A COLLECTOR
-- =============================================================================


--- Add a collector to the roster. Called by each collector file at load time.
-- Tolerant of being called before or after this loader file itself loads,
-- because the list is guarded with `or {}` everywhere it is touched.
---@param collector table { name, enabled, register, start, stop }
function Collectors.Register(collector)
    if type(collector) ~= 'table' or type(collector.name) ~= 'string' then
        if Logger then
            Logger.Critical('Collectors.Register: collector must be a table with a name')
        end
        return false
    end
    Collectors.list[#Collectors.list + 1] = collector
    return true
end


-- =============================================================================
-- INTERNAL: WAIT FOR READINESS
-- =============================================================================


--- Poll BSD.Sentinel.Main.IsReady() until ready or timeout.
---@return boolean ready
local function waitForReady()
    local waited = 0
    while waited < READY_TIMEOUT_MS do
        local Main = BSD.Sentinel.Main
        if Main and Main.IsReady and Main.IsReady() then
            return true
        end
        Citizen.Wait(READY_POLL_MS)
        waited = waited + READY_POLL_MS
    end
    return false
end


-- =============================================================================
-- PUBLIC: START
-- =============================================================================


--- Start all enabled collectors. Safe to call at load time; the real work is
-- deferred into a thread that waits for Sentinel to be ready first.
function Collectors.Start()
    Citizen.CreateThread(function()
        if not waitForReady() then
            Logger.Critical(
                'Collectors: Sentinel did not become ready within %dms; ' ..
                'collectors NOT started. The server-observability layer is OFFLINE.',
                READY_TIMEOUT_MS
            )
            return
        end

        -- Register the shared self-domain once (idempotent).
        local Constants = BSD.Sentinel.Constants
        Registry.RegisterDomain({
            name = COLLECTOR_DOMAIN,
            display_name = 'Sentinel (server observability)',
            version = (Constants and Constants.VERSION) or 'unknown',
        })

        local loaded, enabled, failed = 0, 0, 0
        for _, c in ipairs(Collectors.list) do
            loaded = loaded + 1
            if c.enabled then
                local ok, err = pcall(function()
                    if type(c.register) == 'function' then c.register(COLLECTOR_DOMAIN) end
                    if type(c.start) == 'function' then c.start() end
                end)
                if ok then
                    enabled = enabled + 1
                else
                    failed = failed + 1
                    Logger.Critical('Collector "%s" failed to start: %s',
                        c.name, tostring(err))
                end
            else
                Logger.Info('Collector "%s" disabled by config', c.name)
            end
        end

        -- ARCH Rule 1: report healthy state, not just faults.
        if failed == 0 then
            Logger.Info('Collectors online: %d loaded, %d enabled', loaded, enabled)
        else
            Logger.Warning('Collectors online with errors: %d loaded, %d enabled, %d FAILED',
                loaded, enabled, failed)
        end
    end)
end


-- =============================================================================
-- PUBLIC: STOP
-- =============================================================================


--- Tear down all collectors. Called on resource stop.
function Collectors.Stop()
    for _, c in ipairs(Collectors.list) do
        if type(c.stop) == 'function' then
            local ok, err = pcall(c.stop)
            if not ok then
                Logger.Warning('Collector "%s" stop error: %s', c.name, tostring(err))
            end
        end
    end
end


-- =============================================================================
-- RESOURCE STOP HANDLER
-- =============================================================================

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        Collectors.Stop()
    end
end)


-- =============================================================================
-- AUTO-START
-- =============================================================================
-- Deferred-safe: Start() waits for readiness internally. If you prefer to
-- orchestrate startup explicitly from server/main.lua, delete the line below
-- and call BSD.Sentinel.Collectors.Start() from your main startup sequence
-- after Ingestion.Start().

Collectors.Start()


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

if Logger then
    Logger.Info('Collector loader ready (%d registered so far)', #Collectors.list)
end


-- =============================================================================
-- MODULE VERIFICATION
-- =============================================================================

assert(type(Collectors.Register) == 'function', 'Collectors.Register not defined')
assert(type(Collectors.Start) == 'function', 'Collectors.Start not defined')
assert(type(Collectors.Stop) == 'function', 'Collectors.Stop not defined')