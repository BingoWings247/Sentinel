-- =============================================================================
-- bsd_sentinel / server / query.lua
-- =============================================================================
-- Read-side query interface for Sentinel.
--
-- Other modules use this to retrieve events from the database. Admin
-- commands call these functions. Future exports for an admin UI will
-- call these functions. Domain modules investigating their own state
-- can call these functions.
--
-- DESIGN: This module owns ALL reads of bsd_sentinel_events. Centralizing
-- query construction here:
--   1. Prevents SQL injection by always using parameterized queries
--   2. Ensures consistent result shaping across callers
--   3. Lets us add caching, slow-query logging, and access control in
--      one place when we need them
--   4. Makes it trivial to swap query implementations (e.g., add Redis
--      cache) without changing every caller
--
-- DESIGN: Result rows are SHAPED before returning. The DB stores severity
-- as a TINYINT, but callers want a string. The DB stores metadata as JSON
-- text, but callers want a Lua table. shapeResultRow() handles all of
-- this normalization. Raw DB rows never escape this module.
--
-- DESIGN: Pagination defaults to 25 rows, max 100. If a query matches
-- more rows than the limit, the result includes a `truncated` flag and
-- `total_matched_estimate` so the caller can warn the operator.
--
-- Dependencies: server/db/driver.lua, server/logger.lua, shared/enums.lua,
--               shared/constants.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Query = {}

local Query = BSD.Sentinel.Query
local Logger = BSD.Sentinel.Logger
local Driver = BSD.Sentinel.DB.Driver
local Enums = BSD.Sentinel.Enums
local Constants = BSD.Sentinel.Constants
local Utils = BSD.Sentinel.Utils


-- =============================================================================
-- CONSTANTS
-- =============================================================================

-- Default number of results returned when caller doesn't specify a limit.
-- Chosen to fit comfortably in a single console screenful.
local DEFAULT_LIMIT = 25

-- Hard ceiling on results per query. Larger requests are clamped here
-- and the result is flagged as truncated.
local MAX_LIMIT = 100

-- For correlation chains, we use a higher cap because chains are bounded
-- by their nature (one logical operation rarely emits more than 50 events)
-- and getting the whole chain matters for investigation.
local MAX_CORRELATION_CHAIN_SIZE = 500


-- =============================================================================
-- INTERNAL: JSON DECODING
-- =============================================================================


--- Decode a JSON string back into a Lua table. Returns nil on failure
-- rather than erroring — bad metadata shouldn't break a whole query.
---@param s any
---@return any
local function decodeJson(s)
    if type(s) ~= 'string' or #s == 0 then return nil end
    if json and type(json.decode) == 'function' then
        local ok, decoded = pcall(json.decode, s)
        if ok then return decoded end
    end
    return nil
end


-- =============================================================================
-- INTERNAL: SHAPE A DB ROW INTO AN EVENT TABLE
-- =============================================================================


--- Convert a raw DB row into a normalized event table.
-- Translates severity int -> string, decodes metadata JSON, etc.
---@param row table raw DB row from oxmysql
---@return table event
local function shapeResultRow(row)
    if type(row) ~= 'table' then return {} end

    local severityStr = Enums.IntToSeverity(row.severity) or 'unknown'

    return {
        id = row.id,
        event_id = row.event_id,
        correlation_id = row.correlation_id,
        parent_event_id = row.parent_event_id,
        domain = row.domain,
        event_type = row.event_type,
        event_category = row.event_category,
        severity = severityStr,
        severity_int = row.severity,
        status = row.status,
        actor_type = row.actor_type,
        actor_identifier = row.actor_identifier,
        actor_source = row.actor_source,
        subject_type = row.subject_type,
        subject_id = row.subject_id,
        secondary_subject_id = row.secondary_subject_id,
        amount = row.amount,
        amount_unit = row.amount_unit,
        summary = row.summary,
        metadata = decodeJson(row.metadata),
        reverses_event_id = row.reverses_event_id,
        reversed_by_event_id = row.reversed_by_event_id,
        failure_reason = row.failure_reason,
        created_at = row.created_at,
        ingested_at = row.ingested_at,
    }
end


--- Apply shapeResultRow to every row in a list.
---@param rows table list of raw DB rows
---@return table list of shaped events
local function shapeRows(rows)
    if type(rows) ~= 'table' then return {} end
    local shaped = {}
    for i, row in ipairs(rows) do
        shaped[i] = shapeResultRow(row)
    end
    return shaped
end


-- =============================================================================
-- INTERNAL: FILTER VALIDATION & WHERE CLAUSE BUILDING
-- =============================================================================


