-- =============================================================================
-- bsd_sentinel_agent / server / adapters / qbcore.lua
-- Money movements on Qbox (qbx_core) and QBCore (qb-core).
--
-- Both frameworks fire QBCore:Server:OnMoneyChange(source, moneyType, amount,
-- action, reason) on every AddMoney / RemoveMoney / SetMoney.
--
-- Who moved the money? The framework fires that event itself, so inside the
-- handler GetInvokingResource() is always the framework (qbx_core), never the
-- script that asked for the change. The only thing that names that script is
-- the `reason` it passed. Convention: "<resource>:<action>", for example
-- "bsd_banking:withdraw". When the part before the colon is a resource that is
-- running on this server, the event's src is that resource; otherwise src is
-- the framework and data.via says so.
--
-- Money with no reason (Qbox fills in "unknown"; some scripts pass "Unknown")
-- is sent as source "unknown", always lowercase. Unsourced money is exactly
-- what Sentinel's dupe detection looks for (wire protocol: provenance rule).
-- =============================================================================

SA = SA or {}

local frameworkResource = nil   -- 'qbx_core' or 'qb-core' once started
local lastBalance = {}          -- "src|account" -> last known balance

-- Reasons that say nothing. Compared lowercased and trimmed.
local NO_REASON = { ['unknown'] = true, ['none'] = true, ['n/a'] = true, ['nil'] = true, ['null'] = true }

--- The reason a script gave, or nil when it gave none.
function SA.provenanceOf(reason)
    if type(reason) ~= 'string' then return nil end
    reason = SA.trim(reason)
    if reason == '' or NO_REASON[reason:lower()] then return nil end
    return reason
end

--- The running resource named by a "<resource>:<action>" reason, or nil.
function SA.originOf(provenance)
    if not provenance then return nil end
    local res = provenance:match('^([%w_%-]+):')
    if res and GetResourceState(res) == 'started' then return res end
    return nil
end

local function currentBalance(src, account)
    if frameworkResource == 'qbx_core' then
        local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        if ok and player and player.PlayerData and player.PlayerData.money then
            return tonumber(player.PlayerData.money[account])
        end
    elseif frameworkResource == 'qb-core' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        if ok and core then
            local player = core.Functions.GetPlayer(src)
            if player and player.PlayerData and player.PlayerData.money then
                return tonumber(player.PlayerData.money[account])
            end
        end
    end
    return nil
end

local function onMoneyChange(src, moneyType, amount, action, reason)
    src = tonumber(src)
    amount = tonumber(amount)
    if not src or not amount or type(moneyType) ~= 'string' then return end

    local name, pid = SA.playerRef(src)
    local provenance = SA.provenanceOf(reason)
    local origin = SA.originOf(provenance) or frameworkResource or 'framework'
    local key = src .. '|' .. moneyType
    local balance = currentBalance(src, moneyType)

    if action == 'add' or action == 'remove' then
        if amount == 0 then return end
        SA.emit('econ.txn', {
            player = name,
            player_id = pid,
            direction = action == 'add' and 'in' or 'out',
            amount = amount,
            account = moneyType,
            source = provenance or 'unknown',
            via = frameworkResource,
            balance_after = balance,
        }, origin)
    elseif action == 'set' then
        local previous = lastBalance[key]
        SA.emit('econ.set', {
            player = name,
            player_id = pid,
            account = moneyType,
            value = amount,
            delta = previous and (amount - previous) or nil,
            source = provenance or 'unknown',
            via = frameworkResource,
        }, origin)
        balance = amount
    end

    if balance then lastBalance[key] = balance end
end

--- Register if a supported framework is running. Returns the adapter name or nil.
function SA.startQbcoreAdapter()
    local framework
    if GetResourceState('qbx_core') == 'started' then
        framework, frameworkResource = 'qbox', 'qbx_core'
    elseif GetResourceState('qb-core') == 'started' then
        framework, frameworkResource = 'qbcore', 'qb-core'
    else
        return nil
    end

    AddEventHandler('QBCore:Server:OnMoneyChange', onMoneyChange)
    AddEventHandler('playerDropped', function()
        local prefix = tostring(source) .. '|'
        for k in pairs(lastBalance) do
            if k:sub(1, #prefix) == prefix then lastBalance[k] = nil end
        end
    end)
    return framework
end
