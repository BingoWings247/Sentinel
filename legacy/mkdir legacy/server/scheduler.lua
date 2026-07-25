-- =============================================================================
-- bsd_sentinel / server / scheduler.lua
-- =============================================================================
-- Shared scheduler for recurring tasks.
--
-- Modules that need work done on a timer (retention pruning, health
-- checks, reconciliation, DB heartbeat) register tasks here instead of
-- each spinning up its own Citizen.CreateThread loop.
--
-- BENEFITS:
-- 1. One thread instead of many. Each module's Citizen.CreateThread
--    takes server resources; consolidating reduces that overhead.
-- 2. Uniform slow-task logging. If a task takes longer than expected,
--    we log it once, centrally, rather than each module reinventing
--    duration measurement.
-- 3. Startup orchestration. Tasks don't run until Scheduler.Start is
--    called from main.lua, so no task fires before dependencies are
--    initialized.
-- 4. Observability. Admin commands can query "what's scheduled? when
--    did X last run? when will it next run?"
--
-- USAGE:
--   local Scheduler = BSD.Sentinel.Scheduler
--
--   Scheduler.Register({
--       name = 'retention_prune',
--       intervalSeconds = 604800,  -- 7 days
--       initialDelaySeconds = 60,  -- don't run in first minute
--       handler = function()
--           -- do the pruning work
--       end,
--   })
--
-- DESIGN:
-- The scheduler ticks at a coarse interval (60s by default from
-- Constants.SCHEDULER_TICK_INTERVAL_MS). Each tick, it checks every
-- registered task and runs the ones whose next-due time has passed.
-- This is simpler and lower-overhead than one-thread-per-task, at the
-- cost of sub-minute precision — which we don't need.
--
-- ERROR HANDLING:
-- Handlers run inside pcall. A handler that errors logs a CRITICAL but
-- does NOT break the scheduler — other tasks continue to run. The
-- failed task's next run is still scheduled. If the same task errors
-- repeatedly, Sentinel will log each error, but the scheduler itself
-- stays healthy.
--
-- Dependencies: server/logger.lua, shared/constants.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Scheduler = {}

local Scheduler = BSD.Sentinel.Scheduler
local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants
local Utils = BSD.Sentinel.Utils


-- =============================================================================
-- INTERNAL STATE
-- =============================================================================

-- Registered tasks. Each entry:
--   {
--     name = string (unique),
--     intervalSeconds = number,
--     initialDelaySeconds = number,
--     handler = function,
--     nextRunAt = number (epoch seconds),
--     lastRunAt = number|nil,
--     lastDurationMs = number|nil,
--     runCount = number,
--     errorCount = number,
--     lastError = string|nil,
--   }
local tasks = {}

-- Whether the scheduler's background thread has been started.
-- Set true by Scheduler.Start, never flipped back.
local started = false

-- Whether the scheduler is accepting new registrations.
-- Opens automatically at module load; closes when Shutdown is called.
local accepting = true


-- =============================================================================
-- INTERNAL: TASK VALIDATION
-- =============================================================================

--- Validate a task registration. Returns (ok, reason).
---@param task table
---@return boolean ok
---@return string|nil reason
local function validateTask(task)
    if type(task) ~= 'table' then
        return false, 'task must be a table'
    end

    -- name: required, non-empty string, unique
    local ok, err = Utils.CheckNonEmptyString(task.name, 'task.name')
    if not ok then return false, err end

    for _, existing in ipairs(tasks) do
        if existing.name == task.name then
            return false, string.format(
                'task name "%s" is already registered', task.name
            )
        end
    end

    -- intervalSeconds: required, positive number
    if type(task.intervalSeconds) ~= 'number' or task.intervalSeconds <= 0 then
        return false, 'task.intervalSeconds must be a positive number'
    end

    -- initialDelaySeconds: optional, default 0, non-negative
    if task.initialDelaySeconds ~= nil then
        if type(task.initialDelaySeconds) ~= 'number'
            or task.initialDelaySeconds < 0 then
            return false, 'task.initialDelaySeconds must be a non-negative number'
        end
    end

    -- handler: required, function
    if type(task.handler) ~= 'function' then
        return false, 'task.handler must be a function'
    end

    return true
end


-- =============================================================================
-- PUBLIC: REGISTER TASK
-- =============================================================================


--- Register a new scheduled task.
-- Tasks are registered at module load time by modules that need them.
-- Registration is open until Scheduler.Shutdown is called.
---@param task table see USAGE comment above
---@return boolean ok
---@return string|nil err
function Scheduler.Register(task)
    if not accepting then
        Logger.Warning(
            'Scheduler.Register called after shutdown; ignoring task %s',
            tostring(task and task.name or '?')
        )
        return false, 'scheduler is not accepting new registrations'
    end

    local ok, err = validateTask(task)
    if not ok then
        Logger.Critical('Scheduler.Register rejected task: %s', err)
        return false, err
    end

    local now = os.time()
    local initialDelay = task.initialDelaySeconds or 0

    tasks[#tasks + 1] = {
        name = task.name,
        intervalSeconds = task.intervalSeconds,
        initialDelaySeconds = initialDelay,
        handler = task.handler,
        nextRunAt = now + initialDelay,
        lastRunAt = nil,
        lastDurationMs = nil,
        runCount = 0,
        errorCount = 0,
        lastError = nil,
    }

    Logger.Debug(
        'Scheduler registered task "%s" (interval=%ds, initial delay=%ds)',
        task.name, task.intervalSeconds, initialDelay
    )
    return true
