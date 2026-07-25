-- =============================================================================
-- bsd_sentinel / shared / constants.lua
-- =============================================================================
-- Named constants used throughout Sentinel.
--
-- Every magic number gets a name. Every default value is defined here.
-- Operators override these via config.lua (loaded later in the boot
-- sequence); code references these constants as canonical defaults.
--
-- DESIGN: Separate from config.lua because these are Sentinel's own
-- defaults, not operator-visible config. Operators can override these
-- via Config, but code never reads Config directly for these values —
-- it reads Constants. The Config file's job is to replace Constants
-- values at startup if the operator has provided overrides.
--
-- Dependencies: none
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Constants = {}

local C = BSD.Sentinel.Constants


-- =============================================================================
-- VERSION INFORMATION
-- =============================================================================

-- Semantic version. MAJOR.MINOR.PATCH. See scope doc §22.
-- Bumped on every release.
C.VERSION = '1.0.0-dev'

-- API version used by domain modules to check compatibility. Bumped
-- independently of VERSION when the public API (exports, event shape,
-- registration API) changes in a way domain modules might care about.
-- See scope doc §21 on API stability.
C.API_VERSION = 1

-- Schema version. Bumped when migrations change the event schema in
-- ways domain modules might need to know about. Stored in
-- bsd_sentinel_migrations so operators can check what they're on.
C.SCHEMA_VERSION = 1


-- =============================================================================
-- LIMITS AND SIZES
-- =============================================================================

-- Maximum length for the event summary field. Longer summaries are
-- truncated at ingestion with a warning logged to the operator.
-- Matches VARCHAR(500) in bsd_sentinel_events.summary.
C.MAX_SUMMARY_LENGTH = 500

-- Maximum length for failure_reason. Matches VARCHAR(255).
C.MAX_FAILURE_REASON_LENGTH = 255

