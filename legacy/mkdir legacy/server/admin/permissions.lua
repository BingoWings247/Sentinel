-- =============================================================================
-- bsd_sentinel / server / admin / permissions.lua
-- =============================================================================
-- Permission system for Sentinel admin commands.
--
-- Three tiers, hierarchical:
--   READ          - Can view events. Default for trusted staff.
--   INVESTIGATE   - Can view metadata, correlation chains, sensitive details.
--   ADMIN         - Can do everything, including reverse events and
--                   modify Sentinel's own state.
--
-- The tiers nest: ADMIN implies INVESTIGATE implies READ.
--
-- DESIGN: Permissions are checked via FiveM's ACE (Access Control Entry)
-- system. The actual grants live in server.cfg:
--
--   add_ace group.staff bsd.sentinel.read allow
--   add_ace group.investigator bsd.sentinel.investigate allow
--   add_ace group.superadmin bsd.sentinel.admin allow
--
-- Or alternatively, granted to specific identifiers:
--
--   add_ace identifier.license:abc123 bsd.sentinel.admin allow
--
-- This module abstracts the ACE check so command handlers don't need to
-- know about IsPlayerAceAllowed directly. They just call
-- Permissions.AssertRead(source) and trust the result.
--
-- DESIGN: Console (server-side) actions are always allowed. When source=0,
-- the action came from the server console (e.g., txAdmin live console),
-- which by definition has root access to the server. Refusing console
-- access would lock operators out of their own servers.
--
-- Dependencies: server/logger.lua, shared/constants.lua
-- =============================================================================

BSD = BSD or {}
BSD.Sentinel = BSD.Sentinel or {}
BSD.Sentinel.Admin = BSD.Sentinel.Admin or {}
BSD.Sentinel.Admin.Permissions = {}

local Permissions = BSD.Sentinel.Admin.Permissions
local Logger = BSD.Sentinel.Logger
local Constants = BSD.Sentinel.Constants


-- =============================================================================
-- ACE NODE NAMES
-- =============================================================================

-- These match the constants defined in shared/constants.lua so other
-- modules can reference them without depending on this one.

local NODE_READ        = (Constants and Constants.PERM_READ)        or 'bsd.sentinel.read'
local NODE_INVESTIGATE = (Constants and Constants.PERM_INVESTIGATE) or 'bsd.sentinel.investigate'
local NODE_ADMIN       = (Constants and Constants.PERM_ADMIN)       or 'bsd.sentinel.admin'

Permissions.NODE_READ = NODE_READ
Permissions.NODE_INVESTIGATE = NODE_INVESTIGATE
Permissions.NODE_ADMIN = NODE_ADMIN


-- =============================================================================
-- INTERNAL: ACE CHECK
-- =============================================================================


--- Check whether a source has been granted a specific ACE node.
-- Returns true if the source is the server console, or if the ACE
-- system says the source is allowed. False otherwise.
---@param source integer player source, or 0 for server console
---@param node string ACE node name
---@return boolean
local function hasAce(source, node)
    -- Console always allowed. Source 0 means the action came from the
    -- server itself (txAdmin live console, scheduled task, etc.) and
    -- those have root access by design.
    if not source or source == 0 then
        return true
    end

    -- Validate source is a positive integer (player source).
    if type(source) ~= 'number' or source < 1 then
        return false
    end

    -- IsPlayerAceAllowed is FiveM's standard ACE check.
    if IsPlayerAceAllowed and IsPlayerAceAllowed(source, node) then
        return true
    end

    return false
end


-- =============================================================================
-- PUBLIC: TIER CHECKS (NON-ASSERTING)
-- =============================================================================
-- Use these when you want to check a permission and branch on the result
-- without throwing an error. Useful for conditionally hiding output
-- (e.g., "show metadata only if the user has investigate permission").


--- Does this source have READ permission or higher?
-- Read implies the user can view events. Required for /bsdquery,
-- /bsdevent, /bsdhealth, etc.
---@param source integer
---@return boolean
function Permissions.HasRead(source)
    -- Higher tiers imply lower tiers
    return hasAce(source, NODE_READ)
        or hasAce(source, NODE_INVESTIGATE)
        or hasAce(source, NODE_ADMIN)
