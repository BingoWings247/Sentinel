-- =============================================================================
-- bsd_sentinel / server / db / migrator.lua
-- =============================================================================
-- Database schema migrator.
--
-- On startup, the migrator:
--   1. Ensures the bsd_sentinel_migrations table exists (bootstrap).
--   2. Reads the list of SQL files declared in fxmanifest.lua (files {}).
--   3. Checks which have already been applied (rows in migrations table).
--   4. Runs any that haven't, in order.
--   5. Records each successful run with a checksum of the file contents.
--
-- IDEMPOTENCY:
--   Running the migrator twice in a row is safe. Applied migrations are
--   skipped. First-time install and every restart look identical to the
--   migrator — it just adds 0 or N new migrations each time.
--
-- CHECKSUM CHECKING:
--   Each migration row stores a SHA-256 of the file contents at the time
--   it was applied. On subsequent starts, the migrator re-hashes the file
--   and compares. A mismatch means the operator modified a migration
--   file after it was applied — which is WRONG and dangerous. The
--   migrator logs a critical warning when this happens. See MIGRATION
--   POLICY below.
--
-- MIGRATION POLICY:
--   Migrations are FORWARD-ONLY and IMMUTABLE. Once shipped, a migration
--   file's contents must never change. Schema changes come as new
--   numbered files. This policy is essential to the "lifetime commitment"
--   principle: operators' databases evolve through a deterministic chain
--   of migrations. If we ever edit an already-shipped migration, that
--   chain diverges between operators who upgraded from different points.
--
--   Exception: cosmetic comment-only changes to already-shipped migration
--   files are technically allowed but the checksum will mismatch and
--   produce a warning. Don't do it unless necessary; if you do, add a
--   `checksum_note` entry to the migrations row manually.
--
-- Dependencies: server/db/driver.lua, server/logger.lua, shared/utils.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.DB = BSD.Sentinel.DB or {}
BSD.Sentinel.DB.Migrator = {}

local Migrator = BSD.Sentinel.DB.Migrator
local Driver = BSD.Sentinel.DB.Driver
local Logger = BSD.Sentinel.Logger
local Utils = BSD.Sentinel.Utils


-- =============================================================================
-- MIGRATION DECLARATIONS
-- =============================================================================
-- The migrator discovers migrations by asking FiveM's native file API
-- for the contents of each declared migration file. The list of files
-- is maintained here, matching fxmanifest.lua's files {} block.
--
-- WHY NOT AUTO-DISCOVER BY LISTING THE DIRECTORY:
-- FiveM resources don't have reliable directory-listing APIs from Lua.
-- LoadResourceFile works on declared files. Maintaining the list in
-- two places (fxmanifest and here) is annoying but reliable; auto-
-- discovery would require assumptions about the runtime environment
-- that we can't guarantee.
--
-- TO ADD A MIGRATION:
-- 1. Create sql/NNN_description.sql
-- 2. Add 'sql/NNN_description.sql' to fxmanifest.lua files { }
-- 3. Add an entry to MIGRATIONS below
-- 4. Restart the resource
-- =============================================================================

local MIGRATIONS = {
    {
        id = '001_core_tables',
        file = 'sql/001_core_tables.sql',
        description = 'Core events table, archive table, migrations table',
    },
    {
        id = '002_alerts_tables',
        file = 'sql/002_alerts_tables.sql',
        description = 'Alert queue and alert history tables',
    },
    -- Add new migrations here. DO NOT reorder existing entries.
}


-- =============================================================================
-- INTERNAL: BOOTSTRAP TABLE
-- =============================================================================
-- The migrations table itself is defined inside 001_core_tables.sql, but
-- we need to check "has 001 been applied?" BEFORE 001 has run. Chicken
-- and egg: we can't use the migrations table until it exists.
--
-- Solution: bootstrap it with a minimal CREATE TABLE IF NOT EXISTS that
-- matches the schema in 001. If 001 hasn't run yet, this creates the
-- table now. If 001 has run, this is a no-op. Either way, we end up with
-- a usable migrations table we can query.
--
-- The bootstrap SQL is intentionally identical in shape to what's in 001,
-- so there's no risk of schema divergence.

local BOOTSTRAP_MIGRATIONS_TABLE = [[
    CREATE TABLE IF NOT EXISTS `bsd_sentinel_migrations` (
        `migration_id`      VARCHAR(50) NOT NULL,
        `description`       VARCHAR(255) NOT NULL,
        `applied_at`        TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
        `checksum`          CHAR(64) NULL,
        PRIMARY KEY (`migration_id`)
    ) ENGINE=InnoDB
      DEFAULT CHARSET=utf8mb4
      COLLATE=utf8mb4_unicode_ci
      COMMENT='Migration history for bsd_sentinel';
]]


