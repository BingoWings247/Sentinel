-- =============================================================================
-- bsd_sentinel / server / main.lua
-- =============================================================================
-- Startup orchestrator. The single file that knows the proper boot sequence.
--
-- This file does NOT do any actual work — every step delegates to another
-- module (config validator, DB driver, migrator, scheduler). main.lua's
-- job is to call them in the correct order and handle what happens if
-- any of them fail.
--
-- STARTUP SEQUENCE (executed on resource start):
--   1. Log version banner (confirms resource actually started)
--   2. Validate config (apply defaults, refuse if strict+invalid)
--   3. Select DB driver based on config
--   4. Initialize DB driver (verify oxmysql available, smoke test)
--   5. Run pending migrations (bootstrap migrations table, apply files)
--   6. Start scheduler (kicks off all registered recurring tasks)
--   7. Announce ready
--
-- If any step fails in a way that prevents further progress, main.lua
-- logs the failure clearly and stops the boot sequence. The resource
-- remains loaded (FiveM considers it started) but non-functional. This
-- is preferable to halting FiveM itself.
--
-- SHUTDOWN SEQUENCE (executed on resource stop):
--   1. Mark scheduler as not accepting tasks, stop its thread
--   2. Flush any pending buffered events (placeholder — buffer not yet
--      implemented; will be added when we build the ingestion layer)
--   3. Shut down DB driver (closes connection resources if the backend
--      manages its own; oxmysql manages its own pool)
--
-- Dependencies: every other server-side module
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Main = {}

local Main = BSD.Sentinel.Main

-- Shorthand for modules we orchestrate
local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants
local ConfigValidator = BSD.Sentinel.ConfigValidator
local Driver = BSD.Sentinel.DB.Driver
local Migrator = BSD.Sentinel.DB.Migrator
local Scheduler = BSD.Sentinel.Scheduler


-- =============================================================================
-- INTERNAL STATE
-- =============================================================================

-- Whether startup completed successfully. Exposed via IsReady for admin
-- commands and future exports to check before operating.
local ready = false


-- =============================================================================
-- INTERNAL: BOOT STEPS
-- =============================================================================
-- Each step returns (ok, err). On failure, the caller (Boot) logs and
-- halts the sequence.
-- =============================================================================


--- Step 1: print a startup banner. Always succeeds; this just makes
-- server logs obviously identifiable as a Sentinel startup.
local function logBanner()
    Logger.Info('')
    Logger.Info('==========================================')
    Logger.Info('   BSD Sentinel v%s', Constants.VERSION)
    Logger.Info('   Observability layer for BSD ecosystem')
    Logger.Info('==========================================')
    Logger.Info('')
end


--- Step 2: validate config.
local function validateConfig()
    local ok = ConfigValidator.Validate()
    if not ok then
        return false, 'config validation failed in strict mode'
    end
    return true
end


--- Step 3: select DB driver based on Config.Database.Driver.
local function selectDriver()
    local driverName = Config.Database.Driver
    local ok, err = Driver.Use(driverName)
    if not ok then
        return false, string.format('DB driver selection failed: %s',
            tostring(err))
    end
    return true
end


--- Step 4: initialize DB driver (connect, smoke test).
local function initializeDriver()
    local ok, err = Driver.Initialize(Config.Database)
    if not ok then
        return false, string.format('DB driver initialization failed: %s',
            tostring(err))
    end
    return true
end


--- Step 5: run pending migrations.
local function runMigrations()
    local ok, count = Migrator.RunPending()
    if not ok then
        return false, 'one or more migrations failed; see prior log lines'
    end
    return true
end


--- Step 6: start the scheduler.
-- Note: actual task registration happens at module-load time by each
-- module that needs scheduled work. Scheduler.Start just begins ticking.
local function startScheduler()
    Scheduler.Start()
    return true
end

--- Step 7: start the ingestion subsystem (buffer + flush task).
local function startIngestion()
    BSD.Sentinel.Ingestion.Start()
    return true
end
-- =============================================================================
-- PUBLIC: BOOT
-- =============================================================================


