-- =============================================================================
-- bsd_sentinel / config.lua
-- =============================================================================
--
--   BSD SENTINEL CONFIGURATION
--
-- This file is where you, the server operator, customize Sentinel.
--
-- Every setting has a sensible default. If you delete this entire file,
-- Sentinel will still run — it will use defaults for everything and log
-- a note that no config was present. That's by design.
--
-- If you're unsure about a setting, leave it commented out. Sentinel will
-- use the documented default, and will write what default it used to the
-- console log so you can see exactly what's active.
--
-- ANY changes to this file take effect on next resource restart
-- (via /restart bsd_sentinel, or a full server restart).
--
-- =============================================================================
-- HOW THIS FILE IS STRUCTURED
-- =============================================================================
--
-- Config is a Lua table. Settings are nested under categories:
--
--   Config.Database.Driver    -- database connection settings
--   Config.Buffer.Size        -- event buffer behavior
--   Config.Retention.InfoDays -- how long to keep events
--   ... etc.
--
-- See docs/sentinel/CONFIG.md for a complete reference with examples.
-- =============================================================================

Config = {}


-- =============================================================================
-- CORE BEHAVIOR
-- =============================================================================

-- StrictConfig
-- Default: false
--
-- If true, Sentinel refuses to start when any config value is invalid.
-- Safer for experienced operators — catches typos before they cause
-- subtle problems in production.
--
-- If false (default), invalid values are replaced with documented defaults
-- and a warning is logged. Sentinel still starts. Safer for new operators
-- learning the system.
--
-- Recommended: leave as default until you're comfortable with Sentinel's
-- config structure, then set to true for added safety.
--
-- Config.StrictConfig = false


-- DevMode
-- Default: false
--
-- If true, Sentinel permits behaviors useful during development:
--   - Domain modules can emit events without pre-registering event types
--     (a warning is logged instead of rejection)
--   - Some validation is relaxed for faster iteration
--
-- DO NOT enable this in production. It trades safety for speed of
-- development.
--
-- Config.DevMode = false

-- =============================================================================
-- COLLECTORS (Server Observability)
-- =============================================================================
-- Collectors watch the server itself and record what they see. They observe
-- and report — they never act.
Config.Collectors = {
    Hitch = {
        -- Enabled = true,
        -- IntervalMs = 1000,
        -- WarnDriftMs = 250,
        -- CriticalDriftMs = 1000,
    },
    Pools = {
        -- IntervalSeconds = 60,
        -- VehicleWarn = 300,
        -- PedWarn = 300,
        -- ObjectWarn = 800,
        -- CriticalMultiplier = 1.5,
    },
    Buckets = {
        -- IntervalSeconds = 60,
        -- StrandedThresholdSeconds = 600,
        -- ReEmitCooldownSeconds = 1800,
    },
    Resources = {
        -- FlapThresholdSeconds = 10,
    },
    NativeEvents = {
        -- IntervalSeconds = 60,
    },
}
-- =============================================================================
-- DATABASE
-- =============================================================================

Config.Database = {

    -- Driver
    -- Default: 'mysql'
    --
    -- Which database driver to use. In v1.0, only 'mysql' is supported.
    -- The 'pgsql' option exists as a placeholder but is not implemented.
    --
    -- Driver = 'mysql',


    -- HeartbeatIntervalMs
    -- Default: 30000 (30 seconds)
    --
    -- How often Sentinel pings the database to detect connection loss.
    -- Shorter = faster detection of outages but more DB load.
    -- Longer = less DB load but slower outage detection.
    --
    -- HeartbeatIntervalMs = 30000,


    -- SlowQueryThresholdMs
    -- Default: 1000 (1 second)
    --
    -- Queries taking longer than this are logged so you can investigate.
    -- Does not affect execution — slow queries still complete.
    --
    -- SlowQueryThresholdMs = 1000,
}


