-- =============================================================================
-- bsd_sentinel / server / ingestion.lua
-- =============================================================================
-- Event ingestion and flush orchestration. The heart of Sentinel.
--
-- DESIGN NOTE (v1.0.0-dev fixes applied):
--
-- FIX 1: PARAMETER ORDERING BUG.
--   Earlier version used `params[#params + 1] = row[col]` which broke when
--   row[col] was nil due to Lua's sparse-array length semantics. Fixed by
--   tracking paramIndex explicitly so nil values still occupy real slots.
--
-- FIX 2: OXMYSQL 2.x RESPONSE SHAPE.
--   oxmysql 2.x's :execute callback can return:
--     - a plain number (affected rows count) — older API style
--     - a table with .affectedRows field — newer API style
--     - nil/false on error
--   Earlier code only handled the number case, treating the table case as
--   failure. Fixed by interpreting all three cases correctly.
--
-- FIX 3: FLUSH-IN-PROGRESS DEADLOCK PROTECTION.
--   If the oxmysql callback never fires (network hang, library bug, etc.),
--   flushInProgress stays true forever and all future flush ticks skip.
--   Fixed by tracking flush start time and forcibly resetting if a flush
--   has been "in progress" for longer than reasonably possible.
--
-- Dependencies: server/logger.lua, server/registry.lua, server/correlation.lua,
--               server/buffer.lua, server/scheduler.lua, server/db/driver.lua,
--               shared/enums.lua, shared/constants.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Ingestion = {}

local Ingestion = BSD.Sentinel.Ingestion
local Logger = BSD.Sentinel.Logger
local Registry = BSD.Sentinel.Registry
local Correlation = BSD.Sentinel.Correlation
local Buffer = BSD.Sentinel.Buffer
local Scheduler = BSD.Sentinel.Scheduler
local Driver = BSD.Sentinel.DB.Driver
local Enums = BSD.Sentinel.Enums
local Constants = BSD.Sentinel.Constants
local Utils = BSD.Sentinel.Utils


-- =============================================================================
-- INTERNAL STATE
-- =============================================================================

local stats = {
    accepted_total = 0,
    rejected_total = 0,
    auto_registered_total = 0,
    flush_success_total = 0,
    flush_failure_total = 0,
    last_accepted_at = nil,
    last_rejected_at = nil,
    last_flush_at = nil,
}

local flushInProgress = false
local flushStartedAt = 0  -- epoch seconds when current flush started


-- =============================================================================
-- INTERNAL: JSON ENCODING
-- =============================================================================


local function encodeJson(value)
    if value == nil then return 'null', true end
    if json and type(json.encode) == 'function' then
        local ok, encoded = pcall(json.encode, value)
        if ok and type(encoded) == 'string' then
            return encoded, true
        end
    end
    if type(value) == 'table' then
        return '{}', false
    end
    return tostring(value), false
end


-- =============================================================================
-- INTERNAL: VALIDATION
-- =============================================================================


