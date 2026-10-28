-- Farewell highway drive (second option at the city pickup NPC).
-- A chauffeured luxury car - or a convoy of them for a group - does one last
-- loop of the island on the highways, then drops everyone at the LSIA desk.
--
-- The server owns the group (server_tour.lua). The player who asked spawns
-- the cars; once they leave, each car is driven by one of its own riders'
-- clients. Riders can get in any car of their group.

local TC = Config.Tour
local T            -- my current drive (nil when not on one)

local function net2veh(n) return n and NetworkDoesNetworkIdExist(n) and NetToVeh(n) or 0 end
local function net2ped(n) return n and NetworkDoesNetworkIdExist(n) and NetToPed(n) or 0 end
local function vehOf(i) local c = T and T.cars[i]; return c and net2veh(c.veh) or 0 end
local function pedOf(i) local c = T and T.cars[i]; return c and net2ped(c.ped) or 0 end

local function gpsToDesk()
    local n = Config.Airport.npc.coords
    SetNewWaypoint(n.x, n.y)
    LFC.Notify('GPS set to the LSIA check-in desk.', 'info')
end

local function arrivedMsg()
    return 'Welcome to Los Santos International. Check in at the desk for flight ' .. Config.Flight.number .. '.'
end

local function hideBuckle()
    if T and (T.car or T.promptShown) then
        LFC.Nui('buckle', { show = false })
        T.promptShown = false
    end
end

local function clearTour()
    if not T then return end
    for _, b in pairs(T.blips) do RemoveBlip(b) end
    hideBuckle()
    T = nil
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

local function refreshBlips()
    if not T then return end
    for i in ipairs(T.cars) do
        local veh = vehOf(i)
        local want = veh ~= 0 and (T.state == 'waiting' or T.car == i)
        if want and not T.blips[i] then
            T.blips[i] = AddBlipForEntity(veh)
            SetBlipSprite(T.blips[i], 225)
            SetBlipColour(T.blips[i], 27)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName('Farewell drive')
            EndTextCommandSetBlipName(T.blips[i])
        elseif not want and T.blips[i] then
            RemoveBlip(T.blips[i])
            T.blips[i] = nil
        end
    end
end

