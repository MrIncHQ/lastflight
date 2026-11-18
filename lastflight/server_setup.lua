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
        -- One time only: put the blocked roads written in config.lua into the saved
        -- layout (a bug once saved it with none). Duplicates are skipped, and after
        -- this the setup panel is in charge - blocks deleted there stay deleted.
        -- only counts as done once it has really seen the config.lua blocks (if the
        -- server ran an older shared.lua first, it saw none and must try again)
        local MERGED = 'blocksMerged2'
        local fromConfig = #(LF.DefaultLayout.tourBlocks or {})
        print(('^5[lastflight]^7 Blocked roads: %d in config.lua, %d in the saved locations'):format(fromConfig, #((clean and clean.tourBlocks) or {})))
        if clean and fromConfig > 0 and not GetResourceKvpString(MERGED) then
            local list, added = clean.tourBlocks or {}, 0
            for _, nb in ipairs(LF.DefaultLayout.tourBlocks or {}) do
                local dup = false
                for _, b in ipairs(list) do
                    if #(vector3(b.from.x - nb.from.x, b.from.y - nb.from.y, 0.0)) < 2.0
                        and #(vector3(b.to.x - nb.to.x, b.to.y - nb.to.y, 0.0)) < 2.0 then dup = true break end
                end
                if not dup and #list < LF.LayoutFields.tourBlocks.max then
                    list[#list + 1] = nb
                    added = added + 1
                end
            end
            clean.tourBlocks = list
            if added > 0 then
                SetResourceKvp(KVP, json.encode(clean))
                print(('^5[lastflight]^7 Added %d blocked road(s) from config.lua to the saved locations'):format(added))
            end
            SetResourceKvp(MERGED, '1')
        end
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

---------------------------------------------------------------------------
-- Red lights: do the city taxi and the highway drive stop at them or drive
-- through? Saved on the server, shared with every client via GlobalState.
---------------------------------------------------------------------------
local LIGHTS_KVP = 'runlights'
do
    local v = GetResourceKvpString(LIGHTS_KVP)
    if v == nil then v = Config.Transport.runRedLights and '1' or '0' end
    GlobalState.lf_runLights = v == '1'
end

function LFS.SetRunLights(src, on)
    if not allowed(src) then return reply(src, 'No permission.', 'error') end
    on = on == true
    SetResourceKvp(LIGHTS_KVP, on and '1' or '0')
    GlobalState.lf_runLights = on
    print(('^5[lastflight]^7 %s set red lights to: %s'):format(src == 0 and 'console' or (GetPlayerName(src) or src),
        on and 'drive through' or 'stop'))
    if src ~= 0 then TriggerClientEvent('lastflight:client:setupLights', src, on) end
    reply(src, on and 'The taxi and highway drive now drive through red lights.'
        or 'The taxi and highway drive now stop at red lights.', 'success')
end

---------------------------------------------------------------------------
-- Jet paint job (livery). GTA picks one at random when the jet spawns; an
-- admin can lock one with /lastflight livery <number>. Saved on the server.
---------------------------------------------------------------------------
local LIVERY_KVP = 'livery'
do
    local v = tonumber(GetResourceKvpString(LIVERY_KVP) or '')
    if v == nil then v = tonumber(Config.Aircraft.livery) end
    GlobalState.lf_livery = v
end

function LFS.SetLivery(src, value)
    if not allowed(src) then return reply(src, 'No permission.', 'error') end
    if value == 'random' or value == 'off' then
        DeleteResourceKvp(LIVERY_KVP)
        GlobalState.lf_livery = nil
        return reply(src, 'Jet livery unlocked: GTA picks one each time it spawns.', 'success')
    end
    local n = tonumber(value)
    if not n or n < 0 or n > 50 then return reply(src, 'Usage: /' .. Config.Admin.command .. ' livery <number | random>', 'error') end
    n = math.floor(n)
    SetResourceKvp(LIVERY_KVP, tostring(n))
    GlobalState.lf_livery = n
    reply(src, ('Jet livery locked to %d. The parked jet changes within a few seconds.'):format(n), 'success')
end

---------------------------------------------------------------------------
-- Highway drive route: 'line' (the recorded Highway loop) or 'pins' (key pins,
-- driven GPS-style pin to pin like the airport shuttle). Saved on the server.
---------------------------------------------------------------------------
local ROUTE_KVP = 'tourroute'
do
    local v = GetResourceKvpString(ROUTE_KVP) or Config.Tour.routeMode or 'line'
    GlobalState.lf_tourRoute = v == 'pins' and 'pins' or 'line'
end

function LFS.SetTourRoute(src, mode)
    if not allowed(src) then return reply(src, 'No permission.', 'error') end
    mode = mode == 'pins' and 'pins' or 'line'
    SetResourceKvp(ROUTE_KVP, mode)
    GlobalState.lf_tourRoute = mode
    if src ~= 0 then TriggerClientEvent('lastflight:client:setupTourRoute', src, mode) end
    reply(src, mode == 'pins' and 'Highway drive now drives pin to pin (Highway pins).'
        or 'Highway drive now follows the recorded line (Highway loop).', 'success')
end

RegisterNetEvent('lastflight:server:setTourRoute', function(mode)
    LFS.SetTourRoute(source, tostring(mode))
end)

RegisterNetEvent('lastflight:server:setRunLights', function(on)
    LFS.SetRunLights(source, on == true)
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
        runLights = GlobalState.lf_runLights == true,
        tourRoute = GlobalState.lf_tourRoute or 'line',
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

---------------------------------------------------------------------------
-- Props (setup panel -> PROPS tab). Saved on the server as soon as they are
-- placed, moved or deleted, and shared with every client via GlobalState.
-- Separate from the locations: "Factory reset" does not remove them.
---------------------------------------------------------------------------
local PROPS_KVP = 'props'
local Props, propSeq = {}, 0

local function num(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v < lo or v > hi then return nil end
    return math.floor(v * 1000 + 0.5) / 1000
end

-- a placed prop from the client (or the KVP), cleaned; nil if it's bad
local function cleanProp(d)
    if type(d) ~= 'table' then return nil end
    local model = tostring(d.model or '')
    if #model < 1 or #model > 64 or not model:match('^[%w_%-]+$') then return nil end
    local p = {
        model = model,
        x = num(d.x, -10000, 10000), y = num(d.y, -10000, 10000), z = num(d.z, -500, 3000),
        h = num(d.h, -720, 720) or 0.0,
    }
    if not (p.x and p.y and p.z) then return nil end
    p.h = p.h % 360
    if model == '__text' then
        local text = tostring(d.text or ''):gsub('[%c<>~]', ''):sub(1, 60)
        if text:match('^%s*$') then return nil end
        p.text = text
    end
    return p
end

local function publishProps()
    GlobalState.lf_props = Props
end

local function saveProps()
    SetResourceKvp(PROPS_KVP, json.encode(Props))
    publishProps()
end

do
    local raw = GetResourceKvpString(PROPS_KVP)
    local ok, data = pcall(json.decode, raw or '[]')
    if ok and type(data) == 'table' then
        for _, d in ipairs(data) do
            local p = cleanProp(d)
            if p then
                p.id = tonumber(d.id) or (propSeq + 1)
                propSeq = math.max(propSeq, p.id)
                Props[#Props + 1] = p
            end
        end
    end
    if #Props > 0 then print(('^5[lastflight]^7 %d placed prop(s) loaded'):format(#Props)) end
    publishProps()
end

local function propIndex(id)
    id = tonumber(id)
    for i, p in ipairs(Props) do
        if p.id == id then return i end
    end
end

RegisterNetEvent('lastflight:server:propAdd', function(d)
    local src = source
    if not allowed(src) then return end
    if not (Config.Props and Config.Props.enabled) then return end
    if #Props >= (Config.Props.max or 200) then
        return reply(src, ('Prop limit reached (%d). Delete some first.'):format(Config.Props.max or 200), 'error')
    end
    local p = cleanProp(d)
    if not p then return reply(src, 'That prop could not be placed.', 'error') end
    propSeq = propSeq + 1
    p.id = propSeq
    Props[#Props + 1] = p
    saveProps()
end)

RegisterNetEvent('lastflight:server:propMove', function(id, d)
    local src = source
    if not allowed(src) then return end
    local i = propIndex(id)
    if not i then return end
    local p = cleanProp(d)
    if not p then return reply(src, 'That prop could not be moved.', 'error') end
    p.id = Props[i].id
    Props[i] = p
    saveProps()
end)

RegisterNetEvent('lastflight:server:propDelete', function(id)
    local src = source
    if not allowed(src) then return end
    local i = propIndex(id)
    if not i then return end
    table.remove(Props, i)
    saveProps()
end)

RegisterNetEvent('lastflight:server:propClear', function()
    local src = source
    if not allowed(src) then return end
    local n = #Props
    Props = {}
    saveProps()
    print(('^5[lastflight]^7 %s removed all %d placed props'):format(GetPlayerName(src) or src, n))
    reply(src, ('Removed all %d props.'):format(n), 'success')
end)

-- Party music center: one spot the party song loops from (PROPS tab).
-- startedAt lets every player hear the same part of the song.
local MUSIC_KVP = 'partymusic'
do
    local ok, m = pcall(json.decode, GetResourceKvpString(MUSIC_KVP) or 'null')
    if ok and type(m) == 'table' and tonumber(m.x) and tonumber(m.y) and tonumber(m.z) then
        GlobalState.lf_partyMusic = { x = m.x, y = m.y, z = m.z, startedAt = os.time() }
    else
        GlobalState.lf_partyMusic = nil
    end
end

RegisterNetEvent('lastflight:server:partyMusicSet', function(pos)
    local src = source
    if not allowed(src) then return end
    if type(pos) ~= 'table' then return end
    local x, y, z = num(pos.x, -10000, 10000), num(pos.y, -10000, 10000), num(pos.z, -500, 3000)
    if not (x and y and z) then return end
    SetResourceKvp(MUSIC_KVP, json.encode({ x = x, y = y, z = z }))
    GlobalState.lf_partyMusic = { x = x, y = y, z = z, startedAt = os.time() }
    reply(src, 'Party music now plays from here.', 'success')
end)

-- Party music volume (0-1), set with the slider in the PROPS tab. Kept separate from
-- the music center so changing it never restarts the song.
local MUSIC_VOL_KVP = 'partymusicvol'
do
    local v = tonumber(GetResourceKvpString(MUSIC_VOL_KVP) or '')
    GlobalState.lf_partyVolume = v or ((Config.Props and Config.Props.music and Config.Props.music.volume) or 0.4)
end

RegisterNetEvent('lastflight:server:partyMusicVolume', function(v)
    local src = source
    if not allowed(src) then return end
    v = num(v, 0, 1)
    if not v then return end
    SetResourceKvp(MUSIC_VOL_KVP, tostring(v))
    GlobalState.lf_partyVolume = v
end)

RegisterNetEvent('lastflight:server:partyMusicClear', function()
    local src = source
    if not allowed(src) then return end
    DeleteResourceKvp(MUSIC_KVP)
    GlobalState.lf_partyMusic = nil
    reply(src, 'Party music removed.', 'success')
end)
