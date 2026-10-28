-- In-game location editor (/lastflight setup). Admin only - the server checks
-- the ACE before opening it and again before saving.
--
-- The draft lives here; the NUI just renders it and sends button presses.

local Setup = {
    open = false, focused = false, draft = nil, original = nil, defaults = nil,
    saved = false, busy = false, dirty = false, active = nil, auto = false, route = '',
}

local FIELDS = {
    { key = 'cityNpc',        group = 'City pickup', kind = 'vec4', label = 'Taxi driver NPC (city)',
      hint = 'Stand where the driver NPC should wait (default Legion Square), facing the players.' },
    { key = 'citySpawn',      group = 'City pickup', kind = 'vec4', ground = true, label = 'Taxi spawn',
      hint = 'Near the NPC. The taxi snaps to the closest road, so anywhere by the curb works.' },
    { key = 'cityRoute',      group = 'City pickup', kind = 'list', ground = true, label = 'Taxi route (via points)',
      hint = 'Optional. Leave empty and the driver picks his own route to the airport.' },
    { key = 'cityDropoff',    group = 'City pickup', kind = 'vec3', ground = true, label = 'Airport drop-off',
      hint = 'Where the taxi lets players out at LSIA (by the check-in desk).' },

    { key = 'tourSpawn',      group = 'Highway drive', kind = 'vec4', ground = true, label = 'Farewell car pickup',
      hint = 'Sit in a car where the first farewell car should wait, facing the way it leaves. Extra convoy cars line up behind it. Players start it from the city NPC (G).' },
    { key = 'tourRoute',      group = 'Highway drive', kind = 'list', ground = true, label = 'Highway loop (via points)', spacing = 150.0,
      hint = 'Clear it, then Record with Auto on and drive the exact roads you want from the pickup onto the highway and all the way around (a point every 150 m). The driver follows your points.' },
    { key = 'tourDropoff',    group = 'Highway drive', kind = 'vec3', ground = true, label = 'Highway drive drop-off',
      hint = 'Where the farewell cars let players out at the end (by the check-in desk).' },

    { key = 'npc',           group = 'Airport',  kind = 'vec4', label = 'Check-in desk agent',
      hint = 'Stand where the agent should stand, facing the customers.' },
    { key = 'safeReturn',     group = 'Airport',  kind = 'vec4', label = 'Return / test-mode spawn',
      hint = 'Where removed passengers and test-mode flyers are placed.' },
    { key = 'boardingPoint',  group = 'Airport',  kind = 'vec3', ground = true, label = 'Boarding marker',
      hint = 'Beside the parked jet - players press E here to board.' },

    { key = 'shuttleSpawn',   group = 'Shuttle',  kind = 'vec4', ground = true, label = 'Shuttle pickup',
      hint = 'Sit in a car where the shuttle should wait, facing the way it leaves.' },
    { key = 'shuttleRoute',   group = 'Shuttle',  kind = 'list', ground = true, label = 'Shuttle route (via points)',
      hint = 'Optional. Points the shuttle drives through on the way to the drop-off.' },
    { key = 'shuttleDropoff', group = 'Shuttle',  kind = 'vec3', ground = true, label = 'Shuttle drop-off',
      hint = 'Where the shuttle stops and lets the passenger out (near the boarding marker).' },

    { key = 'parking',        group = 'Aircraft', kind = 'vec4', ground = true, label = 'Jet spawn (parking)',
      hint = 'Stand / drive where the jet should park, facing the way the nose points.' },
    { key = 'taxiRoute',      group = 'Aircraft', kind = 'list', ground = true, label = 'Taxi route to runway',
      hint = 'Drive the taxiway from the parking spot to the runway. Auto-record makes this easy.' },
    { key = 'holdPoint',      group = 'Aircraft', kind = 'vec4', ground = true, label = 'Runway start (hold point)',
      hint = 'On the runway centre line where the takeoff roll starts.' },
    { key = 'liftoffPoint',   group = 'Aircraft', kind = 'vec3', ground = true, label = 'Liftoff point',
      hint = 'Further down the same runway (300 m+). Sets the takeoff direction.' },
}
local FIELD = {}
for _, f in ipairs(FIELDS) do FIELD[f.key] = f end

local function copy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

local function round(n, d) local m = 10 ^ (d or 2); return math.floor(n * m + 0.5) / m end