local function validateEmit(emit)
    if type(emit) ~= 'table' then
        return false, 'event must be a table'
    end

    local ok, err = Utils.CheckNonEmptyString(emit.domain, 'domain')
    if not ok then return false, err end

    ok, err = Utils.CheckNonEmptyString(emit.type, 'type')
    if not ok then return false, err end

    local summary = emit.summary
    if type(summary) ~= 'string' or #summary == 0 then
        summary = string.format('%s.%s', emit.domain, emit.type)
    end
    if #summary > Constants.MAX_SUMMARY_LENGTH then
        summary = Utils.Truncate(summary, Constants.MAX_SUMMARY_LENGTH)
    end

    local registered = Registry.GetEventType(emit.domain, emit.type)
    local devMode = Config.DevMode == true

    if not registered then
        if devMode then
            local cat = emit.category or Enums.EventCategory.SYSTEM
            local sev = emit.severity or Enums.Severity.INFO
            local regOk = Registry.AutoRegisterEventType(
                emit.domain, emit.type, cat, sev
            )
            if not regOk then
                return false, 'unknown event type and auto-register failed'
            end
            stats.auto_registered_total = stats.auto_registered_total + 1
            registered = Registry.GetEventType(emit.domain, emit.type)
        else
            return false, string.format(
                'unknown event type %s.%s (register via RegisterEventType, or enable DevMode)',
                emit.domain, emit.type
            )
        end
    end

    local category = emit.category or registered.category
    if not Enums.IsValidEventCategory(category) then
        return false, string.format(
            'invalid category "%s"', tostring(category)
        )
    end

    local severity = emit.severity or registered.default_severity
    if not Enums.IsValidSeverity(severity) then
        return false, string.format(
            'invalid severity "%s"', tostring(severity)
        )
    end

    local status = emit.status or Enums.EventStatus.COMPLETED
    if not Enums.IsValidEventStatus(status) then
        return false, string.format(
            'invalid status "%s"', tostring(status)
        )
    end

    local actorType = emit.actor_type or Enums.ActorType.SYSTEM
    if not Enums.IsValidActorType(actorType) then
        return false, string.format(
            'invalid actor_type "%s"', tostring(actorType)
        )
    end

    local actorIdentifier = emit.actor_identifier
    if actorIdentifier ~= nil and type(actorIdentifier) ~= 'string' then
        return false, 'actor_identifier must be a string or nil'
    end
    if actorIdentifier and #actorIdentifier > Constants.MAX_ACTOR_IDENTIFIER_LENGTH then
        actorIdentifier = actorIdentifier:sub(1, Constants.MAX_ACTOR_IDENTIFIER_LENGTH)
    end

    local actorSource = emit.actor_source
    if actorSource ~= nil and type(actorSource) ~= 'number' then
        return false, 'actor_source must be a number or nil'
    end

    local subjectType = emit.subject_type
    if subjectType ~= nil and type(subjectType) ~= 'string' then
        return false, 'subject_type must be a string or nil'
    end

    local subjectId = emit.subject_id
    if subjectId ~= nil and type(subjectId) ~= 'string' then
        if type(subjectId) == 'number' then
            subjectId = tostring(subjectId)
        else
            return false, 'subject_id must be a string, number, or nil'
        end
    end
    if subjectId and #subjectId > Constants.MAX_SUBJECT_ID_LENGTH then
        return false, string.format(
            'subject_id too long (max %d)', Constants.MAX_SUBJECT_ID_LENGTH
        )
    end

    local secondarySubjectId = emit.secondary_subject_id
    if secondarySubjectId ~= nil and type(secondarySubjectId) ~= 'string' then
        if type(secondarySubjectId) == 'number' then
            secondarySubjectId = tostring(secondarySubjectId)
        else
            return false, 'secondary_subject_id must be a string, number, or nil'
        end
    end

    local amount = emit.amount
    if amount ~= nil then
        if type(amount) ~= 'number' or amount ~= math.floor(amount) then
            return false, 'amount must be an integer or nil'
        end
    end

    local amountUnit = emit.amount_unit
    if amountUnit ~= nil and type(amountUnit) ~= 'string' then
        return false, 'amount_unit must be a string or nil'
    end

    if #registered.required_fields > 0 then
        local md = emit.metadata or {}
        for _, field in ipairs(registered.required_fields) do
            if md[field] == nil then
                return false, string.format(
                    'required metadata field "%s" is missing', field
                )
            end
        end
    end

    local failureReason = emit.failure_reason
    if failureReason ~= nil then
        if type(failureReason) ~= 'string' then
            return false, 'failure_reason must be a string or nil'
        end
        if #failureReason > Constants.MAX_FAILURE_REASON_LENGTH then
            failureReason = failureReason:sub(1, Constants.MAX_FAILURE_REASON_LENGTH)
        end
    end

    return true, nil, {
        domain = emit.domain,
        event_type = emit.type,
        event_category = category,
        severity = severity,
        status = status,
        actor_type = actorType,
        actor_identifier = actorIdentifier,
        actor_source = actorSource,
        subject_type = subjectType,
        subject_id = subjectId,
        secondary_subject_id = secondarySubjectId,
        amount = amount,
        amount_unit = amountUnit,
        summary = summary,
        metadata = emit.metadata,
        failure_reason = failureReason,
        reverses_event_id = emit.reverses_event_id,
        parent_event_id = emit.parent_event_id,
        correlation_id = emit.correlation_id,
    }
end


-- =============================================================================
-- INTERNAL: SHAPING
-- =============================================================================


