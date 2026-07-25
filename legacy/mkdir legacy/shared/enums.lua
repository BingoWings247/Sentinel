-- =============================================================================
-- bsd_sentinel / shared / enums.lua
-- =============================================================================
-- Canonical enum definitions for Sentinel.
--
-- Every value that has a defined set of valid options is declared here.
-- Other modules reference these tables rather than hardcoding strings, so
-- we never get typo-driven bugs like 'complete' vs 'completed' or
-- 'critical' vs 'Critical' scattered across the codebase.
--
-- DESIGN: These are both lookup tables (for validation) and enum tables
-- (for iteration). Every enum has an array form (for ipairs) and a set
-- form (for O(1) membership checks). The Utils.CheckEnum function
-- handles either.
--
-- DESIGN: Enum values are strings, not integers. Integers are marginally
-- faster and use less storage, but strings are self-documenting when
-- you read a database row or log line. At FiveM's scale, the performance
-- difference is irrelevant; the readability difference is not.
--
-- EXCEPTION: severity is stored as TINYINT in the DB (0-3) because we
-- sort and range-query by severity often and integer indexes are
-- dramatically faster than string indexes for ordered comparisons.
-- See the helper functions at the end of this file for conversion.
--
-- Dependencies: shared/utils.lua (for Utils.CheckEnum)
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Enums = {}

local Enums = BSD.Sentinel.Enums


-- =============================================================================
-- SEVERITY LEVELS
-- =============================================================================
-- Four levels, not six (see scope doc §4 for rationale).
--
-- Stored in the database as TINYINT. Used in code as strings. Conversion
-- helpers at the end of this file.
--
-- Meaning:
--   DEBUG    - development-only events. Not retained long (7 days default).
--              Use for 'function entered', 'variable state', 'this path taken'.
--   INFO     - normal operation events. The bulk of the event log.
--              Transfers, registrations, lookups, routine state changes.
--   WARNING  - something unexpected but not yet broken. Auto-registered
--              event types, reconciliation discrepancies, near-limit conditions,
--              slow queries, degraded dependencies.
--   CRITICAL - action required. Promoted to alerts automatically.
--              Brute force detected, integrity mismatch, security event,
--              system failure.
--
-- DO NOT add a fifth level. The whole point of having four is that operators
-- remember them. Every additional level is one more arbitrary distinction
-- authors have to make and operators have to remember.
-- =============================================================================

Enums.Severity = {
    DEBUG    = 'debug',
    INFO     = 'info',
    WARNING  = 'warning',
    CRITICAL = 'critical',
}

-- Ordered array for iteration and DB conversion.
-- Order is MEANINGFUL: index 1 (offset to 0 below) = debug, index 4 = critical.
-- Used by SeverityToInt / IntToSeverity.
Enums.SeverityOrdered = {
    Enums.Severity.DEBUG,
    Enums.Severity.INFO,
    Enums.Severity.WARNING,
    Enums.Severity.CRITICAL,
}

-- Set form for membership checks.
Enums.SeveritySet = {
    [Enums.Severity.DEBUG]    = true,
    [Enums.Severity.INFO]     = true,
    [Enums.Severity.WARNING]  = true,
    [Enums.Severity.CRITICAL] = true,
}


--- Convert a severity string to its database integer representation.
-- Returns 0-3 for valid severities. Returns nil for unknown values.
---@param severityString string
---@return integer|nil
function Enums.SeverityToInt(severityString)
    for i, sev in ipairs(Enums.SeverityOrdered) do
        if sev == severityString then
            return i - 1  -- 1-indexed Lua, 0-indexed DB
        end
    end
    return nil
end


--- Convert a database integer severity to its string representation.
-- Returns a valid severity string for 0-3. Returns nil for other values.
---@param severityInt integer
---@return string|nil
function Enums.IntToSeverity(severityInt)
    local index = severityInt + 1  -- 0-indexed DB, 1-indexed Lua
    return Enums.SeverityOrdered[index]
end


--- Check whether a severity value is valid.
---@param severity any
---@return boolean
function Enums.IsValidSeverity(severity)
    return type(severity) == 'string' and Enums.SeveritySet[severity] == true
end


-- =============================================================================
-- EVENT CATEGORIES
-- =============================================================================
-- Categories group events by "kind of action" for filtering and authorization.
--
-- Meaning:
--   MUTATION  - the event describes a change to persistent state.
--               Account debit, record update, permission change.
--   QUERY     - the event describes a read-only access.
--               Lookup performed, report generated, balance checked.
--               (Most reads are NOT logged; only ones operators care about.)
--   AUTH      - authentication or authorization event.
--               Login, PIN check, role verification, failed attempt.
--   ADMIN     - action taken by staff/operator rather than a player.
--               Reversal, account freeze, config change, emergency override.
--   SYSTEM    - the resource itself reporting on its own operation.
--               Startup, shutdown, reconciliation run, scheduled task.
--
-- DESIGN: These five are canonical for v1.0. New categories require scope
-- doc update. Do NOT add ad-hoc categories as needed; the whole point is
-- that a small set remains manageable for operators.
-- =============================================================================