-- G key (client_flight's ready key calls this): buckle up in the car
function LFC.TourBuckle()
    if not T or not T.buckling then return false end
    T.buckling = false
    TriggerServerEvent('lastflight:server:tourBuckle', T.id)
    PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
    LFC.Nui('buckle', { done = true })
    return true
end

function LFC.InTour() return T ~= nil end

---------------------------------------------------------------------------
-- Driving (one rider per car)
---------------------------------------------------------------------------
local function takeControl(i)
    local veh, ped = vehOf(i), pedOf(i)
    local deadline = GetGameTimer() + 3000
    while GetGameTimer() < deadline do
        veh, ped = vehOf(i), pedOf(i)
        if veh ~= 0 and ped ~= 0 and NetworkHasControlOfEntity(veh) and NetworkHasControlOfEntity(ped) then break end
        if veh ~= 0 then NetworkRequestControlOfEntity(veh) end
        if ped ~= 0 then NetworkRequestControlOfEntity(ped) end
        Wait(100)
    end
    return veh, ped
end

-- Route helpers, built fresh for every drive (so layout edits apply).
--  * point(k): the road at waypoint k on the carriageway going OUR way. The
--    plain closest road is often the opposite side of a divided highway, and
--    the driver would exit, turn around and come back to reach it.
--  * reached(k, pos): close enough, or already driven past it (so a point
--    missed by a lane never makes the car turn back). Height is checked so a
--    bridge above / road below doesn't count.
local function makeRoute()
    local W = TC.waypoints
    local last = #W
    local cache = {}

    local function dirAt(k)
        local a, b = W[math.max(1, k - 1)], W[math.min(last, k + 1)]
        local d = vector3(b.x - a.x, b.y - a.y, 0.0)
        if #d < 1.0 then return nil end
        return d / #d
    end

    local function point(k)
        if cache[k] then return cache[k] end
        local p = W[k]
        local best = p
        local dir = dirAt(k)
        if dir and k < last then
            local want = LF.HeadingOf(dir)
            for n = 1, 8 do
                local found, node, heading = GetNthClosestVehicleNodeWithHeading(p.x, p.y, p.z, n, 0, 3.0, 0.0)
                if not found or #(node - p) > 30.0 then break end
                if math.abs(LF.AngleDiff(heading, want)) < 60.0 and math.abs(node.z - p.z) < 6.0 then
                    best = node
                    break
                end
            end
        end
        cache[k] = best
        return best
    end

    local function reached(k, pos)
        local p = point(k)
        if math.abs(pos.z - p.z) > 8.0 then return false end
        local flat = vector3(pos.x - p.x, pos.y - p.y, 0.0)
        if k >= last then return #flat < TC.arriveRadius end
        if #flat < TC.viaRadius then return true end
        local dir = dirAt(k)
        if dir and #flat < 150.0 then
            local along = flat.x * dir.x + flat.y * dir.y
            local side = math.abs(flat.x * dir.y - flat.y * dir.x)
            if along > 0.0 and side < 35.0 then return true end    -- already past it
        end
        return false
    end

    -- true when the road runs straight through point k and the next point is
    -- close: safe to aim past k without the driver cutting a corner
    local function straight(k)
        if k <= 1 or k >= last then return false end
        local a, b, c = W[k - 1], W[k], W[k + 1]
        local d1 = vector3(b.x - a.x, b.y - a.y, 0.0)
        local d2 = vector3(c.x - b.x, c.y - b.y, 0.0)
        if #d2 > 250.0 or #d1 < 1.0 or #d2 < 1.0 then return false end
        return math.abs(LF.AngleDiff(LF.HeadingOf(d1), LF.HeadingOf(d2))) < 30.0
    end

    -- which point the driver aims at while heading for point wp
    local function aim(wp)
        local k = wp
        for _ = 1, (TC.lookahead or 1) do
            if not straight(k) then break end
            k = k + 1
        end
        return k
    end

    return { last = last, point = point, reached = reached, aim = aim }
end

-- On straight stretches the driver aims past the next point (no braking at
-- every point); at corners and long gaps it goes point by point.
local curSpeed = TC.speed

local function taskTo(veh, ped, route, wp)
    local k = route.aim(wp)
    local p = route.point(k)
    TaskVehicleDriveToCoordLongrange(ped, veh, p.x, p.y, p.z, curSpeed, TC.drivingStyle, k >= route.last and TC.arriveRadius or 20.0)
    SetPedKeepTask(ped, true)
    return k
end

-- Is the car on a freeway / highway? Uses GTA's own street names
-- ("Del Perro Fwy", "Great Ocean Hwy", ...), so it works for any recorded loop.
local function onHighway(pos)
    local street = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
    local name = street and street ~= 0 and GetStreetNameFromHashKey(street) or ''
    for _, word in ipairs(TC.highwayNames or {}) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

local function drive(t, i)
    local c = t.cars[i]
    if c.driving then return end
    c.driving = true
    local id = t.id
    local veh, ped = takeControl(i)
    if veh == 0 or ped == 0 then
        TriggerServerEvent('lastflight:server:tourFailed', id, i)
        return
    end
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, 0.0)
    local route = makeRoute()
    -- city speed until we're on the highway (two checks in a row, so an
    -- overpass or a side street under a bridge doesn't flip it back and forth)
    local fast = TC.citySpeed == nil or onHighway(GetEntityCoords(veh))
    local streak = 0
    curSpeed = fast and TC.speed or TC.citySpeed
    local aim = taskTo(veh, ped, route, c.wp)
    local lastPos, lastMoveAt, stage, recoveries = GetEntityCoords(veh), GetGameTimer(), 0, 0

    while T == t and t.drivingCar == i do
        Wait(500)
        local now = GetGameTimer()
        veh, ped = vehOf(i), pedOf(i)
        if veh == 0 or ped == 0 or IsEntityDead(veh) or IsEntityDead(ped) then
            TriggerServerEvent('lastflight:server:tourFailed', id, i)
            break
        end
        if not NetworkHasControlOfEntity(veh) then NetworkRequestControlOfEntity(veh) end
        if not NetworkHasControlOfEntity(ped) then NetworkRequestControlOfEntity(ped) end

        local pos = GetEntityCoords(veh)
        if #(pos - lastPos) > 3.0 or IsVehicleStoppedAtTrafficLights(veh) then
            lastPos, lastMoveAt, stage = pos, now, 0
        end
        local stalled = (now - lastMoveAt) / 1000

        if TC.citySpeed then
            if onHighway(pos) ~= fast then streak = streak + 1 else streak = 0 end
            if streak >= 2 then
                fast, streak = not fast, 0
                curSpeed = fast and TC.speed or TC.citySpeed
                SetDriveTaskCruiseSpeed(ped, curSpeed)
                LF.Debug(('Highway drive: %s (%.0f mph)'):format(fast and 'highway speed' or 'city speed', curSpeed * 2.237))
            end
        end

        if route.reached(c.wp, pos) then
            if c.wp >= route.last then
                TaskVehicleTempAction(ped, veh, 27, 4000)   -- stop at the drop-off
                TriggerServerEvent('lastflight:server:tourArrived', id, i)
                break
            end
            -- several close points can be passed in one tick
            repeat c.wp = c.wp + 1 until c.wp >= route.last or not route.reached(c.wp, pos)
            TriggerServerEvent('lastflight:server:tourProgress', id, i, c.wp)
            if route.aim(c.wp) ~= aim then aim = taskTo(veh, ped, route, c.wp) end
            lastMoveAt, stage = now, 0
        elseif stage == 0 and stalled > TC.stuckTime then
            stage = 1
            LF.Debug('Farewell car stalled - re-routing')
            aim = taskTo(veh, ped, route, c.wp)
        elseif stage == 1 and stalled > TC.stuckTime * 1.5 then
            stage = 2
            LF.Debug('Farewell car stalled - backing up')
            TaskVehicleTempAction(ped, veh, 3, 2500)
            SetTimeout(2600, function()
                if T == t and t.drivingCar == i then aim = taskTo(vehOf(i), pedOf(i), route, c.wp) end
            end)
        elseif stage == 2 and stalled > TC.stuckTime * 2 then
            recoveries = recoveries + 1
            lastPos, lastMoveAt, stage = pos, now, 0
            LF.Debug('Farewell car stuck, teleport recovery ' .. recoveries)
            if recoveries > TC.maxStuckRecoveries then
                TriggerServerEvent('lastflight:server:tourFailed', id, i)
                break
            end
            TriggerServerEvent('lastflight:server:tourBlink', id, i)
            local wp = route.point(c.wp)
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
            aim = taskTo(veh, ped, route, c.wp)
        end
    end
    c.driving = false
