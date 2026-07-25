-- =============================================================================
-- bsd_sentinel / server / correlation.lua
-- =============================================================================
-- Correlation ID management.
--
-- When a player performs one logical operation — say, "buy a car" — that
-- operation may produce multiple events across multiple domains:
--   banking.withdrawal_completed    (player's account debited)
--   banking.deposit_completed       (dealership account credited)
--   vehicle.title_transferred       (vehicle ownership moved)
--   dmv.registration_issued         (DMV updated)
--   treasury.sales_tax_remitted     (city received tax)
--
-- Investigating "where did this car come from?" means finding all five
-- events. That only works if they share a common identifier: the
-- correlation_id.
--
-- This module provides two ways to manage correlation_ids:
--
-- 1. EXPLICIT: create an ID at the start of an operation, pass it through
--    every event emission manually.
--
--      local correlationId = Sentinel.NewCorrelationId()
--      -- ... do work, pass correlationId to every emit
--
-- 2. CONTEXT: wrap the operation in a function that automatically
--    propagates the correlation ID. Any emit call made within the
--    function picks up the current correlation ID without needing it
--    explicitly passed.
--
--      Sentinel.WithContext(function()
--          BuyCar(player, vehicle)  -- any emits inside get the same ID
--      end)
--
-- USAGE PATTERN: WithContext is preferred for operations that have a
-- clear logical boundary. Explicit IDs are better for long-running
-- operations that span multiple ticks, or cross-resource operations
-- where the context stack doesn't help.
--
-- DESIGN: Uses a thread-local context stack. Each Citizen.CreateThread
-- has its own Lua coroutine, and we track context per-coroutine. This
-- means concurrent operations don't leak their correlation IDs into
-- each other.
--
-- Dependencies: server/logger.lua, shared/utils.lua, shared/constants.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Correlation = {}

local Correlation = BSD.Sentinel.Correlation
local Logger = BSD.Sentinel.Logger
local Utils = BSD.Sentinel.Utils
local Constants = BSD.Sentinel.Constants


-- =============================================================================
-- INTERNAL STATE
-- =============================================================================
-- contextStacks: coroutine -> list of correlation IDs (stack)
-- Using weak keys so dead coroutines get garbage collected rather than
-- leaking memory indefinitely.
local contextStacks = setmetatable({}, { __mode = 'k' })


-- =============================================================================
-- INTERNAL: CURRENT COROUTINE ACCESS
-- =============================================================================

--- Get the stack for the current coroutine, creating it if needed.
---@return table
local function currentStack()
    local co = coroutine.running()
    if not contextStacks[co] then
        contextStacks[co] = {}
    end
    return contextStacks[co]
end


-- =============================================================================
-- PUBLIC: GENERATE NEW CORRELATION ID
-- =============================================================================


--- Generate a new correlation ID.
-- Simply a UUID v7. The type is the same as event_id but the semantic
-- meaning is different: this groups events, not identifies them.
---@return string
function Correlation.NewCorrelationId()
    return Utils.GenerateUUIDv7()
end


-- =============================================================================
-- PUBLIC: WITH CONTEXT
-- =============================================================================


--- Execute a function with an automatic correlation ID in context.
-- Any event emitted via Sentinel.Emit within the function body picks up
-- the context's correlation ID.
--
-- If a correlationId is not provided, a new one is generated.
-- Nested calls to WithContext stack: inner calls get their own ID by
-- default (reflecting "sub-operation"), but can be told to inherit the
-- outer context's ID via the inherit=true flag.
---@param fn function the operation to execute
---@param correlationId string|nil explicit ID, or nil to generate new one
---@param inherit boolean|nil if true, reuse the outer context's ID
---@return any ... whatever the function returned
function Correlation.WithContext(fn, correlationId, inherit)
    if type(fn) ~= 'function' then
        Logger.Critical('WithContext: fn must be a function')
        return
    end

    local stack = currentStack()

    -- Check stack depth for runaway recursion protection
    local maxDepth = (Constants and Constants.MAX_CONTEXT_STACK_DEPTH) or 32
    if #stack >= maxDepth then
        Logger.Critical(
            'WithContext: stack depth %d exceeds limit %d; ' ..
            'possible runaway recursion — refusing to push',
            #stack, maxDepth
        )
        return fn()  -- execute without context rather than failing entirely
    end

    -- Determine what ID to use
    local idToPush
    if inherit and #stack > 0 then
        idToPush = stack[#stack]  -- reuse outer context's ID
    elseif correlationId and type(correlationId) == 'string' and Utils.IsUUID(correlationId) then
        idToPush = correlationId  -- use provided ID
    else
        idToPush = Correlation.NewCorrelationId()  -- generate new
    end

    -- Push
    stack[#stack + 1] = idToPush

    -- Execute with error capture so we always pop
    local ok, result = pcall(fn)

    -- Pop
    stack[#stack] = nil

    if not ok then
        -- Rethrow the error after cleanup
        error(result, 2)
    end

    return result
end


-- =============================================================================
-- PUBLIC: CURRENT CONTEXT
-- =============================================================================


--- Return the currently active correlation ID, if any.
-- Returns nil if not inside a WithContext block.
---@return string|nil
function Correlation.Current()
    local stack = currentStack()
    if #stack == 0 then return nil end
    return stack[#stack]
end


--- Return the entire current context stack (useful for debugging).
-- Returns a COPY so callers can't mutate internal state.
---@return table
function Correlation.Stack()
    local stack = currentStack()
    local copy = {}
    for i, v in ipairs(stack) do copy[i] = v end
    return copy
end


-- =============================================================================
-- PUBLIC: EXPLICIT PUSH/POP
-- =============================================================================
-- For cases where WithContext's function-wrapping doesn't fit — e.g.,
-- long-running operations that span ticks. Use with care; forgotten
-- Pop calls cause stack buildup.


--- Push a correlation ID onto the current coroutine's stack.
-- Caller must Pop when done. Prefer WithContext when possible.
---@param correlationId string|nil ID to push, or nil to generate
---@return string id the ID that was pushed
function Correlation.Push(correlationId)
    local stack = currentStack()
    local maxDepth = (Constants and Constants.MAX_CONTEXT_STACK_DEPTH) or 32
    if #stack >= maxDepth then
        Logger.Critical(
            'Correlation.Push: stack depth %d exceeds limit %d; ' ..
            'refusing to push. Check for missing Pop calls.',
            #stack, maxDepth
        )
        return stack[#stack] or Correlation.NewCorrelationId()
    end

    local id = correlationId
    if type(id) ~= 'string' or not Utils.IsUUID(id) then
        id = Correlation.NewCorrelationId()
    end
    stack[#stack + 1] = id
    return id
end


--- Pop the top of the current coroutine's correlation stack.
-- Returns the ID that was popped, or nil if the stack was empty.
---@return string|nil
function Correlation.Pop()
    local stack = currentStack()
    if #stack == 0 then
        Logger.Warning('Correlation.Pop called on empty stack')
        return nil
    end
    local popped = stack[#stack]
    stack[#stack] = nil
    return popped
end


-- =============================================================================
-- PUBLIC: RESOLVE (for ingestion)
-- =============================================================================


--- Resolve the correlation ID for an event being emitted.
-- The ingestion layer calls this to pick the right correlation ID:
--   - If the emitter explicitly provided one, use it
--   - Otherwise, use the current context ID if inside WithContext
--   - Otherwise, generate a new single-event correlation ID
--
-- Single-event correlation IDs are valid — an event that stands alone
-- still gets an ID so it's self-consistent with events that chain.
---@param explicitId string|nil an ID provided by the caller
---@return string correlationId
function Correlation.Resolve(explicitId)
    if type(explicitId) == 'string' and Utils.IsUUID(explicitId) then
        return explicitId
    end
    local current = Correlation.Current()
    if current then return current end
    return Correlation.NewCorrelationId()
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Correlation tracker loaded')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Correlation.NewCorrelationId) == 'function', 'Correlation.NewCorrelationId not defined')
assert(type(Correlation.WithContext) == 'function', 'Correlation.WithContext not defined')
assert(type(Correlation.Current) == 'function', 'Correlation.Current not defined')
assert(type(Correlation.Resolve) == 'function', 'Correlation.Resolve not defined')