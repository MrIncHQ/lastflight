-- Props placed by admins (setup panel -> PROPS tab), e.g. a little party area.
-- The server saves them and shares the list via GlobalState.lf_props; every
-- client spawns its own local (non-networked) copy when it is close enough.
--
-- Placing: a see-through hologram follows the mouse cursor (hold right mouse to
-- look around), mouse wheel rotates, Up / Down arrows raise / lower, E or left
-- click places (hold Shift to keep placing), Backspace cancels.

local PC = Config.Props or {}
local CATALOG = {}
for _, c in ipairs(PC.list or {}) do CATALOG[c.model] = c end

local current = GlobalState.lf_props or {}
local spawned = {}   -- id -> entity (false = model failed to load)
local sig     = {}   -- id -> "model x y z h" the entity was spawned with
local hidden  = {}   -- id -> true while that prop is being moved
local dirty   = true
local P = nil        -- the prop being placed / moved right now

local TEXT = '__text'

local function list() return current or {} end

local function find(id)
    id = tonumber(id)
    for _, p in ipairs(list()) do
        if p.id == id then return p end
    end
end

local function labelOf(p)
    if p.model == TEXT then return 'Sign: ' .. (p.text or '') end
    local c = CATALOG[p.model]
    return c and c.label or p.model
end

local function loadModel(hash)
    if not IsModelInCdimage(hash) then return false end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

local function drawSign(x, y, z, text, dist)
    SetTextScale(0.0, math.max(0.35, 0.85 - dist * 0.015))
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 235)
    SetTextOutline()
    SetTextCentre(true)
    SetDrawOrigin(x, y, z, 0)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

---------------------------------------------------------------------------
-- Spawning the saved props near the player
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Drinks: props with drink = '...' in Config.Props get "Pour a glass" (ox_target)
---------------------------------------------------------------------------
local GLASS = {
    champagne = { model = 'prop_drink_champ',     label = 'champagne' },
    cocktail  = { model = 'prop_cocktail_glass',  label = 'cocktail' },
    beer      = { model = 'prop_amb_beer_bottle', label = 'beer' },
    whisky    = { model = 'prop_drink_whisky',    label = 'whisky' },
}
local drinking = false

local function haveDrink(kind)
    if drinking then return end
    local g = GLASS[kind] or GLASS.champagne
    drinking = true
    CreateThread(function()
        local ped = PlayerPedId()
        local hash = joaat(g.model)
        local dict, anim = 'mp_player_intdrink', 'loop_bottle'
        RequestAnimDict(dict)
        local deadline = GetGameTimer() + 3000
        while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do Wait(10) end
        if not loadModel(hash) or not HasAnimDictLoaded(dict) then drinking = false return end
        LFC.Notify(('You pour yourself a %s. Cheers!'):format(g.label), 'success')
        local c = GetEntityCoords(ped)
        local glass = CreateObject(hash, c.x, c.y, c.z + 0.2, false, false, false)
        SetEntityCollision(glass, false, false)
        AttachEntityToEntity(glass, ped, GetPedBoneIndex(ped, 18905), 0.12, 0.008, 0.03, 240.0, -60.0, 0.0,
            true, true, false, true, 1, true)
        TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 49, 0, false, false, false)
        Wait(6000)
        StopAnimTask(ped, dict, anim, 1.0)
        if DoesEntityExist(glass) then DeleteEntity(glass) end
        SetModelAsNoLongerNeeded(hash)
        RemoveAnimDict(dict)
        drinking = false
    end)
end

local function hasTarget() return GetResourceState('ox_target') == 'started' end

local function despawn(id)
    local e = spawned[id]
    if e and DoesEntityExist(e) then
        if hasTarget() then pcall(function() exports.ox_target:removeLocalEntity(e, 'lastflight_drink') end) end
        DeleteEntity(e)
    end
    spawned[id], sig[id] = nil, nil
end