end

---------------------------------------------------------------------------
-- Quieter roads while riding
---------------------------------------------------------------------------
-- Random NPC traffic around the car (or in a box ahead). Never touches player cars,
-- player-owned parked cars, or anything a script made (mission entities,
-- which includes every farewell car).
local function clearAhead(myVeh)
    local tr = TC.traffic
    local removed = 0
    local pos = GetEntityCoords(myVeh)
    local fwd = GetEntityForwardVector(myVeh)
    for _, v in ipairs(GetGamePool('CVehicle')) do
        -- class 21 = trains: deleting carriages breaks the train line (and they never block the road)
        if v ~= myVeh and not IsEntityAMissionEntity(v) and not GetVehicleHasBeenOwnedByPlayer(v)
            and GetVehicleClass(v) ~= 21 then
            local d = GetEntityCoords(v) - pos
            local hit
            if tr.clearAll then
                hit = #d < (tr.clearRadius or 300.0)
            else
                local along = d.x * fwd.x + d.y * fwd.y
                local side = math.abs(d.x * fwd.y - d.y * fwd.x)
                hit = along > tr.aheadMin and along < tr.aheadMax and side < tr.width
            end
            if hit then
                local driver = GetPedInVehicleSeat(v, -1)
                local playerCar = false
                for seat = -1, GetVehicleModelNumberOfSeats(GetEntityModel(v)) - 2 do
                    local p = GetPedInVehicleSeat(v, seat)
                    if p ~= 0 and IsPedAPlayer(p) then playerCar = true break end
                end
                if not playerCar then
                    if NetworkHasControlOfEntity(v) and (driver == 0 or NetworkHasControlOfEntity(driver)) then
                        if driver ~= 0 then
                            SetEntityAsMissionEntity(driver, true, true)
                            DeletePed(driver)
                        end
                        SetEntityAsMissionEntity(v, true, true)
                        DeleteVehicle(v)
                        removed = removed + 1
                    else
                        -- owned by another player's game: ask for it, removed on the next pass
                        NetworkRequestControlOfEntity(v)
                        if driver ~= 0 then NetworkRequestControlOfEntity(driver) end
                    end
                end
            end
        end
    end
    if removed > 0 then LF.Debug(('Highway drive: cleared %d car(s) ahead'):format(removed)) end
