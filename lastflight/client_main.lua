-- Client core: NUI bridge, notifications, restore/cleanup, keybinds, dev tools.

LFC = {
    debug     = Config.Debug,
    hasTicket = false,
    ticketStatus = 'none',     -- none | boarding | queued | aboard
    focus     = false,
    onCleanup = {},            -- functions other files register to run on restore/stop
}

function LFC.Nui(action, data)
    SendNUIMessage({ action = action, data = data })
end

function LFC.Focus(state)
    LFC.focus = state
    SetNuiFocus(state, state)
end

function LFC.Notify(msg, kind)
    kind = kind or 'info'
    local p = Config.Notify.provider
    if p == 'ox_lib' and GetResourceState('ox_lib') == 'started' then
        TriggerEvent('ox_lib:notify', { title = Config.Flight.number, description = msg, type = kind, duration = Config.Notify.duration })
    elseif p == 'native' then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(msg)
        EndTextCommandThefeedPostTicker(false, true)
    else
        LFC.Nui('toast', { msg = msg, kind = kind, duration = Config.Notify.duration })
    end
end

RegisterNetEvent('lastflight:client:notify', function(msg, kind)
    LFC.Notify(msg, kind)
end)

RegisterNetEvent('lastflight:client:console', function(msg)
    print('[lastflight] ' .. msg)
end)

function LFC.HelpText(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, false, -1)
end

function LFC.LoadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) then
        LF.Warn('Model not found: ' .. tostring(model))
        return nil
    end
    RequestModel(hash)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then return nil end
        Wait(20)
    end
    return hash
end

function LFC.NetEntity(netId, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 5000)
    while GetGameTimer() < deadline do
        if NetworkDoesNetworkIdExist(netId) then
            local ent = NetToEnt(netId)
            if ent ~= 0 and DoesEntityExist(ent) then return ent end
        end
        Wait(50)
    end
    return nil
end

-- Ground height under a point, so NPCs stand on the pavement whether the
-- coords were taken from a standing player or from the ground.
function LFC.GroundZ(x, y, z)
    local found, gz = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
    if found and math.abs(gz - z) < 3.0 then return gz end
    return z - 1.0
end

-- Teleports the local player to a vec4 with collision loaded.
-- safe = true: snap to the nearest open, walkable spot (never inside a building).
function LFC.Teleport(c, safe)
    local ped = PlayerPedId()
    if IsEntityAttached(ped) then DetachEntity(ped, true, false) end
    ClearPedTasksImmediately(ped)
    local x, y, z = c.x, c.y, c.z
    RequestCollisionAtCoord(x, y, z)
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, c.w or 0.0)
    local deadline = GetGameTimer() + 4000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(x, y, z)
        Wait(50)
    end
    if safe then
        local found, pos = GetSafeCoordForPed(x, y, z, true, 16)
        if found and #(pos - vector3(x, y, z)) < 40.0 then
            SetEntityCoords(ped, pos.x, pos.y, pos.z, false, false, false, false)
        end
    end
end

