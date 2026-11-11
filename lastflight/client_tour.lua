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

local radioMuted = false

local function clearTour()
    if not T then return end
    for _, b in pairs(T.blips) do RemoveBlip(b) end
    hideBuckle()
    if T.music then
        LFC.Nui('audioFade', { kind = 'music', duration = ((TC.music and TC.music.fadeOut) or 4) * 1000 })
    end
    if radioMuted then
        SetUserRadioControlEnabled(true)
        radioMuted = false
    end
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

-- client_flight's scroll-wheel volume works while this is true:
-- riding in my farewell car while it drives and the music plays
function LFC.TourMusicOn()
    if not T or not T.music or T.state ~= 'driving' or not T.car then return false end
    local veh = vehOf(T.car)
    return veh ~= 0 and GetVehiclePedIsIn(PlayerPedId(), false) == veh
end

---------------------------------------------------------------------------
-- Music, radio and "now passing" pop-ups (every rider, while driving)
---------------------------------------------------------------------------
local function startMusic(t)
    local m = TC.music
    if t.music or not m or not m.tracks or #m.tracks == 0 then return end
    t.music = true
    LFC.Nui('playlist', { tracks = m.tracks, volume = m.volume or 0.5, offset = 0 })
end

local function rideExtras(t)
    local shown, nextView, nextMute = {}, 0, 0
    local radius = TC.viewRadius or 250.0
    while T == t and t.state == 'driving' do
        local now = GetGameTimer()
        local veh = t.car and vehOf(t.car) or 0
        if veh ~= 0 then
            -- the car's own GTA radio would play over the music
            if now >= nextMute then
                nextMute = now + 2000
                SetVehRadioStation(veh, 'OFF')
                SetVehicleRadioEnabled(veh, false)
                SetUserRadioControlEnabled(false)
                radioMuted = true
            end
            if now >= nextView then
                nextView = now + 1000
                local pos = GetEntityCoords(veh)
                for i, v in ipairs(TC.viewpoints or {}) do
                    if not shown[i] and #(vector3(pos.x - v.pos.x, pos.y - v.pos.y, 0.0)) < radius then
                        shown[i] = true
                        LFC.Nui('landmark', { label = v.label, quote = v.quote })
                        nextView = now + 9000         -- let one pop-up finish before the next
                        break
                    end
                end
            end
        end
        Wait(250)
    end