end

-- Qbox's qbx_density sets traffic every frame, which would override ours, so
-- while riding we lower it through its export and put the server's own
-- values back afterwards.
local DENSITY_KEYS = { 'parked', 'vehicle', 'randomvehicles', 'peds', 'scenario' }
local quietOn = false

-- vals = { key = value } to set, or nil to restore qbx_density's config values
local function qbxDensity(vals)
    if GetResourceState('qbx_density') ~= 'started' then return end
    if vals == nil then
        local src = LoadResourceFile('qbx_density', 'config/client.lua')
        local ok, cfg = pcall(function() return src and load(src)() end)
        local def = (ok and type(cfg) == 'table') and cfg or {}
        vals = {}
        for _, k in ipairs(DENSITY_KEYS) do vals[k] = tonumber(def[k]) or 0.8 end
    end
    for k, v in pairs(vals) do
        pcall(function() exports.qbx_density:SetDensity(k, v) end)
    end
end

local function quietRoads(t)
    local tr = TC.traffic
    if not tr then return end
    local nextClear = 0
    local d = tr.density or 1.0           -- vehicles
    local pd = tr.pedDensity or 1.0       -- people on the sidewalks
    if d < 1.0 or pd < 1.0 then
        quietOn = true
        local vals = {}
        if d < 1.0 then vals.vehicle, vals.randomvehicles, vals.parked = d, d, d end
        if pd < 1.0 then vals.peds, vals.scenario = pd, pd end
        qbxDensity(vals)
    end
    while T == t and t.state == 'driving' do
        if d < 1.0 then
            SetVehicleDensityMultiplierThisFrame(d)
            SetRandomVehicleDensityMultiplierThisFrame(d)
            SetParkedVehicleDensityMultiplierThisFrame(d)
        end
        if pd < 1.0 then
            SetPedDensityMultiplierThisFrame(pd)
            SetScenarioPedDensityMultiplierThisFrame(pd, pd)
        end
        if tr.clearAhead and GetGameTimer() >= nextClear then
            nextClear = GetGameTimer() + 1000
            local veh = t.car and vehOf(t.car) or 0
            if veh ~= 0 and (tr.clearAll or GetEntitySpeed(veh) > 3.0) then clearAhead(veh) end
        end
        Wait(0)
    end
    if quietOn then
        quietOn = false
        qbxDensity(nil)
    end
end