local function shapeRow(resolved)
    local eventId = Utils.GenerateUUIDv7()
    local correlationId = Correlation.Resolve(resolved.correlation_id)
    local nowTs = Utils.NowMysqlTimestamp()

    local severityInt = Enums.SeverityToInt(resolved.severity) or 1

    local metadataJson = nil
    if resolved.metadata ~= nil then
        local encoded, _ = encodeJson(resolved.metadata)
        metadataJson = encoded
    end

    return {
        event_id = eventId,
        correlation_id = correlationId,
        parent_event_id = resolved.parent_event_id,
        domain = resolved.domain,
        event_type = resolved.event_type,
        event_category = resolved.event_category,
        severity = severityInt,
        status = resolved.status,
        actor_type = resolved.actor_type,
        actor_identifier = resolved.actor_identifier,
        actor_source = resolved.actor_source,
        subject_type = resolved.subject_type,
        subject_id = resolved.subject_id,
        secondary_subject_id = resolved.secondary_subject_id,
        amount = resolved.amount,
        amount_unit = resolved.amount_unit,
        summary = resolved.summary,
        metadata = metadataJson,
        reverses_event_id = resolved.reverses_event_id,
        failure_reason = resolved.failure_reason,
        created_at = nowTs,
    }
end


-- =============================================================================
-- PUBLIC: EMIT
-- =============================================================================


function Ingestion.Emit(emit)
    local ok, err, resolved = validateEmit(emit)
    if not ok then
        stats.rejected_total = stats.rejected_total + 1
        stats.last_rejected_at = os.time()

        Logger.Warning(
            'Event rejected (%s.%s): %s',
            tostring(emit and emit.domain or '?'),
            tostring(emit and emit.type or '?'),
            err
        )
        return false, nil, err
    end

    local row = shapeRow(resolved)

    local accepted = Buffer.Push(row)
    if not accepted then
        Logger.Warning(
            'Buffer full on emit of %s.%s; spilling directly',
            resolved.domain, resolved.event_type
        )
        Buffer.Spill({ row })
    end

    stats.accepted_total = stats.accepted_total + 1
    stats.last_accepted_at = os.time()
    return true, row.event_id
end


-- =============================================================================
-- INTERNAL: INTERPRET OXMYSQL RESULT
-- =============================================================================


--- Interpret oxmysql's :execute callback result.
-- Different oxmysql versions return different shapes. This function
-- normalizes all of them into a (success, affectedRows) tuple.
---@param result any
---@return boolean success
---@return integer affectedRows
local function interpretExecuteResult(result)
    -- nil/false = explicit failure
    if result == nil or result == false then
        return false, 0
    end

    -- Plain number = older oxmysql API, returns affected row count directly
    if type(result) == 'number' then
        if result > 0 then
            return true, result
        end
        return false, 0
    end

    -- Table = newer oxmysql API, returns result object
    if type(result) == 'table' then
        -- oxmysql 2.x typical shape: { affectedRows, insertId, ... }
        if type(result.affectedRows) == 'number' then
            if result.affectedRows > 0 then
                return true, result.affectedRows
            end
            return false, 0
        end

        -- Some versions use "changedRows" or similar
        if type(result.changedRows) == 'number' then
            if result.changedRows > 0 then
                return true, result.changedRows
            end
            return false, 0
        end

        -- If it's a non-empty table with no recognized field but no error,
        -- assume success. This is conservative — better to think we succeeded
        -- on a real success than to retry-loop on a successful insert.
        if next(result) ~= nil then
            return true, 1
        end
    end

    -- Unknown shape: assume failure
    return false, 0
end


-- =============================================================================
-- INTERNAL: FLUSH TO DB
-- =============================================================================


