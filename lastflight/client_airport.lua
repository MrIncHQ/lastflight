-- Airport: blip, check-in NPC + desk (local entities), ticket UI, boarding marker.

local AP = Config.Airport
local npcPed, deskObj
local boardBlip
local targetAdded = false

local function useTarget()
    local u = Config.Interaction.useTarget
    if GetResourceState('ox_target') ~= 'started' then return false end
    return u == 'auto' or u == true
end

---------------------------------------------------------------------------
-- Blips
---------------------------------------------------------------------------
local airportBlip

local function makeAirportBlip()
    if airportBlip then RemoveBlip(airportBlip); airportBlip = nil end
    if not Config.Enabled or not AP.blip.enabled then return end
    local b = AP.blip
    airportBlip = AddBlipForCoord(b.coords.x, b.coords.y, b.coords.z)
    SetBlipSprite(airportBlip, b.sprite)
    SetBlipColour(airportBlip, b.color)
    SetBlipScale(airportBlip, b.scale)
    SetBlipAsShortRange(airportBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(b.label)
    EndTextCommandSetBlipName(airportBlip)
end
CreateThread(makeAirportBlip)

local function setBoardingBlip(show)
    if show and not boardBlip then
        local p, b = AP.boardingPoint, AP.boardingBlip
        boardBlip = AddBlipForCoord(p.x, p.y, p.z)
        SetBlipSprite(boardBlip, b.sprite)
        SetBlipColour(boardBlip, b.color)
        SetBlipScale(boardBlip, b.scale)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(b.label)
        EndTextCommandSetBlipName(boardBlip)
    elseif not show and boardBlip then
        RemoveBlip(boardBlip)
        boardBlip = nil
    end
end
LFC.SetBoardingBlip = setBoardingBlip

function LFC.UpdateTicket(info)
    if not info then return end
    LFC.ticketStatus = info.status
    LFC.hasTicket = info.status == 'boarding' or info.status == 'queued'
    setBoardingBlip(LFC.hasTicket)
end

---------------------------------------------------------------------------
-- Desk NPC
---------------------------------------------------------------------------
local function openDesk()
    TriggerServerEvent('lastflight:server:openDesk')
end

local function spawnDesk()
    local n = AP.npc
    local hash = LFC.LoadModel(n.model)
    if not hash then return end
    npcPed = CreatePed(4, hash, n.coords.x, n.coords.y, LFC.GroundZ(n.coords.x, n.coords.y, n.coords.z), n.coords.w, false, true)
    SetModelAsNoLongerNeeded(hash)
    SetEntityInvincible(npcPed, true)
    FreezeEntityPosition(npcPed, true)
    SetBlockingOfNonTemporaryEvents(npcPed, true)
    SetPedCanRagdoll(npcPed, false)
    SetPedDiesWhenInjured(npcPed, false)
    if n.scenario then TaskStartScenarioInPlace(npcPed, n.scenario, 0, true) end

    local d = AP.desk
    if d.enabled then
        local dh = LFC.LoadModel(d.model)
        if dh then
            local pos, heading
            if d.autoPlace then
                local r = math.rad(n.coords.w)
                pos = vector3(n.coords.x - math.sin(r) * d.distance, n.coords.y + math.cos(r) * d.distance, n.coords.z - 1.0)
                heading = (n.coords.w + 180.0) % 360.0
            else
                pos = vector3(d.coords.x, d.coords.y, d.coords.z - 1.0)
                heading = d.coords.w
            end
            deskObj = CreateObject(dh, pos.x, pos.y, pos.z + (d.zOffset or 0.0), false, false, false)
            SetEntityHeading(deskObj, heading)
            PlaceObjectOnGroundProperly(deskObj)
            if d.zOffset and d.zOffset ~= 0.0 then
                local c = GetEntityCoords(deskObj)
                SetEntityCoordsNoOffset(deskObj, c.x, c.y, c.z + d.zOffset, false, false, false)
            end
            FreezeEntityPosition(deskObj, true)
            SetModelAsNoLongerNeeded(dh)
        end
    end

    if useTarget() then
        exports.ox_target:addLocalEntity(npcPed, {
            {
                name = 'lastflight_desk',
                label = ('Check in - Flight %s'):format(Config.Flight.number),
                icon = 'fa-solid fa-plane-departure',
                distance = n.interactDistance,
                onSelect = openDesk,
            },
        })
        targetAdded = true
    end
end

local function despawnDesk()
    if npcPed and DoesEntityExist(npcPed) then
        if targetAdded then pcall(function() exports.ox_target:removeLocalEntity(npcPed, 'lastflight_desk') end) end
        DeleteEntity(npcPed)
    end
    if deskObj and DoesEntityExist(deskObj) then DeleteEntity(deskObj) end
    npcPed, deskObj, targetAdded = nil, nil, false
end

CreateThread(function()
    if not Config.Enabled then return end
    local n = AP.npc
    while true do
        local npcPos = vector3(n.coords.x, n.coords.y, n.coords.z)   -- re-read: admins can move the desk
        local dist = #(GetEntityCoords(PlayerPedId()) - npcPos)
        if dist < n.spawnDistance then
            if not npcPed then spawnDesk() end
        elseif npcPed then
            despawnDesk()
        end

        if npcPed and not targetAdded and dist < n.interactDistance and not LFC.focus then
            local sleep = 0
            while #(GetEntityCoords(PlayerPedId()) - npcPos) < n.interactDistance and not LFC.focus do
                LFC.HelpText(('~INPUT_CONTEXT~ Check in - Flight %s to %s'):format(Config.Flight.number, Config.Flight.destination))
                if IsControlJustReleased(0, Config.Interaction.key) then openDesk() end
                Wait(sleep)
            end
        end
        Wait(dist < 20.0 and 250 or 1000)
    end
end)

---------------------------------------------------------------------------
-- Ticket UI
---------------------------------------------------------------------------
RegisterNetEvent('lastflight:client:deskInfo', function(info)
    LFC.UpdateTicket(info)
    LFC.Nui('desk', info)
    LFC.Focus(true)
end)

RegisterNetEvent('lastflight:client:ticketStatus', function(info)
    LFC.UpdateTicket(info)
end)

RegisterNUICallback('buy', function(_, cb)
    TriggerServerEvent('lastflight:server:buyTicket')
    cb(1)
end)

RegisterNetEvent('lastflight:client:ticketResult', function(ok, msg, info)
    LFC.UpdateTicket(info)
    LFC.Nui('ticketResult', { ok = ok, msg = msg, info = info })
    if not ok then LFC.Notify(msg, 'error') end
end)

RegisterNUICallback('transport', function(data, cb)
    LFC.Focus(false)
    LFC.Nui('hidePanels')
    if data.choice == 'shuttle' then
        TriggerServerEvent('lastflight:server:requestShuttle')
    elseif data.choice == 'drive' then
        LFC.StartDrive()
    end
    cb(1)
end)

RegisterNetEvent('lastflight:client:boardingOpen', function()
    LFC.ticketStatus, LFC.hasTicket = 'boarding', true
    setBoardingBlip(true)
    LFC.Notify(('Your aircraft is ready. Flight %s is now boarding - head to the gate.'):format(Config.Flight.number), 'success')
    PlaySoundFrontend(-1, 'Text_Arrive_Tone', 'Phone_SoundSet_Default', true)
end)

---------------------------------------------------------------------------
-- Boarding marker
---------------------------------------------------------------------------
CreateThread(function()
    if not Config.Enabled then return end
    while true do
        local sleep = 1000
        local bp = AP.boardingPoint   -- ground position
        local gs = GlobalState.lastflight
        if LFC.hasTicket and gs and gs.boarding and not (LFC.InFlight and LFC.InFlight()) then
            local dist = #(GetEntityCoords(PlayerPedId()) - bp)
            if dist < 60.0 then
                sleep = 0
                DrawMarker(1, bp.x, bp.y, bp.z + 0.02, 0, 0, 0, 0, 0, 0, AP.boardingRadius * 2, AP.boardingRadius * 2, 1.0,
                    80, 180, 255, 120, false, false, 2, false, nil, nil, false)
                if dist < AP.boardingRadius then
                    LFC.HelpText(('~INPUT_CONTEXT~ Board flight %s'):format(Config.Flight.number))
                    if IsControlJustReleased(0, Config.Interaction.key) and not IsPedInAnyVehicle(PlayerPedId(), false) then
                        TriggerServerEvent('lastflight:server:board')
                        Wait(1000)
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

table.insert(LFC.onCleanup, function()
    LFC.Nui('hidePanels')
end)

-- Admin saved new locations: move the desk, blips and markers.
AddEventHandler('lastflight:client:layoutChanged', function()
    despawnDesk()          -- the distance loop respawns it at the new spot
    makeAirportBlip()
    if boardBlip then setBoardingBlip(false); setBoardingBlip(true) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    despawnDesk()
    setBoardingBlip(false)
end)

-- Pick up an existing ticket after (re)joining or a resource restart.
CreateThread(function()
    Wait(3000)
    TriggerServerEvent('lastflight:server:ticketStatus')
end)
