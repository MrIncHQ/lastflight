-- Local scripted cameras. Only ever created on a passenger's own client.

Cams = {}

local CIN = Config.Cinematics
local active = {}      -- cams we own
local current          -- currently rendered cam
local token = 0        -- bumps to cancel running sequences
local rendering = false

local function newCam(fov)
    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    if not cam or cam == 0 then return nil end
    SetCamFov(cam, fov or 50.0)
    active[#active + 1] = cam
    return cam
end

local function destroy(cam)
    if not cam then return end
    if DoesCamExist(cam) then DestroyCam(cam, false) end
    for i = #active, 1, -1 do
        if active[i] == cam then table.remove(active, i) end
    end
end

-- Blend from the current cam (or gameplay) into `cam`.
local function show(cam, blendMs)
    blendMs = blendMs or CIN.transitionTime
    if not rendering then
        SetCamActive(cam, true)
        RenderScriptCams(true, blendMs > 0, blendMs, true, false)
        rendering = true
    elseif current and DoesCamExist(current) then
        SetCamActiveWithInterp(cam, current, blendMs, 1, 1)
        local old = current
        SetTimeout(blendMs + 100, function() if old ~= current then destroy(old) end end)
    else
        SetCamActive(cam, true)
    end
    current = cam
end

function Cams.IsRendering() return rendering end

-- Return to the player's normal gameplay camera.
function Cams.Stop(blendMs)
    token = token + 1
    if rendering then
        RenderScriptCams(false, (blendMs or 0) > 0, blendMs or 0, true, false)
    end
    rendering = false
    current = nil
    local list = active
    active = {}
    SetTimeout((blendMs or 0) + 100, function()
        for _, cam in ipairs(list) do
            if DoesCamExist(cam) then DestroyCam(cam, false) end
        end
    end)
end

local function runwayFrame()
    local h = Config.Aircraft.holdPoint
    local fwd = LF.RunwayDir()
    local right = vector3(fwd.y, -fwd.x, 0.0)
    return vector3(h.x, h.y, h.z), fwd, right
end

local function buildShot(shot, veh)
    local cam = newCam(shot.fov)
    if not cam then return nil end
    if shot.type == 'runway' then
        local origin, fwd, right = runwayFrame()
        local p = origin + fwd * (shot.along or 0.0) + right * (shot.side or 0.0)
        SetCamCoord(cam, p.x, p.y, p.z + (shot.height or 3.0))
    else
        local o = shot.offset
        AttachCamToEntity(cam, veh, o.x, o.y, o.z, true)
    end
    PointCamAtEntity(cam, veh, 0.0, 0.0, 0.0, true)
    return cam
end

-- Plays a list of shots once (or looping) around the vehicle. Cancelled by Cams.Stop / any new sequence.
function Cams.Sequence(shots, veh, loop, until_fn)
    if not CIN.enabled or not shots or #shots == 0 then return end
    token = token + 1
    local my = token
    CreateThread(function()
        repeat
            for _, shot in ipairs(shots) do
                if token ~= my or not DoesEntityExist(veh) then return end
                if until_fn and until_fn() then return end
                local ok, cam = pcall(buildShot, shot, veh)
                if ok and cam then show(cam) end
                local endAt = GetGameTimer() + (shot.duration or 6000)
                while GetGameTimer() < endAt do
                    if token ~= my then return end
                    if until_fn and until_fn() then return end
                    Wait(100)
                end
            end
        until not loop
    end)
end

---------------------------------------------------------------------------
-- Passenger-selectable views during the scenic flight
---------------------------------------------------------------------------
Cams.modes = { 'gameplay', 'orbit', 'wing', 'chase', 'flyby' }
Cams.modeLabels = { gameplay = 'Free look', orbit = 'Orbit', wing = 'Wing view', chase = 'Chase', flyby = 'Fly-by' }

function Cams.Mode(mode, veh)
    token = token + 1
    local my = token
    if mode == 'gameplay' then
        Cams.Stop(CIN.transitionTime)
        return
    end
    local cam = newCam(mode == 'flyby' and 40.0 or 55.0)
    if not cam then return Cams.Stop(0) end

    if mode == 'wing' then
        AttachCamToEntity(cam, veh, 22.0, -6.0, 2.5, true)
        PointCamAtEntity(cam, veh, 0.0, 120.0, -10.0, true)
        show(cam)
    elseif mode == 'chase' then
        AttachCamToEntity(cam, veh, 0.0, -95.0, 22.0, true)
        PointCamAtEntity(cam, veh, 0.0, 10.0, 0.0, true)
        show(cam)
    elseif mode == 'orbit' then
        show(cam)
        CreateThread(function()
            local a = 0.0
            while token == my and DoesEntityExist(veh) do
                a = a + GetFrameTime() * 0.12
                AttachCamToEntity(cam, veh, math.cos(a) * 110.0, math.sin(a) * 110.0, 25.0, true)
                PointCamAtEntity(cam, veh, 0.0, 0.0, 0.0, true)
                Wait(0)
            end
        end)
    elseif mode == 'flyby' then
        -- drop a static camera ahead of the jet, let it pass, repeat
        show(cam)
        CreateThread(function()
            while token == my and DoesEntityExist(veh) do
                local fwd = GetEntityForwardVector(veh)
                local pos = GetEntityCoords(veh)
                local right = vector3(fwd.y, -fwd.x, 0.0)
                local p = pos + fwd * 450.0 + right * 70.0
                SetCamCoord(cam, p.x, p.y, p.z - 15.0)
                PointCamAtEntity(cam, veh, 0.0, 0.0, 0.0, true)
                local endAt = GetGameTimer() + 14000
                while GetGameTimer() < endAt and token == my do Wait(200) end
            end
        end)
    end
end

-- Short wide shot of a landmark; calls done() when finished (unless cancelled).
function Cams.Landmark(veh, done)
    token = token + 1
    local my = token
    local cam = newCam(55.0)
    if not cam then return done and done() end
    local fwd = GetEntityForwardVector(veh)
    local pos = GetEntityCoords(veh)
    local right = vector3(fwd.y, -fwd.x, 0.0)
    local p = pos + fwd * 650.0 + right * 320.0
    SetCamCoord(cam, p.x, p.y, p.z - 60.0)
    PointCamAtEntity(cam, veh, 0.0, 0.0, 0.0, true)
    show(cam)
    CreateThread(function()
        local endAt = GetGameTimer() + CIN.landmarkShotDuration * 1000
        while GetGameTimer() < endAt do
            if token ~= my then return end
            Wait(100)
        end
        if token == my and done then done() end
    end)
end

-- Final farewell: a fixed camera that the jet flies away from, slowly widening.
function Cams.Final(veh, durationSec)
    token = token + 1
    local my = token
    local cam = newCam(CIN.finalCamFovStart)
    if not cam then return end
    local fwd = GetEntityForwardVector(veh)
    local pos = GetEntityCoords(veh)
    local right = vector3(fwd.y, -fwd.x, 0.0)
    local p = pos - fwd * 120.0 + right * 60.0
    SetCamCoord(cam, p.x, p.y, p.z + 25.0)
    PointCamAtEntity(cam, veh, 0.0, 0.0, 0.0, true)
    show(cam, 2500)
    CreateThread(function()
        local start = GetGameTimer()
        local dur = math.max(1.0, durationSec) * 1000
        while token == my do
            local f = math.min(1.0, (GetGameTimer() - start) / dur)
            SetCamFov(cam, CIN.finalCamFovStart + (CIN.finalCamFovEnd - CIN.finalCamFovStart) * f)
            if f >= 1.0 then break end
            Wait(0)
        end
    end)
end

table.insert(LFC.onCleanup, function() Cams.Stop(0) end)