local function buildInsertStatement(rows)
    local columns = {
        'event_id', 'correlation_id', 'parent_event_id',
        'domain', 'event_type', 'event_category',
        'severity', 'status',
        'actor_type', 'actor_identifier', 'actor_source',
        'subject_type', 'subject_id', 'secondary_subject_id',
        'amount', 'amount_unit',
        'summary', 'metadata',
        'reverses_event_id', 'failure_reason',
        'created_at'
    }

    local placeholders = {}
    for _ = 1, #columns do placeholders[#placeholders + 1] = '?' end
    local onePlaceholderGroup = '(' .. table.concat(placeholders, ', ') .. ')'

    local valueGroups = {}
    local params = {}
    local paramIndex = 0

    for _, row in ipairs(rows) do
        valueGroups[#valueGroups + 1] = onePlaceholderGroup
        for _, col in ipairs(columns) do
            paramIndex = paramIndex + 1
            params[paramIndex] = row[col]
        end
    end

    params.n = paramIndex

    local sql = string.format(
        'INSERT INTO bsd_sentinel_events (%s) VALUES %s',
        table.concat(columns, ', '),
        table.concat(valueGroups, ', ')
    )
    return sql, params
end


-- Maximum reasonable time a flush can take, in seconds. Beyond this, we
-- assume the callback is dead and forcibly reset the in-progress flag.
local FLUSH_TIMEOUT_SECONDS = 30


local function runFlush()
    -- Defensive: if a flush has been "in progress" for longer than the
    -- timeout, assume something hung and reset. This prevents permanent
    -- deadlock if a callback never fires.
    if flushInProgress then
        local elapsed = os.time() - flushStartedAt
        if elapsed > FLUSH_TIMEOUT_SECONDS then
            Logger.Warning(
                'Flush appears stuck (in progress for %ds); resetting flag',
                elapsed
            )
            flushInProgress = false
            -- Fall through to start a new flush
        else
            Logger.Debug('Flush still in progress; skipping this tick')
            return
        end
    end

    flushInProgress = true
    flushStartedAt = os.time()

    local batchSize = (Config and Config.Buffer and Config.Buffer.FlushBatchSize)
        or Constants.DEFAULT_FLUSH_BATCH_SIZE

    local events = Buffer.Drain(batchSize)
    if #events == 0 then
        flushInProgress = false
        return
    end

    if not Driver.Ping() then
        Logger.Warning('DB unreachable; re-buffering %d events and spilling', #events)
        local _, rejected = Buffer.Rebuffer(events)
        if rejected > 0 then
            local toSpill = {}
            local start = #events - rejected + 1
            for i = start, #events do
                toSpill[#toSpill + 1] = events[i]
            end
            Buffer.Spill(toSpill)
        end
        stats.flush_failure_total = stats.flush_failure_total + 1
        flushInProgress = false
        return
    end

    local sql, params = buildInsertStatement(events)

    Driver.Execute(sql, params, function(result)
        local success, affectedRows = interpretExecuteResult(result)

        if success then
            Buffer.RecordFlush(#events)
            stats.flush_success_total = stats.flush_success_total + 1
            stats.last_flush_at = os.time()
            Logger.Debug('Flushed %d events (DB affected: %d)',
                #events, affectedRows)
        else
            Logger.Critical(
                'Flush of %d events failed (result type=%s); re-buffering',
                #events, type(result)
            )
            local _, rejected = Buffer.Rebuffer(events)
            if rejected > 0 then
                local toSpill = {}
                local start = #events - rejected + 1
                for i = start, #events do
                    toSpill[#toSpill + 1] = events[i]
                end
                Buffer.Spill(toSpill)
            end
            stats.flush_failure_total = stats.flush_failure_total + 1
        end
        flushInProgress = false
    end)
end


-- =============================================================================
-- PUBLIC: START
-- =============================================================================


function Ingestion.Start()
    Buffer.Initialize(Config.Buffer, Config.Spill)

    local intervalMs = (Config and Config.Buffer and Config.Buffer.FlushIntervalMs)
        or Constants.DEFAULT_FLUSH_INTERVAL_MS
    local intervalSeconds = math.max(1, math.floor(intervalMs / 1000))

    Scheduler.Register({
        name = 'sentinel_flush',
        intervalSeconds = intervalSeconds,
        initialDelaySeconds = intervalSeconds,
        handler = runFlush,
    })

    Logger.Info('Ingestion started (flush every %ds)', intervalSeconds)
end


-- =============================================================================
-- PUBLIC: STATS
-- =============================================================================


function Ingestion.Stats()
    return {
        accepted_total = stats.accepted_total,
        rejected_total = stats.rejected_total,
        auto_registered_total = stats.auto_registered_total,
        flush_success_total = stats.flush_success_total,
        flush_failure_total = stats.flush_failure_total,
        last_accepted_at = stats.last_accepted_at,
        last_rejected_at = stats.last_rejected_at,
        last_flush_at = stats.last_flush_at,
    }
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Ingestion loaded (awaiting Start)')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Ingestion.Emit) == 'function', 'Ingestion.Emit not defined')
assert(type(Ingestion.Start) == 'function', 'Ingestion.Start not defined')
assert(type(Ingestion.Stats) == 'function', 'Ingestion.Stats not defined')