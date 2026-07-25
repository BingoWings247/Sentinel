-- =============================================================================
-- bsd_sentinel / sql / 001_core_tables.sql
-- =============================================================================
-- First migration. Creates the core event log table.
--
-- This migration is idempotent. Running it twice is safe.
-- This migration is forward-only. There is no rollback path; restore from
-- backup if you need to revert.
--
-- Schema is locked for v1.x. Changes come as new migration files
-- (002, 003, ...) that ADD columns or tables. Existing columns are never
-- renamed, retyped, or removed within a major version.
--
-- DESIGN: The events table is intentionally generic. Domain-specific fields
-- live in the `metadata` JSON column, not as typed columns. This choice
-- trades per-column indexability for schema flexibility. The indexes
-- defined below cover the forensic query patterns we actually expect
-- (by correlation, by actor, by subject, by time). Domain-specific
-- indexes on JSON fields can be added via later migrations if needed.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- bsd_sentinel_events
-- -----------------------------------------------------------------------------
-- The core forensic ledger. Every action of significance across every BSD
-- domain module is recorded here, append-only.
--
-- Reads: fast by id (internal FKs), by correlation_id (investigation),
--        by actor_identifier + created_at (player timelines),
--        by subject_id + created_at (account/resource timelines).
--
-- Writes: append-only in v1.0. Application enforces this; DB-level enforcement
--         is documented as a recommended deployment practice (separate DB
--         user with INSERT-only grants on this table).
--
-- Size: expected growth ~10-50k rows/day on a 50-player server. Retention
--       policy (§13 of scope) prunes non-critical events after 7-90 days.
--       Critical events retained forever. Archival table defined in
--       002_alerts_tables.sql (misnamed for historical reasons; splitting
--       here to keep this file focused on core events).
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `bsd_sentinel_events` (
    -- -------------------------------------------------------------------------
    -- Identity
    -- -------------------------------------------------------------------------
    `id`                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    -- DESIGN: event_id is UUID v7 for external reference. CHAR(36) holds the
    -- canonical dash-separated form. See shared/utils.lua for generation.
    `event_id`              CHAR(36) NOT NULL,

    -- -------------------------------------------------------------------------
    -- Correlation
    -- -------------------------------------------------------------------------
    -- DESIGN: correlation_id is UUID v7 (same format as event_id) that links
    -- all events from one logical operation. A player buying a car might
    -- produce 6 events across banking, vehicle registry, DMV, and treasury —
    -- all sharing one correlation_id. Staff investigating "where did this
    -- car come from" query by correlation_id and see the full chain.
    `correlation_id`        CHAR(36) NOT NULL,

    -- DESIGN: parent_event_id is nullable. When present, it links this event
    -- to a specific earlier event that caused it (vs correlation_id which
    -- groups all events in an operation). Enables tree-structured event
    -- chains for complex multi-step operations. Costs nothing if unused.
    `parent_event_id`       CHAR(36) NULL,

    -- -------------------------------------------------------------------------
    -- Classification
    -- -------------------------------------------------------------------------
    -- Domain and event_type together identify what kind of event this is.
    -- Both must be registered via BSD.Sentinel.RegisterEventType before
    -- events of that type can be emitted (strict validation).
    `domain`                VARCHAR(50) NOT NULL,
    `event_type`            VARCHAR(100) NOT NULL,

    -- event_category is one of: 'mutation', 'query', 'auth', 'admin', 'system'
    -- Enforced as an enum in the application layer; stored as VARCHAR for
    -- forward flexibility (adding new categories in a future version
    -- doesn't require an ALTER TABLE).
    `event_category`        VARCHAR(50) NOT NULL,

    -- severity: 0=debug, 1=info, 2=warning, 3=critical
    -- DESIGN: TINYINT UNSIGNED. 4 levels. See scope §4 for rationale on
    -- choosing 4 over syslog's 6.
    `severity`              TINYINT UNSIGNED NOT NULL,

    -- status: 'intended', 'completed', 'failed', 'reversed', 'pending'
    -- Describes the lifecycle state of the action this event represents.
    `status`                VARCHAR(20) NOT NULL,

    -- -------------------------------------------------------------------------
    -- Actor
    -- -------------------------------------------------------------------------
    -- Who caused this event.
    --
    -- actor_type: 'player', 'staff', 'system', 'scheduled', 'external'
    -- 'scheduled' distinguishes cron/timer-triggered events from event-
    -- driven 'system' events. Off-hours detection rules need this distinction.
    `actor_type`            VARCHAR(20) NOT NULL,

    -- actor_identifier: usually a license or identifier string. For 'system'
    -- or 'scheduled' actors, conventionally 'system' or the task name.
    -- NULL only for events where there is genuinely no actor (e.g., automated
    -- system self-tests). Prefer a concrete identifier whenever possible.
    `actor_identifier`      VARCHAR(100) NULL,

    -- actor_source: the FiveM `source` integer if this event was triggered
    -- by a player currently on the server. Null for players who have since
    -- disconnected, and null for non-player actors.
    `actor_source`          INT UNSIGNED NULL,

    -- -------------------------------------------------------------------------
    -- Subject
    -- -------------------------------------------------------------------------
    -- What the action was done to.
    --
    -- subject_type: domain-defined. 'account', 'patient', 'vehicle', 'incident'.
    -- subject_id: domain-defined identifier for the thing being acted on.
    --
    -- Both nullable because some events (e.g., resource startup, system
    -- heartbeat) don't act on a specific subject.
    `subject_type`          VARCHAR(50) NULL,
    `subject_id`            VARCHAR(100) NULL,

    -- For events that involve TWO subjects (transfers, treatments-with-source),
    -- secondary_subject_id captures the second party. Primary subject
    -- remains in subject_id. By convention: "from" is subject_id,
    -- "to" is secondary_subject_id.
    `secondary_subject_id`  VARCHAR(100) NULL,

    -- -------------------------------------------------------------------------
    -- Amount
    -- -------------------------------------------------------------------------
    -- Generic numeric field for the quantity this event is about.
    -- Integer storage in the unit declared by amount_unit.
    --
    -- Money: cents (5000 = $50.00)
    -- Medication: mg × 100 (2500 = 25.00 mg, preserving 2 decimal precision)
    -- Ammunition: rounds (30 = 30 rounds)
    -- Distance: meters × 100 if precision matters, meters otherwise
    --
    -- UNCERTAIN: BIGINT gives us ±9.2 quintillion range which is wildly
    -- more than any FiveM use case requires. The overhead is ~4 bytes
    -- per row vs INT (BIGINT is 8, INT is 4). At 50k events/day, that's
    -- ~200KB/day of overhead. Acceptable for the safety margin.
    `amount`                BIGINT NULL,

    -- amount_unit describes what amount represents. Documented conventions
    -- live in docs/sentinel/EVENTS.md. Common values:
    --   'cents', 'mg', 'mg_x100', 'rounds', 'meters', 'seconds'
    `amount_unit`           VARCHAR(20) NULL,

    -- -------------------------------------------------------------------------
    -- Human-readable summary
    -- -------------------------------------------------------------------------
    -- DESIGN: Pre-rendered at ingestion time, not computed at read time.
    -- Storage cost is trivial compared to the compute savings on every
    -- admin query that renders event lists. Operators read summaries;
    -- code reads metadata.
    --
    -- Capped at 500 chars. Longer inputs are truncated with a warning
    -- logged to the operator.
    `summary`               VARCHAR(500) NOT NULL,

    -- -------------------------------------------------------------------------
    -- Metadata
    -- -------------------------------------------------------------------------
    -- Domain-specific structured data. Free-form JSON, but every domain's
    -- schema for its events is documented in the domain's documentation
    -- and enforced at registration time by server/registry.lua.
    --
    -- Query patterns against metadata use MySQL JSON functions. For high-
    -- frequency queries, future migrations may add generated columns or
    -- functional indexes on specific JSON paths.
    `metadata`              JSON NULL,

    -- -------------------------------------------------------------------------
    -- Reversal tracking
    -- -------------------------------------------------------------------------
    -- Reversal is first-class. When an event is reversed, we record a NEW
    -- event (the reversal) and cross-link the two.
    --
    -- reversed_by_event_id: when set, names the event_id of the reversal
    -- that negated this event. Populated on the original event when a
    -- reversal is successfully recorded.
    `reversed_by_event_id`  CHAR(36) NULL,

    -- reverses_event_id: when set, names the event_id of the original event
    -- that this event reverses. Populated on the reversal event at creation.
    `reverses_event_id`     CHAR(36) NULL,

    -- -------------------------------------------------------------------------
    -- Failure metadata
    -- -------------------------------------------------------------------------
    -- When status='failed', failure_reason describes why in operator-readable
    -- terms. For failures that cite structured data, the data lives in
    -- `metadata`; failure_reason is a short human-readable summary.
    `failure_reason`        VARCHAR(255) NULL,

    -- -------------------------------------------------------------------------
    -- Timestamps
    -- -------------------------------------------------------------------------
    -- DESIGN: Two separate timestamps.
    --
    -- created_at: when the event HAPPENED, provided by the caller. May be
    -- backdated during replay of spill files after a DB outage.
    --
    -- ingested_at: when Sentinel WROTE the row. Diverges from created_at
    -- during buffer flush. Together, these timestamps let operators diagnose
    -- ingestion lag ("events from 10 minutes ago are still arriving").
    --
    -- Both are TIMESTAMP(6) for microsecond precision. Events within the
    -- same millisecond need ordering precision the default TIMESTAMP lacks.
    `created_at`            TIMESTAMP(6) NOT NULL,
    `ingested_at`           TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    -- -------------------------------------------------------------------------
    -- Constraints and indexes
    -- -------------------------------------------------------------------------
    PRIMARY KEY (`id`),

    -- event_id is unique and externally referenceable.
    UNIQUE KEY `uk_events_event_id` (`event_id`),

    -- Forensic query indexes. Each corresponds to a specific admin command
    -- or expected query pattern.
    KEY `idx_events_correlation` (`correlation_id`, `created_at`),
    KEY `idx_events_domain_type` (`domain`, `event_type`, `created_at`),
    KEY `idx_events_actor` (`actor_identifier`, `created_at`),
    KEY `idx_events_subject` (`subject_type`, `subject_id`, `created_at`),
    KEY `idx_events_created_at` (`created_at`),
    KEY `idx_events_severity` (`severity`, `created_at`),

    -- Reversal lookup: "has this event been reversed?" and "what does
    -- this reversal apply to?"
    KEY `idx_events_reversed_by` (`reversed_by_event_id`),
    KEY `idx_events_reverses` (`reverses_event_id`)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  ROW_FORMAT=DYNAMIC
  COMMENT='BSD Sentinel core event log. Append-only forensic ledger for every significant action across every BSD domain module.';


-- -----------------------------------------------------------------------------
-- bsd_sentinel_events_archive
-- -----------------------------------------------------------------------------
-- Monthly aggregate archive. Non-critical events are summary-archived here
-- when retention pruning runs, preserving long-term trend visibility
-- without keeping individual rows forever.
--
-- DESIGN: Defined in this file (not 002) because it's core to the events
-- subsystem. The alerts tables in 002 are a separate concern.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `bsd_sentinel_events_archive` (
    `id`                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,

    -- Aggregation key: one row per domain+event_type+severity per month.
    `month_start`       DATE NOT NULL,
    `domain`            VARCHAR(50) NOT NULL,
    `event_type`        VARCHAR(100) NOT NULL,
    `severity`          TINYINT UNSIGNED NOT NULL,

    -- Aggregate measurements.
    `event_count`       BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `failed_count`      BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `reversed_count`    BIGINT UNSIGNED NOT NULL DEFAULT 0,

    -- Sum and count of the amount column when non-null. Enables queries
    -- like "total cents moved by banking/transfer_completed in March"
    -- even after individual rows are pruned.
    `amount_sum`        BIGINT NULL,
    `amount_count`      BIGINT UNSIGNED NOT NULL DEFAULT 0,

    `archived_at`       TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_archive_month_type` (`month_start`, `domain`, `event_type`, `severity`),
    KEY `idx_archive_month` (`month_start`),
    KEY `idx_archive_domain` (`domain`, `month_start`)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Monthly aggregates for pruned non-critical events. Preserves long-term trend visibility.';


-- -----------------------------------------------------------------------------
-- bsd_sentinel_migrations
-- -----------------------------------------------------------------------------
-- Tracks which migrations have run. Idempotency is enforced at the
-- application layer (migrator.lua checks this table before running
-- each migration file).
--
-- This table is populated by the migrator itself, not by migration files.
-- Migration 001 does NOT insert its own row; the migrator does.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `bsd_sentinel_migrations` (
    `migration_id`      VARCHAR(50) NOT NULL,
    `description`       VARCHAR(255) NOT NULL,
    `applied_at`        TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `checksum`          CHAR(64) NULL,  -- SHA-256 of migration file contents
    PRIMARY KEY (`migration_id`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Migration history for bsd_sentinel. Populated by server/db/migrator.lua.';

-- =============================================================================
-- End of migration 001_core_tables.sql
-- =============================================================================