--- Validate filter input. Returns (ok, filters_or_error).
-- Filters can be nil (treated as empty), or a table of fields. Each
-- field is validated and unrecognized fields are stripped out — we
-- don't want a typo'd filter to silently apply nothing.
---@param filters any
---@return boolean ok
---@return table|string filters_or_error
local function validateFilters(filters)
    if filters == nil then return true, {} end
    if type(filters) ~= 'table' then
        return false, 'filters must be a table'
    end

    local clean = {}

    if filters.domain ~= nil then
        if type(filters.domain) ~= 'string' or #filters.domain == 0 then
            return false, 'filter.domain must be a non-empty string'
        end
        clean.domain = filters.domain
    end

    if filters.event_type ~= nil then
        if type(filters.event_type) ~= 'string' or #filters.event_type == 0 then
            return false, 'filter.event_type must be a non-empty string'
        end
        clean.event_type = filters.event_type
    end

    if filters.event_category ~= nil then
        if not Enums.IsValidEventCategory(filters.event_category) then
            return false, 'filter.event_category must be a valid category'
        end
        clean.event_category = filters.event_category
    end

    if filters.severity_min ~= nil then
        if not Enums.IsValidSeverity(filters.severity_min) then
            return false, 'filter.severity_min must be a valid severity'
        end
        clean.severity_min = filters.severity_min
    end

    if filters.status ~= nil then
        if not Enums.IsValidEventStatus(filters.status) then
            return false, 'filter.status must be a valid status'
        end
        clean.status = filters.status
    end

    if filters.actor_identifier ~= nil then
        if type(filters.actor_identifier) ~= 'string' then
            return false, 'filter.actor_identifier must be a string'
        end
        clean.actor_identifier = filters.actor_identifier
    end

    if filters.actor_type ~= nil then
        if not Enums.IsValidActorType(filters.actor_type) then
            return false, 'filter.actor_type must be a valid actor type'
        end
        clean.actor_type = filters.actor_type
    end

    if filters.subject_id ~= nil then
        if type(filters.subject_id) ~= 'string' then
            return false, 'filter.subject_id must be a string'
        end
        clean.subject_id = filters.subject_id
    end

    if filters.subject_type ~= nil then
        if type(filters.subject_type) ~= 'string' then
            return false, 'filter.subject_type must be a string'
        end
        clean.subject_type = filters.subject_type
    end

    if filters.correlation_id ~= nil then
        if type(filters.correlation_id) ~= 'string' or not Utils.IsUUID(filters.correlation_id) then
            return false, 'filter.correlation_id must be a UUID'
        end
        clean.correlation_id = filters.correlation_id
    end

    -- Time range. Both bounds optional. since/until are MySQL timestamp strings.
    if filters.since ~= nil then
        if type(filters.since) ~= 'string' then
            return false, 'filter.since must be a MySQL timestamp string'
        end
        clean.since = filters.since
    end

    if filters['until'] ~= nil then
        if type(filters['until']) ~= 'string' then
            return false, 'filter.until must be a MySQL timestamp string'
        end
        clean['until'] = filters['until']
    end

    return true, clean
end


