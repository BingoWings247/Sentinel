-- =============================================================================
-- bsd_sentinel / sql / 002_alerts_tables.sql
-- =============================================================================
-- Second migration. Creates the alerts table and its supporting structures.
--
-- This migration is idempotent. Running it twice is safe.
-- This migration is forward-only. Restore from backup to revert.
--
-- DESIGN: Alerts are kept SEPARATE from events for architectural clarity.
-- An event is an immutable record of something that happened. An alert
-- is a mutable record of something that needs human attention — it has
-- a workflow (new -> acknowledged -> investigating -> resolved), an
-- assignee, resolution notes. Different data types, different access
-- patterns, different retention rules. Putting them in the same table
-- would force compromises on both.
--
-- DESIGN: Deduplication is a first-class feature. When the same rule
-- or the same direct-emission pattern generates the same alert signal
-- repeatedly within a window, Sentinel collapses them into one alert
-- with an occurrence_count. This prevents alert storms from burying
-- the Discord channel in identical notifications.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- bsd_sentinel_alerts
-- -----------------------------------------------------------------------------
-- The alert queue. Each row is one alert — one thing a human needs to
-- look at. Multiple underlying events may be rolled up into a single
-- alert via the related_events JSON array and occurrence_count counter.
--
-- Reads: by alert_id (individual lookup), by status (open alert list),
--        by deduplication_key + status (dedup check), by created_at
--        (recent activity), by assigned_to (staff workload view).
--
-- Writes: on creation (new alert), on occurrence (dedup increment),
--         on status change (acknowledge / resolve / false-positive).
--
-- Size: much smaller than events table. A busy server might generate
--       tens of alerts per day; most are quickly resolved. Expected
--       total rows remain under a million even over years.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `bsd_sentinel_alerts` (
    -- -------------------------------------------------------------------------
    -- Identity
    -- -------------------------------------------------------------------------
    `id`                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `alert_id`              CHAR(36) NOT NULL,  -- UUID v7

    -- -------------------------------------------------------------------------
    -- Source
    -- -------------------------------------------------------------------------
    -- rule_id identifies what produced this alert.
    --
    -- For alerts created by direct emission (severity=critical event
    -- auto-promoted), rule_id = 'direct_emit'.
    --
    -- For alerts created by the anomaly engine (v1.1+), rule_id is the
    -- rule's registered identifier, e.g. 'banking.rapid_transfers'.
    `rule_id`               VARCHAR(100) NOT NULL,

    -- severity mirrors the severity of the event(s) that caused the alert.
    -- Alerts can only be severity 2 (warning) or 3 (critical). Debug and
    -- info events never produce alerts. Enforced in application code.
    `severity`              TINYINT UNSIGNED NOT NULL,

    -- -------------------------------------------------------------------------
    -- Content
    -- -------------------------------------------------------------------------
    -- title is the one-line summary shown in lists. Short, scannable.
    -- Example: "Rapid transfer pattern detected"
    `title`                 VARCHAR(255) NOT NULL,

    -- summary is the longer human-readable description. Appears in alert
    -- detail views and Discord notifications.
    -- Example: "Account 1234567 received 15 transfers totaling $47,000
    --           from 3 different accounts in 4 minutes."
    `summary`               TEXT NOT NULL,

    -- domain is the BSD domain the alert comes from. Allows filtering
    -- alerts by domain in admin UIs.
    `domain`                VARCHAR(50) NOT NULL,

    -- -------------------------------------------------------------------------
    -- Deduplication
    -- -------------------------------------------------------------------------
    -- deduplication_key is a rule-or-emitter-defined string that
    -- identifies "the same alert signal." Subsequent alerts with the
    -- same key within the dedup window do not create new rows — they
    -- update the existing row's occurrence_count and related_events.
    --
    -- Example keys:
    --   'banking.brute_force.account_1234567'
    --   'medical.controlled_substance_overdispense.officer_joe'
    --
    -- NULL means no deduplication (every instance is a new alert).
    `deduplication_key`     VARCHAR(255) NULL,

    -- occurrence_count: how many times this alert signal has fired.
    -- Starts at 1 on creation. Incremented on dedup merge.
    `occurrence_count`      INT UNSIGNED NOT NULL DEFAULT 1,

    -- first_seen_at: when the first occurrence of this alert was recorded.
    -- Immutable after creation.
    `first_seen_at`         TIMESTAMP(6) NOT NULL,

    -- last_seen_at: when the most recent occurrence was recorded.
    -- Updated on dedup merge.
    `last_seen_at`          TIMESTAMP(6) NOT NULL,

    -- -------------------------------------------------------------------------
    -- Related events and subjects
    -- -------------------------------------------------------------------------
    -- related_events is a JSON array of event_ids that contributed to
    -- this alert. Dedup merges append to this list, up to a cap (see
    -- application code) to prevent unbounded growth.
    --
    -- Staff investigating the alert can click through to each event in
    -- the query interface to see the full context.
    `related_events`        JSON NOT NULL,

    -- related_actor: the primary actor associated with this alert, if any.
    -- E.g., the player whose account was brute-forced, the officer whose
    -- fleet card had suspicious charges.
    --
    -- Separate column (not just in metadata) because staff filter by
    -- this often: "show me alerts involving player X."
    `related_actor`         VARCHAR(100) NULL,

    -- related_subjects: JSON array of {type, id} pairs for subjects
    -- involved. E.g., accounts involved in a transfer-pattern alert.
    `related_subjects`      JSON NULL,

    -- -------------------------------------------------------------------------
    -- Suggested actions
    -- -------------------------------------------------------------------------
    -- Per the "answer is in the tool, not the forum" principle: every
    -- alert should tell the operator what they probably want to do about it.
    --
    -- JSON array of action objects, each with 'label' (shown to operator),
    -- 'command' (what to run), and 'description' (why this action).
    --
    -- Example:
    --   [
    --     {
    --       "label": "Freeze account",
    --       "command": "/bsdbankfreeze 1234567 \"investigating alert\"",
    --       "description": "Block further activity pending investigation"
    --     },
    --     {
    --       "label": "View full activity",
    --       "command": "/bsdaccount 1234567",
    --       "description": "See the account's recent transaction history"
    --     }
    --   ]
    --
    -- NULL when the emitter has no specific guidance.
    `suggested_actions`     JSON NULL,

    -- -------------------------------------------------------------------------
    -- Workflow
    -- -------------------------------------------------------------------------
    -- status values: 'new', 'acknowledged', 'investigating', 'resolved', 'false_positive'
    -- See shared/enums.lua (AlertStatus).
    --
    -- ENUM constraint at DB level provides defense-in-depth against
    -- application-layer bugs introducing bad statuses.
    `status`                ENUM('new', 'acknowledged', 'investigating', 'resolved', 'false_positive')
                            NOT NULL DEFAULT 'new',

    -- assigned_to: staff identifier of whoever is responsible for the
    -- alert. NULL means unassigned. Useful for staff-workload queries
    -- and for accountability: 'who owns this unresolved alert?'
    `assigned_to`           VARCHAR(100) NULL,

    -- -------------------------------------------------------------------------
    -- Resolution
    -- -------------------------------------------------------------------------
    -- These are populated when status transitions to 'resolved' or
    -- 'false_positive'. NULL before that.

    -- resolution_notes: human-written explanation of what was done
    -- (for resolved) or why this was a false positive. Required when
    -- status transitions to resolved/false_positive; enforced in app.
    `resolution_notes`      TEXT NULL,

    -- resolved_at: when status transitioned to resolved/false_positive.
    `resolved_at`           TIMESTAMP(6) NULL,

    -- resolved_by: staff identifier of whoever resolved it.
    `resolved_by`           VARCHAR(100) NULL,

    -- -------------------------------------------------------------------------
    -- Timestamps
    -- -------------------------------------------------------------------------
    `created_at`            TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at`            TIMESTAMP(6) NOT NULL
                            DEFAULT CURRENT_TIMESTAMP(6)
                            ON UPDATE CURRENT_TIMESTAMP(6),

    -- -------------------------------------------------------------------------
    -- Constraints and indexes
    -- -------------------------------------------------------------------------
    PRIMARY KEY (`id`),

    UNIQUE KEY `uk_alerts_alert_id` (`alert_id`),

    -- Status-based queries are common: "show me all open alerts."
    -- Status first because most queries filter on it.
    KEY `idx_alerts_status_created` (`status`, `created_at`),

    -- Deduplication lookup: "is there an unresolved alert with this
    -- dedup key?" Only indexes rows where dedup_key is set (non-null).
    -- Compound with status for efficient dedup lookup.
    KEY `idx_alerts_dedup` (`deduplication_key`, `status`),

    -- Domain filtering for admin UIs.
    KEY `idx_alerts_domain_status` (`domain`, `status`, `created_at`),

    -- Actor filtering: "show me alerts involving player X."
    KEY `idx_alerts_actor` (`related_actor`, `created_at`),

    -- Assignment queries: "what's in my queue?"
    KEY `idx_alerts_assigned` (`assigned_to`, `status`),

    -- Severity filtering: "show me critical alerts only."
    KEY `idx_alerts_severity_created` (`severity`, `created_at`),

    -- Rule tracking: for v1.1 anomaly engine, "how is this rule
    -- performing?" queries filter by rule_id.
    KEY `idx_alerts_rule` (`rule_id`, `created_at`)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  ROW_FORMAT=DYNAMIC
  COMMENT='BSD Sentinel alert queue. Human-facing summary of events needing attention.';


-- -----------------------------------------------------------------------------
-- bsd_sentinel_alert_history
-- -----------------------------------------------------------------------------
-- Append-only history of state changes on alerts. When a staff member
-- acknowledges, assigns, resolves, or reopens an alert, a row is added
-- here describing what changed.
--
-- This is the audit trail for alert handling itself. "Who marked this
-- as a false positive?" "Who reopened a resolved alert?" "How long
-- was it sitting in investigating before being resolved?"
--
-- DESIGN: Separate table because alerts change often (workflow), but
-- the history never changes (audit). Mixed access patterns don't
-- mix well in one table.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `bsd_sentinel_alert_history` (
    `id`                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,

    -- The alert this history entry belongs to. References alerts.alert_id
    -- (not alerts.id) because we export via UUID externally.
    `alert_id`              CHAR(36) NOT NULL,

    -- What changed. Enum at DB level for safety.
    `action`                ENUM('created', 'acknowledged', 'assigned', 'reassigned',
                                 'status_changed', 'resolved', 'reopened',
                                 'merged', 'noted') NOT NULL,

    -- Who did it. Staff identifier. 'system' for automated actions
    -- (e.g., created=system for direct-emit promotions).
    `actor_identifier`      VARCHAR(100) NOT NULL,

    -- Before/after values for state-changing actions. JSON so we can
    -- describe any kind of change without schema changes per action.
    -- E.g., {"field": "status", "from": "new", "to": "acknowledged"}
    --       {"field": "assigned_to", "from": null, "to": "staff_jane"}
    `change_detail`         JSON NULL,

    -- Optional free-form note from the actor. "Assigning to Jane because
    -- she's dealt with this pattern before."
    `note`                  TEXT NULL,

    `created_at`            TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    PRIMARY KEY (`id`),
    KEY `idx_alert_history_alert` (`alert_id`, `created_at`),
    KEY `idx_alert_history_actor` (`actor_identifier`, `created_at`),
    KEY `idx_alert_history_created` (`created_at`)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Append-only audit trail of state changes on alerts. Never updated or deleted.';


-- =============================================================================
-- End of migration 002_alerts_tables.sql
-- =============================================================================