-- =============================================================================
-- INTERNAL: SHA-256 (POLYFILL)
-- =============================================================================
-- We want a checksum of each migration file's contents. FiveM provides
-- no native SHA function from Lua. Options:
--
-- 1. Pull in a pure-Lua SHA-256 library. ~500 lines of code. Works.
-- 2. Use a weaker hash (djb2, FNV-1a). ~15 lines. Collision risk in
--    adversarial settings, but nobody is adversarially constructing
--    migration file contents to collide.
--
-- For v1.0 we use FNV-1a 64-bit. It's not cryptographically secure, but
-- we're not using it for security — we're using it to detect "did this
-- file change after being applied?" which is a non-adversarial question.
--
-- DESIGN: Stored as hex in a CHAR(64) column for forward compatibility
-- with SHA-256 if we upgrade later. FNV-1a 64-bit fits in 16 hex chars;
-- we zero-pad to 64.
-- =============================================================================

--- Compute FNV-1a 64-bit hash of a string. Returns 64-char zero-padded hex.
---@param s string
---@return string
local function fnv1a64Hex(s)
    -- FNV-1a 64-bit
    -- offset_basis = 0xcbf29ce484222325
    -- prime        = 0x100000001b3
    --
    -- Lua 5.4 has 64-bit integers, so this is straightforward.
    if type(s) ~= 'string' then return string.rep('0', 64) end

    local hash = 0xcbf29ce484222325
    local prime = 0x100000001b3
    for i = 1, #s do
        hash = hash ~ string.byte(s, i)
        hash = (hash * prime) & 0xffffffffffffffff
    end

    -- Format as 16 hex chars, then zero-pad to 64.
    local hex = string.format('%016x', hash)
    return string.rep('0', 48) .. hex
end


-- =============================================================================
-- INTERNAL: LOAD MIGRATION FILE
-- =============================================================================

--- Read the contents of a migration file.
-- Uses FiveM's LoadResourceFile. Returns nil on failure.
---@param relativePath string path relative to the resource root
---@return string|nil contents
local function loadMigrationFile(relativePath)
    if not LoadResourceFile then
        return nil
    end
    local resourceName = GetCurrentResourceName and GetCurrentResourceName() or 'bsd_sentinel'
    local contents = LoadResourceFile(resourceName, relativePath)
    if type(contents) ~= 'string' or #contents == 0 then
        return nil
    end
    return contents
end


-- =============================================================================
-- INTERNAL: SPLIT SQL FILE INTO STATEMENTS
-- =============================================================================
-- MySQL driver APIs typically take one statement at a time. Our migration
-- files contain multiple statements separated by semicolons. We split on
-- ; at end-of-line but respect -- comments and string literals.
--
-- This is not a general-purpose SQL parser — it's just smart enough to
-- handle our own migration files, which follow a simple style:
--   - Comments start with -- and run to end of line
--   - String literals are quoted with ' or "
--   - Statements end with ; followed by newline
--   - No stored procedures, no DELIMITER changes