Enums.EventCategory = {
    MUTATION = 'mutation',
    QUERY    = 'query',
    AUTH     = 'auth',
    ADMIN    = 'admin',
    SYSTEM   = 'system',
}

Enums.EventCategoryOrdered = {
    Enums.EventCategory.MUTATION,
    Enums.EventCategory.QUERY,
    Enums.EventCategory.AUTH,
    Enums.EventCategory.ADMIN,
    Enums.EventCategory.SYSTEM,
}

Enums.EventCategorySet = {
    [Enums.EventCategory.MUTATION] = true,
    [Enums.EventCategory.QUERY]    = true,
    [Enums.EventCategory.AUTH]     = true,
    [Enums.EventCategory.ADMIN]    = true,
    [Enums.EventCategory.SYSTEM]   = true,
}


--- Check whether an event category value is valid.
---@param category any
---@return boolean
function Enums.IsValidEventCategory(category)
    return type(category) == 'string' and Enums.EventCategorySet[category] == true
end


-- =============================================================================
-- ACTOR TYPES
-- =============================================================================
-- Describes who caused an event.
--
-- Meaning:
--   PLAYER    - a specific human player did this. actor_identifier is their
--               license or equivalent.
--   STAFF     - a staff member (admin, moderator, staff role) did this.
--               Separated from PLAYER so staff actions can be filtered and
--               audited independently. actor_identifier is their staff ID.
--   SYSTEM    - the server itself did this, as part of normal operation.
--               actor_identifier is conventionally 'system' or a subsystem
--               name like 'sentinel_startup' or 'banking_reconciler'.
--   SCHEDULED - a cron or timer did this. Distinguished from SYSTEM because
--               'actions at 3am by an automated task' is a different
--               investigation pattern than 'actions triggered by an event'.
--               actor_identifier is the task name.
--   EXTERNAL  - an outside caller did this. Reserved for future API/webhook
--               integrations. Not used in v1.0 except for self-documentation.
-- =============================================================================

Enums.ActorType = {
    PLAYER    = 'player',
    STAFF     = 'staff',
    SYSTEM    = 'system',
    SCHEDULED = 'scheduled',
    EXTERNAL  = 'external',
}

Enums.ActorTypeOrdered = {
    Enums.ActorType.PLAYER,
    Enums.ActorType.STAFF,
    Enums.ActorType.SYSTEM,
    Enums.ActorType.SCHEDULED,
    Enums.ActorType.EXTERNAL,
}

Enums.ActorTypeSet = {
    [Enums.ActorType.PLAYER]    = true,
    [Enums.ActorType.STAFF]     = true,
    [Enums.ActorType.SYSTEM]    = true,
    [Enums.ActorType.SCHEDULED] = true,
    [Enums.ActorType.EXTERNAL]  = true,
}


--- Check whether an actor type value is valid.
---@param actorType any
---@return boolean
function Enums.IsValidActorType(actorType)
    return type(actorType) == 'string' and Enums.ActorTypeSet[actorType] == true
end


-- =============================================================================
-- EVENT STATUS
-- =============================================================================
-- Lifecycle state of the action the event describes.
--
-- Meaning:
--   INTENDED   - the action was requested but has not yet been attempted.
--                Rare in practice; used when we want to record 'the system
--                was asked to do X' separately from 'X completed'.
--   PENDING    - the action is in progress and has not resolved.
--                Used for multi-step operations where we want to record
--                the intermediate state.
--   COMPLETED  - the action succeeded. Default status for most events.
--   FAILED     - the action was attempted and did not succeed.
--                failure_reason should be populated.
--   REVERSED   - this event has been reversed by a later event.
--                reversed_by_event_id should be populated.
--
-- DESIGN: REVERSED is a status on the ORIGINAL event, not on the reversal
-- event. The reversal event itself has status COMPLETED, and its
-- reverses_event_id points at the original. This keeps the reversal
-- chain queryable in both directions.
-- =============================================================================

Enums.EventStatus = {
    INTENDED  = 'intended',
    PENDING   = 'pending',
    COMPLETED = 'completed',
    FAILED    = 'failed',
    REVERSED  = 'reversed',
}

Enums.EventStatusOrdered = {
    Enums.EventStatus.INTENDED,
    Enums.EventStatus.PENDING,
    Enums.EventStatus.COMPLETED,
    Enums.EventStatus.FAILED,
    Enums.EventStatus.REVERSED,
}

Enums.EventStatusSet = {
    [Enums.EventStatus.INTENDED]  = true,
    [Enums.EventStatus.PENDING]   = true,
    [Enums.EventStatus.COMPLETED] = true,
    [Enums.EventStatus.FAILED]    = true,
    [Enums.EventStatus.REVERSED]  = true,
}


--- Check whether an event status value is valid.
---@param status any
---@return boolean
function Enums.IsValidEventStatus(status)
    return type(status) == 'string' and Enums.EventStatusSet[status] == true
end


