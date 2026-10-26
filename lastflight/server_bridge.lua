-- Framework (money) + inventory (boarding pass item) adapters.
-- Nothing here is required: with Framework = 'standalone' and Inventory = 'none'
-- the resource runs on a bare FiveM server.

Bridge = {}

---------------------------------------------------------------------------
-- Framework detection
---------------------------------------------------------------------------
local framework
local QBCore, ESX

local function started(name) return GetResourceState(name) == 'started' end

local function detectFramework()
    local cfg = tostring(Config.Framework or 'auto'):lower()
    if cfg == 'qbx' or cfg == 'qbx_core' then cfg = 'qbox' end
    if cfg == 'qb' or cfg == 'qb-core' then cfg = 'qbcore' end

    if cfg == 'auto' then
        if started('qbx_core') then cfg = 'qbox'
        elseif started('qb-core') then cfg = 'qbcore'
        elseif started('es_extended') then cfg = 'esx'
        else cfg = 'standalone' end
    end

    if cfg == 'qbcore' and started('qb-core') then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif cfg == 'esx' and started('es_extended') then
        ESX = exports.es_extended:getSharedObject()
    elseif cfg ~= 'qbox' and cfg ~= 'standalone' then
        LF.Warn(('Framework "%s" is not running - falling back to standalone'):format(cfg))
        cfg = 'standalone'
    end
    if cfg == 'qbox' and not started('qbx_core') then
        LF.Warn('Framework "qbox" selected but qbx_core is not running - falling back to standalone')
        cfg = 'standalone'
    end
    return cfg
end

function Bridge.Framework()
    if not framework then framework = detectFramework() end
    return framework
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------
local function esxAccount(account)
    return account == 'cash' and 'money' or account
end

local function getBalance(src, account)
    local fw = Bridge.Framework()
    if fw == 'qbox' then
        return tonumber(exports.qbx_core:GetMoney(src, account)) or 0
    elseif fw == 'qbcore' then
        local p = QBCore.Functions.GetPlayer(src)
        return p and tonumber(p.PlayerData.money[account]) or 0
    elseif fw == 'esx' then
        local p = ESX.GetPlayerFromId(src)
        local acc = p and p.getAccount(esxAccount(account))
        return acc and tonumber(acc.money) or 0
    end
    return 0
end

local function removeMoney(src, account, amount, reason)
    local fw = Bridge.Framework()
    if fw == 'qbox' then
        return exports.qbx_core:RemoveMoney(src, account, amount, reason) == true
    elseif fw == 'qbcore' then
        local p = QBCore.Functions.GetPlayer(src)
        return p and p.Functions.RemoveMoney(account, amount, reason) == true or false
    elseif fw == 'esx' then
        local p = ESX.GetPlayerFromId(src)
        if not p then return false end
        p.removeAccountMoney(esxAccount(account), amount, reason)
        return true
    end
    return false
end

local function addMoney(src, account, amount, reason)
    local fw = Bridge.Framework()
    if fw == 'qbox' then
        return exports.qbx_core:AddMoney(src, account, amount, reason) == true
    elseif fw == 'qbcore' then
        local p = QBCore.Functions.GetPlayer(src)
        return p and p.Functions.AddMoney(account, amount, reason) == true or false
    elseif fw == 'esx' then
        local p = ESX.GetPlayerFromId(src)
        if not p then return false end
        p.addAccountMoney(esxAccount(account), amount, reason)
        return true
    end
    return false
end

-- Returns success, accountUsed
function Bridge.Charge(src, amount)
    if amount <= 0 then return true, 'free' end

    if Bridge.Framework() == 'standalone' then
        local fn = Config.Payment.standaloneCharge
        if type(fn) == 'function' then
            local ok, res = pcall(fn, src, amount)
            return ok and res == true, 'standalone'
        end
        return true, 'free'
    end

    for _, account in ipairs(Config.Tickets.accounts) do
        if getBalance(src, account) >= amount then
            if removeMoney(src, account, amount, 'lastflight-ticket') then
                return true, account
            end
        end
    end
    return false
end

function Bridge.Refund(src, amount, account)
    if not amount or amount <= 0 or account == 'free' then return true end
    if account == 'standalone' or Bridge.Framework() == 'standalone' then
        local fn = Config.Payment.standaloneRefund
        if type(fn) == 'function' then pcall(fn, src, amount) end
        return true
    end
    return addMoney(src, account or Config.Tickets.accounts[1] or 'cash', amount, 'lastflight-refund')
end

---------------------------------------------------------------------------
-- Inventory (same provider pattern as masterbaits_fishing / EBP)
---------------------------------------------------------------------------
local function inventoryProvider()
    local cfg = tostring(Config.Inventory.provider or 'ox'):lower()
    if cfg == 'ox_inventory' then cfg = 'ox' end
    if cfg == 'jaksam_inventory' then cfg = 'jaksam' end
    if cfg == 'none' or not Config.Inventory.giveTicketItem then return 'none' end

    if cfg == 'ox' and started('ox_inventory') then return 'ox' end
    if cfg == 'jaksam' and started('jaksam_inventory') then return 'jaksam' end
    if cfg == 'auto' then
        if started('ox_inventory') then return 'ox' end
        if started('jaksam_inventory') then return 'jaksam' end
    end
    return 'none'
