-- =============================================================================
-- bsd_sentinel_agent / server / adapters / qbcore.lua
-- Money movements on Qbox (qbx_core) and QBCore (qb-core).
--
-- Both frameworks fire QBCore:Server:OnMoneyChange(source, moneyType, amount,
-- action, reason) on every AddMoney / RemoveMoney / SetMoney. The `reason`
-- argument is the provenance: scripts that pass one get credit for the money;
-- money with no reason arrives as source "unknown", which is exactly what
-- Sentinel's dupe detection looks for (wire protocol: provenance rule).
-- =============================================================================

SA = SA or {}

local lastBalance = {}   -- "src|account" -> last known balance

local function currentBalance(src, account)
    if GetResourceState('qbx_core') == 'started' then
        local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        if ok and player and player.PlayerData and player.PlayerData.money then
            return tonumber(player.PlayerData.money[account])
        end
    elseif GetResourceState('qb-core') == 'started' then
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
    local provenance = (type(reason) == 'string' and reason ~= '') and reason or 'unknown'
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
            source = provenance,
            balance_after = balance,
        }, GetInvokingResource() or 'framework')
    elseif action == 'set' then
        local previous = lastBalance[key]
        SA.emit('econ.set', {
            player = name,
            player_id = pid,
            account = moneyType,
            value = amount,
            delta = previous and (amount - previous) or nil,
            source = provenance,
        }, GetInvokingResource() or 'framework')
        balance = amount
    end

    if balance then lastBalance[key] = balance end
end

--- Register if a supported framework is running. Returns the adapter name or nil.
function SA.startQbcoreAdapter()
    local framework
    if GetResourceState('qbx_core') == 'started' then framework = 'qbox'
    elseif GetResourceState('qb-core') == 'started' then framework = 'qbcore'
    else return nil end

    AddEventHandler('QBCore:Server:OnMoneyChange', onMoneyChange)
    AddEventHandler('playerDropped', function()
        local prefix = tostring(source) .. '|'
        for k in pairs(lastBalance) do
            if k:sub(1, #prefix) == prefix then lastBalance[k] = nil end
        end
    end)
    return framework
end
