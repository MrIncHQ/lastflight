-- Passenger side of the flight: seating, readiness, the aircraft movement
-- controller, audio cues, cameras and the farewell.
--
-- Movement: the jet follows the shared timeline (shared.lua). Whichever
-- passenger's client OWNS the networked jet moves it each frame; everyone
-- else just sees it via OneSync. If ownership migrates, the new owner picks
-- up from the same timeline, so the flight never stalls or desyncs.

local S   = LF.States
local A   = Config.Aircraft
local CIN = Config.Cinematics
local SF  = Config.ScenicFlight

local F = {}
local savedViewMode

local function resetF()
    F = {
        active = false, flightId = nil, netId = nil, veh = nil, seat = nil, mode = nil,
        phase = nil, phaseStartLocal = 0, isController = false, groundOffset = nil,
        ready = false, locked = false, camMode = 'gameplay', landmarksDone = {},
        thirdPerson = false, gearUp = false, pitch = 0.0, roll = 0.0, frozen = false,
        fadeScheduled = false, buckling = false, musicStarted = false,
    }
end
resetF()

function LFC.InFlight() return F.active end

-- Seated passengers use the normal GTA camera. Passengers attached inside the
-- fuselage (when the jet runs out of real seats) get a mouse-controlled
-- free-look camera instead, because the GTA camera would clip inside the plane.
local function defaultCamMode()
    if not SF.allowFreeLook then return 'chase' end
    if F.mode == 'attach' then return 'freelook' end
    return 'gameplay'
end

local function resolveVeh()
    if F.netId and NetworkDoesNetworkIdExist(F.netId) then
        local v = NetToVeh(F.netId)
        if v ~= 0 and DoesEntityExist(v) then F.veh = v end
    end
    return F.veh
end

local function phaseElapsed()
    return (GetGameTimer() - F.phaseStartLocal) / 1000.0
end

table.insert(LFC.onCleanup, function()
    if savedViewMode then SetFollowVehicleCamViewMode(savedViewMode); savedViewMode = nil end
    resetF()
end)

---------------------------------------------------------------------------
-- Boarding / seating
---------------------------------------------------------------------------
local function seatPlayer(veh, mode, seat)
    local ped = PlayerPedId()
    if mode == 'seat' then
        if not IsVehicleSeatFree(veh, seat) and GetPedInVehicleSeat(veh, seat) ~= ped then return false end
        TaskWarpPedIntoVehicle(ped, veh, seat)
        local deadline = GetGameTimer() + 2500
        while GetPedInVehicleSeat(veh, seat) ~= ped and GetGameTimer() < deadline do Wait(50) end
        return GetPedInVehicleSeat(veh, seat) == ped
    end
    local o = A.attachOffsets[seat]
    if not o then return false end
    ClearPedTasksImmediately(ped)
    SetEntityCollision(ped, false, false)
    AttachEntityToEntity(ped, veh, 0, o.x, o.y, o.z, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    SetEntityVisible(ped, false, false)
    return IsEntityAttachedToEntity(ped, veh)
end

RegisterNetEvent('lastflight:client:board', function(data)
    CreateThread(function()
        DoScreenFadeOut(500)
        local d = GetGameTimer() + 1500
        while not IsScreenFadedOut() and GetGameTimer() < d do Wait(10) end

        local veh = LFC.NetEntity(data.netId, 8000)
        local modelSeats = veh and GetVehicleModelNumberOfSeats(GetEntityModel(veh)) or nil
        local ok = veh and seatPlayer(veh, data.mode, data.seat) or false

        if ok then
            local wasActive = F.active
            if not wasActive then resetF() end
            F.active, F.flightId, F.netId, F.veh = true, data.flightId, data.netId, veh
            F.seat, F.mode = data.seat, data.mode
            F.camMode = defaultCamMode()
            local ped = PlayerPedId()
            SetPedConfigFlag(ped, 184, true)        -- never shuffle into the pilot seat
            SetEntityInvincible(ped, true)
            savedViewMode = savedViewMode or GetFollowVehicleCamViewMode()
            if F.mode == 'attach' then Cams.Mode('freelook', veh) end
            LFC.Nui('readyShow', { flight = data.flight, destination = data.destination })
            LFC.Focus(true)
            LFC.Notify(('Welcome aboard flight %s. Press READY (or %s) when you are set.'):format(data.flight, Config.Keys.ready), 'success')
        end

        TriggerServerEvent('lastflight:server:seatResult', data.flightId, ok, modelSeats, veh ~= nil)
        DoScreenFadeIn(600)
    end)
end)

RegisterNetEvent('lastflight:client:manifest', function(data)
    if not F.active or data.flightId ~= F.flightId then return end
    F.ready = data.youReady
    F.locked = data.locked
    data.key = Config.Keys.ready
    LFC.Nui('manifest', data)
end)

-- Seatbelt key: the runway buckle, the shuttle buses and the farewell car
function LFC.Buckle()
    if F.active and F.buckling then
        F.buckling = false
        TriggerServerEvent('lastflight:server:buckle', F.flightId)
        PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)
        LFC.Nui('buckle', { done = true })
        return
    end
    if LFC.RideBuckle and LFC.RideBuckle() then return end
    if LFC.TourBuckle then LFC.TourBuckle() end
