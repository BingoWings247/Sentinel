-- bsd_sentinel/fxmanifest.lua
--
-- The observability and security operations layer for the BSD ecosystem.
-- A unified event log, forensic investigation interface, and (v1.1)
-- anomaly detection engine that every BSD domain module writes to.
--
-- See docs/sentinel/SCOPE.md for the complete v1.0 specification.

fx_version 'cerulean'
game 'gta5'
use_experimental_fxv2_oal 'yes'
lua54 'yes'

name 'bsd_sentinel'
author 'BlackStone Development'
version '1.0.0-dev'
description 'Observability and security operations layer for the BSD ecosystem'
repository 'https://github.com/BlackStoneDev/bsd-ecosystem'

-- =============================================================================
-- DEPENDENCIES
-- =============================================================================
-- Sentinel is foundational. It has no BSD dependencies. Every BSD domain
-- module depends on Sentinel; Sentinel depends on nothing BSD.
--
-- oxmysql is the primary database driver. pgsql support is scoped for
-- v1.1 but the driver abstraction exists now so adding pgsql later is
-- a non-breaking addition.
--
-- ox_lib is a soft dependency. Sentinel uses it when present for utilities
-- like UUID generation and notifications, and falls back to in-house
-- implementations when absent. It is NOT listed as a hard dependency.

dependencies {
    'oxmysql',
}

-- =============================================================================
-- SQL MIGRATIONS
-- =============================================================================
-- Migrations run in numeric order on resource startup. They are idempotent
-- (safe to run twice). Schema changes across versions ship as new numbered
-- migration files; existing files are never modified.
--
-- Migration execution is handled by server/db/migrator.lua (not listed here
-- because it's loaded as part of the server scripts below).

files {
    'sql/001_core_tables.sql',
    'sql/002_alerts_tables.sql',
    'sql/003_indexes.sql',
}

-- =============================================================================
-- SHARED SCRIPTS
-- =============================================================================
-- Shared scripts run on both client and server contexts. Sentinel has no
-- client-side behavior in v1.0, but shared utilities (UUID generation,
-- constant definitions, enum values) are loaded as shared so they're
-- available to any future client-side code without duplication.

shared_scripts {
    'config.lua',               -- operator configuration, loaded before everything
    'shared/constants.lua',
    'shared/enums.lua',
    'shared/utils.lua',
}

-- =============================================================================
-- SERVER SCRIPTS
-- =============================================================================
-- Load order matters. Dependencies must load before dependents.
--
-- Phase 1: bootstrap. Logger and config must exist before anything else runs.
-- Phase 2: storage. DB driver and migrator prepare the persistence layer.
-- Phase 3: core primitives. Scheduler, registry, buffer, correlation.
-- Phase 4: ingestion. Records events, writes to buffer, flushes to DB.
-- Phase 5: query. Read access to the event log.
-- Phase 6: retention. Scheduled pruning and archival.
-- Phase 7: alerts. Alert queue, deduplication, Discord integration.
-- Phase 8: reconciliation. Integrity check orchestration.
-- Phase 9: health. Resource heartbeat tracking.
-- Phase 10: admin. Command handlers and formatters.
-- Phase 11: setup. /bsdsetup wizard (depends on everything above).
-- Phase 12: exports. Public API surface.
-- Phase 13: main. Lifecycle entry point.

server_scripts {
    -- Phase 1: bootstrap
    'server/logger.lua',
    'server/config_validator.lua',

    -- Phase 2: storage
    'server/db/driver.lua',
    'server/db/mysql.lua',
    'server/db/pgsql.lua',       -- v1.1+ stub; registers but does not implement
    'server/db/migrator.lua',

    -- Phase 3: core primitives
    'server/scheduler.lua',
    'server/registry.lua',
    'server/buffer.lua',
    'server/correlation.lua',

    -- Phase 4: ingestion
    'server/ingestion.lua',

    -- Phase 5: query
    'server/query.lua',

    -- Phase 6: retention
    'server/retention.lua',

    -- Phase 7: alerts
    'server/alerts/alerts.lua',
    'server/alerts/dedup.lua',
    'server/alerts/discord.lua',

    -- Phase 8: reconciliation
    'server/reconciliation.lua',
    'server/admin/formatters.lua',
    'server/admin/permissions.lua',
    -- Phase 9: health
    'server/health.lua',
    -- Phase 9b: collectors (server observability)
    'server/collectors/loader.lua',
    'server/collectors/hitch.lua',
    -- Phase 10: admin
    'server/admin/permissions.lua',
    'server/admin/formatters.lua',
    'server/admin/commands.lua',

    -- Phase 11: setup wizard
    'server/setup.lua',

    -- Phase 12: exports (must load after everything it wraps)
    'server/exports.lua',
    
    -- Phase 12b: producer SDK
       'server/sdk.lua',

    -- Phase 13: main entry point (orchestrates startup)
    'server/main.lua',
}

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
-- Sentinel's configuration is loaded as a shared script (above) because
-- both server startup and admin commands need access to it.

-- config.lua is intentionally included above in shared_scripts. Keeping
-- this note here because future developers will look for a dedicated
-- 'config' block and need to know where it actually lives.

-- =============================================================================
-- CONVAR CONFIGURATION
-- =============================================================================
-- Sentinel supports runtime configuration via convars. These override the
-- values in config.lua. Useful for operators who manage multiple servers
-- with a shared resource directory but server-specific settings.
--
-- Documented convars (full list in docs/sentinel/ADMIN.md):
--   bsd_sentinel_dev_mode           -- 0 or 1; permits unregistered event types
--   bsd_sentinel_spill_directory    -- path to spill-to-file directory
--   bsd_sentinel_buffer_size        -- max events in memory buffer
--   bsd_sentinel_strict_config      -- 0 or 1; fatal on config validation failure
-- (and more, see docs)

-- =============================================================================
-- NOTES
-- =============================================================================
-- This manifest does NOT declare ui_page. Sentinel has no NUI in v1.0. All
-- admin interaction happens via server console commands. A future bsd_admin
-- resource will provide NUI on top of Sentinel's exports.
--
-- This manifest does NOT declare client_scripts. Sentinel has no client-side
-- behavior in v1.0. Resource heartbeat tracking is server-side.
--
-- This manifest does NOT declare exports inline. Exports are registered
-- programmatically by server/exports.lua so they can be conditionally
-- enabled or renamed without editing the manifest.
