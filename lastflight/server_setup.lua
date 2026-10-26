-- In-game location editor (server side). Saved locations live in the server's
-- resource KVP store, survive restarts/re-uploads, and override config.lua.

local KVP = 'layout'

local function allowed(src)
    return Bridge.IsAdmin(src)
end

local function publish(layout, saved)
    GlobalState.lastflight_layout = { layout = layout, saved = saved, version = LF.LayoutVersion }
end

local function routeSummary()
    local tl = LF.Timeline
    return ('Taxi %ds | takeoff %ds | scenic %ds @ %.0f m/s | departure %ds'):format(
        math.floor(tl.TAXIING.duration), math.floor(tl.TAKEOFF.duration),
        math.floor(tl.CRUISING.duration), tl.cruiseSpeed, math.floor(tl.FINAL_DEPARTURE.duration))
end

local function busy()
    local s = LFS.Status()
    return s.passengers > 0
end

-- Load saved locations at start
do
    local raw = GetResourceKvpString(KVP)
    local applied = false
    if raw then
        local ok, data = pcall(json.decode, raw)
        local clean, err
        if ok then clean, err = LF.ValidateLayout(data) else err = 'corrupt JSON' end
        if clean then
            LF.ApplyLayout(clean)
            publish(clean, true)
            applied = true
            print('^5[lastflight]^7 Using locations saved with /' .. Config.Admin.command .. ' setup')
            LF.PrintRoute()
        else
            LF.Warn('Saved locations are invalid (' .. tostring(err) .. ') - using config.lua')
        end
    end
    if not applied then publish(LF.LayoutFromConfig(), false) end
end

local function reply(src, msg, kind)
    if src == 0 then print('[lastflight] ' .. msg) else Bridge.Notify(src, msg, kind) end
end

---------------------------------------------------------------------------
-- Farewell mode: test / live_return / live_kick (saved on the server,
-- overrides Config.Farewell.mode)
---------------------------------------------------------------------------
local MODE_KVP = 'testmode'
do
    local v = GetResourceKvpString(MODE_KVP)
    if v == '1' then v = 'test' elseif v == '0' then v = 'live_kick' end   -- older saves were on/off
    if v and LF.Modes[v] then Config.Farewell.mode = v end
    LF.Mode()
end

function LFS.SetMode(src, mode)
    if not allowed(src) then return reply(src, 'No permission.', 'error') end
    if not LF.Modes[mode] then return reply(src, 'Unknown mode. Use test, return or kick.', 'error') end
    Config.Farewell.mode = mode
    SetResourceKvp(MODE_KVP, mode)
    local m = LF.Modes[mode]
    print(('^5[lastflight]^7 %s switched to %s'):format(src == 0 and 'console' or (GetPlayerName(src) or src), m.label))
    if src ~= 0 then TriggerClientEvent('lastflight:client:setupMode', src, mode) end
    reply(src, m.label .. ': ' .. m.desc, 'success')
end

RegisterNetEvent('lastflight:server:setMode', function(mode)
    LFS.SetMode(source, tostring(mode))
end)

function LFS.OpenSetup(src)
    if not allowed(src) then return reply(src, 'No permission.', 'error') end
    TriggerClientEvent('lastflight:client:setupOpen', src, {
        layout   = LF.LayoutFromConfig(),
        defaults = LF.DefaultLayout,
        saved    = GetResourceKvpString(KVP) ~= nil,
        busy     = busy(),
        route    = routeSummary(),
        mode     = LF.Mode(),
        returnTo = Config.Farewell.returnTo,
    })
end

RegisterNetEvent('lastflight:server:setupOpen', function()
    LFS.OpenSetup(source)
end)

---------------------------------------------------------------------------
-- Flight Logbook item: using it opens the setup panel (same pattern as EBP)
---------------------------------------------------------------------------
local function sourceFromInventory(inventory)
    if type(inventory) == 'table' then
        return tonumber(inventory.id or inventory.source or inventory.player)
    end
    return tonumber(inventory)
end

local function useLogbook(src)
    if not allowed(src) then
        return reply(src, 'Only flight administrators can use the logbook.', 'error')
    end
    LFS.OpenSetup(src)
end

-- ox_inventory: items.lua -> server = { export = 'lastflight.useLogbook' }
exports('useLogbook', function(...)
    local event = select(1, ...)
    local inventory = select(3, ...)
    if event == nil and type(select(2, ...)) == 'string' then
        event = select(2, ...)
        inventory = select(4, ...)
    end
    local src = sourceFromInventory(inventory)
    if not src or src <= 0 then src = source end
    if event == 'usingItem' then
        if not allowed(src) then
            reply(src, 'Only flight administrators can use the logbook.', 'error')
            return false
        end
        LFS.OpenSetup(src)
        return true
    end
end)

-- jaksam_inventory
CreateThread(function()
    Wait(1000)
    if GetResourceState('jaksam_inventory') ~= 'started' then return end
    local ok = pcall(function()
        exports['jaksam_inventory']:registerUsableItem(Config.Inventory.logbookItem, function(src)
            useLogbook(src)
        end)
    end)
    if not ok then LF.Warn('Could not register the logbook as a usable jaksam item.') end
end)

-- /lastflight logbook [server id]  (admin) - hands out the logbook item
function LFS.GiveLogbook(src, target)
    if not allowed(src) then return reply(src, 'No permission.', 'error') end
    target = tonumber(target) or src
    if target == 0 or not GetPlayerName(target) then return reply(src, 'Player not found.', 'error') end
    local ok = Bridge.GiveItem(target, Config.Inventory.logbookItem, {
        label = 'Flight Logbook', description = 'Last Flight to Vice City - flight setup (admin)',
    })
    reply(src, ok and 'Flight Logbook given.' or 'Could not give the logbook - is the item added to your inventory?', ok and 'success' or 'error')
end

RegisterNetEvent('lastflight:server:setupSave', function(layout)
    local src = source
    if not allowed(src) then return end
    if busy() then
        return reply(src, 'A flight has passengers right now. Wait for it to finish or use /' .. Config.Admin.command .. ' reset first.', 'error')
    end
    local clean, err = LF.ValidateLayout(layout)
    if not clean then return reply(src, 'Not saved: ' .. tostring(err), 'error') end

    SetResourceKvp(KVP, json.encode(clean))
    LF.ApplyLayout(clean)
    publish(clean, true)
    LFS.Reset(true, 'layout saved')      -- puts a fresh jet at the new parking spot
    LF.PrintRoute()
    print(('^5[lastflight]^7 Locations saved by %s (%s)'):format(GetPlayerName(src) or 'console', Bridge.Identifier(src)))
    TriggerClientEvent('lastflight:client:setupSaved', src, { saved = true, route = routeSummary() })
    reply(src, 'Locations saved as the new defaults. ' .. routeSummary(), 'success')
end)

RegisterNetEvent('lastflight:server:setupFactory', function()
    local src = source
    if not allowed(src) then return end
    if busy() then
        return reply(src, 'A flight has passengers right now. Try again when it is finished.', 'error')
    end
    DeleteResourceKvp(KVP)
    local clean = LF.ValidateLayout(LF.DefaultLayout)
    if clean then LF.ApplyLayout(clean) end
    publish(LF.LayoutFromConfig(), false)
    LFS.Reset(true, 'factory reset')
    TriggerClientEvent('lastflight:client:setupSaved', src, { saved = false, route = routeSummary() })
    reply(src, 'Saved locations cleared - back to the values in config.lua.', 'success')
end)