end

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
local function makeRoute(W)
    W = W or TC.waypoints
    local last = #W
    local cache = {}

    local function dirAt(k)
        local a, b = W[math.max(1, k - 1)], W[math.min(last, k + 1)]
        local d = vector3(b.x - a.x, b.y - a.y, 0.0)
        if #d < 1.0 then return nil end
        return d / #d
    end

    -- the first route point at least `dist` metres on from point k
    local function ahead(k, dist)
        local p = W[k]
        for j = k + 1, last do
            if #(vector3(W[j].x - p.x, W[j].y - p.y, 0.0)) >= dist then return W[j] end
        end
        return W[last]
    end

    local function point(k)
        if cache[k] then return cache[k] end
        local p = W[k]
        local best = p
        local dir = dirAt(k)
        -- snapRadius 0 (default): drive to the recorded point itself. Points recorded
        -- in the lane don't need moving, and the lane-lock below can move them onto
        -- the wrong road: a two-way street's node can point either way, so it may
        -- grab the cross street instead; next to a ramp it may grab the ramp.
        local snap = TC.snapRadius or 0.0
        if snap > 0.0 and dir and k < last then
            local want = LF.HeadingOf(dir)
            local cands = {}
            for n = 1, 8 do
                local found, node, heading = GetNthClosestVehicleNodeWithHeading(p.x, p.y, p.z, n, 0, 3.0, 0.0)
                if not found or #(node - p) > snap then break end
                if math.abs(LF.AngleDiff(heading, want)) < 60.0 and math.abs(node.z - p.z) < 6.0 then
                    cands[#cands + 1] = { node = node, heading = heading }
                end
            end
            if #cands == 1 then
                best = cands[1].node
            elseif #cands > 1 then
                -- Two lanes going our way, e.g. where a ramp splits off the freeway: take
                -- the one that leads toward the route further on. A ramp curves away from
                -- it; the road we want keeps pointing at it.
                local far = ahead(k, TC.splitLook or 60.0)
                local bestScore
                for _, c in ipairs(cands) do
                    local toward = LF.HeadingOf(vector3(far.x - c.node.x, far.y - c.node.y, 0.0))
                    local score = math.abs(LF.AngleDiff(c.heading, toward))
                    if not bestScore or score < bestScore - 5.0 then best, bestScore = c.node, score end
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
        -- only once the car is actually there: with points ~20 m apart a big radius
        -- ticked points off one or two ahead of the car (even while still parked)
        if #flat < (TC.viaRadius or 10.0) then return true end
        local dir = dirAt(k)
        if dir and #flat < 60.0 then
            local along = flat.x * dir.x + flat.y * dir.y
            local side = math.abs(flat.x * dir.y - flat.y * dir.x)
            if along > 0.0 and side < (TC.passSide or 10.0) then return true end    -- just driven past it, a lane or two over
            -- it's behind us and the next point is already closer: we went by it
            -- further over (wide freeway) - never turn back for it
            if along > 0.0 and k < last then
                local q = point(k + 1)
                if #(vector3(q.x - pos.x, q.y - pos.y, 0.0)) < #flat then return true end
            end
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

    -- A sharp corner within the next `cornerLook` metres: aim at a point just past
    -- it. Given a point in the middle of the turn, GTA's driver just steers at it
    -- from whatever lane it's in; given one round the corner, its GPS sees a turn
    -- and moves into the turn lane first, like a normal car.
    local function cornerExit(wp)
        local CA = TC.corners or {}
        if CA.enabled == false then return nil end
        local look, sharp, past = CA.look or 60.0, CA.bend or 25.0, CA.past or 20.0
        local dist, lastBend = 0.0, nil
        for k = math.max(2, wp), math.min(last - 1, wp + 8) do
            if k > wp then dist = dist + #(vector3(W[k].x - W[k - 1].x, W[k].y - W[k - 1].y, 0.0)) end
            if dist > look then break end
            local a, b, c = W[k - 1], W[k], W[k + 1]
            local bend = math.abs(LF.AngleDiff(LF.HeadingOf(vector3(b.x - a.x, b.y - a.y, 0.0)),
                LF.HeadingOf(vector3(c.x - b.x, c.y - b.y, 0.0))))
            if bend > sharp then lastBend = k end
        end
        if not lastBend then return nil end
        -- the first point at least `past` metres beyond the end of the turn (not a
        -- point count: that could land far round the corner)
        local from = W[lastBend]
        for k = lastBend + 1, last do
            if #(vector3(W[k].x - from.x, W[k].y - from.y, 0.0)) >= past then return k end
        end
        return last
    end

    -- which point the driver aims at while heading for point wp
    local function aim(wp)
        local corner = cornerExit(wp)
        if corner then return corner end
        local k = wp
        for _ = 1, (TC.lookahead or 1) do
            if not straight(k) then break end
            k = k + 1
        end
        return k
    end

    -- a sharp turn coming up: the route turns more than `angle` degrees in total
    -- over the next few points within `dist` metres of the car (a city corner
    -- is usually spread over 2-3 recorded points). It slows down before it
    -- instead of swinging wide.
    local function turnAhead(wp, pos, angle, dist)
        local total = 0.0
        for k = math.max(2, wp - 1), math.min(last - 1, wp + 4) do
            local a, b, c = W[k - 1], W[k], W[k + 1]
            if #(vector3(b.x - pos.x, b.y - pos.y, 0.0)) < dist then
                total = total + math.abs(LF.AngleDiff(LF.HeadingOf(vector3(b.x - a.x, b.y - a.y, 0.0)),
                    LF.HeadingOf(vector3(c.x - b.x, c.y - b.y, 0.0))))
            end
        end
        return total > angle
    end

    return { last = last, point = point, reached = reached, aim = aim, turnAhead = turnAhead,
             raw = function(k) return W[k] end }
end

-- On straight stretches the driver aims past the next point (no braking at
-- every point); at corners and long gaps it goes point by point.
local curSpeed = TC.speed
local dbgAim            -- the last order given to the driver (for the /lastflight debug view)

local function taskTo(veh, ped, route, wp)
    local k = route.aim(wp)
    local p = route.point(k)
    TaskVehicleDriveToCoordLongrange(ped, veh, p.x, p.y, p.z, curSpeed, LF.DriveStyle(TC.drivingStyle), k >= route.last and TC.arriveRadius or 20.0)
    SetPedKeepTask(ped, true)
    local r = route.raw(k)
    dbgAim = { k = k, p = p, moved = #(vector3(p.x - r.x, p.y - r.y, 0.0)) }
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

-- Fewer points on straight road: every point in a turn is kept, on the
-- straights only one every maxGap metres. The saved points aren't changed -
-- every client thins them the same way, so point numbers match for handover.
local thinRoute, thinKey
local thinMap           -- [index in the thinned list] = the recorded point's number (nil = not thinned)
local function thinned()
    if thinRoute and thinKey == LF.LayoutVersion then return thinRoute end
    local W, T2 = TC.waypoints, TC.thin or {}
    if T2.enabled == false then thinMap = nil; return W end
    local maxGap, keepBend, turnAt = T2.maxGap or 60.0, T2.keepBend or 12.0, T2.turnAt or 6.0
    local keepAfter = T2.keepAfterTurn or 40.0
    local out = { W[1] }
    local map = { 1 }
    local lastKept, turned, lastTurn = W[1], 0.0, nil
    for k = 2, #W - 1 do
        local a, b, c = W[k - 1], W[k], W[k + 1]
        local bend = math.abs(LF.AngleDiff(LF.HeadingOf(vector3(b.x - a.x, b.y - a.y, 0.0)), LF.HeadingOf(vector3(c.x - b.x, c.y - b.y, 0.0))))
        turned = turned + bend
        local gap = #(vector3(b.x - lastKept.x, b.y - lastKept.y, 0.0))
        -- the straight just after a turn keeps its points too, so a corner always
        -- has exit points to aim at
        local exiting = lastTurn and #(vector3(b.x - lastTurn.x, b.y - lastTurn.y, 0.0)) <= keepAfter
        if bend >= turnAt or turned >= keepBend or gap >= maxGap or exiting then
            out[#out + 1] = b
            map[#out] = k
            lastKept, turned = b, 0.0
        end
        if bend >= turnAt then lastTurn = b end
    end
    if #W > 1 then
        out[#out + 1] = W[#W]
        map[#out] = #W
    end
    LF.Debug(('Highway drive: %d recorded points -> %d used'):format(#W, #out))
    thinRoute, thinKey, thinMap = out, LF.LayoutVersion, map
    return out
end

---------------------------------------------------------------------------
-- /lastflight debug: show where the driver is being sent. Only on the game
-- that is driving the car (usually whoever started the drive).
--   red pillar + line  = the spot the driver was told to drive to
--   green pillar       = the next point it still has to reach
---------------------------------------------------------------------------
local dbg

local function recordedNo(k) return thinMap and thinMap[k] or k end

CreateThread(function()
    while true do
        if Config.Debug and dbg and T and dbg.t == T then
            local veh = vehOf(dbg.car)
            if veh ~= 0 then
                local pos = GetEntityCoords(veh)
                local a, n = dbg.aim, dbg.next
                if n then
                    DrawMarker(1, n.x, n.y, n.z - 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.6, 1.6, 9.0, 40, 255, 90, 150, false, false, 2, false, nil, nil, false)
                end
                if a then
                    DrawMarker(1, a.x, a.y, a.z - 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.4, 2.4, 14.0, 255, 40, 40, 150, false, false, 2, false, nil, nil, false)
                    DrawLine(pos.x, pos.y, pos.z + 0.6, a.x, a.y, a.z + 0.6, 255, 40, 40, 255)
                end
                SetTextFont(4)
                SetTextScale(0.42, 0.42)
                SetTextOutline()
                SetTextCentre(true)
                BeginTextCommandDisplayText('STRING')
                AddTextComponentSubstringPlayerName(('Next: Highway %d   |   Sent to: Highway %d (%.0f m away)%s   |   %.0f mph'):format(
                    recordedNo(dbg.wp), recordedNo(dbg.aimK), a and #(vector3(a.x - pos.x, a.y - pos.y, 0.0)) or 0.0,
                    dbg.moved and dbg.moved > 1.0 and (' ~r~moved %.0f m by lane-lock~s~'):format(dbg.moved) or '',
                    GetEntitySpeed(veh) * 2.237))
                EndTextCommandDisplayText(0.5, 0.06)
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

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
    local route = makeRoute(thinned())
    -- city speed until we're on the highway (two checks in a row, so an
    -- overpass or a side street under a bridge doesn't flip it back and forth)
    local fast = TC.citySpeed == nil or onHighway(GetEntityCoords(veh))
    local streak = 0
    curSpeed = fast and TC.speed or TC.citySpeed
    local aim = taskTo(veh, ped, route, c.wp)
    local lastPos, lastMoveAt, stage, recoveries = GetEntityCoords(veh), GetGameTimer(), 0, 0
    local loggedK

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

        -- /lastflight debug: where the driver is being sent (drawn by the debug thread, logged to F8)
        if Config.Debug and dbgAim then
            dbg = { t = t, car = i, aim = dbgAim.p, aimK = dbgAim.k, moved = dbgAim.moved, next = route.point(c.wp), wp = c.wp }
            if loggedK ~= dbgAim.k then
                loggedK = dbgAim.k
                print(('[lastflight] next Highway %d -> driver sent to Highway %d (%.0f m away)%s'):format(
                    recordedNo(c.wp), recordedNo(dbgAim.k), #(vector3(dbgAim.p.x - pos.x, dbgAim.p.y - pos.y, 0.0)),
                    dbgAim.moved > 1.0 and (' [moved %.0f m by lane-lock]'):format(dbgAim.moved) or ''))
            end
        else
            dbg = nil
        end

        if TC.citySpeed then
            if onHighway(pos) ~= fast then streak = streak + 1 else streak = 0 end
            if streak >= 2 then
                fast, streak = not fast, 0
                LF.Debug(('Highway drive: %s'):format(fast and 'highway speed' or 'city speed'))
            end
        end
        -- city / highway speed, and slower into a sharp turn so it doesn't swing wide
        local want = fast and TC.speed or TC.citySpeed
        local TS = TC.turnSlow or {}
        if TS.enabled ~= false and route.turnAhead(c.wp, pos, TS.angle or 40.0, TS.distance or 50.0) then
            want = math.min(want, TS.speed or 8.0)
        end
        if want ~= curSpeed then
            curSpeed = want
            SetDriveTaskCruiseSpeed(ped, curSpeed)
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
    dbg = nil
end

---------------------------------------------------------------------------
-- Quieter roads while riding
---------------------------------------------------------------------------
-- Only the game's own random traffic: population types 1-5 (random permanent,
-- parked, patrol, scenario, ambient). Script-made vehicles (6/7) - garages,
-- jobs, the farewell cars - never qualify.
local function isRandomTraffic(v)
    local pop = GetEntityPopulationType(v)
    return pop >= 1 and pop <= 5
end

-- A player drove it last (e.g. a car someone took and parked)
local function playerDroveIt(v)
    local last = GetLastPedInVehicleSeat(v, -1)
    return last ~= 0 and IsPedAPlayer(last)
end

-- Random NPC traffic around the car (or in a box ahead). Never touches player cars,
-- cars a player last drove, or anything a script made (garage cars, job cars,
-- every farewell car).
local function clearAhead(myVeh)
    local tr = TC.traffic
    local removed = 0
    local pos = GetEntityCoords(myVeh)
    local fwd = GetEntityForwardVector(myVeh)
    for _, v in ipairs(GetGamePool('CVehicle')) do
        -- class 21 = trains: deleting carriages breaks the train line (and they never block the road)
        if v ~= myVeh and not IsEntityAMissionEntity(v) and isRandomTraffic(v) and not playerDroveIt(v)
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
                LFC.Nui('buckle', { show = true, key = Config.Keys.seatbelt, scroll = TC.music ~= nil })
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
        if t.car then
            startMusic(t)
            CreateThread(function() rideExtras(t) end)
        end
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