end


--- Does this source have INVESTIGATE permission or higher?
-- Investigate gates access to metadata, correlation chains, and full
-- event details. Required for /bsdcorrelation and metadata views.
---@param source integer
---@return boolean
function Permissions.HasInvestigate(source)
    return hasAce(source, NODE_INVESTIGATE)
        or hasAce(source, NODE_ADMIN)
end


--- Does this source have ADMIN permission?
-- Admin gates access to mutating commands and Sentinel's own internal
-- controls. Required for /bsdreverse, /bsdretention, etc.
---@param source integer
---@return boolean
function Permissions.HasAdmin(source)
    return hasAce(source, NODE_ADMIN)
end


-- =============================================================================
-- PUBLIC: TIER ASSERTIONS (THROWING)
-- =============================================================================
-- Use these at the top of command handlers when you want a clean
-- pattern: assert the permission, return early on failure with a
-- consistent error message. The handlers themselves don't have to
-- duplicate the permission-denied messaging.


--- Assert that a source has READ permission. If not, log the denial
-- and return false. Caller should then return early without doing work.
---@param source integer
---@param commandName string for logging context
---@return boolean ok true if allowed, false if denied
function Permissions.AssertRead(source, commandName)
    if Permissions.HasRead(source) then
        return true
    end
    Logger.Warning(
        'Permission denied: source=%s tried to run %s (requires %s)',
        tostring(source), tostring(commandName), NODE_READ
    )
    return false
end


--- Assert that a source has INVESTIGATE permission.
---@param source integer
---@param commandName string
---@return boolean ok
function Permissions.AssertInvestigate(source, commandName)
    if Permissions.HasInvestigate(source) then
        return true
    end
    Logger.Warning(
        'Permission denied: source=%s tried to run %s (requires %s)',
        tostring(source), tostring(commandName), NODE_INVESTIGATE
    )
    return false
end


--- Assert that a source has ADMIN permission.
---@param source integer
---@param commandName string
---@return boolean ok
function Permissions.AssertAdmin(source, commandName)
    if Permissions.HasAdmin(source) then
        return true
    end
    Logger.Warning(
        'Permission denied: source=%s tried to run %s (requires %s)',
        tostring(source), tostring(commandName), NODE_ADMIN
    )
    return false
end


-- =============================================================================
-- PUBLIC: TIER NAME LOOKUP
-- =============================================================================


--- Get the highest permission tier this source has.
-- Returns one of: 'admin', 'investigate', 'read', or nil if no tier.
-- Useful for output that says "you are connected as <tier>" or for
-- audit logs of what permission level a user is operating with.
---@param source integer
---@return string|nil tier
function Permissions.HighestTier(source)
    if Permissions.HasAdmin(source) then return 'admin' end
    if Permissions.HasInvestigate(source) then return 'investigate' end
    if Permissions.HasRead(source) then return 'read' end
    return nil
end


--- Friendly description of what each tier can do.
-- Useful for /bsdpermissions or similar discovery commands.
---@return table
function Permissions.Describe()
    return {
        {
            node = NODE_READ,
            tier = 'read',
            description = 'View events, run queries, see basic event details.',
        },
        {
            node = NODE_INVESTIGATE,
            tier = 'investigate',
            description = 'Read tier plus: view metadata, follow correlation chains, see sensitive event details.',
        },
        {
            node = NODE_ADMIN,
            tier = 'admin',
            description = 'Investigate tier plus: reverse events, modify retention policy, control Sentinel state.',
        },
    }
end


-- =============================================================================
-- SELF-ANNOUNCE
-- =============================================================================

Logger.Info('Permissions module loaded (3 tiers: %s, %s, %s)',
    NODE_READ, NODE_INVESTIGATE, NODE_ADMIN)


-- =============================================================================
-- MODULE EXPORT
-- =============================================================================

assert(type(Permissions.HasRead) == 'function', 'Permissions.HasRead not defined')
assert(type(Permissions.AssertRead) == 'function', 'Permissions.AssertRead not defined')
assert(type(Permissions.HighestTier) == 'function', 'Permissions.HighestTier not defined')