end
Bridge.InventoryProvider = inventoryProvider

local function jaksam(fnName, ...)
    local args = { ... }
    local ok, res = pcall(function()
        return exports['jaksam_inventory'][fnName](exports['jaksam_inventory'], table.unpack(args))
    end)
    if not ok then LF.Debug('jaksam_inventory:' .. fnName .. ' failed: ' .. tostring(res)) end
    return ok and res or nil
end

local function giveItem(src, item, metadata)
    local provider = inventoryProvider()
    if provider == 'none' or not item then return false end
    local ok
    if provider == 'ox' then
        ok = exports.ox_inventory:AddItem(src, item, 1, metadata)
    else
        ok = jaksam('addItem', src, item, 1, metadata)
    end
    if not ok then
        LF.Warn(('Could not give "%s" to %s. Is the item registered in %s? (ticket still valid)'):format(item, src, provider))
    end
    return ok and true or false
end

Bridge.GiveItem = function(src, item, metadata) return giveItem(src, item, metadata) end

local function countItem(src, item)
    local provider = inventoryProvider()
    if provider == 'none' or not item then return 0 end
    if provider == 'ox' then
        return exports.ox_inventory:Search(src, 'count', item) or 0
    end
    local count = jaksam('getTotalItemAmount', src, item)
    if count == nil then
        return jaksam('hasItem', src, item, 1) == true and 1 or 0
    end
    return tonumber(count) or 0
end

local function removeItem(src, item)
    if countItem(src, item) <= 0 then return end
    if inventoryProvider() == 'ox' then
        exports.ox_inventory:RemoveItem(src, item, 1)
    else
        jaksam('removeItem', src, item, 1)
    end
end

local function passMetadata(ticket, torn)
    return {
        label       = torn and ('Boarding Pass Stub %s'):format(Config.Flight.number)
                           or ('Boarding Pass %s'):format(Config.Flight.number),
        description = ('%s -> %s | Ticket #%s%s'):format(Config.Flight.airport, Config.Flight.destination,
                           ticket.id, torn and ' | Boarded' or ''),
        flight      = Config.Flight.number,
        ticket      = ticket.id,
        boarded     = torn and os.date('%Y-%m-%d %H:%M') or nil,
    }
end

-- Full ticket at purchase.
function Bridge.GiveTicketItem(src, ticket)
    return giveItem(src, Config.Inventory.ticketItem, passMetadata(ticket, false))
end

-- On boarding: tear the stub off (full ticket -> stub). Only once per ticket.
function Bridge.TearTicket(src, ticket)
    if inventoryProvider() == 'none' then return end
    if ticket.torn then return end
    ticket.torn = true
    removeItem(src, Config.Inventory.ticketItem)
    giveItem(src, Config.Inventory.stubItem, passMetadata(ticket, true))
end

function Bridge.HasTicketItem(src)
    if inventoryProvider() == 'none' then return true end
    return countItem(src, Config.Inventory.ticketItem) > 0 or countItem(src, Config.Inventory.stubItem) > 0
end

-- Refunds: take back whichever version they hold.
function Bridge.RemoveTicketItem(src, ticket)
    if not Config.Inventory.removeOnRefund or inventoryProvider() == 'none' then return end
    if ticket and ticket.torn then
        removeItem(src, Config.Inventory.stubItem)
    else
        removeItem(src, Config.Inventory.ticketItem)
    end
end

---------------------------------------------------------------------------
-- Admin check: the server's normal admins (no extra ACE setup needed)
---------------------------------------------------------------------------
function Bridge.IsAdmin(src)
    if src == 0 then return true end
    if Config.Admin.ace and IsPlayerAceAllowed(src, Config.Admin.ace) then return true end
    for _, ace in ipairs(Config.Admin.serverAdminAces or {}) do
        if IsPlayerAceAllowed(src, ace) then return true end
    end
    local fw = Bridge.Framework()
    if fw == 'qbcore' and QBCore then
        local ok, res = pcall(function()
            return QBCore.Functions.HasPermission(src, 'admin') or QBCore.Functions.HasPermission(src, 'god')
        end)
        if ok and res then return true end
    elseif fw == 'esx' and ESX then
        local p = ESX.GetPlayerFromId(src)
        local group = p and p.getGroup and p.getGroup()
        if group == 'admin' or group == 'superadmin' then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Identifiers / notify
---------------------------------------------------------------------------
function Bridge.Identifier(src)
    local id = GetPlayerIdentifierByType(src, 'license2') or GetPlayerIdentifierByType(src, 'license')
        or GetPlayerIdentifierByType(src, 'fivem') or GetPlayerIdentifierByType(src, 'steam')
    return id or ('src:' .. tostring(src))
end

function Bridge.Notify(src, msg, kind)
    TriggerClientEvent('lastflight:client:notify', src, msg, kind or 'info')
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    print(('^5[lastflight]^7 Framework: %s | Ticket item: %s'):format(Bridge.Framework(), inventoryProvider()))
end)
