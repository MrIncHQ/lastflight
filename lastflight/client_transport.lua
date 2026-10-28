-- Ground transport:
--   * City pickup: NPC in the city (default Legion Square) -> shared shuttle to the airport desk
--   * Gate shuttle: airport desk -> the plane (after buying a ticket), or GPS to drive yourself
--
-- ONE shared bus per stop (the server decides). The first rider's client
-- spawns it; everyone who asks while it waits gets on the same bus. Seated
-- riders press B to buckle and it leaves once everyone is buckled. One rider's
-- client drives it (the "controller"); if they get off or drop, another takes over.

local SH = Config.Transport.shuttle
local CT = Config.Transport.city
local R            -- my current ride (nil when not on one)

function LFC.StartDrive()
    local bp = Config.Airport.boardingPoint
    SetNewWaypoint(bp.x, bp.y)
    LFC.SetBoardingBlip(true)
    LFC.Notify('GPS set to the boarding gate. Drive to the marker beside the aircraft.', 'info')
end

local function gpsToDesk()
    local n = Config.Airport.npc.coords
    SetNewWaypoint(n.x, n.y)
    LFC.Notify('GPS set to the LSIA check-in desk.', 'info')
end

-- Settings for each kind of ride
local function trip(kind)
    if kind == 'city' then
        return {
            cfg = CT, spawn = CT.spawn, waypoints = CT.waypoints, snapToRoad = CT.snapToRoad == true,
            name = 'airport shuttle',
            arrived  = 'Welcome to Los Santos International. Check in at the desk for flight ' .. Config.Flight.number .. '.',
            fallback = gpsToDesk,
            rescue   = function() local w = CT.waypoints[#CT.waypoints]; return vector4(w.x, w.y, w.z + 1.0, 0.0) end,
        }
    end
    return {
        cfg = SH, spawn = SH.spawn, waypoints = SH.waypoints, snapToRoad = false,
        name = 'gate shuttle',
        arrived  = 'Welcome to the gate. Step onto the boarding marker.',
        fallback = LFC.StartDrive,
        rescue   = function() local bp = Config.Airport.boardingPoint; return vector4(bp.x, bp.y, bp.z + 1.0, 0.0) end,
        autoBoard = SH.autoBoardPlane ~= false,
    }
end

local function vehOf(r) return r.vehNet and NetworkDoesNetworkIdExist(r.vehNet) and NetToVeh(r.vehNet) or 0 end
local function pedOf(r) return r.pedNet and NetworkDoesNetworkIdExist(r.pedNet) and NetToPed(r.pedNet) or 0 end

local function hideBuckle(r)
    if r and (r.seated or r.buckling or r.promptShown) then
        LFC.Nui('buckle', { show = false })
        r.promptShown = false
    end
end

local function clearRide()
    if not R then return end
    if R.blip then RemoveBlip(R.blip) end
    hideBuckle(R)              -- always: buckled riders' "SEATBELT FASTENED" box must not stay up
    R = nil
end

local function addBlip(r)
    local veh = vehOf(r)
    if veh ~= 0 and not r.blip then
        r.blip = AddBlipForEntity(veh)
        SetBlipSprite(r.blip, 513)
        SetBlipColour(r.blip, 3)
    end
end

local function fadeBlink(fn)
    DoScreenFadeOut(400)
    local deadline = GetGameTimer() + 1000
    while not IsScreenFadedOut() and GetGameTimer() < deadline do Wait(10) end
    if fn then fn() end
    Wait(300)
    DoScreenFadeIn(500)
end

local function freeSeat(veh)
    local seats = GetVehicleModelNumberOfSeats(GetEntityModel(veh))
    for i = 1, seats - 2 do
        if IsVehicleSeatFree(veh, i) then return i end
    end
    if IsVehicleSeatFree(veh, 0) then return 0 end
    return nil
end

-- G key: buckle up on the shuttle (client_flight's ready key calls this first)
function LFC.RideBuckle()
    if not R or not R.buckling then return false end
    R.buckling = false
    TriggerServerEvent('lastflight:server:rideBuckle', R.id)
    PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
    LFC.Nui('buckle', { done = true })
    return true
end

---------------------------------------------------------------------------
-- Driving (controller only)
---------------------------------------------------------------------------
local function takeControl(r)
    local veh, ped = vehOf(r), pedOf(r)
    local deadline = GetGameTimer() + 3000
    while GetGameTimer() < deadline do
        veh, ped = vehOf(r), pedOf(r)
        if veh ~= 0 and ped ~= 0 and NetworkHasControlOfEntity(veh) and NetworkHasControlOfEntity(ped) then break end
        if veh ~= 0 then NetworkRequestControlOfEntity(veh) end
        if ped ~= 0 then NetworkRequestControlOfEntity(ped) end
        Wait(100)
    end
    return veh, ped
end

local function taskTo(r, veh, ped, wp)
    local c = r.t.cfg
    TaskVehicleDriveToCoordLongrange(ped, veh, wp.x, wp.y, wp.z, c.speed, c.drivingStyle, c.arriveRadius)
    SetPedKeepTask(ped, true)
end

local function driveRide(r)
    if r.driving then return end
    r.driving = true
    local t, c = r.t, r.t.cfg
    local veh, ped = takeControl(r)
    if veh == 0 or ped == 0 then
        TriggerServerEvent('lastflight:server:rideFailed', r.id)
        return
    end
    SetBlockingOfNonTemporaryEvents(ped, true)
    taskTo(r, veh, ped, t.waypoints[r.wp])
    local lastPos, lastMoveAt, stage = GetEntityCoords(veh), GetGameTimer(), 0

    while R == r and r.isController and r.state == 'driving' do
        Wait(500)
        local now = GetGameTimer()
        veh, ped = vehOf(r), pedOf(r)

        if veh == 0 or ped == 0 or IsEntityDead(veh) or IsEntityDead(ped) then
            LF.Debug('Shuttle destroyed')
            TriggerServerEvent('lastflight:server:rideFailed', r.id)
            return
        end
        if not NetworkHasControlOfEntity(veh) then NetworkRequestControlOfEntity(veh) end
        if not NetworkHasControlOfEntity(ped) then NetworkRequestControlOfEntity(ped) end

        local wp = t.waypoints[r.wp]
        local pos = GetEntityCoords(veh)
        -- "stuck" = hasn't moved 3 m for a while. Red lights and traffic queues
        -- don't count, and gentle fixes come long before any teleport.
        if #(pos - lastPos) > 3.0 or IsVehicleStoppedAtTrafficLights(veh) then
            lastPos, lastMoveAt, stage = pos, now, 0
        end
        local stalled = (now - lastMoveAt) / 1000

        if #(pos - wp) < c.arriveRadius then
            if r.wp < #t.waypoints then
                r.wp = r.wp + 1
                TriggerServerEvent('lastflight:server:rideProgress', r.id, r.wp)
                taskTo(r, veh, ped, t.waypoints[r.wp])
                lastMoveAt, stage = now, 0
            else
                TaskVehicleTempAction(ped, veh, 27, 4000)   -- stop at the drop-off
                TriggerServerEvent('lastflight:server:rideArrived', r.id)
                return
            end
        elseif stage == 0 and stalled > c.stuckTime then
            stage = 1
            LF.Debug('Shuttle stalled - re-routing')
            taskTo(r, veh, ped, wp)
        elseif stage == 1 and stalled > c.stuckTime * 1.5 then
            stage = 2
            LF.Debug('Shuttle stalled - backing up')
            TaskVehicleTempAction(ped, veh, 3, 2500)      -- brake + reverse
            SetTimeout(2600, function() if R == r and r.isController then taskTo(r, vehOf(r), pedOf(r), wp) end end)
        elseif stage == 2 and stalled > c.stuckTime * 2 then
            r.recoveries = (r.recoveries or 0) + 1
            lastPos, lastMoveAt, stage = pos, now, 0
            LF.Debug('Shuttle stuck, teleport recovery ' .. r.recoveries)
            if r.recoveries > c.maxStuckRecoveries then
                TriggerServerEvent('lastflight:server:rideFailed', r.id)
                return
            end
            TriggerServerEvent('lastflight:server:rideBlink', r.id)   -- other riders fade too
            fadeBlink(function()
                local dir = wp - pos
                local step = math.min(#dir, 40.0)
                local target = pos + (dir / math.max(#dir, 0.01)) * step
                local found, node, heading = GetClosestVehicleNodeWithHeading(target.x, target.y, target.z, 0, 3.0, 0)
                if not found or #(node - target) > 30.0 then node, heading = target, LF.HeadingOf(dir) end
                SetEntityCoords(veh, node.x, node.y, node.z, false, false, false, false)
                SetEntityHeading(veh, heading)
                SetVehicleOnGroundProperly(veh)
            end)
            taskTo(r, veh, ped, wp)
        end
    end
    r.driving = false
end

---------------------------------------------------------------------------
-- Spawning (first rider only)
---------------------------------------------------------------------------
local function spawnRide(r)
    local t, c = r.t, r.t.cfg
    local vehHash = LFC.LoadModel(c.vehicle)
    local pedHash = LFC.LoadModel(c.driver)
    if not vehHash or not pedHash then
        LFC.Notify(('The %s is unavailable right now.'):format(t.name), 'error')
        TriggerServerEvent('lastflight:server:rideLeft', r.id)
        clearRide()
        return t.fallback()
    end

    local sp = t.spawn
    local x, y, z, h = sp.x, sp.y, sp.z, sp.w
    if t.snapToRoad then
        -- node type 0 = real roads only (type 1 also matches park footpaths)
        local found, node, heading = GetClosestVehicleNodeWithHeading(sp.x, sp.y, sp.z, 0, 3.0, 0)
        if found and #(node - vector3(sp.x, sp.y, sp.z)) < 25.0 then
            -- nodes sit in the middle of the road: slide toward the NPC's curb
            local rad = math.rad(heading)
            local right = vector3(math.cos(rad), math.sin(rad), 0.0)
            local n = CT.npc
            local lat = (n.x - node.x) * right.x + (n.y - node.y) * right.y
            local side = lat >= 0 and 1.0 or -1.0
            local p = node + right * (math.max(0.0, math.abs(lat) - 2.5) * side)
            if side < 0 then heading = (heading + 180.0) % 360.0 end
            x, y, z, h = p.x, p.y, node.z, heading
        end
    end
    local veh = CreateVehicle(vehHash, x, y, z, h, true, false)
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleDoorsLocked(veh, 2)              -- no carjacking the driver; riders are warped in
    SetVehicleHasBeenOwnedByPlayer(veh, false)
    local ped = CreatePedInsideVehicle(veh, 26, pedHash, -1, true, false)
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, 0.0)
    SetEntityInvincible(ped, true)
    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)

    r.vehNet, r.pedNet = VehToNet(veh), PedToNet(ped)
    local capacity = math.max(1, GetVehicleModelNumberOfSeats(vehHash) - 1)
    TriggerServerEvent('lastflight:server:rideSpawned', r.id, r.vehNet, r.pedNet, capacity)
end

---------------------------------------------------------------------------
-- Every rider: get on, buckle, ride, get off
---------------------------------------------------------------------------
local function riderLoop(r)
    local t = r.t
    LFC.Notify(('The %s is waiting at the curb. Walk over and press E to get in.'):format(t.name), 'info')
    local lastHud = 0
    while R == r do
        local me = PlayerPedId()
        local veh = vehOf(r)
        local inside = veh ~= 0 and GetVehiclePedIsIn(me, false) == veh

        -- seatbelt prompt: "2 / 3 passengers buckled - leaves in 22s"
        if r.state == 'waiting' and r.seated and r.counts and GetGameTimer() - lastHud > 1000 then
            lastHud = GetGameTimer()
            local note
            if r.leavesAt then
                local left = math.max(0, math.ceil((r.leavesAt - GetGameTimer()) / 1000))
                note = left > 0 and ('leaves in %ds'):format(left) or 'departing'
            else
                note = 'waiting for passengers'
            end
            LFC.Nui('buckle', { count = r.counts[1], total = r.counts[2], note = note })
        end

        if r.state == 'waiting' then
            if inside and not r.seated then
                r.seated = true
                r.buckling = true
                r.promptShown = true
                TriggerServerEvent('lastflight:server:rideSeated', r.id, true)
                LFC.Nui('buckle', { show = true, key = Config.Keys.seatbelt })
            elseif not inside and r.seated then
                hideBuckle(r)
                r.seated, r.buckling = false, false
                TriggerServerEvent('lastflight:server:rideSeated', r.id, false)
            end
            if not inside and veh ~= 0 and #(GetEntityCoords(me) - GetEntityCoords(veh)) < 7.0 then
                LFC.HelpText(('~INPUT_CONTEXT~ Get in the %s'):format(t.name))
                if IsControlJustReleased(0, Config.Interaction.key) then
                    local seat = freeSeat(veh)
                    if seat then TaskWarpPedIntoVehicle(me, veh, seat)
                    else LFC.Notify('The shuttle is full - it will be back for you.', 'error') end
                end
                Wait(0)
            else
                Wait(250)
            end
        elseif r.state == 'driving' then
            if not inside then
                -- got off early: the bus carries on for everyone else
                TriggerServerEvent('lastflight:server:rideLeft', r.id)
                LFC.Notify(('You left the %s.'):format(t.name), 'info')
                clearRide()
                return t.fallback()
            end
            DisableControlAction(0, 75, true)      -- no accidental exits while moving
            Wait(0)
        else
            Wait(250)
        end
    end
end

local function startRide(id, kind, vehNet, pedNet, isController)
    if R then return end
    R = { id = id, kind = kind, t = trip(kind), vehNet = vehNet, pedNet = pedNet, isController = isController,
          state = vehNet and 'waiting' or 'spawning', wp = 1 }
    local r = R
    CreateThread(function()
        if isController and not vehNet then spawnRide(r) end
        if R ~= r then return end
        r.state = 'waiting'
        local deadline = GetGameTimer() + 5000
        while vehOf(r) == 0 and GetGameTimer() < deadline do Wait(100) end
        addBlip(r)
        riderLoop(r)
    end)
end

-- I called it first: spawn it
RegisterNetEvent('lastflight:client:shuttleApproved', function(id, kind)
    startRide(id, kind, nil, nil, true)
end)

-- Someone else's bus is waiting: get on it
RegisterNetEvent('lastflight:client:rideJoin', function(id, kind, vehNet, pedNet)
    startRide(id, kind, vehNet, pedNet, false)
end)

RegisterNetEvent('lastflight:client:rideStatus', function(id, s)
    if not R or R.id ~= id then return end
    local was = R.state
    if s.state == 'driving' or s.state == 'waiting' or s.state == 'arrived' then R.state = s.state end
    R.counts = { s.buckled, s.riders }
    R.leavesAt = s.leavesIn and (GetGameTimer() + s.leavesIn * 1000) or nil
    if R.state ~= 'waiting' then
        hideBuckle(R)          -- bus is moving / arrived: the seatbelt prompt is done
        R.buckling = false
    end
    if was == 'waiting' and R.state == 'driving' then
        LFC.Notify(('All aboard - the %s is departing.'):format(R.t.name), 'success')
    end
end)

RegisterNetEvent('lastflight:client:rideDepart', function(id)
    if not R or R.id ~= id or not R.isController then return end
    if R.state == 'waiting' then
        LFC.Notify(('All aboard - the %s is departing.'):format(R.t.name), 'success')
    end
    R.state = 'driving'
    hideBuckle(R)
    R.buckling = false
    CreateThread(function() driveRide(R) end)
end)

-- I've been handed the wheel (previous controller got off / dropped)
RegisterNetEvent('lastflight:client:rideController', function(id, state, wp)
    if not R or R.id ~= id then return end
    R.isController = true
    R.wp = tonumber(wp) or R.wp
    if state == 'driving' then
        R.state = 'driving'
        local r = R
        CreateThread(function() driveRide(r) end)
    end
end)

RegisterNetEvent('lastflight:client:rideBlink', function(id)
    if R and R.id == id then CreateThread(function() fadeBlink() end) end
end)

-- Drop-off
RegisterNetEvent('lastflight:client:rideExit', function(id)
    if not R or R.id ~= id then return end
    local r = R
    r.state = 'arrived'
    CreateThread(function()
        local veh = vehOf(r)
        Wait(800)
        if r.t.autoBoard and LFC.hasTicket then
            -- gate shuttle: board the plane straight from the bus
            TriggerServerEvent('lastflight:server:board', true)
            Wait(4000)
            if LFC.InFlight and LFC.InFlight() then
                if R == r then clearRide() end
                return
            end
        end
        local me = PlayerPedId()
        if veh ~= 0 and GetVehiclePedIsIn(me, false) == veh then
            TaskLeaveVehicle(me, veh, 0)
            local deadline = GetGameTimer() + 6000
            while GetVehiclePedIsIn(PlayerPedId(), false) == veh and GetGameTimer() < deadline do Wait(100) end
            if GetVehiclePedIsIn(PlayerPedId(), false) == veh then TaskLeaveVehicle(PlayerPedId(), veh, 16) end
        end
        LFC.Notify(r.t.arrived, 'success')
    end)
end)

-- Bus destroyed / gave up / timed out: put riders at the destination safely
RegisterNetEvent('lastflight:client:rideRescue', function(id)
    if not R or R.id ~= id then return end
    local t = R.t
    local wasOn = R.seated
    clearRide()
    if wasOn then
        fadeBlink(function() LFC.Teleport(t.rescue(), true) end)
        LFC.Notify(t.arrived, 'success')
    else
        t.fallback()
    end
end)

RegisterNetEvent('lastflight:client:rideTimedOut', function(id)
    if not R or R.id ~= id then return end
    local t = R.t
    clearRide()
    LFC.Notify(('Nobody boarded, so the %s left.'):format(t.name), 'info')
end)

RegisterNetEvent('lastflight:client:rideEnded', function(id)
    if R and R.id == id then clearRide() end
end)

table.insert(LFC.onCleanup, function()
    if R then
        TriggerServerEvent('lastflight:server:rideLeft', R.id)
        clearRide()
    end
end)

---------------------------------------------------------------------------
-- City pickup NPC (local entity, only exists while you are close)
---------------------------------------------------------------------------
local cityPed, cityBlip
local cityTarget = false

local function useTarget()
    local u = Config.Interaction.useTarget
    if GetResourceState('ox_target') ~= 'started' then return false end
    return u == 'auto' or u == true
end

local function requestCityRide()
    if R then return LFC.Notify('You are already on the shuttle list.', 'error') end
    TriggerServerEvent('lastflight:server:requestShuttle', 'city')
end

local function makeCityBlip()
    if cityBlip then RemoveBlip(cityBlip); cityBlip = nil end
    if not Config.Enabled or not CT.enabled or not CT.blip.enabled then return end
    cityBlip = AddBlipForCoord(CT.npc.x, CT.npc.y, CT.npc.z)
    SetBlipSprite(cityBlip, CT.blip.sprite)
    SetBlipColour(cityBlip, CT.blip.color)
    SetBlipScale(cityBlip, CT.blip.scale)
    SetBlipAsShortRange(cityBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(CT.blip.label)
    EndTextCommandSetBlipName(cityBlip)
end
CreateThread(makeCityBlip)

local function spawnCityPed()
    local hash = LFC.LoadModel(CT.npcModel)
    if not hash then return end
    local n = CT.npc
    cityPed = CreatePed(4, hash, n.x, n.y, LFC.GroundZ(n.x, n.y, n.z), n.w, false, true)
    SetModelAsNoLongerNeeded(hash)
    SetEntityInvincible(cityPed, true)
    FreezeEntityPosition(cityPed, true)
    SetBlockingOfNonTemporaryEvents(cityPed, true)
    SetPedCanRagdoll(cityPed, false)
    if CT.scenario then TaskStartScenarioInPlace(cityPed, CT.scenario, 0, true) end
    if useTarget() then
        exports.ox_target:addLocalEntity(cityPed, {
            {
                name = 'lastflight_city',
                label = 'Ride to LSIA - Last Flight',
                icon = 'fa-solid fa-bus',
                distance = CT.interactDistance,
                onSelect = requestCityRide,
            },
            {
                name = 'lastflight_tour',
                label = 'Farewell highway drive',
                icon = 'fa-solid fa-car',
                distance = CT.interactDistance,
                canInteract = function() return Config.Tour.enabled end,
                onSelect = function() LFC.OpenTour() end,
            },
        })
        cityTarget = true
    end
end

local function despawnCityPed()
    if cityPed and DoesEntityExist(cityPed) then
        if cityTarget then
            pcall(function() exports.ox_target:removeLocalEntity(cityPed, { 'lastflight_city', 'lastflight_tour' }) end)
        end
        DeleteEntity(cityPed)
    end
    cityPed, cityTarget = nil, false
end

CreateThread(function()
    if not Config.Enabled or not CT.enabled then return end
    while true do
        local pos = vector3(CT.npc.x, CT.npc.y, CT.npc.z)
        local dist = #(GetEntityCoords(PlayerPedId()) - pos)
        if dist < CT.spawnDistance then
            if not cityPed then spawnCityPed() end
        elseif cityPed then
            despawnCityPed()
        end
        if cityPed and not cityTarget and dist < CT.interactDistance and not LFC.focus then
            local tour = Config.Tour.enabled
            while #(GetEntityCoords(PlayerPedId()) - pos) < CT.interactDistance and not LFC.focus do
                LFC.HelpText(tour and '~INPUT_CONTEXT~ Ride to Los Santos International Airport~n~~INPUT_DETONATE~ Farewell highway drive'
                    or '~INPUT_CONTEXT~ Ride to Los Santos International Airport')
                if IsControlJustReleased(0, Config.Interaction.key) then requestCityRide(); Wait(1000) end
                if tour and IsControlJustReleased(0, Config.Tour.key) and not IsPedInAnyVehicle(PlayerPedId(), false) then
                    LFC.OpenTour(); Wait(1000)
                end
                Wait(0)
            end
        end
        Wait(dist < 20.0 and 250 or 1000)
    end
end)

AddEventHandler('lastflight:client:layoutChanged', function()
    despawnCityPed()
    makeCityBlip()
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearRide()            -- the server deletes the bus itself
    despawnCityPed()
    if cityBlip then RemoveBlip(cityBlip) end
end)