--- Build a SQL WHERE clause and parameter list from filters.
-- Returns (whereClause, paramsList). whereClause includes the leading
-- 'WHERE' if any conditions were added, or empty string if no filters.
---@param filters table validated filter table
---@return string whereClause
---@return table params
local function buildWhereClause(filters)
    local conditions = {}
    local params = {}
    local paramIndex = 0

    if filters.domain then
        conditions[#conditions + 1] = 'domain = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.domain
    end

    if filters.event_type then
        conditions[#conditions + 1] = 'event_type = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.event_type
    end

    if filters.event_category then
        conditions[#conditions + 1] = 'event_category = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.event_category
    end

    if filters.severity_min then
        conditions[#conditions + 1] = 'severity >= ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = Enums.SeverityToInt(filters.severity_min)
    end

    if filters.status then
        conditions[#conditions + 1] = 'status = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.status
    end

    if filters.actor_identifier then
        conditions[#conditions + 1] = 'actor_identifier = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.actor_identifier
    end

    if filters.actor_type then
        conditions[#conditions + 1] = 'actor_type = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.actor_type
    end

    if filters.subject_id then
        conditions[#conditions + 1] = 'subject_id = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.subject_id
    end

    if filters.subject_type then
        conditions[#conditions + 1] = 'subject_type = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.subject_type
    end

    if filters.correlation_id then
        conditions[#conditions + 1] = 'correlation_id = ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.correlation_id
    end

    if filters.since then
        conditions[#conditions + 1] = 'created_at >= ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters.since
    end

    if filters['until'] then
        conditions[#conditions + 1] = 'created_at <= ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = filters['until']
    end

    params.n = paramIndex

    if #conditions == 0 then
        return '', params
    end

    return 'WHERE ' .. table.concat(conditions, ' AND '), params
end


-- =============================================================================
-- PUBLIC: Find
-- =============================================================================


--- Search for events matching filters.
-- The main query function. Used by /bsdquery and many other consumers.
--
-- USAGE:
--   local result = Query.Find({
--       domain = 'banking',
--       severity_min = 'warning',
--       actor_identifier = 'license:abc',
--       since = '2026-04-27 00:00:00',
--   }, {
--       limit = 50,
--       order = 'desc',
--   })
--
--   for _, event in ipairs(result.events) do
--       -- ...
--   end
--   if result.truncated then
--       -- show "showing 50 of 200+ matches" hint
--   end
--
---@param filters table|nil filter conditions
---@param options table|nil { limit, offset, order ('asc'|'desc') }
---@return table result { events, count, limit, offset, truncated, error }
function Query.Find(filters, options)
    options = options or {}

    -- Validate filters
    local ok, validatedOrError = validateFilters(filters)
    if not ok then
        Logger.Warning('Query.Find rejected: %s', tostring(validatedOrError))
        return {
            events = {},
            count = 0,
            limit = 0,
            offset = 0,
            truncated = false,
            error = validatedOrError,
        }
    end
    local validated = validatedOrError

    -- Resolve limit and offset
    local limit = options.limit or DEFAULT_LIMIT
    if type(limit) ~= 'number' or limit < 1 then
        limit = DEFAULT_LIMIT
    end
    if limit > MAX_LIMIT then
        limit = MAX_LIMIT
    end
    limit = math.floor(limit)

    local offset = options.offset or 0
    if type(offset) ~= 'number' or offset < 0 then
        offset = 0
    end
    offset = math.floor(offset)

    local order = options.order
    if order ~= 'asc' and order ~= 'desc' then
        order = 'desc'  -- newest first by default
    end

    -- Build query
    local whereClause, params = buildWhereClause(validated)

    -- We fetch limit+1 rows so we can detect "truncated" without an
    -- additional COUNT(*) query. If we asked for 25 and got 26 back,
    -- there are more results than the caller asked for.
    local fetchLimit = limit + 1

    local sql = string.format(
        'SELECT * FROM bsd_sentinel_events %s ORDER BY created_at %s, id %s LIMIT %d OFFSET %d',
        whereClause,
        order:upper(),
        order:upper(),
        fetchLimit,
        offset
    )

    -- Run the query synchronously. Admin commands and reports want
    -- results inline; we're not on the player hot path.
    local rows = Driver.QuerySync(sql, params)
    if type(rows) ~= 'table' then
        return {
            events = {},
            count = 0,
            limit = limit,
            offset = offset,
            truncated = false,
            error = 'database query failed',
        }
    end

    -- Detect truncation: did we get more rows than the limit?
    local truncated = #rows > limit
    if truncated then
        -- Drop the extra row so caller sees exactly `limit` events
        rows[#rows] = nil
    end

    return {
        events = shapeRows(rows),
        count = #rows,
        limit = limit,
        offset = offset,
        truncated = truncated,
        error = nil,
    }
end


-- =============================================================================
-- PUBLIC: GetById
-- =============================================================================


--- Fetch a single event by its event_id (UUID).
-- Returns the full shaped event, or nil if not found.
---@param eventId string
---@return table|nil event
---@return string|nil error
function Query.GetById(eventId)
    if type(eventId) ~= 'string' or not Utils.IsUUID(eventId) then
        return nil, 'event_id must be a valid UUID'
    end

    local rows = Driver.QuerySync(
        'SELECT * FROM bsd_sentinel_events WHERE event_id = ? LIMIT 1',
        { eventId }
    )
    if type(rows) ~= 'table' or #rows == 0 then
        return nil, 'event not found'
    end

    return shapeResultRow(rows[1]), nil
end


-- =============================================================================
-- PUBLIC: Correlation
-- =============================================================================


--- Fetch all events sharing a correlation_id, ordered by creation time.
-- This is the "investigation" function — when staff want to know
-- "where did this car come from?" or "what happened in this transfer?",
-- they query by correlation_id.
---@param correlationId string
---@return table result { events, count, truncated, error }
function Query.Correlation(correlationId)
    if type(correlationId) ~= 'string' or not Utils.IsUUID(correlationId) then
        return {
            events = {},
            count = 0,
            truncated = false,
            error = 'correlation_id must be a valid UUID',
        }
    end

    -- Higher limit for chains; investigators want the whole chain.
    local fetchLimit = MAX_CORRELATION_CHAIN_SIZE + 1

    local rows = Driver.QuerySync(
        string.format(
            'SELECT * FROM bsd_sentinel_events WHERE correlation_id = ? ORDER BY created_at ASC, id ASC LIMIT %d',
            fetchLimit
        ),
        { correlationId }
    )
    if type(rows) ~= 'table' then
        return {
            events = {},
            count = 0,
            truncated = false,
            error = 'database query failed',
        }
    end

    local truncated = #rows > MAX_CORRELATION_CHAIN_SIZE
    if truncated then
        rows[#rows] = nil
    end

    return {
        events = shapeRows(rows),
        count = #rows,
        truncated = truncated,
        error = nil,
    }
end


-- =============================================================================
-- PUBLIC: RecentByActor
-- =============================================================================


--- Fetch recent events for a specific actor.
-- Convenience wrapper for the common "what has this player been doing?"
-- query. Equivalent to Query.Find({actor_identifier = X}, {limit = N})
-- but more discoverable in the API.
---@param actorIdentifier string
---@param limit integer|nil default 25
---@return table result
function Query.RecentByActor(actorIdentifier, limit)
    return Query.Find(
        { actor_identifier = actorIdentifier },
        { limit = limit, order = 'desc' }
    )
end


-- =============================================================================
-- PUBLIC: RecentBySubject
-- =============================================================================


--- Fetch recent events affecting a specific subject.
-- E.g., "show me all activity on account 12345" or "all activity on
-- vehicle plate ABC123".
---@param subjectType string e.g., 'account', 'vehicle'
---@param subjectId string
---@param limit integer|nil default 25
---@return table result
function Query.RecentBySubject(subjectType, subjectId, limit)
    return Query.Find(
        {
            subject_type = subjectType,
            subject_id = subjectId,
        },
        { limit = limit, order = 'desc' }
    )
end


-- =============================================================================
-- PUBLIC: Stats
-- =============================================================================


--- Aggregate statistics for dashboards and health checks.
-- Returns counts by severity, by domain, and total event count.
-- Optional time range filter via since/until.
---@param options table|nil { since, until }
---@return table stats
function Query.Stats(options)
    options = options or {}

    local conditions = {}
    local params = {}
    local paramIndex = 0

    if options.since then
        conditions[#conditions + 1] = 'created_at >= ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = options.since
    end
    if options['until'] then
        conditions[#conditions + 1] = 'created_at <= ?'
        paramIndex = paramIndex + 1
        params[paramIndex] = options['until']
    end
    params.n = paramIndex

    local whereClause = ''
    if #conditions > 0 then
        whereClause = 'WHERE ' .. table.concat(conditions, ' AND ')
    end

    -- Total count
    local countRows = Driver.QuerySync(
        string.format('SELECT COUNT(*) AS total FROM bsd_sentinel_events %s', whereClause),
        params
    )
    local total = 0
    if type(countRows) == 'table' and countRows[1] then
        total = countRows[1].total or 0
    end

    -- Counts by severity
    local severityRows = Driver.QuerySync(
        string.format(
            'SELECT severity, COUNT(*) AS n FROM bsd_sentinel_events %s GROUP BY severity ORDER BY severity DESC',
            whereClause
        ),
        params
    )
    local bySeverity = {}
    if type(severityRows) == 'table' then
        for _, row in ipairs(severityRows) do
            local sevStr = Enums.IntToSeverity(row.severity) or 'unknown'
            bySeverity[sevStr] = row.n or 0
        end
    end

    -- Counts by domain
    local domainRows = Driver.QuerySync(
        string.format(
            'SELECT domain, COUNT(*) AS n FROM bsd_sentinel_events %s GROUP BY domain ORDER BY n DESC LIMIT 20',
            whereClause
        ),
        params
    )
    local byDomain = {}
    if type(domainRows) == 'table' then
        for _, row in ipairs(domainRows) do
            byDomain[row.domain] = row.n or 0
        end
    end

    return {
        total = total,
        by_severity = bySeverity,
        by_domain = byDomain,
        since = options.since,
        ['until'] = options['until'],
    }
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Query module loaded')


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Query.Find) == 'function', 'Query.Find not defined')
assert(type(Query.GetById) == 'function', 'Query.GetById not defined')
assert(type(Query.Correlation) == 'function', 'Query.Correlation not defined')
assert(type(Query.RecentByActor) == 'function', 'Query.RecentByActor not defined')
assert(type(Query.Stats) == 'function', 'Query.Stats not defined')