--- Run the full boot sequence. Called automatically on resource start
-- via onResourceStart handler below.
-- Logs progress at each step. On failure, logs what failed and halts.
function Main.Boot()
    logBanner()

    -- Step-by-step, halt on any failure.
    local steps = {
        { name = 'Validate configuration',    fn = validateConfig    },
        { name = 'Select database driver',    fn = selectDriver      },
        { name = 'Initialize database',       fn = initializeDriver  },
        { name = 'Run database migrations',   fn = runMigrations     },
        { name = 'Start scheduler',           fn = startScheduler    },
        { name = 'Start ingestion',           fn = startIngestion    },
    }

    for _, step in ipairs(steps) do
        local ok, err = step.fn()
        if not ok then
            Logger.Critical('')
            Logger.Critical('==========================================')
            Logger.Critical('   SENTINEL BOOT FAILED')
            Logger.Critical('==========================================')
            Logger.Critical('   Step: %s', step.name)
            Logger.Critical('   Reason: %s', tostring(err))
            Logger.Critical('')
            Logger.Critical(
                '   Sentinel is loaded but NOT operational.'
            )
            Logger.Critical(
                '   Domain resources depending on Sentinel will ' ..
                'experience degraded or failed operation.'
            )
            Logger.Critical(
                '   Fix the issue above and restart bsd_sentinel.'
            )
            Logger.Critical('==========================================')
            Logger.Critical('')
            return
        end
    end

    -- All steps succeeded.
    ready = true
    Logger.Info('')
    Logger.Info('==========================================')
    Logger.Info('   BSD Sentinel ready')
    Logger.Info('==========================================')
    Logger.Info('')
end


-- =============================================================================
-- PUBLIC: SHUTDOWN
-- =============================================================================


--- Run the shutdown sequence. Called automatically on resource stop
-- via onResourceStop handler below. Best-effort cleanup; failures here
-- log warnings but don't prevent the resource from stopping.
function Main.Shutdown()
    if not ready then
        -- Never fully booted; minimal cleanup
        Logger.Info('Sentinel shutting down (never became ready)')
        Scheduler.Shutdown()
        return
    end

    Logger.Info('')
    Logger.Info('==========================================')
    Logger.Info('   BSD Sentinel shutting down')
    Logger.Info('==========================================')

    -- Stop scheduler first so nothing new starts running
    Logger.Debug('Shutdown step 1: scheduler')
    Scheduler.Shutdown()

    -- Placeholder: flush the event buffer. The buffer module will register
    -- itself here once it exists.
    Logger.Debug('Shutdown step 2: flush buffer (not yet implemented)')

    -- Shut down DB driver
    Logger.Debug('Shutdown step 3: database driver')
    Driver.Shutdown()

    ready = false
    Logger.Info('Sentinel shutdown complete')
    Logger.Info('')
end


-- =============================================================================
-- PUBLIC: READINESS CHECK
-- =============================================================================


--- Returns true if Sentinel successfully completed boot and is operational.
-- Admin commands and domain resource integrations should check this before
-- calling Sentinel's exports.
---@return boolean
function Main.IsReady()
    return ready
end


-- =============================================================================
-- RESOURCE LIFECYCLE HANDLERS
-- =============================================================================
-- FiveM calls these when the resource starts and stops. We respond by
-- kicking off Boot / Shutdown respectively.
--
-- DESIGN: onResourceStart fires for EVERY resource that starts, not just
-- our own. We check resourceName to make sure we're responding to our
-- own start. Same for stop.
-- =============================================================================

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Citizen.CreateThread(function()
        Main.Boot()
    end)
end)


AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Main.Shutdown()
end)


-- =============================================================================
-- MANUAL BOOT FALLBACK
-- =============================================================================
-- If for some reason onResourceStart doesn't fire (unusual — normally
-- happens automatically when the resource starts), we provide a small
-- delayed boot as a safety net. The delay lets other modules finish
-- loading their top-level code, then we check if Boot already ran.
--
-- DESIGN: Using Citizen.CreateThread with a short wait rather than calling
-- Boot immediately at load time. Calling Boot directly here would run
-- before all module load-time code completes.
-- =============================================================================

Citizen.CreateThread(function()
    Citizen.Wait(500)
    if not ready then
        Logger.Debug('Fallback boot path engaged (onResourceStart may not have fired)')
        Main.Boot()
    end
end)


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Main.Boot) == 'function', 'Main.Boot not defined')
assert(type(Main.Shutdown) == 'function', 'Main.Shutdown not defined')
assert(type(Main.IsReady) == 'function', 'Main.IsReady not defined')

-- =============================================================================
-- End of main.lua
-- =============================================================================
-- At this point, all server-side Lua modules have loaded. Their load-time
-- code (registering backends, registering scheduled tasks, setting up
-- internal state) has executed. The fxmanifest load order guarantees
-- main.lua loads LAST among server_scripts.
--
-- What happens next:
--   - onResourceStart fires (or the fallback thread wakes up)
--   - Main.Boot runs
--   - Each boot step succeeds or fails
--   - Sentinel becomes either ready, or loaded-but-broken with clear log
-- =============================================================================