-- Maximum length for event_type. Matches VARCHAR(100).
-- Enforced at registration time, not at event emission (if the type
-- got registered, it's already within limit).
C.MAX_EVENT_TYPE_LENGTH = 100

-- Maximum length for domain. Matches VARCHAR(50).
C.MAX_DOMAIN_LENGTH = 50

-- Maximum length for actor_identifier. Matches VARCHAR(100).
C.MAX_ACTOR_IDENTIFIER_LENGTH = 100

-- Maximum length for subject_id and secondary_subject_id.
-- Matches VARCHAR(100).
C.MAX_SUBJECT_ID_LENGTH = 100

-- Maximum length for amount_unit. Matches VARCHAR(20).
C.MAX_AMOUNT_UNIT_LENGTH = 20


-- =============================================================================
-- BUFFER AND SPILL
-- =============================================================================

-- Maximum number of events held in the in-memory ring buffer.
-- When full, oldest events are spilled to the JSONL spill file on disk.
-- See scope doc §5.
--
-- DESIGN: 10,000 at ~1KB per event = ~10MB memory footprint. Reasonable
-- for any FiveM host. Adjustable per server via config if a very busy
-- server needs more headroom.
C.DEFAULT_BUFFER_SIZE = 10000

-- Directory (relative to resource root) where spill files are written
-- when the DB is unavailable and the in-memory buffer is full.
--
-- Operators can override via config or convar. Relative path preferred
-- so it stays inside the resource folder and survives redeployment.
C.DEFAULT_SPILL_DIRECTORY = 'spill'

-- Filename pattern for spill files. %s is replaced with a timestamp.
-- One spill file per DB outage; events from the same outage append to
-- the same file.
C.SPILL_FILE_PATTERN = 'spill_%s.jsonl'

-- How often to attempt DB reconnection when spilling. Milliseconds.
-- Too-frequent retries waste resources; too-infrequent means longer
-- before events make it to the DB after recovery.
C.DEFAULT_SPILL_RETRY_INTERVAL_MS = 5000

-- Maximum spill file size in bytes before rolling to a new file.
-- Prevents pathological cases where a multi-day outage produces a
-- single multi-gigabyte spill file.
C.MAX_SPILL_FILE_BYTES = 50 * 1024 * 1024  -- 50 MB


-- =============================================================================
-- INGESTION FLUSH
-- =============================================================================

-- How often the buffer flushes to DB under normal operation. Milliseconds.
-- Smaller values = events visible sooner in queries but more DB load.
-- Larger values = lower DB load but events sit in buffer longer.
--
-- 1000ms (one second) is a reasonable default: a forensic query run
-- immediately after an event sees it within a second.
C.DEFAULT_FLUSH_INTERVAL_MS = 1000

-- Maximum events per flush batch. Prevents single huge inserts when
-- the buffer has been sitting without flush. Larger batches = more
-- efficient, but longer-blocking DB operations.
C.DEFAULT_FLUSH_BATCH_SIZE = 500


-- =============================================================================
-- RETENTION POLICY
-- =============================================================================
-- Scope doc §13. Tiered by severity. Per-domain overrides available
-- in config.

-- Retention in DAYS per severity level. 0 = forever (no pruning).
C.DEFAULT_RETENTION_DAYS = {
    -- Critical events are never pruned. Also: all admin actions,
    -- all reversals, all events with status='reversed' (they are
    -- evidence of the original event regardless of its severity).
    critical = 0,    -- forever

    warning  = 365,  -- 1 year
    info     = 90,   -- 90 days
    debug    = 7,    -- 7 days
}

-- How often retention pruning runs. A week is more than enough;
-- retention is not time-critical, and running it less often means
-- less I/O load on the database.
C.DEFAULT_PRUNE_INTERVAL_HOURS = 168  -- 7 days

-- Whether archive-to-aggregate is enabled by default.
-- FALSE by default per scope doc §13: operators must opt in via
-- Config.Retention.ArchiveEnabled to avoid first-boot surprise data loss.
C.DEFAULT_ARCHIVE_ENABLED = false


-- =============================================================================
-- ALERT DEDUPLICATION
-- =============================================================================
-- Scope doc §4.

-- Time window within which duplicate alerts are collapsed. Seconds.
-- If a rule or direct emission produces a second alert with the same
-- deduplication_key within this window, the existing alert's
-- occurrence_count is incremented instead of a new row being created.
C.DEFAULT_DEDUP_WINDOW_SECONDS = 3600  -- 1 hour


-- =============================================================================
-- DISCORD INTEGRATION
-- =============================================================================
-- Scope doc §9.

-- Max Discord messages per minute. Sentinel's queue backs up if rules
-- storm past dedup; Discord's webhook does not get rate-limited by our
-- posts.
C.DEFAULT_DISCORD_RATE_LIMIT_PER_MINUTE = 20

-- Hour of day (0-23, server local time) for the daily digest post.
-- 8am chosen because it's shift-change for most staff teams. Warning-
-- severity alerts from the previous 24 hours go in one digest message.
C.DEFAULT_DIGEST_HOUR = 8

-- HTTP timeout for Discord webhook posts. Milliseconds.
C.DISCORD_REQUEST_TIMEOUT_MS = 5000


-- =============================================================================
-- QUERY LIMITS
-- =============================================================================
-- Scope doc §7.

-- Maximum results returnable from a single query call.
-- Callers must pass explicit limit; this is the hard ceiling.
C.MAX_QUERY_LIMIT = 1000

-- There is no DEFAULT_QUERY_LIMIT. Callers must always pass limit;
-- no-limit queries are rejected with an error. See scope doc §7.


-- =============================================================================
-- SCHEDULER
-- =============================================================================

-- Default tick interval for the shared scheduler. Milliseconds.
-- Most scheduled work has a coarser granularity (hourly, daily), but
-- the scheduler itself ticks this often to check whether work is due.
--
-- DESIGN: 60 seconds is plenty. A task that needs to run 'every 5
-- minutes' is fine with a 60-second scheduler tick — worst case, it
-- runs 60 seconds late. Tasks needing sub-minute precision are not
-- expected in v1.0.
C.SCHEDULER_TICK_INTERVAL_MS = 1000

-- Maximum execution time for a single scheduled task before the
-- scheduler logs a warning. Milliseconds. Not a hard kill — the task
-- is allowed to finish — but slow tasks are surfaced for investigation.
C.SCHEDULER_SLOW_TASK_THRESHOLD_MS = 5000


-- =============================================================================
-- HEALTH AND HEARTBEAT
-- =============================================================================
-- Scope doc §11.

-- How long a domain can go without emitting before being marked SILENT.
-- Seconds. Default: 15 minutes. Overridable per-domain in config.
C.DEFAULT_HEARTBEAT_SILENT_THRESHOLD_SECONDS = 900  -- 15 min

-- Error rate threshold for marking a domain as ERRORING.
-- Percentage (0-100) of recent events with status='failed'.
-- Computed over the last 1000 events or 1 hour, whichever is smaller.
C.DEFAULT_ERRORING_THRESHOLD_PERCENT = 20

-- Window (in events) over which error rate is computed.
C.HEALTH_ERROR_WINDOW_SIZE = 1000

-- Window (in seconds) over which error rate is computed.
C.HEALTH_ERROR_WINDOW_SECONDS = 3600


-- =============================================================================
-- RECONCILIATION
-- =============================================================================
-- Scope doc §10.

-- Default interval between scheduled reconciliation runs. Hours.
-- Per-domain overridable.
C.DEFAULT_RECONCILIATION_INTERVAL_HOURS = 6

-- Maximum time a reconciliation callback is allowed to run before
-- Sentinel flags it as problematic. Seconds. Reconciliation should
-- be fast; if a domain's reconciliation is slow, that's a problem
-- worth surfacing.
C.RECONCILIATION_TIMEOUT_SECONDS = 30


-- =============================================================================
-- PIN AND AUTH (reserved for future banking integration)
-- =============================================================================
-- Scope doc §5.
--
-- Sentinel does NOT handle PINs itself. These constants exist so that
-- banking and other PIN-consuming domains can use consistent lockout
-- thresholds. They are defaults; banking may override.
--
-- UNCERTAIN: These might move to banking when it's rebuilt. For now,
-- parking them here to avoid inconsistency across future modules.

C.DEFAULT_PIN_MAX_ATTEMPTS = 3
C.DEFAULT_PIN_LOCKOUT_SECONDS = 900  -- 15 min


-- =============================================================================
-- DEV MODE
-- =============================================================================
-- Scope doc §5.

-- Whether dev mode is enabled by default. FALSE. Dev mode permits
-- auto-registration of unknown event types with a warning; production
-- is strict. Operators explicitly opt in via config or convar.
C.DEFAULT_DEV_MODE = false

-- Convar name operators can use to enable dev mode without editing
-- config.lua. Useful for testing on a dev server while keeping
-- production strict.
C.CONVAR_DEV_MODE = 'bsd_sentinel_dev_mode'


-- =============================================================================
-- PERMISSION NODES
-- =============================================================================
-- Scope doc §8. Three tiers.
--
-- DESIGN: These are the node NAMES. The actual permission grants live
-- in server.cfg ACE configuration; Sentinel just checks whether the
-- player has the node.
--
-- Each node inherits from the previous: granting admin implicitly
-- grants investigate, which implicitly grants read. Implemented in
-- server/admin/permissions.lua via explicit hierarchy checks.

C.PERM_READ        = 'bsd.sentinel.read'
C.PERM_INVESTIGATE = 'bsd.sentinel.investigate'
C.PERM_ADMIN       = 'bsd.sentinel.admin'


-- =============================================================================
-- COMMAND PREFIX
-- =============================================================================
-- Scope doc §8. Consistent BSD-wide prefix for admin commands.

C.DEFAULT_COMMAND_PREFIX = 'bsd'


-- =============================================================================
-- CORRELATION
-- =============================================================================

-- Maximum depth of nested WithContext calls. Prevents runaway recursion
-- from corrupting the context stack. 32 is far more than any legitimate
-- use case should need; if you're nesting 32 deep, something is wrong.
C.MAX_CONTEXT_STACK_DEPTH = 32


-- =============================================================================
-- LOGGING
-- =============================================================================

-- Prefix for all Sentinel console log lines. Makes it easy to grep
-- Sentinel output in a mixed resource log.
C.LOG_PREFIX = '[bsd_sentinel]'

-- Whether to include millisecond timestamps in console output. TRUE
-- helps with diagnosing ordering issues; FALSE keeps output compact.
-- Default TRUE because Sentinel is observability infrastructure;
-- precise timing is core to its value.
C.LOG_INCLUDE_TIMESTAMPS = true


-- =============================================================================
-- DATABASE
-- =============================================================================

-- Which DB driver to use. Possible values: 'mysql', 'pgsql'.
-- v1.0 only implements 'mysql'. 'pgsql' is a stub that refuses to
-- load with a clear error message.
C.DEFAULT_DB_DRIVER = 'mysql'

-- Connection verification interval. Milliseconds. Sentinel pings the
-- DB at this interval to detect outages before they affect ingestion.
C.DB_HEARTBEAT_INTERVAL_MS = 30000  -- 30 sec

-- Slow query threshold. Queries taking longer than this are logged
-- for investigation. Milliseconds.
C.DB_SLOW_QUERY_THRESHOLD_MS = 1000


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(C.VERSION) == 'string', 'C.VERSION not defined')
assert(type(C.DEFAULT_BUFFER_SIZE) == 'number', 'C.DEFAULT_BUFFER_SIZE not defined')
assert(type(C.DEFAULT_RETENTION_DAYS) == 'table', 'C.DEFAULT_RETENTION_DAYS not defined')
assert(C.DEFAULT_RETENTION_DAYS.critical == 0, 'critical retention should be 0 (forever)')
assert(type(C.PERM_READ) == 'string', 'C.PERM_READ not defined')