---------------------------------------------------------------------------
-- Spawning (the player who asked)
---------------------------------------------------------------------------
local function spawnCars(id, n)
    local vehHash = LFC.LoadModel(TC.vehicle)
    local pedHash = LFC.LoadModel(TC.driver)
    if not vehHash or not pedHash then
        TriggerServerEvent('lastflight:server:tourSpawned', id, {}, 0)
        return
    end
    local sp = TC.spawn
    local rad = math.rad(sp.w)
    local back = vector3(math.sin(rad), -math.cos(rad), 0.0)    -- opposite of the car's forward vector
    local list = {}
    for i = 1, n do
        local p = vector3(sp.x, sp.y, sp.z) + back * (TC.carSpacing * (i - 1))
        local veh = CreateVehicle(vehHash, p.x, p.y, p.z, sp.w, true, false)
        SetEntityAsMissionEntity(veh, true, true)
        SetVehicleOnGroundProperly(veh)
        SetVehicleEngineOn(veh, true, true, false)
        SetVehicleDoorsLocked(veh, 2)              -- riders are warped in; no carjacking the chauffeur
        SetVehicleHasBeenOwnedByPlayer(veh, false)
        SetVehicleDirtLevel(veh, 0.0)
        local ped = CreatePedInsideVehicle(veh, 26, pedHash, -1, true, false)
        SetEntityAsMissionEntity(ped, true, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        SetDriverAbility(ped, 1.0)
        SetDriverAggressiveness(ped, 0.0)
        SetEntityInvincible(ped, true)
        list[#list + 1] = { veh = VehToNet(veh), ped = PedToNet(ped) }
    end
    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(pedHash)
    local capacity = math.max(1, GetVehicleModelNumberOfSeats(vehHash) - 1)
    TriggerServerEvent('lastflight:server:tourSpawned', id, list, capacity)
end

---------------------------------------------------------------------------
-- Every rider: get in, buckle, ride, get out
---------------------------------------------------------------------------
local function carIn(me)
    local v = GetVehiclePedIsIn(me, false)
    if v == 0 then return nil end
    for i in ipairs(T.cars) do
        if vehOf(i) == v then return i end
    end
end

local function riderLoop(t)
    local n = #t.cars
    LFC.Notify(n > 1 and ('%d farewell cars are waiting at the curb. Walk over and press E to get in any of them.'):format(n)
        or 'Your farewell car is waiting at the curb. Walk over and press E to get in.', 'info')
    local lastHud = 0
    while T == t do
        local me = PlayerPedId()
        local inCar = carIn(me)
        refreshBlips()

        if t.state == 'waiting' and t.car and t.counts and GetGameTimer() - lastHud > 1000 then
            lastHud = GetGameTimer()
            local note
            if t.leavesAt then
                local left = math.max(0, math.ceil((t.leavesAt - GetGameTimer()) / 1000))
                note = left > 0 and ('leaves in %ds'):format(left) or 'departing'
            else
                note = 'waiting for everyone'
            end
            LFC.Nui('buckle', { count = t.counts[1], total = t.counts[2], note = note })
        end

        if t.state == 'waiting' then
            if inCar and t.car ~= inCar then
                -- got in (or swapped to another car in the line): buckle up again
                t.car, t.buckling, t.promptShown = inCar, true, true
                LFC.Nui('buckle', { show = true, key = Config.Keys.seatbelt })
                TriggerServerEvent('lastflight:server:tourSeated', t.id, inCar)
            elseif not inCar and t.car then
                hideBuckle()
                t.car, t.buckling = nil, false
                TriggerServerEvent('lastflight:server:tourSeated', t.id, nil)
            end
            -- nearest car of my group with a free seat
            local near, best = nil, 7.0
            if not inCar then
                local pos = GetEntityCoords(me)
                for i in ipairs(t.cars) do
                    local veh = vehOf(i)
                    if veh ~= 0 then
                        local d = #(pos - GetEntityCoords(veh))
                        if d < best then near, best = veh, d end
                    end
                end
            end
            if near then
                LFC.HelpText('~INPUT_CONTEXT~ Get in the farewell car')
                if IsControlJustReleased(0, Config.Interaction.key) then
                    local seat = freeSeat(near)
                    if seat then TaskWarpPedIntoVehicle(me, near, seat)
                    else LFC.Notify('This car is full - try another one in the line.', 'error') end
                end
                Wait(0)
            else
                Wait(250)
            end
        elseif t.state == 'driving' then
            if not t.car or inCar ~= t.car then
                TriggerServerEvent('lastflight:server:tourLeft', t.id)
                LFC.Notify('You left the farewell drive.', 'info')
                clearTour()
                return gpsToDesk()
            end
            DisableControlAction(0, 75, true)      -- no accidental exits at highway speed
            Wait(0)
        else
            Wait(250)
        end
    end
end

---------------------------------------------------------------------------
-- NPC menu (opened from client_transport's city NPC)
---------------------------------------------------------------------------
function LFC.OpenTour()
    if not TC.enabled then return end
    if T then return LFC.Notify('You are already booked on the farewell drive - get in!', 'info') end
    TriggerServerEvent('lastflight:server:tourInfo')
end

RegisterNetEvent('lastflight:client:tourInfo', function(info)
    if T or LFC.focus then return end
    LFC.Nui('tour', info)
    LFC.Focus(true)
end)

RegisterNUICallback('tourStart', function(data, cb)
    cb(1)
    LFC.Focus(false)
    LFC.Nui('hidePanels')
    TriggerServerEvent('lastflight:server:tourRequest', tonumber(data.size) or 1)
end)

---------------------------------------------------------------------------
-- Server -> rider
---------------------------------------------------------------------------
RegisterNetEvent('lastflight:client:tourSpawn', function(id, n)
    CreateThread(function() spawnCars(id, n) end)
end)

RegisterNetEvent('lastflight:client:tourJoin', function(id, list)
    if T then return end
    T = { id = id, cars = {}, blips = {}, state = 'waiting' }
    for i, c in ipairs(list or {}) do T.cars[i] = { veh = c.veh, ped = c.ped, wp = 1 } end
    local t = T
    CreateThread(function()
        local deadline = GetGameTimer() + 5000
        while vehOf(1) == 0 and GetGameTimer() < deadline do Wait(100) end
        riderLoop(t)
    end)
end)

RegisterNetEvent('lastflight:client:tourStatus', function(id, s)
    if not T or T.id ~= id then return end
    local was = T.state
    if s.state == 'waiting' or s.state == 'driving' then T.state = s.state end
    T.counts = { s.buckled, s.riders }
    T.leavesAt = s.leavesIn and (GetGameTimer() + s.leavesIn * 1000) or nil
    if T.state ~= 'waiting' then
        hideBuckle()
        T.buckling = false
    end
    if T.state == 'driving' and not T.quiet then
        T.quiet = true
        local t = T
        CreateThread(function() quietRoads(t) end)
    end
    if was == 'waiting' and T.state == 'driving' then
        LFC.Notify('Here we go - one last drive around the island. Sit back and enjoy the view.', 'success')
    end
end)

-- I drive car i (the convoy leaves staggered, so each car may wait a moment)
RegisterNetEvent('lastflight:client:tourDrive', function(id, i, wp, delay)
    if not T or T.id ~= id or not T.cars[i] then return end
    local t = T
    t.state = 'driving'
    hideBuckle()
    t.buckling = false
    t.drivingCar = i
    t.cars[i].wp = tonumber(wp) or t.cars[i].wp
    CreateThread(function()
        if (delay or 0) > 0 then Wait(delay * 1000) end
        if T == t and t.drivingCar == i then drive(t, i) end
    end)
end)

RegisterNetEvent('lastflight:client:tourBlink', function(id, i)
    if T and T.id == id and T.car == i then CreateThread(function() fadeBlink() end) end
end)

RegisterNetEvent('lastflight:client:tourExit', function(id, i)
    if not T or T.id ~= id or T.car ~= i then return end
    local veh = vehOf(i)
    T.state = 'arrived'
    T.drivingCar = nil
    clearTour()
    CreateThread(function()
        Wait(800)
        local me = PlayerPedId()
        if veh ~= 0 and GetVehiclePedIsIn(me, false) == veh then
            TaskLeaveVehicle(me, veh, 0)
            local deadline = GetGameTimer() + 6000
            while GetVehiclePedIsIn(PlayerPedId(), false) == veh and GetGameTimer() < deadline do Wait(100) end
            if GetVehiclePedIsIn(PlayerPedId(), false) == veh then TaskLeaveVehicle(PlayerPedId(), veh, 16) end
        end
        LFC.Notify(arrivedMsg(), 'success')
    end)
end)

-- Car destroyed / gave up / timed out: put its riders at the drop-off safely
RegisterNetEvent('lastflight:client:tourRescue', function(id, i)
    if not T or T.id ~= id or T.car ~= i then return end
    clearTour()
    local d = TC.waypoints[#TC.waypoints]
    fadeBlink(function() LFC.Teleport(vector4(d.x, d.y, d.z + 1.0, 0.0), true) end)
    LFC.Notify(arrivedMsg(), 'success')
end)

RegisterNetEvent('lastflight:client:tourTimedOut', function(id)
    if not T or T.id ~= id then return end
    clearTour()
    LFC.Notify('Nobody got in, so the farewell car left.', 'info')
end)

RegisterNetEvent('lastflight:client:tourEnded', function(id)
    if T and T.id == id then clearTour() end
end)

table.insert(LFC.onCleanup, function()
    if T then
        TriggerServerEvent('lastflight:server:tourLeft', T.id)
        clearTour()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearTour()
    if quietOn then qbxDensity(nil) end
end)