-- =============================================================================
-- ALERT STATUS
-- =============================================================================
-- Lifecycle state of an alert in the alert queue.
--
-- Meaning:
--   NEW            - just created, no human has looked at it.
--   ACKNOWLEDGED   - staff has seen it and is tracking it, no action yet.
--   INVESTIGATING  - staff is actively working on it.
--   RESOLVED       - the issue was real and has been addressed.
--                    resolution_notes should explain what was done.
--   FALSE_POSITIVE - the alert was incorrect. Used to tune rules later.
--
-- DESIGN: Distinct from event status because alerts have their own
-- lifecycle separate from the events that triggered them. An event can
-- be completed, and the alert about it can still be in investigating
-- state because staff is figuring out what to do about it.
-- =============================================================================

Enums.AlertStatus = {
    NEW            = 'new',
    ACKNOWLEDGED   = 'acknowledged',
    INVESTIGATING  = 'investigating',
    RESOLVED       = 'resolved',
    FALSE_POSITIVE = 'false_positive',
}

Enums.AlertStatusOrdered = {
    Enums.AlertStatus.NEW,
    Enums.AlertStatus.ACKNOWLEDGED,
    Enums.AlertStatus.INVESTIGATING,
    Enums.AlertStatus.RESOLVED,
    Enums.AlertStatus.FALSE_POSITIVE,
}

Enums.AlertStatusSet = {
    [Enums.AlertStatus.NEW]            = true,
    [Enums.AlertStatus.ACKNOWLEDGED]   = true,
    [Enums.AlertStatus.INVESTIGATING]  = true,
    [Enums.AlertStatus.RESOLVED]       = true,
    [Enums.AlertStatus.FALSE_POSITIVE] = true,
}


--- Check whether an alert status value is valid.
---@param status any
---@return boolean
function Enums.IsValidAlertStatus(status)
    return type(status) == 'string' and Enums.AlertStatusSet[status] == true
end


--- Check whether an alert status represents an open (unresolved) state.
-- Open statuses: NEW, ACKNOWLEDGED, INVESTIGATING.
-- Closed statuses: RESOLVED, FALSE_POSITIVE.
-- Used by admin commands and health reports to count open alerts.
---@param status string
---@return boolean
function Enums.IsOpenAlertStatus(status)
    return status == Enums.AlertStatus.NEW
        or status == Enums.AlertStatus.ACKNOWLEDGED
        or status == Enums.AlertStatus.INVESTIGATING
end


-- =============================================================================
-- DOMAIN STATUS (Resource Health)
-- =============================================================================
-- Describes the operational state of a registered domain module as seen
-- by Sentinel.
--
-- Meaning:
--   ALIVE        - emitting events at its usual rate. Healthy.
--   SILENT       - registered and loaded, but no recent events.
--                  Possibly broken, possibly just idle in a quiet period.
--   ERRORING     - emitting elevated rates of 'failed' status events.
--                  Something is going wrong inside the domain.
--   NEVER_SEEN   - listed as a dependent in server.cfg or expected to be
--                  registered, but has never emitted any events. Probably
--                  crashed at startup.
--
-- DESIGN: These are computed on-demand, not stored persistently. The
-- query engine evaluates a domain's recent event pattern when asked,
-- which is the correct tradeoff — a persistent status field would
-- require constant updates as events arrive.
-- =============================================================================

Enums.DomainStatus = {
    ALIVE      = 'alive',
    SILENT     = 'silent',
    ERRORING   = 'erroring',
    NEVER_SEEN = 'never_seen',
}

Enums.DomainStatusOrdered = {
    Enums.DomainStatus.ALIVE,
    Enums.DomainStatus.SILENT,
    Enums.DomainStatus.ERRORING,
    Enums.DomainStatus.NEVER_SEEN,
}

Enums.DomainStatusSet = {
    [Enums.DomainStatus.ALIVE]      = true,
    [Enums.DomainStatus.SILENT]     = true,
    [Enums.DomainStatus.ERRORING]   = true,
    [Enums.DomainStatus.NEVER_SEEN] = true,
}


--- Check whether a domain status value is valid.
---@param status any
---@return boolean
function Enums.IsValidDomainStatus(status)
    return type(status) == 'string' and Enums.DomainStatusSet[status] == true
end


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================
-- All enums defined and attached to BSD.Sentinel.Enums above.
-- Sanity checks to catch typos at load time.
-- =============================================================================

assert(type(Enums.Severity) == 'table', 'Enums.Severity not defined')
assert(Enums.Severity.CRITICAL == 'critical', 'Enums.Severity.CRITICAL has wrong value')
assert(type(Enums.SeverityToInt) == 'function', 'Enums.SeverityToInt not defined')
assert(Enums.SeverityToInt('debug') == 0, 'SeverityToInt(debug) should be 0')
assert(Enums.SeverityToInt('critical') == 3, 'SeverityToInt(critical) should be 3')
assert(Enums.IntToSeverity(0) == 'debug', 'IntToSeverity(0) should be debug')
assert(Enums.IntToSeverity(3) == 'critical', 'IntToSeverity(3) should be critical')
assert(Enums.IsValidSeverity('warning') == true, 'IsValidSeverity(warning) should be true')
assert(Enums.IsValidSeverity('bogus') == false, 'IsValidSeverity(bogus) should be false')