local function spawnProp(p)
    local hash = joaat(p.model)
    if not loadModel(hash) then spawned[p.id] = false return end
    local e = CreateObjectNoOffset(hash, p.x, p.y, p.z, false, false, false)
    SetEntityHeading(e, p.h + 0.0)
    FreezeEntityPosition(e, true)
    SetEntityInvincible(e, true)
    SetModelAsNoLongerNeeded(hash)
    local c = CATALOG[p.model]
    if c and c.drink and hasTarget() then
        local kind = c.drink
        exports.ox_target:addLocalEntity(e, {{
            name = 'lastflight_drink',
            label = ('Pour a glass of %s'):format((GLASS[kind] or GLASS.champagne).label),
            icon = 'fa-solid fa-champagne-glasses',
            distance = 2.0,
            canInteract = function() return not drinking and not IsPedInAnyVehicle(PlayerPedId(), false) end,
            onSelect = function() haveDrink(kind) end,
        }})
    end
    spawned[p.id] = e
    sig[p.id] = ('%s %.3f %.3f %.3f %.2f'):format(p.model, p.x, p.y, p.z, p.h)
end

AddStateBagChangeHandler('lf_props', 'global', function(_, _, value)
    current = value or {}
    dirty = true
    if LFC.SetupPush then LFC.SetupPush() end
end)

CreateThread(function()
    while true do
        if PC.enabled ~= false then
            local props = list()
            if dirty then
                dirty = false
                -- drop props that were deleted or moved, they respawn below
                local byId = {}
                for _, p in ipairs(props) do byId[p.id] = p end
                for id in pairs(spawned) do
                    local p = byId[id]
                    if not p or sig[id] ~= ('%s %.3f %.3f %.3f %.2f'):format(p.model, p.x, p.y, p.z, p.h) then despawn(id) end
                end
            end
            local me = GetEntityCoords(PlayerPedId())
            local range = PC.spawnDistance or 150.0
            for _, p in ipairs(props) do
                if p.model ~= TEXT then
                    local near = #(me - vector3(p.x, p.y, p.z)) < range
                    if near and not hidden[p.id] then
                        if spawned[p.id] == nil then spawnProp(p) end
                    elseif spawned[p.id] ~= nil then
                        despawn(p.id)
                    end
                end
            end
        end
        -- check every second, sooner when something changed
        for _ = 1, 10 do
            if dirty then break end
            Wait(100)
        end
    end
end)

---------------------------------------------------------------------------
-- Party music: loops from the music center, fades out with distance
---------------------------------------------------------------------------
local MUS = PC.music or {}
local partyMusic = GlobalState.lf_partyMusic
local musicOn = false

local function musicStop()
    if musicOn then LFC.Nui('partyMusic', { stop = true }) end
    musicOn = false
end

AddStateBagChangeHandler('lf_partyMusic', 'global', function(_, _, value)
    partyMusic = value
    musicStop()            -- restarts from the new spot (or stays off) on the next check
    if LFC.SetupPush then LFC.SetupPush() end
end)

-- volume from the slider in the PROPS tab (saved on the server); falls back to config
local partyVolume = GlobalState.lf_partyVolume
AddStateBagChangeHandler('lf_partyVolume', 'global', function(_, _, value)
    partyVolume = value
    if LFC.SetupPush then LFC.SetupPush() end
end)
local function baseVolume() return tonumber(partyVolume) or MUS.volume or 0.4 end

CreateThread(function()
    while true do
        local sleep = 1000
        local m = partyMusic
        if m and MUS.file and PC.enabled ~= false then
            local d = #(GetEntityCoords(PlayerPedId()) - vector3(m.x, m.y, m.z))
            local full, silent = MUS.fullUpTo or 15.0, MUS.silentAt or 45.0
            -- the flight and the highway drive have their own music
            local busy = (LFC.InFlight and LFC.InFlight()) or (LFC.InTour and LFC.InTour())
            if d < silent and not busy then
                sleep = 200
                local f = d <= full and 1.0 or math.max(0.0, 1.0 - (d - full) / (silent - full))
                -- squared: matches how loud it sounds (a linear 40% still sounds loud), and eases out
                local b = baseVolume()
                local vol = b * b * f * f
                if not musicOn then
                    musicOn = true
                    LFC.Nui('partyMusic', { file = MUS.file, volume = vol,
                        elapsed = math.max(0, GetCloudTimeAsInt() - (m.startedAt or 0)) })
                else
                    LFC.Nui('partyMusic', { volume = vol })
                end
            else
                musicStop()
            end
        else
            musicStop()
        end
        Wait(sleep)
    end
end)