end

function LFC.ToggleReady()
    if not F.active or F.locked then return end
    TriggerServerEvent('lastflight:server:setReady', F.flightId, not F.ready)
end

RegisterNUICallback('ready', function(data, cb)
    if F.active and not F.locked then
        TriggerServerEvent('lastflight:server:setReady', F.flightId, data.value == true)
        if data.value == true then LFC.Focus(false) end
    end
    cb(1)
end)

local function leaveAircraft()
    if not F.active or F.locked then return end
    local id = F.flightId
    if F.mode == 'attach' then
        local bp = Config.Airport.boardingPoint
        LFC.ResetPlayerState()
        LFC.Teleport(vector4(bp.x, bp.y, bp.z + 1.0, 0.0), true)
    else
        LFC.ResetPlayerState()
    end
    TriggerServerEvent('lastflight:server:leave', id)
end

RegisterNetEvent('lastflight:client:reseat', function()
    local veh = resolveVeh()
    if F.active and veh then seatPlayer(veh, F.mode, F.seat) end
end)

RegisterNetEvent('lastflight:client:controller', function(flightId)
    if F.active and F.flightId == flightId then
        F.isController = true
        LF.Debug('I am the flight controller')
    end
end)

RegisterNetEvent('lastflight:client:groundOffset', function(flightId, off)
    if F.active and F.flightId == flightId then F.groundOffset = off end
end)

RegisterNetEvent('lastflight:client:notAboard', function()
    if F.active then LFC.Restore(Config.Airport.safeReturn, 'You are no longer on the flight.') end
end)

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------
local function scheduleFinale(duration)
    -- music fade + screen fade timed to the end of the departure leg
    local id = F.flightId
    local musicAt = math.max(0, duration - Config.Audio.musicFadeDuration)
    local fadeAt  = math.max(0, duration - CIN.fadeDuration)
    SetTimeout(math.floor(musicAt * 1000), function()
        if F.active and F.flightId == id then
            LFC.Nui('audioFade', { kind = 'music', duration = Config.Audio.musicFadeDuration * 1000 })
        end
    end)
    SetTimeout(math.floor(fadeAt * 1000), function()
        if F.active and F.flightId == id then
            LFC.Nui('fade', { to = 1, duration = CIN.fadeDuration * 1000 })
        end
    end)
end