-- Returns the player to normal gameplay. Safe to call any time, any number of times.
function LFC.ResetPlayerState()
    for _, fn in ipairs(LFC.onCleanup) do pcall(fn) end
    local ped = PlayerPedId()
    if IsEntityAttached(ped) then DetachEntity(ped, true, false) end
    FreezeEntityPosition(ped, false)
    SetEntityInvincible(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetPedConfigFlag(ped, 184, false)
    DisplayRadar(true)
    LFC.Nui('reset')
    if LFC.focus then LFC.Focus(false) end
end

function LFC.Restore(coords, msg, fadeIn)
    DoScreenFadeOut(500)
    local deadline = GetGameTimer() + 1500
    while not IsScreenFadedOut() and GetGameTimer() < deadline do Wait(10) end
    LFC.ResetPlayerState()
    if coords then LFC.Teleport(coords, true) end
    Wait(300)
    if fadeIn ~= false then DoScreenFadeIn(800) end
    if msg then LFC.Notify(msg, 'info') end
end

RegisterNetEvent('lastflight:client:restore', function(coords, msg)
    LFC.hasTicket, LFC.ticketStatus = false, 'none'
    TriggerServerEvent('lastflight:server:ticketStatus')
    LFC.Restore(coords, msg)
end)

---------------------------------------------------------------------------
-- Saved locations from /lastflight setup (replicated by the server)
---------------------------------------------------------------------------
local appliedVersion

local function applyLayout(value)
    if type(value) ~= 'table' or not value.layout then return end
    if appliedVersion == value.version and value.version ~= nil then return end
    local clean = LF.ValidateLayout(value.layout)
    if not clean then return end
    appliedVersion = value.version
    LF.ApplyLayout(clean)
    TriggerEvent('lastflight:client:layoutChanged')
end

AddStateBagChangeHandler('lastflight_layout', 'global', function(_, _, value)
    applyLayout(value)
end)

CreateThread(function()
    Wait(250)
    applyLayout(GlobalState.lastflight_layout)
end)

---------------------------------------------------------------------------
-- NUI setup
---------------------------------------------------------------------------
CreateThread(function()
    Wait(1000)
    LFC.Nui('config', {
        flight = Config.Flight.number, destination = Config.Flight.destination,
        airport = Config.Flight.airport, price = Config.Tickets.price,
        keys = Config.Keys,
        farewell = {
            message = Config.Farewell.message, subMessage = Config.Farewell.subMessage,
            font = Config.Farewell.font, color = Config.Farewell.color,
        },
    })
end)

RegisterNUICallback('close', function(_, cb)
    LFC.Focus(false)
    LFC.Nui('hidePanels')
    cb(1)
end)

-- ESC on the readiness panel: release the mouse but keep the panel visible.
RegisterNUICallback('unfocus', function(_, cb)
    LFC.Focus(false)
    cb(1)
end)

---------------------------------------------------------------------------
-- Keybinds (rebindable in GTA settings)
---------------------------------------------------------------------------
RegisterCommand('lastflight_ready', function()
    if LFC.ToggleReady then LFC.ToggleReady() end
end, false)
RegisterKeyMapping('lastflight_ready', 'Last Flight: toggle ready', 'keyboard', Config.Keys.ready)

RegisterCommand('lastflight_camera', function()
    if LFC.CycleCamera then LFC.CycleCamera() end
end, false)
RegisterKeyMapping('lastflight_camera', 'Last Flight: change camera', 'keyboard', Config.Keys.camera)

---------------------------------------------------------------------------
-- Debug + dev tools (/lastflight coords, /lastflight record ...)
---------------------------------------------------------------------------
RegisterNetEvent('lastflight:client:debug', function(state)
    LFC.debug = state
    Config.Debug = state
end)

local recorded = {}

local function fmt(n) return ('%.2f'):format(n) end

RegisterNetEvent('lastflight:client:devtool', function(tool, arg)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local ent = veh ~= 0 and veh or ped
    local c, h = GetEntityCoords(ent), GetEntityHeading(ent)

    if tool == 'coords' then
        local line = ('vec4(%s, %s, %s, %s)'):format(fmt(c.x), fmt(c.y), fmt(c.z), fmt(h))
        print(line)
        LFC.Nui('copy', { text = line })
        LFC.Notify('Coords copied + printed to F8: ' .. line, 'success')
        return
    end

    arg = arg or 'add'
    if arg == 'start' then
        recorded = {}
        LFC.Notify('Route recording started. Use /' .. Config.Admin.command .. ' record add at each point.', 'info')
    elseif arg == 'add' then
        recorded[#recorded + 1] = c
        LFC.Notify(('Point %d recorded (%s, %s, %s)'):format(#recorded, fmt(c.x), fmt(c.y), fmt(c.z)), 'success')
    elseif arg == 'print' then
        local lines = {}
        for _, p in ipairs(recorded) do
            lines[#lines + 1] = ('    vec3(%s, %s, %s),'):format(fmt(p.x), fmt(p.y), fmt(p.z))
        end
        local text = table.concat(lines, '\n')
        print('---- lastflight recorded route ----\n' .. text .. '\n-----------------------------------')
        LFC.Nui('copy', { text = text })
        LFC.Notify(('%d points printed to F8 and copied.'):format(#recorded), 'success')
    elseif arg == 'stop' then
        recorded = {}
        LFC.Notify('Route recording cleared.', 'info')
    end
end)

-- Draws configured routes when debug is on.
CreateThread(function()
    while true do
        if LFC.debug then
            local tl = LF.Timeline
            local me = GetEntityCoords(PlayerPedId())
            for _, name in ipairs({ 'TAXIING', 'TAKEOFF', 'CRUISING', 'FINAL_DEPARTURE' }) do
                for _, leg in ipairs(tl[name].legs) do
                    local pts = leg.path.pts
                    for i = 1, #pts - 1, 3 do
                        local a, b = pts[i], pts[math.min(i + 3, #pts)]
                        if #(a - me) < 1500.0 then
                            DrawLine(a.x, a.y, a.z + 1.0, b.x, b.y, b.z + 1.0, 255, 200, 0, 255)
                        end
                    end
                end
            end
            for i = 1, #recorded - 1 do
                local a, b = recorded[i], recorded[i + 1]
                DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 0, 255, 120, 255)
            end
            Wait(0)
        else
            Wait(1000)
        end
    end
end)

---------------------------------------------------------------------------
-- Resource stop: never leave anyone on a black screen / frozen
---------------------------------------------------------------------------
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    local wasFlying = LFC.InFlight and LFC.InFlight()
    LFC.ResetPlayerState()
    if wasFlying then
        local c = Config.Airport.safeReturn
        local ped = PlayerPedId()
        ClearPedTasksImmediately(ped)
        SetEntityCoords(ped, c.x, c.y, c.z, false, false, false, false)
    end
    DoScreenFadeIn(0)
end)