--- Split a SQL file's contents into individual statements.
---@param sql string
---@return table statements
local function splitStatements(sql)
    local statements = {}
    local current = {}
    local inSingleQuote = false
    local inDoubleQuote = false
    local inLineComment = false
    local i = 1
    local len = #sql

    while i <= len do
        local c = sql:sub(i, i)
        local next1 = i + 1 <= len and sql:sub(i + 1, i + 1) or ''

        if inLineComment then
            if c == '\n' then
                inLineComment = false
            end
            current[#current + 1] = c
        elseif inSingleQuote then
            current[#current + 1] = c
            if c == "'" and sql:sub(i - 1, i - 1) ~= '\\' then
                inSingleQuote = false
            end
        elseif inDoubleQuote then
            current[#current + 1] = c
            if c == '"' and sql:sub(i - 1, i - 1) ~= '\\' then
                inDoubleQuote = false
            end
        else
            if c == '-' and next1 == '-' then
                inLineComment = true
                current[#current + 1] = c
            elseif c == "'" then
                inSingleQuote = true
                current[#current + 1] = c
            elseif c == '"' then
                inDoubleQuote = true
                current[#current + 1] = c
            elseif c == ';' then
                current[#current + 1] = c
                local stmt = table.concat(current)
                -- Strip whitespace-only statements
                if stmt:match('%S') then
                    statements[#statements + 1] = stmt
                end
                current = {}
            else
                current[#current + 1] = c
            end
        end
        i = i + 1
    end

    -- Handle final statement (no trailing semicolon)
    local final = table.concat(current)
    if final:match('%S') then
        statements[#statements + 1] = final
    end

    return statements
end


-- =============================================================================
-- INTERNAL: APPLY ONE MIGRATION
-- =============================================================================

--- Apply a single migration. Returns (ok, err).
-- Runs each statement in the file. On any failure, logs and returns false.
-- Does NOT wrap in a transaction because DDL in MySQL is auto-committed
-- per statement anyway.
---@param migration table entry from MIGRATIONS list
---@return boolean ok
---@return string|nil err
local function applyMigration(migration)
    local contents = loadMigrationFile(migration.file)
    if not contents then
        return false, string.format('failed to read %s', migration.file)
    end

    local statements = splitStatements(contents)
    if #statements == 0 then
        Logger.Warning('Migration %s contains no statements', migration.id)
        return true  -- vacuously applied
    end

    Logger.Debug('Applying migration %s (%d statements)', migration.id, #statements)

    for i, statement in ipairs(statements) do
        local ok, err = pcall(function()
            Driver.ExecuteSync(statement, {})
        end)
        if not ok then
            return false, string.format(
                'statement %d failed: %s',
                i, tostring(err)
            )
        end
    end

    -- Record successful application
    local checksum = fnv1a64Hex(contents)
    local recordOk, recordErr = pcall(function()
        Driver.ExecuteSync(
            'INSERT INTO bsd_sentinel_migrations (migration_id, description, checksum) VALUES (?, ?, ?)',
            { migration.id, migration.description, checksum }
        )
    end)
    if not recordOk then
        -- Migration ran but couldn't be recorded. This is a problem:
        -- a future run will attempt to re-apply this migration. Log loudly.
        return false, string.format(
            'migration applied but could not be recorded: %s',
            tostring(recordErr)
        )
    end

    return true
end


-- =============================================================================
-- INTERNAL: LOAD APPLIED MIGRATIONS
-- =============================================================================

--- Read the set of already-applied migrations from the DB.
-- Returns a table of migration_id -> {applied_at, checksum}.
---@return table
local function loadAppliedMigrations()
    local applied = {}
    local ok, rows = pcall(function()
        return Driver.QuerySync(
            'SELECT migration_id, applied_at, checksum FROM bsd_sentinel_migrations',
            {}
        )
    end)
    if not ok or type(rows) ~= 'table' then
        Logger.Warning(
            'Could not read migrations table; assuming no migrations applied'
        )
        return applied
    end
    for _, row in ipairs(rows) do
        applied[row.migration_id] = {
            applied_at = row.applied_at,
            checksum = row.checksum,
        }
    end
    return applied
end


-- =============================================================================
-- PUBLIC: RUN ALL PENDING MIGRATIONS
-- =============================================================================


--- Run all pending migrations. Called by main.lua after DB driver is initialized.
-- Returns (ok, count) where count is the number of migrations just applied.
-- Returns ok=false if any migration failed, halting the chain.
---@return boolean ok
---@return integer applied_count
function Migrator.RunPending()
    Logger.Section('Running database migrations')

    -- Step 1: bootstrap the migrations table.
    local bootstrapOk, bootstrapErr = pcall(function()
        Driver.ExecuteSync(BOOTSTRAP_MIGRATIONS_TABLE, {})
    end)
    if not bootstrapOk then
        Logger.Result('Running database migrations', false,
            string.format('could not create migrations table: %s', tostring(bootstrapErr))
        )
        return false, 0
    end

    -- Step 2: load the list of already-applied migrations.
    local applied = loadAppliedMigrations()

    -- Step 3: walk the declared migrations in order.
    local appliedCount = 0
    for _, migration in ipairs(MIGRATIONS) do
        if applied[migration.id] then
            -- Already applied. Verify checksum if we can.
            local contents = loadMigrationFile(migration.file)
            if contents then
                local currentChecksum = fnv1a64Hex(contents)
                local recordedChecksum = applied[migration.id].checksum
                if recordedChecksum and currentChecksum ~= recordedChecksum then
                    Logger.Warning(
                        'Migration %s checksum mismatch: file has changed since it was applied. ' ..
                        'This is a serious issue — see MIGRATION POLICY in migrator.lua. ' ..
                        'Recorded: %s, current: %s',
                        migration.id,
                        tostring(recordedChecksum):sub(-16),
                        currentChecksum:sub(-16)
                    )
                end
            end
            Logger.Debug('Migration %s already applied', migration.id)
        else
            -- Not applied. Run it.
            Logger.Info('Applying migration: %s (%s)',
                migration.id, migration.description)
            local ok, err = applyMigration(migration)
            if not ok then
                Logger.Result('Running database migrations', false,
                    string.format('migration %s failed: %s',
                        migration.id, tostring(err))
                )
                return false, appliedCount
            end
            appliedCount = appliedCount + 1
        end
    end

    if appliedCount == 0 then
        Logger.SectionDone('Running database migrations', 'schema up-to-date')
    else
        Logger.SectionDone('Running database migrations',
            string.format('%d migration(s) applied', appliedCount)
        )
    end
    return true, appliedCount
end


--- Get a human-readable status report of migration state. Used by admin
-- commands like /bsdmigrations.
---@return table report
function Migrator.Status()
    local applied = loadAppliedMigrations()
    local report = {}
    for _, migration in ipairs(MIGRATIONS) do
        local entry = {
            id = migration.id,
            description = migration.description,
            file = migration.file,
            status = 'pending',
            applied_at = nil,
        }
        if applied[migration.id] then
            entry.status = 'applied'
            entry.applied_at = applied[migration.id].applied_at
        end
        report[#report + 1] = entry
    end
    return report
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Migrator loaded (%d declared migrations)', #MIGRATIONS)


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Migrator.RunPending) == 'function', 'Migrator.RunPending not defined')
assert(type(Migrator.Status) == 'function', 'Migrator.Status not defined')