local function enterPhase(state, elapsedMs)
    F.phase = state
    F.phaseStartLocal = GetGameTimer() - (elapsedMs or 0)
    F.locked = true
    local veh = resolveVeh()
    if not veh then
        TriggerServerEvent('lastflight:server:resync')
        return
    end

    -- Music: starts with the takeoff roll. If we join later (resync) it starts at the right spot.
    if (state == S.TAKEOFF or state == S.CRUISING or state == S.FINAL_DEPARTURE) and not F.musicStarted then
        F.musicStarted = true
        local offset = (elapsedMs or 0) / 1000
        if state ~= S.TAKEOFF then offset = offset + LF.Timeline.TAKEOFF.duration end
        if state == S.FINAL_DEPARTURE then offset = offset + LF.Timeline.CRUISING.duration end
        LFC.Nui('playlist', { tracks = Config.Music.tracks, volume = Config.Music.volume, offset = offset })
    end

    if state == S.TAXIING then
        LFC.Nui('readyHide')
        LFC.Focus(false)
        DisplayRadar(false)
        SetVehicleEngineOn(veh, true, true, false)
        LFC.Notify('Doors closed. We are now taxiing to the runway.', 'info')
        -- a single shot just holds (no re-cut); several shots loop until takeoff
        if CIN.enabled then Cams.Sequence(CIN.taxiShots, veh, #CIN.taxiShots > 1) end
        local pre = {}
        if Config.Audio.seatbelt.enabled then pre[1] = { kind = 'seatbelt', file = Config.Audio.seatbelt.file } end
        if Config.Audio.pilot.enabled then pre[#pre + 1] = { kind = 'pilot', file = Config.Audio.pilot.file } end
        for _, t in ipairs(Config.Music.tracks) do pre[#pre + 1] = { kind = 'music', file = t.file } end
        LFC.Nui('preload', pre)

    elseif state == S.RUNWAY_WAIT then
        LFC.Notify('Holding short of the runway.', 'info')

    elseif state == S.TAKEOFF then
        F.buckling = false
        LFC.Nui('buckle', { show = false })
        if CIN.enabled then
            Cams.Sequence(CIN.takeoffShots, veh, false, function() return F.thirdPerson end)
        end

    elseif state == S.CRUISING then
        LFC.Nui('seatbelt', { on = false })    -- cruise altitude: seatbelt sign off
        LFC.Nui('hud', { show = true, camLabel = Cams.modeLabels[F.camMode], camKey = Config.Keys.camera, toggle = SF.enableCameraToggle })

    elseif state == S.FINAL_DEPARTURE then
        local dur = LF.Timeline.FINAL_DEPARTURE.duration - (elapsedMs or 0) / 1000
        LFC.Nui('hud', { show = false })
        LFC.Nui('seatbelt', { on = false })
        if CIN.enabled then Cams.Final(veh, dur) end
        if not F.fadeScheduled then
            F.fadeScheduled = true
            scheduleFinale(dur)
        end
    end
end

RegisterNetEvent('lastflight:client:phase', function(data)
    if not F.active or data.flightId ~= F.flightId then return end
    if data.netId then F.netId = data.netId end
    if data.groundOffset then F.groundOffset = data.groundOffset end
    enterPhase(data.state, data.elapsed)
end)

RegisterNetEvent('lastflight:client:sync', function(flightId, state, elapsedMs, netId)
    if not F.active or flightId ~= F.flightId then return end
    F.netId = netId or F.netId
    if state ~= F.phase then
        enterPhase(state, elapsedMs)
        return
    end
    local localElapsed = GetGameTimer() - F.phaseStartLocal
    if math.abs(localElapsed - elapsedMs) > 250 then
        F.phaseStartLocal = GetGameTimer() - elapsedMs
    end
end)

---------------------------------------------------------------------------
-- Audio cues
---------------------------------------------------------------------------
RegisterNetEvent('lastflight:client:announcement', function(flightId)
    if not F.active or flightId ~= F.flightId then return end
    local a = Config.Audio.pilot
    LFC.Nui('audio', { kind = 'pilot', file = a.file, volume = a.volume, fallback = a.fallbackDuration, report = true })
    LFC.Notify('This is your captain speaking...', 'info')
end)

RegisterNUICallback('audioDone', function(data, cb)
    if data.kind == 'pilot' and F.active then
        TriggerServerEvent('lastflight:server:audioDone', F.flightId)
    end
    cb(1)
end)

RegisterNetEvent('lastflight:client:seatbelt', function(flightId, requireBuckle)
    if not F.active or flightId ~= F.flightId then return end
    local a = Config.Audio.seatbelt
    if a.enabled then LFC.Nui('audio', { kind = 'seatbelt', file = a.file, volume = a.volume }) end
    LFC.Nui('seatbelt', { on = true })
    if requireBuckle then
        F.buckling = true
        LFC.Nui('buckle', { show = true, key = Config.Keys.seatbelt })
    else
        LFC.Nui('buckle', { show = true, key = Config.Keys.seatbelt, info = true })
        SetTimeout(4000, function() LFC.Nui('buckle', { show = false }) end)
    end
end)

RegisterNetEvent('lastflight:client:buckleStatus', function(flightId, done, total)
    if F.active and flightId == F.flightId then LFC.Nui('buckle', { count = done, total = total }) end
end)

RegisterNetEvent('lastflight:client:buckleDone', function(flightId)
    if not F.active or flightId ~= F.flightId then return end
    F.buckling = false
    LFC.Nui('buckle', { show = false })
end)

---------------------------------------------------------------------------
-- Farewell
---------------------------------------------------------------------------
RegisterNetEvent('lastflight:client:farewell', function(flightId)
    if not F.active or flightId ~= F.flightId then return end
    LFC.Nui('fade', { to = 1, duration = 500 })
    LFC.Nui('audioFade', { kind = 'music', duration = 1500 })
    LFC.Nui('farewell', { show = true })
    CreateThread(function()
        Wait(600)
        DoScreenFadeOut(0)
        Wait(Config.Farewell.displayDuration * 1000)
        TriggerServerEvent('lastflight:server:farewellDone', flightId)
    end)
end)

-- Not kicked (test / live-return mode): back to Legion Square or the airport. msg comes from the server.
RegisterNetEvent('lastflight:client:testReturn', function(coords, msg)
    LFC.hasTicket, LFC.ticketStatus = false, 'none'
    local where = Config.Farewell.returnTo == 'city' and 'Legion Square' or 'the check-in desk'
    LFC.Restore(coords, msg or ('Welcome back to %s.'):format(where))
end)

---------------------------------------------------------------------------
-- Camera toggle (scenic flight)
---------------------------------------------------------------------------
function LFC.CycleCamera()
    if not F.active or not F.thirdPerson or F.phase ~= S.CRUISING or not SF.enableCameraToggle then return end
    local veh = resolveVeh()
    if not veh then return end
    local modes = {}
    for _, m in ipairs(Cams.modes) do
        -- one "free look" entry: the GTA camera for seated players, the orbit camera for attached ones
        local wantFree = SF.allowFreeLook and (F.mode == 'attach' and m == 'freelook' or F.mode ~= 'attach' and m == 'gameplay')
        if wantFree or (m ~= 'gameplay' and m ~= 'freelook') then modes[#modes + 1] = m end
    end
    local idx = 1
    for i, m in ipairs(modes) do if m == F.camMode then idx = i end end
    F.camMode = modes[idx % #modes + 1]
    F.inLandmark = false
    Cams.Mode(F.camMode, veh)
    LFC.Nui('hud', { show = true, camLabel = Cams.modeLabels[F.camMode], camKey = Config.Keys.camera, toggle = true })
end

---------------------------------------------------------------------------
-- Aircraft movement (runs only on the client that owns the jet)
---------------------------------------------------------------------------
local function lerp(a, b, f) return a + (b - a) * f end

-- Height of the jet's origin above its wheels, from the model itself (exact,
-- no physics needed - the same value SettleParkedJet uses).
local function measureGroundOffset(veh)
    local min = GetModelDimensions(GetEntityModel(veh))
    local h = -min.z + 0.05
    if h > 0.3 and h < 20.0 then return h end
    h = GetEntityHeightAboveGround(veh)
    if h > 0.3 and h < 20.0 then return h end
    return nil
end

local function drive(veh)
    local phase = LF.Timeline[F.phase]
    local t = phaseElapsed()
    local pos, tan, speed, ground = LF.EvalPhase(phase, t)

    if F.frozen then FreezeEntityPosition(veh, false); F.frozen = false end

    if not F.groundOffset then
        F.groundOffset = measureGroundOffset(veh) or 3.0
        if F.isController then TriggerServerEvent('lastflight:server:groundOffset', F.flightId, F.groundOffset) end
    end
    -- Route heights are wheel heights, so the wheel offset is added in the air
    -- too. (Without it the jet dropped into the runway at the liftoff point.)
    local z = pos.z + F.groundOffset
    if ground then
        local found, gz = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z + 5.0, false)
        z = (found and math.abs(gz - pos.z) < 6.0 and gz or pos.z) + F.groundOffset
    end

    local heading = LF.HeadingOf(tan)
    local dt = math.min(GetFrameTime(), 0.1)
    local targetPitch, targetRoll = 0.0, 0.0
    if not ground then
        targetPitch = math.deg(math.atan(tan.z, math.sqrt(tan.x * tan.x + tan.y * tan.y)))
        local _, tan2 = LF.EvalPhase(phase, t + 1.0)
        local yawRate = LF.AngleDiff(heading, LF.HeadingOf(tan2))
        targetRoll = math.max(-A.maxBank, math.min(A.maxBank, -yawRate * A.bankFactor * A.bankDirection))
    end
    F.pitch = lerp(F.pitch, targetPitch, math.min(1.0, dt * 1.5))
    F.roll  = lerp(F.roll, targetRoll, math.min(1.0, dt * 1.0))
    -- blends the small heading steps where one phase hands over to the next
    F.heading = F.heading or heading
    F.heading = (F.heading + LF.AngleDiff(F.heading, heading) * math.min(1.0, dt * 4.0)) % 360.0

    SetEntityCoordsNoOffset(veh, pos.x, pos.y, z, false, false, false)
    SetEntityRotation(veh, F.pitch, F.roll, F.heading, 2, true)
    SetEntityVelocity(veh, tan.x * speed, tan.y * speed, tan.z * speed)

    if not ground and not F.gearUp and GetEntityHeightAboveGround(veh) > A.gearUpHeight then
        ControlLandingGear(veh, 1)
        F.gearUp = true
    end
end

-- Puts the parked jet on the ground at its parking spot - but only once the
-- runway collision is loaded (otherwise it falls through the map). Also
-- brings it back if it drifted / sank. Returns true when done.
function LFC.SettleParkedJet(veh)
    local p = Config.Aircraft.parking
    RequestCollisionAtCoord(p.x, p.y, p.z)
    if not HasCollisionLoadedAroundEntity(veh) then
        FreezeEntityPosition(veh, true)
        return false
    end
    -- Never unfreeze a parked jet: physics on a 70 m plane that overlaps the
    -- ground even slightly shoves it violently (sparks, then it is flung away).
    -- Instead place it exactly: ground height + the model's own wheel height.
    FreezeEntityPosition(veh, true)
    local found, gz = GetGroundZFor_3dCoord(p.x, p.y, p.z + 5.0, false)
    if not found or math.abs(gz - p.z) > 6.0 then gz = p.z end
    local min = GetModelDimensions(GetEntityModel(veh))
    local z = gz - min.z + 0.05
    local pos = GetEntityCoords(veh)
    local flat = #(vector3(pos.x - p.x, pos.y - p.y, 0.0))
    if flat > 0.5 or math.abs(pos.z - z) > 0.3 then
        if flat > 8.0 then LF.Debug(('Parked jet was %.0fm off its spot - moving it back'):format(flat)) end
        SetEntityCoordsNoOffset(veh, p.x, p.y, z, false, false, false)
    end
    SetEntityRotation(veh, 0.0, 0.0, p.w, 2, true)
    SetEntityVelocity(veh, 0.0, 0.0, 0.0)
    return true
end

local function holdStill(veh)
    local parked = F.phase == nil or F.phase == S.BOARDING or F.phase == S.READY_CHECK
    if parked and not F.settled then
        if LFC.SettleParkedJet(veh) then F.settled = true end
    end
    if not F.frozen then
        FreezeEntityPosition(veh, true)
        F.frozen = true
    end
end

-- The jet's own GTA radio would play over the flight music. Passengers only, local.
local radioMuted = false
local function muteRadio(veh)
    SetVehRadioStation(veh, 'OFF')
    SetVehicleRadioEnabled(veh, false)
    SetRadioToStationName('OFF')
    SetUserRadioControlEnabled(false)
    SetMobileRadioEnabledDuringGameplay(false)
    radioMuted = true
end

table.insert(LFC.onCleanup, function()
    if radioMuted then
        SetUserRadioControlEnabled(true)
        radioMuted = false
    end
end)

local function protect(veh)
    SetEntityInvincible(veh, true)
    SetVehicleCanBeVisiblyDamaged(veh, false)
    SetVehicleExplodesOnHighExplosionDamage(veh, false)
    SetVehicleDoorsLocked(veh, 2)
    local pilot = GetPedInVehicleSeat(veh, -1)
    if pilot ~= 0 and not IsPedAPlayer(pilot) and NetworkHasControlOfEntity(pilot) then
        SetBlockingOfNonTemporaryEvents(pilot, true)
        SetPedCanBeDraggedOut(pilot, false)
        SetEntityInvincible(pilot, true)
    end
end

-- Per-frame owner loop
CreateThread(function()
    local lastProtect, lastMute = 0, 0
    while true do
        local veh = F.active and F.veh
        if veh and DoesEntityExist(veh) then
            if GetGameTimer() - lastMute > 2000 then
                lastMute = GetGameTimer()
                muteRadio(veh)
            end
            local owns = NetworkHasControlOfEntity(veh)
            if F.isController and not owns then NetworkRequestControlOfEntity(veh) end
            if owns then
                if GetGameTimer() - lastProtect > 2000 then
                    lastProtect = GetGameTimer()
                    protect(veh)
                    if F.isController and IsEntityDead(veh) then
                        TriggerServerEvent('lastflight:server:aircraftDestroyed', F.flightId)
                    end
                end
                if F.phase and LF.Moving[F.phase] then drive(veh) else holdStill(veh) end
            else
                F.frozen = false   -- re-freeze when we get ownership back
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- Scroll wheel = this player's music volume (only while the music plays).
-- Saved on the player's own PC so it's remembered next flight.
local musicLevel
do
    local ok, saved = pcall(GetResourceKvpInt, 'musicLevel')
    musicLevel = (ok and saved and saved > 0) and math.min(100, saved) or 100
    if ok and saved == -1 then musicLevel = 0 end
end

-- Only while you are actually aboard the jet and the music is playing
-- (takeoff, island loop, departure) - never on the shuttle or on foot.
local function onPlaneWithMusic()
    if not F.active or not F.musicStarted then return false end
    if F.phase ~= S.TAKEOFF and F.phase ~= S.CRUISING and F.phase ~= S.FINAL_DEPARTURE then return false end
    local veh = F.veh
    if not veh or not DoesEntityExist(veh) then return false end
    local ped = PlayerPedId()
    return GetVehiclePedIsIn(ped, false) == veh or IsEntityAttachedToEntity(ped, veh)
end

CreateThread(function()
    local sent = false
    while true do
        if onPlaneWithMusic() then
            if not sent then LFC.Nui('musicVolume', { level = musicLevel / 100 }); sent = true end
            -- the wheel would otherwise switch weapons / radio in the jet
            for _, c in ipairs({ 14, 15, 16, 17, 81, 82, 99, 100, 241, 242, 261, 262 }) do DisableControlAction(0, c, true) end
            local step = IsDisabledControlJustPressed(0, 241) and 5 or IsDisabledControlJustPressed(0, 242) and -5 or 0
            if step ~= 0 then
                musicLevel = math.max(0, math.min(100, musicLevel + step))
                pcall(SetResourceKvpInt, 'musicLevel', musicLevel == 0 and -1 or musicLevel)
                LFC.Nui('musicVolume', { level = musicLevel / 100, show = true })
            end
            Wait(0)
        else
            sent = false
            Wait(500)
        end
    end
end)

-- Controls + seat security + camera altitude switch + landmarks
CreateThread(function()
    local lastCheck = 0
    while true do
        if F.active then
            local ped = PlayerPedId()
            if F.locked then
                DisableControlAction(0, 75, true)    -- exit vehicle
                DisableControlAction(0, 23, true)    -- enter
                DisablePlayerFiring(PlayerId(), true)
            elseif F.mode == 'attach' and IsControlJustPressed(0, 75) then
                leaveAircraft()          -- attached passengers press F to get off before departure
            end

            if GetGameTimer() - lastCheck > 500 then
                lastCheck = GetGameTimer()
                local veh = resolveVeh()
                if veh and DoesEntityExist(veh) then
                    -- still seated?
                    local inside = F.mode == 'attach' and IsEntityAttachedToEntity(ped, veh) or IsPedInVehicle(ped, veh, false)
                    if not inside then
                        if F.locked then seatPlayer(veh, F.mode, F.seat)
                        elseif F.mode ~= 'attach' then leaveAircraft() end
                    end

                    -- third-person handover after the climb
                    if not F.thirdPerson and (F.phase == S.CRUISING or (F.phase == S.TAKEOFF and GetEntityHeightAboveGround(veh) > CIN.thirdPersonAltitude)) then
                        F.thirdPerson = true
                        F.camMode = defaultCamMode()
                        if F.camMode == 'gameplay' then
                            Cams.Stop(CIN.transitionTime)
                            SetFollowVehicleCamViewMode(2)
                        else
                            Cams.Mode(F.camMode, veh)
                        end
                    end

                    -- landmark shots (only interrupt the default free-look, never a chosen view)
                    if F.phase == S.CRUISING and F.thirdPerson then
                        local pos = GetEntityCoords(veh)
                        for i, w in ipairs(SF.waypoints) do
                            if not F.landmarksDone[i] and #(pos - w.pos) < CIN.landmarkRadius then
                                F.landmarksDone[i] = true
                                if w.label then LFC.Nui('landmark', { label = w.label }) end
                                if w.camera == 'landmark' and SF.enableLandmarkCameras and CIN.enabled
                                    and F.camMode == defaultCamMode() and not F.inLandmark then
                                    F.inLandmark = true
                                    local mode = F.camMode
                                    Cams.Landmark(veh, function()
                                        F.inLandmark = false
                                        if F.active and F.camMode == mode then Cams.Mode(mode, veh) end
                                    end)
                                end
                            end
                        end
                        local remaining = (LF.Timeline.CRUISING.duration - phaseElapsed()) + LF.Timeline.FINAL_DEPARTURE.duration
                        LFC.Nui('hudTime', { remaining = math.max(0, math.floor(remaining)) })
                    end
                end
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

---------------------------------------------------------------------------
-- Everyone (not just passengers): keep the parked jet from rolling/sinking
-- when an unrelated player happens to own it.
---------------------------------------------------------------------------
CreateThread(function()
    local settled = nil      -- entity handle we already placed on the ground while owning it
    while true do
        Wait(2000)
        local gs = GlobalState.lastflight
        if gs and gs.netId and not F.active and (gs.state == S.BOARDING or gs.state == S.READY_CHECK)
            and NetworkDoesNetworkIdExist(gs.netId) then
            local veh = NetToVeh(gs.netId)
            if veh ~= 0 and NetworkHasControlOfEntity(veh) then
                local p = Config.Aircraft.parking
                local pos = GetEntityCoords(veh)
                if #(vector3(pos.x - p.x, pos.y - p.y, 0.0)) > 8.0 or pos.z < p.z - 3.0 then
                    settled = nil                      -- drifted / fell: settle it again
                end
                if settled ~= veh then
                    if LFC.SettleParkedJet(veh) then settled = veh end
                end
                FreezeEntityPosition(veh, true)
                SetEntityInvincible(veh, true)
                SetVehicleDoorsLocked(veh, 2)
            else
                settled = nil
            end
        end
    end
end)