-- 3D text signs (+ the music center marker while the setup panel is open)
CreateThread(function()
    while true do
        local sleep = 1000
        if PC.enabled ~= false then
            local me = GetEntityCoords(PlayerPedId())
            local m = partyMusic
            if m and LFC.SetupIsOpen and LFC.SetupIsOpen() and #(me - vector3(m.x, m.y, m.z)) < 60.0 then
                sleep = 0
                DrawMarker(1, m.x, m.y, m.z - 1.0, 0, 0, 0, 0, 0, 0, 1.0, 1.0, 0.6, 255, 61, 139, 160, false, false, 2, false, nil, nil, false)
                drawSign(m.x, m.y, m.z + 0.3, 'Party music', #(me - vector3(m.x, m.y, m.z)))
            end
            local range = PC.textDistance or 30.0
            for _, p in ipairs(list()) do
                if p.model == TEXT and p.text and not hidden[p.id] then
                    local d = #(me - vector3(p.x, p.y, p.z))
                    if d < range then
                        sleep = 0
                        drawSign(p.x, p.y, p.z, p.text, d)
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

---------------------------------------------------------------------------
-- Placing / moving (hologram)
---------------------------------------------------------------------------
local function stopPlacing()
    if not P then return end
    if P.ghost and DoesEntityExist(P.ghost) then DeleteEntity(P.ghost) end
    if P.hash then SetModelAsNoLongerNeeded(P.hash) end
    local id = P.moveId
    P = nil
    if id then
        -- keep the old copy hidden until the server's update has arrived
        SetTimeout(1500, function() hidden[id] = nil; dirty = true end)
    end
    if LFC.SetupPush then LFC.SetupPush() end
end
LFC.PropsCancel = stopPlacing
function LFC.PropsPlacing() return P ~= nil end

local function groundAt(x, y, z)
    local found, gz = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
    return found and gz or (z - 1.0)
end

local function startPlacing(model, text, moveId)
    stopPlacing()
    local hash, baseZ = nil, 1.5   -- text signs float 1.5 m above the ground
    if model ~= TEXT then
        hash = joaat(model)
        if not loadModel(hash) then
            return LFC.Notify(('"%s" was not found in the game. Check the model name.'):format(model), 'error')
        end
        local mn = GetModelDimensions(hash)
        baseZ = -mn.z                 -- puts the bottom of the prop on the ground
    end
    local ped = PlayerPedId()
    P = { model = model, hash = hash, text = text, baseZ = baseZ, heading = GetEntityHeading(ped), height = 0.0, dist = 3.0, moveId = moveId }
    if moveId then
        local p = find(moveId)
        if p then
            local gz = groundAt(p.x, p.y, p.z)
            P.heading = p.h
            P.height = math.max(-3.0, math.min(15.0, p.z - (gz + baseZ)))
            P.spot = vector3(p.x, p.y, gz)
            P.waitMouse = true   -- stay on the old spot until the mouse moves
        end
        hidden[moveId] = true
        dirty = true
    end
    if hash then
        local c = GetEntityCoords(ped)
        local g = CreateObjectNoOffset(hash, c.x, c.y, c.z - 50.0, false, false, false)
        SetEntityAlpha(g, 160, false)
        SetEntityCollision(g, false, false)
        FreezeEntityPosition(g, true)
        SetEntityInvincible(g, true)
        P.ghost = g
    end
    if LFC.SetupFocus then LFC.SetupFocus(false) end
    LFC.Notify(moveId and 'Moving the prop: point with the mouse, E or click to put it down, Backspace to cancel.'
        or 'Placing the prop: point with the mouse, E or click to place, Backspace to cancel.', 'info')
end

-- Mouse cursor -> point in the world: a ray from the camera through the cursor
local function cross(a, b)
    return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end
local function unit(v)
    local l = #v
    return l > 0 and v / l or v
end

local function cursorRay()
    local camPos, rot = GetGameplayCamCoord(), GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local fwd = vector3(-math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx))
    local right = unit(cross(fwd, vector3(0.0, 0.0, 1.0)))
    local up = cross(right, fwd)
    local w, h = GetActiveScreenResolution()
    local tanV = math.tan(math.rad(GetGameplayCamFov()) / 2)     -- GTA's FOV is vertical
    local tanH = tanV * (w / h)
    local cx, cy = GetDisabledControlNormal(0, 239), GetDisabledControlNormal(0, 240)
    local dir = unit(fwd + right * ((cx * 2 - 1) * tanH) + up * ((1 - cy * 2) * tanV))
    return camPos, dir
end

-- where the cursor points: hits the ground, buildings and props (not you or the hologram)
local function cursorHit()
    local from, dir = cursorRay()
    local to = from + dir * 60.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 + 16, PlayerPedId(), 4)
    local _, hit, pos = GetShapeTestResult(ray)
    if hit == 1 then return pos end