local function capture(field)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local ent = (field.ground and veh ~= 0) and veh or ped
    local c, h = GetEntityCoords(ent), GetEntityHeading(ent)
    local z = c.z
    if field.ground then
        local found, gz = GetGroundZFor_3dCoord(c.x, c.y, c.z + 1.0, false)
        z = found and gz or (c.z - 1.0)
    end
    local p = { x = round(c.x), y = round(c.y), z = round(z) }
    if field.kind == 'vec4' then p.w = round(h, 1) end
    return p
end

local function vec(p) return vector3(p.x, p.y, p.z) end

---------------------------------------------------------------------------
-- State -> NUI
---------------------------------------------------------------------------
local function stats()
    local d = Setup.draft
    local s = {}
    if d.holdPoint and d.liftoffPoint then
        local a, b = vec(d.holdPoint), vec(d.liftoffPoint)
        s.roll = math.floor(#(vector3(b.x, b.y, 0) - vector3(a.x, a.y, 0)))
    end
    local taxi = 0
    local prev = d.parking and vec(d.parking)
    for _, p in ipairs(d.taxiRoute or {}) do
        if prev then taxi = taxi + #(vec(p) - prev) end
        prev = vec(p)
    end
    if prev and d.holdPoint then taxi = taxi + #(vec(d.holdPoint) - prev) end
    s.taxi = math.floor(taxi)
    return s
end

local function push()
    if not Setup.open then return end
    LFC.Nui('setup', {
        show = true, fields = FIELDS, draft = Setup.draft, saved = Setup.saved, busy = Setup.busy,
        dirty = Setup.dirty, active = Setup.active, auto = Setup.auto, insert = Setup.insert, route = Setup.route,
        focused = Setup.focused, stats = stats(),
        mode = Setup.mode, modes = LF.Modes, modeOrder = LF.ModeOrder, returnTo = Setup.returnTo,
        keys = { panel = Config.Admin.setupKey, point = Config.Admin.setupPointKey },
        spacing = Config.Admin.autoRecordSpacing,
    })
end

local function setFocus(state)
    Setup.focused = state
    LFC.Focus(state)
    push()
end

local function changed()
    Setup.dirty = true
    push()
end

-- Where each route starts and ends (used to place inserted points)
local ROUTE_ENDS = {
    cityRoute    = { 'citySpawn', 'cityDropoff' },
    tourRoute    = { 'tourSpawn', 'tourDropoff' },
    shuttleRoute = { 'shuttleSpawn', 'shuttleDropoff' },
    taxiRoute    = { 'parking', 'holdPoint' },
}

-- The list index where p fits best: the gap whose detour through p is smallest
local function bestGap(key, p)
    local list, ends = Setup.draft[key], ROUTE_ENDS[key]
    local chain = {}
    if ends and Setup.draft[ends[1]] then chain[#chain + 1] = Setup.draft[ends[1]] end
    local offset = #chain           -- chain index -> list index
    for _, q in ipairs(list) do chain[#chain + 1] = q end
    if ends and Setup.draft[ends[2]] then chain[#chain + 1] = Setup.draft[ends[2]] end
    if #chain < 2 then return #list + 1 end
    local here = vec(p)
    local best, bestCost = #list + 1, math.huge
    for j = 1, #chain - 1 do
        local a, b = vec(chain[j]), vec(chain[j + 1])
        local cost = #(here - a) + #(here - b) - #(b - a)
        if cost < bestCost then
            bestCost = cost
            best = math.max(1, math.min(j - offset + 1, #list + 1))
        end
    end
    return best
end

local function addPoint()
    local key = Setup.active
    local f = key and FIELD[key]
    if not f or f.kind ~= 'list' then return end
    local list = Setup.draft[key]
    if #list >= LF.LayoutFields[key].max then
        return LFC.Notify('That route already has the maximum number of points.', 'error')
    end
    local p = capture(f)
    if Setup.insert then
        local at = bestGap(key, p)
        table.insert(list, at, p)
        local where = at == 1 and 'at the start' or at == #list and 'at the end'
            or ('between %d and %d'):format(at - 1, at + 1)
        LFC.Notify(('Inserted as point %d (%s).'):format(at, where), 'success')
    else
        list[#list + 1] = p
    end
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    changed()
end

local function deleteNearest(key)
    local list = Setup.draft[key]
    local me = GetEntityCoords(PlayerPedId())
    local best, bestD
    for i, q in ipairs(list) do
        local d = #(vec(q) - me)
        if not bestD or d < bestD then best, bestD = i, d end
    end
    if not best then return end
    table.remove(list, best)
    LFC.Notify(('Removed point %d (%.0f m from you).'):format(best, bestD), 'success')
    changed()
end

local function close()
    Setup.open, Setup.active, Setup.auto, Setup.insert = false, nil, false, false
    LFC.Nui('setup', { show = false })
    if Setup.focused then LFC.Focus(false) end
    Setup.focused = false
end

---------------------------------------------------------------------------
-- Server -> editor
---------------------------------------------------------------------------
RegisterNetEvent('lastflight:client:setupOpen', function(data)
    -- using the logbook (or /lastflight setup) while the editor is open closes it
    if Setup.open then
        close()
        if Setup.dirty then LFC.Notify('Flight setup closed - unsaved changes were discarded.', 'info') end
        return
    end
    Setup.draft    = copy(data.layout)
    Setup.original = copy(data.layout)
    Setup.defaults = copy(data.defaults)
    Setup.saved, Setup.busy, Setup.route = data.saved, data.busy, data.route
    Setup.mode, Setup.returnTo = data.mode, data.returnTo
    Setup.dirty, Setup.active, Setup.auto, Setup.insert = false, nil, false, false
    Setup.open = true
    LFC.Nui('hidePanels')
    setFocus(true)
end)

RegisterNetEvent('lastflight:client:setupMode', function(mode)
    Setup.mode = mode
    Config.Farewell.mode = mode
    push()
end)

RegisterNetEvent('lastflight:client:setupSaved', function(info)
    if not Setup.open then return end
    Setup.saved, Setup.route = info.saved, info.route
    if not info.saved then Setup.draft = LF.LayoutFromConfig() end   -- factory reset
    Setup.original = copy(Setup.draft)
    Setup.dirty = false
    push()
end)

---------------------------------------------------------------------------
-- NUI -> editor
---------------------------------------------------------------------------
local function toConfigText(d)
    local function v3s(p) return ('vec3(%.2f, %.2f, %.2f)'):format(p.x, p.y, p.z) end
    local function v4s(p) return ('vec4(%.2f, %.2f, %.2f, %.1f)'):format(p.x, p.y, p.z, p.w or 0) end
    local function list(l, indent)
        local out = {}
        for _, p in ipairs(l) do out[#out + 1] = indent .. v3s(p) .. ',' end
        return table.concat(out, '\n')
    end
    local via = list(d.shuttleRoute, '    ')
    local cityVia = list(d.cityRoute, '    ')
    local tourVia = list(d.tourRoute, '    ')
    return table.concat({
        '-- Paste these into config.lua (Last Flight setup export)',
        'Config.Transport.city.npc   = ' .. v4s(d.cityNpc),
        'Config.Transport.city.spawn = ' .. v4s(d.citySpawn),
        'Config.Transport.city.waypoints = {',
        cityVia .. (cityVia ~= '' and '\n' or '') .. '    ' .. v3s(d.cityDropoff) .. ',   -- airport drop-off',
        '}',
        'Config.Tour.spawn = ' .. v4s(d.tourSpawn),
        'Config.Tour.waypoints = {',
        tourVia .. (tourVia ~= '' and '\n' or '') .. '    ' .. v3s(d.tourDropoff) .. ',   -- drop-off',
        '}',
        'Config.Airport.npc.coords     = ' .. v4s(d.npc),
        'Config.Airport.blip.coords    = ' .. v3s(d.npc),
        'Config.Airport.safeReturn     = ' .. v4s(d.safeReturn),
        'Config.Farewell.testReturn    = ' .. v4s(d.safeReturn),
        'Config.Airport.boardingPoint  = ' .. v3s(d.boardingPoint),
        'Config.Transport.shuttle.spawn = ' .. v4s(d.shuttleSpawn),
        'Config.Transport.shuttle.waypoints = {',
        via .. (via ~= '' and '\n' or '') .. '    ' .. v3s(d.shuttleDropoff) .. ',   -- drop-off',
        '}',
        'Config.Aircraft.parking      = ' .. v4s(d.parking),
        'Config.Aircraft.taxiRoute    = {',
        list(d.taxiRoute, '    '),
        '}',
        'Config.Aircraft.holdPoint    = ' .. v4s(d.holdPoint),
        'Config.Aircraft.liftoffPoint = ' .. v3s(d.liftoffPoint),
    }, '\n')
end

RegisterNUICallback('setupAction', function(data, cb)
    cb(1)
    if not Setup.open then return end
    local a, key = data.action, data.field
    local f = key and FIELD[key]

    if a == 'set' and f and f.kind ~= 'list' then
        Setup.draft[key] = capture(f)
        changed()
    elseif a == 'go' and f then
        local p = f.kind == 'list' and Setup.draft[key][tonumber(data.index) or #Setup.draft[key]] or Setup.draft[key]
        if p then
            setFocus(false)
            LFC.Teleport(vector4(p.x, p.y, p.z + 1.0, p.w or GetEntityHeading(PlayerPedId())))
            push()
        end
    elseif a == 'record' and f and f.kind == 'list' then
        Setup.active, Setup.insert = key, false
        setFocus(false)
        LFC.Notify(('Recording "%s": press %s at each point, %s to reopen the panel.')
            :format(f.label, Config.Admin.setupPointKey, Config.Admin.setupKey), 'info')
    elseif a == 'insert' and f and f.kind == 'list' then
        Setup.active, Setup.insert, Setup.auto = key, true, false
        setFocus(false)
        LFC.Notify(('Inserting into "%s": go where the new point belongs and press %s. It slots between the two points it fits best. %s reopens the panel.')
            :format(f.label, Config.Admin.setupPointKey, Config.Admin.setupKey), 'info')
    elseif a == 'nearest' and f and f.kind == 'list' then
        deleteNearest(key)
    elseif a == 'stop' then
        Setup.active, Setup.auto, Setup.insert = nil, false, false
        push()
    elseif a == 'auto' and not Setup.insert then
        Setup.auto = not Setup.auto
        push()
    elseif a == 'undo' and f and f.kind == 'list' then
        table.remove(Setup.draft[key])
        changed()
    elseif a == 'clear' and f and f.kind == 'list' then
        Setup.draft[key] = {}
        changed()
    elseif a == 'move' then
        setFocus(false)
    elseif a == 'save' then
        TriggerServerEvent('lastflight:server:setupSave', Setup.draft)
    elseif a == 'revert' then
        Setup.draft = copy(Setup.original)
        Setup.dirty = false
        push()
    elseif a == 'defaults' then
        Setup.draft = copy(Setup.defaults)
        changed()
    elseif a == 'factory' then
        TriggerServerEvent('lastflight:server:setupFactory')
    elseif a == 'mode' and LF.Modes[data.mode or ''] then
        TriggerServerEvent('lastflight:server:setMode', data.mode)
    elseif a == 'export' then
        local text = toConfigText(Setup.draft)
        print(text)
        LFC.Nui('copy', { text = text })
        LFC.Notify('Config lines printed to F8 and copied to the clipboard.', 'success')
    elseif a == 'close' then
        close()
    end
end)

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------
RegisterCommand('lastflight_setup', function()
    if Setup.open then setFocus(not Setup.focused) end
end, false)
RegisterKeyMapping('lastflight_setup', 'Last Flight: setup panel (admin)', 'keyboard', Config.Admin.setupKey)

RegisterCommand('lastflight_setup_point', function()
    if Setup.open and Setup.active then addPoint() end
end, false)
RegisterKeyMapping('lastflight_setup_point', 'Last Flight: add route point (admin)', 'keyboard', Config.Admin.setupPointKey)

---------------------------------------------------------------------------
-- Auto-record + world preview
---------------------------------------------------------------------------
local function text3d(p, txt)
    SetDrawOrigin(p.x, p.y, p.z, 0)
    SetTextScale(0.32, 0.32)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(txt)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function marker(p, r, g, b, label, heading)
    DrawMarker(28, p.x, p.y, p.z + 0.3, 0, 0, 0, 0, 0, 0, 0.6, 0.6, 0.6, r, g, b, 200, false, false, 2, false, nil, nil, false)
    if heading then
        local rad = math.rad(heading)
        DrawLine(p.x, p.y, p.z + 0.3, p.x - math.sin(rad) * 4.0, p.y + math.cos(rad) * 4.0, p.z + 0.3, r, g, b, 255)
    end
    if label then text3d(vector3(p.x, p.y, p.z + 1.4), label) end
end

local function line(a, b, r, g, bl)
    DrawLine(a.x, a.y, a.z + 0.3, b.x, b.y, b.z + 0.3, r, g, bl, 255)
end

-- Cached spline preview of the real taxi path the jet will follow
local previewKey, previewPath

local function taxiPreview(d)
    if not (d.parking and d.holdPoint and d.liftoffPoint) then return nil end
    local key = json.encode({ d.parking, d.taxiRoute, d.holdPoint, d.liftoffPoint })
    if key == previewKey then return previewPath end
    local hold, lift = vec(d.holdPoint), vec(d.liftoffPoint)
    local dir = vector3(lift.x - hold.x, lift.y - hold.y, 0.0)
    dir = #dir > 1 and dir / #dir or vector3(0.0, 1.0, 0.0)
    local pts = { vec(d.parking) }
    for _, p in ipairs(d.taxiRoute) do pts[#pts + 1] = vec(p) end
    local lineUp = hold - dir * 40.0
    if #(pts[#pts] - lineUp) > 15.0 and #(pts[#pts] - hold) > 15.0 then pts[#pts + 1] = lineUp end
    pts[#pts + 1] = hold
    previewKey, previewPath = key, LF.BuildPath(pts, 3.0)
    return previewPath
end

CreateThread(function()
    while true do
        if Setup.open and Setup.draft then
            local d = Setup.draft
            local me = GetEntityCoords(PlayerPedId())
            local near = function(p) return p and #(vec(p) - me) < 500.0 end

            -- auto record
            if Setup.auto and Setup.active and not Setup.insert then
                local list = d[Setup.active]
                local f = FIELD[Setup.active]
                local here = capture(f)
                local last = list[#list]
                if not last or #(vec(here) - vec(last)) >= (f.spacing or Config.Admin.autoRecordSpacing) then addPoint() end
            end

            -- single points
            for _, f in ipairs(FIELDS) do
                local p = d[f.key]
                if f.kind ~= 'list' and near(p) then
                    marker(p, 255, 61, 139, f.label, f.kind == 'vec4' and f.key ~= 'holdPoint' and p.w or nil)
                end
            end

            -- city taxi: spawn -> via -> airport drop-off (green)
            local cprev = d.citySpawn
            for i, p in ipairs(d.cityRoute) do
                if near(p) or near(cprev) then
                    line(cprev, p, 61, 220, 132)
                    marker(p, 61, 220, 132, ('City taxi %d'):format(i))
                end
                cprev = p
            end

            -- highway drive: pickup -> loop -> drop-off (purple)
            local tprev = d.tourSpawn
            for i, p in ipairs(d.tourRoute) do
                if near(p) or near(tprev) then
                    line(tprev, p, 170, 110, 255)
                    marker(p, 170, 110, 255, ('Highway %d'):format(i))
                end
                tprev = p
            end
            if near(tprev) or near(d.tourDropoff) then line(tprev, d.tourDropoff, 170, 110, 255) end

            -- shuttle: pickup -> via -> drop-off (blue)
            local prev = d.shuttleSpawn
            for i, p in ipairs(d.shuttleRoute) do
                if near(p) or near(prev) then
                    line(prev, p, 24, 209, 197)
                    marker(p, 24, 209, 197, ('Shuttle %d'):format(i))
                end
                prev = p
            end
            if near(prev) or near(d.shuttleDropoff) then line(prev, d.shuttleDropoff, 24, 209, 197) end

            -- taxi route points (yellow) + spline the jet will really follow
            for i, p in ipairs(d.taxiRoute) do
                if near(p) then marker(p, 255, 200, 0, ('Taxi %d'):format(i)) end
            end
            local path = taxiPreview(d)
            if path then
                local pts = path.pts
                for i = 1, #pts - 1 do
                    if #(pts[i] - me) < 500.0 then
                        line(pts[i], pts[i + 1], 255, 200, 0)
                    end
                end
            end
            -- runway roll (red)
            if near(d.holdPoint) or near(d.liftoffPoint) then line(d.holdPoint, d.liftoffPoint, 255, 60, 60) end

            -- hint bar while moving around
            if not Setup.focused then
                local msg
                if Setup.active then
                    msg =('%s ~y~%s~s~ - %d points%s~n~%s %s  |  %s open panel'):format(
                        Setup.insert and 'Inserting into' or 'Recording',
                        FIELD[Setup.active].label, #d[Setup.active], Setup.auto and ' ~g~(auto)~s~' or '',
                        Config.Admin.setupPointKey, Setup.insert and 'insert point here' or 'add point', Config.Admin.setupKey)
                else
                    msg = ('Last Flight setup - %s open the panel~n~Use the logbook again to close'):format(Config.Admin.setupKey)
                end
                LFC.HelpText(msg)
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and Setup.open then close() end
end)
