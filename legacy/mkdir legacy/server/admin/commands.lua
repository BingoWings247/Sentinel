-- =============================================================================
-- bsd_sentinel / server / admin / commands.lua
-- =============================================================================
-- Admin console commands. The thin wiring layer.
--
-- Each command is three steps: check permission -> call a data function ->
-- run the result through a formatter and print it. No business logic lives
-- here; it all sits in Permissions, Query/Health/Scheduler, and Formatters.
-- That separation is deliberate: when the bsd_admin NUI arrives, it reuses
-- steps 1 and 2 and replaces step 3 (print) with rendering.
--
-- OUTPUT (v1.0): console-first. v1.0 admin is console-only by design (see
-- fxmanifest notes), so output goes to the server console via print(). The
-- permission check still correctly gates in-game callers; delivering output
-- to an in-game player's screen is a NUI-era concern. The respond() seam
-- below is where player-facing delivery would be added.
--
-- Commands: /bsdhealth (READ), /bsdquery (READ), /bsdsched (READ).
--
-- Dependencies: server/logger.lua, server/admin/permissions.lua,
--               server/admin/formatters.lua, server/health.lua,
--               server/query.lua, server/scheduler.lua, shared/constants.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Admin = BSD.Sentinel.Admin or {}

local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants


-- =============================================================================
-- CONFIG
-- =============================================================================

local PREFIX = (Config and Config.Permissions and Config.Permissions.CommandPrefix)
    or (Constants and Constants.DEFAULT_COMMAND_PREFIX)
    or 'bsd'

local PERM_READ = (Constants and Constants.PERM_READ) or 'bsd.sentinel.read'
local MAX_LIMIT = (Constants and Constants.MAX_QUERY_LIMIT) or 1000


-- =============================================================================
-- OUTPUT SEAM
-- =============================================================================


--- Deliver command output. v1.0: console. The single place to extend for
-- in-game/NUI delivery later.
---@param source number 0 = console
---@param text string
local function respond(source, text)
    print(text)
    -- Future: if source > 0 then deliver to the player (NUI / chat).
end


--- Standard access-denied line (plain ASCII, matching formatter house style).
local function denied(source, permission)
    respond(source, string.format('[sentinel] access denied (requires %s)', permission))
end


--- Resolve admin modules lazily at call time (robust against load order).
local function modules()
    return BSD.Sentinel.Admin.Permissions,
           BSD.Sentinel.Admin.Formatters,
           BSD.Sentinel.Health
end


-- =============================================================================
-- /bsdhealth  — domain health snapshot (requires READ)
-- =============================================================================

RegisterCommand(PREFIX .. 'health', function(source, args, raw)
    local Permissions, Formatters, Health = modules()

    if not Permissions or not Permissions.AssertRead(source, PREFIX .. 'health') then
        denied(source, PERM_READ)
        return
    end
    if not Health or not Formatters then
        respond(source, '[sentinel] health/formatter module not ready')
        return
    end

    respond(source, Formatters.Health(Health.Snapshot()))
end, false)


-- =============================================================================
-- /bsdquery  — arbitrary event slice (requires READ)
-- =============================================================================
-- Usage:
--   /bsdquery
--   /bsdquery --domain banking --severity warning --limit 50
--   /bsdquery --actor sentinel_hitch_monitor --order asc
--
-- Flags (all optional): --domain --type --severity --actor --status --subject
--                       --limit (capped at MAX_QUERY_LIMIT) --order (asc|desc)
-- No flags => the 25 most recent events.

RegisterCommand(PREFIX .. 'query', function(source, args, raw)
    local Permissions, Formatters = modules()
    local Query = BSD.Sentinel.Query

    if not Permissions or not Permissions.AssertRead(source, PREFIX .. 'query') then
        denied(source, PERM_READ)
        return
    end
    if not Query or not Formatters then
        respond(source, '[sentinel] query/formatter module not ready')
        return
    end

    -- Parse flags into a filters table + query options.
    local filters = {}
    local options = { limit = 25, order = 'desc' }

    local i = 1
    while i <= #args do
        local flag, value = args[i], args[i + 1]
        if flag == '--domain' then filters.domain = value; i = i + 2
        elseif flag == '--type' then filters.event_type = value; i = i + 2
        elseif flag == '--severity' then filters.severity_min = value; i = i + 2
        elseif flag == '--actor' then filters.actor_identifier = value; i = i + 2
        elseif flag == '--status' then filters.status = value; i = i + 2
        elseif flag == '--subject' then filters.subject_id = value; i = i + 2
        elseif flag == '--limit' then
            options.limit = math.min(tonumber(value) or 25, MAX_LIMIT); i = i + 2
        elseif flag == '--order' then
            options.order = (value == 'asc') and 'asc' or 'desc'; i = i + 2
        else
            i = i + 1  -- skip unrecognized token
        end
    end

    local result = Query.Find(filters, options)
    if type(result) ~= 'table' then
        respond(source, '[sentinel] query returned no result (check filters)')
        return
    end

    respond(source, Formatters.EventList(result.events))
    respond(source, Formatters.Pagination(result))
end, false)


-- =============================================================================
-- /bsdsched  — scheduler task status (requires READ)
-- =============================================================================
-- Shows every registered scheduled task, including the collector sweeps,
-- so you can confirm they are actually ticking.

RegisterCommand(PREFIX .. 'sched', function(source, args, raw)
    local Permissions, Formatters = modules()
    local Scheduler = BSD.Sentinel.Scheduler

    if not Permissions or not Permissions.AssertRead(source, PREFIX .. 'sched') then
        denied(source, PERM_READ)
        return
    end
    if not Scheduler or not Formatters then
        respond(source, '[sentinel] scheduler/formatter module not ready')
        return
    end

    respond(source, Formatters.Scheduler(Scheduler.Status()))
end, false)


-- =============================================================================
-- (Remaining commands land here: /bsdevent, /bsdtrace, /bsdstats.)
-- =============================================================================


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

if Logger then
    Logger.Info('Admin commands registered (prefix "/%s"): %shealth, %squery, %ssched',
        PREFIX, PREFIX, PREFIX, PREFIX)
end