end

local BLOCK = { 1, 2, 14, 15, 16, 17, 24, 25, 36, 37, 38, 44, 51, 68, 69, 70, 91, 92, 106, 114, 140, 141, 142,
                172, 173, 174, 175, 177, 199, 239, 240, 241, 242, 257, 261, 262, 263, 264 }

CreateThread(function()
    while true do
        if not P then
            Wait(250)
        elseif LFC.focus or not (LFC.SetupIsOpen and LFC.SetupIsOpen()) then
            stopPlacing()           -- panel reopened or closed: cancel
        else
            for _, c in ipairs(BLOCK) do DisableControlAction(0, c, true) end
            -- hold right mouse to look around; otherwise the mouse moves a cursor
            local looking = IsDisabledControlPressed(0, 25)
            if looking then
                EnableControlAction(0, 1, true)
                EnableControlAction(0, 2, true)
            else
                SetMouseCursorActiveThisFrame()
            end
            local ped = PlayerPedId()

            -- mouse wheel rotates (hold Ctrl for fine steps)
            local step = IsDisabledControlPressed(0, 36) and 1.0 or 7.5
            if IsDisabledControlJustPressed(0, 241) then P.heading = (P.heading + step) % 360 end
            if IsDisabledControlJustPressed(0, 242) then P.heading = (P.heading - step) % 360 end
            -- arrows: up / down = height
            if IsDisabledControlPressed(0, 172) then P.height = math.min(15.0, P.height + 0.02) end
            if IsDisabledControlPressed(0, 173) then P.height = math.max(-3.0, P.height - 0.02) end

            -- follow the cursor (stays put while looking around or pointing at the sky)
            -- (only once the mouse moves, so Move starts exactly where the prop was)
            if not looking then
                local cx, cy = GetDisabledControlNormal(0, 239), GetDisabledControlNormal(0, 240)
                if P.waitMouse then
                    P.waitMouse, P.cx, P.cy = false, cx, cy
                elseif not P.cx or math.abs(cx - P.cx) + math.abs(cy - P.cy) > 0.002 then
                    P.cx, P.cy = cx, cy
                    local hit = cursorHit()
                    if hit and #(hit - GetEntityCoords(ped)) < 50.0 then P.spot = hit end
                end
            end
            if not P.spot then
                local pc, fwd = GetEntityCoords(ped), GetEntityForwardVector(ped)
                P.spot = vector3(pc.x + fwd.x * 3.0, pc.y + fwd.y * 3.0, groundAt(pc.x + fwd.x * 3.0, pc.y + fwd.y * 3.0, pc.z))
            end
            local pc = GetEntityCoords(ped)
            local x, y = P.spot.x, P.spot.y
            local z = P.spot.z + P.baseZ + P.height

            if P.ghost then
                SetEntityCoordsNoOffset(P.ghost, x, y, z, false, false, false)
                SetEntityHeading(P.ghost, P.heading)
            else
                drawSign(x, y, z, P.text or '', #(pc - vector3(x, y, z)))
            end
            DrawMarker(25, x, y, z - P.baseZ - P.height + 0.03, 0, 0, 0, 0, 0, 0, 0.8, 0.8, 0.8, 24, 209, 197, 150, false, false, 2, false, nil, nil, false)

            LFC.HelpText(('Mouse: point where it goes~n~~INPUT_AIM~ Hold to look around~n~~INPUT_CURSOR_SCROLL_UP~ ~INPUT_CURSOR_SCROLL_DOWN~ Rotate (Ctrl = fine)~n~~INPUT_CELLPHONE_UP~ ~INPUT_CELLPHONE_DOWN~ Up / down  %.2f m~n~~INPUT_PICKUP~ or ~INPUT_ATTACK~ Place%s~n~~INPUT_CELLPHONE_CANCEL~ Cancel')
                :format(P.height, P.moveId and '' or '~n~Hold Shift to keep placing'))

            if IsDisabledControlJustPressed(0, 38) or (not looking and IsDisabledControlJustPressed(0, 24)) then
                local d = { model = P.model, text = P.text, x = x, y = y, z = z, h = P.heading }
                PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                if P.moveId then
                    TriggerServerEvent('lastflight:server:propMove', P.moveId, d)
                    stopPlacing()
                else
                    TriggerServerEvent('lastflight:server:propAdd', d)
                    if not IsControlPressed(0, 21) then
                        stopPlacing()
                        LFC.Notify(('Placed. %s opens the panel again.'):format(Config.Admin.setupKey), 'success')
                    end
                end
            elseif IsDisabledControlJustPressed(0, 177) then
                PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                stopPlacing()
            end
            Wait(0)
        end
    end
end)

---------------------------------------------------------------------------
-- Setup panel (PROPS tab)
---------------------------------------------------------------------------
local catalog
function LFC.PropsPanel()
    if not catalog then
        catalog = {}
        for _, c in ipairs(PC.list or {}) do
            catalog[#catalog + 1] = { model = c.model, label = c.label or c.model, group = c.group or 'Props',
                ok = c.model == TEXT or IsModelInCdimage(joaat(c.model)) }
        end
    end
    local me = GetEntityCoords(PlayerPedId())
    local placed = {}
    for _, p in ipairs(list()) do
        placed[#placed + 1] = { id = p.id, label = labelOf(p), dist = math.floor(#(me - vector3(p.x, p.y, p.z))) }
    end
    table.sort(placed, function(a, b) return a.dist < b.dist end)
    local m = partyMusic
    return { enabled = PC.enabled ~= false, catalog = catalog, placed = placed, max = PC.max or 200,
        music = MUS.file and { set = m ~= nil, dist = m and math.floor(#(me - vector3(m.x, m.y, m.z))) or nil,
            volume = math.floor(baseVolume() * 100 + 0.5) } or nil }
end

RegisterNUICallback('propAction', function(data, cb)
    cb(1)
    if not (LFC.SetupIsOpen and LFC.SetupIsOpen()) then return end
    local a = data.action
    CreateThread(function()
        if a == 'place' then
            local model = tostring(data.model or ''):gsub('%s', '')
            if model == '' then return LFC.Notify('Pick a prop from the list (or type a model name) first.', 'error') end
            if model == TEXT then
                local text = tostring(data.text or ''):sub(1, 60)
                if text:match('^%s*$') then return LFC.Notify('Type the text for the sign first.', 'error') end
                startPlacing(TEXT, text)
            else
                startPlacing(model)
            end
        elseif a == 'move' then
            local p = find(data.id)
            if p then startPlacing(p.model, p.text, p.id) end
        elseif a == 'delete' then
            TriggerServerEvent('lastflight:server:propDelete', tonumber(data.id))
        elseif a == 'go' then
            local p = find(data.id)
            if p then
                if LFC.SetupFocus then LFC.SetupFocus(false) end
                LFC.Teleport(vector4(p.x, p.y, p.z + 1.0, GetEntityHeading(PlayerPedId())), true)
            end
        elseif a == 'clear' then
            TriggerServerEvent('lastflight:server:propClear')
        elseif a == 'musicHere' then
            local c = GetEntityCoords(PlayerPedId())
            TriggerServerEvent('lastflight:server:partyMusicSet', { x = c.x, y = c.y, z = c.z })
        elseif a == 'musicGo' and partyMusic then
            if LFC.SetupFocus then LFC.SetupFocus(false) end
            LFC.Teleport(vector4(partyMusic.x, partyMusic.y, partyMusic.z, GetEntityHeading(PlayerPedId())), true)
        elseif a == 'musicVolume' then
            local v = tonumber(data.volume)
            if v then TriggerServerEvent('lastflight:server:partyMusicVolume', math.max(0, math.min(100, v)) / 100) end
        elseif a == 'musicOff' then
            TriggerServerEvent('lastflight:server:partyMusicClear')
        elseif a == 'refresh' then
            if LFC.SetupPush then LFC.SetupPush() end
        end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(spawned) do despawn(id) end
    if P and P.ghost and DoesEntityExist(P.ghost) then DeleteEntity(P.ghost) end
    musicStop()
end)