-- =============================================================================
-- BUFFER
-- =============================================================================
-- The buffer holds events in memory before flushing to the database.
-- This absorbs spikes in event volume and protects against DB outages.

Config.Buffer = {

    -- Size
    -- Default: 10000
    --
    -- Max events held in memory before spilling to disk. At ~1KB per event,
    -- 10000 ≈ 10MB RAM — fine for any FiveM host. Very busy servers may
    -- want to increase this.
    --
    -- Size = 10000,


    -- FlushIntervalMs
    -- Default: 1000 (1 second)
    --
    -- How often the buffer writes pending events to the database.
    -- Shorter = events show up in queries faster, more DB writes.
    -- Longer = events sit in memory longer, fewer DB writes.
    --
    -- FlushIntervalMs = 1000,


    -- FlushBatchSize
    -- Default: 500
    --
    -- Maximum events per single flush. Prevents single huge inserts when
    -- the buffer has accumulated many events. You almost never need to
    -- change this.
    --
    -- FlushBatchSize = 500,
}


-- =============================================================================
-- SPILL (Disk Fallback During DB Outage)
-- =============================================================================
-- If the database is unreachable AND the in-memory buffer is full,
-- Sentinel spills events to disk so nothing is lost. When the database
-- comes back, spilled events are replayed.

Config.Spill = {

    -- Directory
    -- Default: 'spill'
    --
    -- Path (relative to the resource folder) where spill files are written.
    -- Created automatically on first spill. If you move Sentinel between
    -- servers, bring this directory along to preserve unwritten events.
    --
    -- Directory = 'spill',


    -- RetryIntervalMs
    -- Default: 5000 (5 seconds)
    --
    -- While in a DB outage, how often Sentinel retries the connection.
    --
    -- RetryIntervalMs = 5000,


    -- MaxFileBytes
    -- Default: 52428800 (50 MB)
    --
    -- Maximum size of a single spill file before it rolls to a new one.
    -- Prevents one multi-day outage from producing a single massive file.
    --
    -- MaxFileBytes = 52428800,
}


-- =============================================================================
-- RETENTION
-- =============================================================================
-- How long different severity levels of events are kept in the database.
-- After retention expires, events are pruned (and optionally archived to
-- monthly aggregates).
--
-- CRITICAL events are retained FOREVER by default. This is the correct
-- setting for a forensic system — you don't want to learn after the fact
-- that evidence of a year-ago incident was auto-deleted.
--
-- If you absolutely must prune critical events (legal requirement, disk
-- space, etc.), set CriticalDays to a non-zero value. Sentinel will
-- ALERT you about this on every startup as a safety check.

Config.Retention = {

    -- CriticalDays
    -- Default: 0 (forever)
    --
    -- Days to retain critical-severity events. 0 = never prune.
    -- Changing this from 0 is NOT recommended. Read this entire comment.
    --
    -- CriticalDays = 0,


    -- WarningDays
    -- Default: 365 (one year)
    --
    -- WarningDays = 365,


    -- InfoDays
    -- Default: 90
    --
    -- InfoDays = 90,


    -- DebugDays
    -- Default: 7
    --
    -- Debug events are high-volume and low-value long-term. 7 days is
    -- enough for recent troubleshooting.
    --
    -- DebugDays = 7,


    -- PruneIntervalHours
    -- Default: 168 (7 days)
    --
    -- How often the retention pruner runs. Pruning is not time-critical.
    --
    -- PruneIntervalHours = 168,


    -- ArchiveEnabled
    -- Default: false
    --
    -- If true, pruned events are summarized into monthly aggregates
    -- (domain + event_type + severity counts and amount sums) before
    -- deletion, preserving long-term trends.
    --
    -- Disabled by default because some operators prefer hard deletion
    -- for privacy/compliance reasons. Opt in if you want trend data.
    --
    -- ArchiveEnabled = false,
}