end


-- =============================================================================
-- INTERNAL: RUN ONE TASK
-- =============================================================================

--- Execute a task's handler, tracking duration and catching errors.
---@param task table internal task entry
local function runTask(task)
    local startMs = GetGameTimer and GetGameTimer() or 0
    local ok, err = pcall(task.handler)
    local endMs = GetGameTimer and GetGameTimer() or 0

    local durationMs = endMs - startMs
    task.lastRunAt = os.time()
    task.lastDurationMs = durationMs
    task.runCount = task.runCount + 1
    task.nextRunAt = task.lastRunAt + task.intervalSeconds

    if not ok then
        task.errorCount = task.errorCount + 1
        task.lastError = tostring(err)
        Logger.Critical(
            'Scheduled task "%s" raised error: %s',
            task.name, tostring(err)
        )
        return
    end

    -- Slow task warning
    local threshold = (Constants and Constants.SCHEDULER_SLOW_TASK_THRESHOLD_MS) or 5000
    if durationMs > threshold then
        Logger.Warning(
            'Scheduled task "%s" took %dms (threshold %dms)',
            task.name, durationMs, threshold
        )
    else
        Logger.Debug(
            'Scheduled task "%s" completed in %dms',
            task.name, durationMs
        )
    end
end


-- =============================================================================
-- INTERNAL: TICK
-- =============================================================================

--- Run one scheduler tick. Checks every task; runs those whose nextRunAt
-- has passed. Called from the background thread started by Scheduler.Start.
local function tick()
    local now = os.time()
    for _, task in ipairs(tasks) do
        if now >= task.nextRunAt then
            runTask(task)
        end
    end
end


-- =============================================================================
-- PUBLIC: START
-- =============================================================================


--- Start the scheduler's background thread. Called by main.lua after all
-- other initialization is complete.
-- Tasks registered BEFORE Start was called have their nextRunAt already
-- set relative to their registration time, so Start doesn't restart them.
-- Idempotent — calling twice is a no-op with a warning.
function Scheduler.Start()
    if started then
        Logger.Warning('Scheduler.Start called but scheduler is already running')
        return
    end
    started = true

    local intervalMs = (Constants and Constants.SCHEDULER_TICK_INTERVAL_MS) or 60000

    Logger.Info('Scheduler started (tick interval=%dms, %d tasks registered)',
        intervalMs, #tasks)

    Citizen.CreateThread(function()
        while started do
            tick()
            Citizen.Wait(intervalMs)
        end
        Logger.Debug('Scheduler thread exiting')
    end)
end


-- =============================================================================
-- PUBLIC: SHUTDOWN
-- =============================================================================


--- Stop accepting new registrations and halt the background thread.
-- Called on resource stop from main.lua's onResourceStop handler.
function Scheduler.Shutdown()
    accepting = false
    started = false
    Logger.Debug('Scheduler shutdown requested (%d tasks registered at stop)',
        #tasks)
end


-- =============================================================================
-- PUBLIC: STATUS
-- =============================================================================


--- Get a snapshot of all registered tasks and their state.
-- Used by admin commands for visibility into what's scheduled.
-- Returns a LIST OF COPIES — caller can't mutate internal state.
---@return table
function Scheduler.Status()
    local snapshot = {}
    local now = os.time()
    for i, task in ipairs(tasks) do
        snapshot[i] = {
            name = task.name,
            intervalSeconds = task.intervalSeconds,
            nextRunInSeconds = math.max(0, task.nextRunAt - now),
            lastRunAt = task.lastRunAt,
            lastDurationMs = task.lastDurationMs,
            runCount = task.runCount,
            errorCount = task.errorCount,
            lastError = task.lastError,
        }
    end
    return snapshot
end


--- Check if the scheduler has started.
---@return boolean
function Scheduler.IsRunning()
    return started
end


--- Run a single task by name immediately, outside its schedule.
-- Useful for admin commands like /bsdprune to manually trigger retention
-- rather than waiting for the scheduled run.
---@param name string
---@return boolean ok
---@return string|nil err
function Scheduler.RunNow(name)
    for _, task in ipairs(tasks) do
        if task.name == name then
            Logger.Info('Scheduler.RunNow: manually running task "%s"', name)
            runTask(task)
            return true
        end
    end
    return false, string.format('no task named "%s" is registered', name)
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Scheduler loaded')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Scheduler.Register) == 'function', 'Scheduler.Register not defined')
assert(type(Scheduler.Start) == 'function', 'Scheduler.Start not defined')
assert(type(Scheduler.Status) == 'function', 'Scheduler.Status not defined')