-- =============================================================================
-- ALERTS
-- =============================================================================
-- Alerts are curated summaries of events needing human attention.
-- See docs/sentinel/ALERTS.md for the full model.

Config.Alerts = {

    -- DedupWindowSeconds
    -- Default: 3600 (1 hour)
    --
    -- Time window within which duplicate alert signals are merged into
    -- a single alert (with occurrence_count incremented). Prevents
    -- alert storms from burying the Discord channel.
    --
    -- Set to 0 to disable deduplication.
    --
    -- DedupWindowSeconds = 3600,
}


-- =============================================================================
-- DISCORD
-- =============================================================================
-- Optional. Sends alert notifications to a Discord webhook.
-- See docs/sentinel/DISCORD.md for setup instructions.

Config.Discord = {

    -- Enabled
    -- Default: false
    --
    -- Must explicitly be set to true to enable Discord notifications.
    -- No webhook calls happen until you turn this on.
    --
    -- Enabled = false,


    -- WebhookURL
    -- Default: '' (empty, disabled)
    --
    -- Discord webhook URL. Get one from your Discord server's channel
    -- settings -> Integrations -> Webhooks.
    --
    -- WebhookURL = '',


    -- RateLimitPerMinute
    -- Default: 20
    --
    -- Max alerts posted to Discord per minute. If more arrive, they
    -- queue up. Protects your channel from alert floods.
    --
    -- RateLimitPerMinute = 20,


    -- DigestHour
    -- Default: 8
    --
    -- Hour of day (0-23, server local time) for the daily digest of
    -- warning-severity alerts from the previous 24 hours.
    --
    -- DigestHour = 8,
}


-- =============================================================================
-- HEALTH
-- =============================================================================
-- How Sentinel determines whether registered domain modules are healthy.

Config.Health = {

    -- SilentThresholdSeconds
    -- Default: 900 (15 minutes)
    --
    -- A domain that hasn't emitted any events for this long is marked
    -- as 'silent' — possibly broken, possibly just idle.
    --
    -- SilentThresholdSeconds = 900,


    -- ErroringThresholdPercent
    -- Default: 20
    --
    -- If a domain's recent events are more than this percentage 'failed'
    -- status, the domain is marked as 'erroring' and surfaced in health
    -- reports.
    --
    -- ErroringThresholdPercent = 20,
}


-- =============================================================================
-- RECONCILIATION
-- =============================================================================
-- Scheduled integrity checks performed by each domain module.

Config.Reconciliation = {

    -- IntervalHours
    -- Default: 6
    --
    -- How often scheduled reconciliation runs. Each domain may override
    -- this for itself when it registers.
    --
    -- IntervalHours = 6,
}


-- =============================================================================
-- PERMISSIONS
-- =============================================================================
-- How Sentinel's admin commands identify authorized users.

Config.Permissions = {

    -- CommandPrefix
    -- Default: 'bsd'
    --
    -- Prefix for admin commands. Default is 'bsd', making commands
    -- like /bsdquery, /bsdalerts, /bsdsetup.
    --
    -- If another BSD resource uses a different prefix (uncommon), or
    -- if you want to match your server's convention (e.g., 'admin'
    -- would give /adminquery), change this.
    --
    -- CommandPrefix = 'bsd',
}


-- =============================================================================
-- END OF CONFIG
-- =============================================================================
--
-- If you've made it here: you've seen every setting Sentinel exposes.
-- Sentinel is intentionally configurable at the edges and opinionated
-- at the core. The things you CAN'T change (storage format, event
-- schema, severity levels) are deliberate — they're what makes Sentinel
-- Sentinel.
--
-- Questions? See:
--   docs/sentinel/CONFIG.md  — complete configuration reference
--   docs/sentinel/SCOPE.md   — why Sentinel is the way it is
--   docs/sentinel/ADMIN.md   — how to run and investigate with Sentinel
--
-- =============================================================================