-- Shared by client and server: states, config validation, route math.
-- The server and every passenger build the exact same timeline from config,
-- so the server only has to send "phase X started N ms ago".

LF = LF or {}

local IS_SERVER = IsDuplicityVersion()

LF.States = {
    IDLE            = 'IDLE',
    BOARDING        = 'BOARDING',
    READY_CHECK     = 'READY_CHECK',
    TAXIING         = 'TAXIING',
    RUNWAY_WAIT     = 'RUNWAY_WAIT',
    TAKEOFF         = 'TAKEOFF',
    CRUISING        = 'CRUISING',
    FINAL_DEPARTURE = 'FINAL_DEPARTURE',
    ENDING          = 'ENDING',
    CLEANUP         = 'CLEANUP',
}

-- States in which the doors are locked and nobody can join or leave.
LF.Locked = {
    TAXIING = true, RUNWAY_WAIT = true, TAKEOFF = true, CRUISING = true,
    FINAL_DEPARTURE = true, ENDING = true, CLEANUP = true,
}

-- States where the jet moves along a timeline path.
LF.Moving = { TAXIING = true, TAKEOFF = true, CRUISING = true, FINAL_DEPARTURE = true }

-- Farewell modes (see Config.Farewell.mode)
LF.Modes = {
    test        = { label = 'TEST MODE',         kick = false, record = false,
                    desc = 'Admin testing. Nobody is kicked and flights are not recorded.' },
    live_return = { label = 'LIVE - RETURN',     kick = false, record = true,
                    desc = 'Live event. Nobody is kicked - passengers come back after the farewell.' },
    live_kick   = { label = 'LIVE - DISCONNECT', kick = true,  record = true,
                    desc = 'Live event. Passengers are disconnected after the farewell.' },
}
LF.ModeOrder = { 'test', 'live_return', 'live_kick' }

function LF.Mode()
    local F = Config.Farewell
    if not LF.Modes[F.mode or ''] then
        -- older configs only had testMode = true/false
        F.mode = F.testMode == false and 'live_kick' or 'test'
    end
    return F.mode
end

function LF.Debug(...)
    if Config.Debug then
        print('^5[lastflight]^7', ...)
    end
end

function LF.Warn(...)
    print('^3[lastflight] WARNING:^7', ...)
end

local function v3(v)
    return vector3(v.x + 0.0, v.y + 0.0, v.z + 0.0)
end
LF.v3 = v3

---------------------------------------------------------------------------
-- Config validation
---------------------------------------------------------------------------
local function num(v, def, min, max)
    v = tonumber(v) or def
    if min and v < min then v = min end
    if max and v > max then v = max end
    return v
end

local function validate()
    Config.Tickets.price = math.floor(num(Config.Tickets.price, 100, 0, 1000000000))

    local sf = Config.ScenicFlight
    sf.maxDuration = num(sf.maxDuration, 600, 60, 7200)
    sf.duration    = num(sf.duration, 600, 30, 7200)
    if sf.duration > sf.maxDuration and not sf.allowDurationOverride then
        if IS_SERVER then
            LF.Warn(('ScenicFlight.duration %ds is above maxDuration %ds - clamped. Set allowDurationOverride = true to allow it.')
                :format(sf.duration, sf.maxDuration))
        end
        sf.duration = sf.maxDuration
    end
    sf.minSpeed = num(sf.minSpeed, 35.0, 10.0, 200.0)
    sf.maxSpeed = num(sf.maxSpeed, 95.0, sf.minSpeed, 250.0)

    local b = Config.Boarding
    b.boardingDuration   = num(b.boardingDuration, 120, 10, 3600)
    b.readinessTimeout   = num(b.readinessTimeout, 60, 10, 3600)
    b.minimumPassengers  = math.floor(num(b.minimumPassengers, 1, 1, 64))
    b.departureCountdown = num(b.departureCountdown, 10, 0, 120)
    if b.unreadyPolicy ~= 'refund' and b.unreadyPolicy ~= 'requeue' then b.unreadyPolicy = 'refund' end

    local a = Config.Aircraft
    a.maxPassengers = math.floor(num(a.maxPassengers, 8, 1, 64))
    a.taxiSpeed     = num(a.taxiSpeed, 7.0, 1.0, 30.0)
    a.rotateSpeed   = num(a.rotateSpeed, 72.0, 20.0, 150.0)
    a.cooldown      = num(a.cooldown, 15, 0, 3600)
    if a.seatMode ~= 'auto' and a.seatMode ~= 'seats' and a.seatMode ~= 'attach' then a.seatMode = 'auto' end

    local f = Config.Farewell
    f.displayDuration   = num(f.displayDuration, 8, 1, 120)
    f.reconnectCooldown = num(f.reconnectCooldown, 60, 0, 86400)

    Config.Audio.pilot.fallbackDuration    = num(Config.Audio.pilot.fallbackDuration, 20, 1, 600)
    Config.Audio.seatbelt.fallbackDuration = num(Config.Audio.seatbelt.fallbackDuration, 3, 1, 60)
    Config.Audio.announcementTimeout       = num(Config.Audio.announcementTimeout, 120, 5, 900)
    Config.Audio.musicFadeDuration         = num(Config.Audio.musicFadeDuration, 6, 0, 300)

    Config.Seatbelt = Config.Seatbelt or { requireBuckle = false, timeout = 20 }
    Config.Seatbelt.timeout = num(Config.Seatbelt.timeout, 20, 3, 300)
    Config.Music = Config.Music or { tracks = {} }
    Config.Music.volume = num(Config.Music.volume, 0.5, 0, 1)
    for _, t in ipairs(Config.Music.tracks or {}) do t.duration = num(t.duration, 0, 0, 7200) end

    local c = Config.Cinematics
    c.fadeDuration        = num(c.fadeDuration, 6, 0.5, 60)
    c.thirdPersonAltitude = num(c.thirdPersonAltitude, 150.0, 10.0, 2000.0)

    if Config.Admin.cancelPolicy ~= 'refund' and Config.Admin.cancelPolicy ~= 'requeue' then
        Config.Admin.cancelPolicy = 'refund'
    end
end
validate()

---------------------------------------------------------------------------
-- Path math (centripetal Catmull-Rom, sampled into an arc-length table)
---------------------------------------------------------------------------
local function catmull(p0, p1, p2, p3, t)
    local function knot(ti, a, b)
        local d = #(b - a)
        if d < 0.01 then d = 0.01 end
        return ti + math.sqrt(d)
    end
    local t0 = 0.0
    local t1 = knot(t0, p0, p1)
    local t2 = knot(t1, p1, p2)
    local t3 = knot(t2, p2, p3)
    local u  = t1 + (t2 - t1) * t

    local a1 = p0 * ((t1 - u) / (t1 - t0)) + p1 * ((u - t0) / (t1 - t0))
    local a2 = p1 * ((t2 - u) / (t2 - t1)) + p2 * ((u - t1) / (t2 - t1))
    local a3 = p2 * ((t3 - u) / (t3 - t2)) + p3 * ((u - t2) / (t3 - t2))
    local b1 = a1 * ((t2 - u) / (t2 - t0)) + a2 * ((u - t0) / (t2 - t0))
    local b2 = a2 * ((t3 - u) / (t3 - t1)) + a3 * ((u - t1) / (t3 - t1))
    return b1 * ((t2 - u) / (t2 - t1)) + b2 * ((u - t1) / (t2 - t1))
end

-- Chaikin corner cutting: rounds every corner so hand-placed waypoints never
-- produce snap turns. End points are kept exactly.
local function chaikin(p, iterations)
    for _ = 1, iterations do
        if #p < 3 then return p end
        local out = { p[1] }
        for i = 1, #p - 1 do
            local a, b = p[i], p[i + 1]
            out[#out + 1] = a * 0.75 + b * 0.25
            out[#out + 1] = a * 0.25 + b * 0.75
        end
        out[#out + 1] = p[#p]
        p = out
    end
    return p
end

function LF.BuildPath(points, step, smooth)
    step = step or 5.0
    local p = {}
    for _, v in ipairs(points) do
        local q = v3(v)
        if #p == 0 or #(q - p[#p]) > 0.5 then p[#p + 1] = q end
    end
    if smooth and smooth > 0 then p = chaikin(p, smooth) end

    local path = { pts = { p[1] }, cum = { 0.0 }, length = 0.0 }
    local n = #p
    if n < 2 then return path end

    local function at(i)
        if i < 1 then return p[1] + (p[1] - p[2]) end
        if i > n then return p[n] + (p[n] - p[n - 1]) end
        return p[i]
    end

    local total = 0.0
    for i = 1, n - 1 do
        local count = math.max(1, math.ceil(#(p[i + 1] - p[i]) / step))
        for k = 1, count do
            local q = catmull(at(i - 1), p[i], p[i + 1], at(i + 2), k / count)
            total = total + #(q - path.pts[#path.pts])
            path.pts[#path.pts + 1] = q
            path.cum[#path.cum + 1] = total
        end
    end
    path.length = total
    return path
end

function LF.SampleAt(path, s)
    local pts, cum = path.pts, path.cum
    local n = #pts
    if n == 1 or s <= 0 then return pts[1] end
    if s >= path.length then return pts[n] end

    local lo, hi = 1, n
    while hi - lo > 1 do
        local mid = (lo + hi) // 2
        if cum[mid] <= s then lo = mid else hi = mid end
    end
    local span = cum[hi] - cum[lo]
    local f = span > 0 and (s - cum[lo]) / span or 0.0
    return pts[lo] + (pts[hi] - pts[lo]) * f
end

function LF.TangentAt(path, s)
    local d = LF.SampleAt(path, s + 3.0) - LF.SampleAt(path, s - 3.0)
    local len = #d
    if len < 0.001 then return vector3(0.0, 1.0, 0.0) end
    return d / len
end

-- GTA heading (degrees, 0 = north, counter-clockwise) from a direction vector.
function LF.HeadingOf(dir)
    return (math.deg(math.atan(-dir.x, dir.y)) + 360.0) % 360.0
end

function LF.AngleDiff(a, b)
    return (b - a + 540.0) % 360.0 - 180.0
end

---------------------------------------------------------------------------
-- Timeline
-- Each moving phase is a list of legs. A leg is either:
--   ease   : starts and ends at rest (taxi), smootherstep profile
--   linear : constant acceleration from v0 to v1
---------------------------------------------------------------------------
local function linearLeg(path, v0, v1, ground)
    local avg = (v0 + v1) * 0.5
    if avg < 0.1 then avg = 0.1 end
    return { path = path, kind = 'linear', v0 = v0, v1 = v1, ground = ground, duration = path.length / avg }
end

local function easeLeg(path, speed, ground)
    -- smootherstep peaks at 1.875x the average speed; 1.6 keeps the peak near `speed`
    return { path = path, kind = 'ease', ground = ground, duration = path.length / speed * 1.6 }
end

local function evalLeg(leg, t)
    local T, L = leg.duration, leg.path.length
    if T <= 0 then return L, 0.0 end
    if t >= T then return L, (leg.kind == 'linear') and leg.v1 or 0.0 end
    if leg.kind == 'ease' then
        local x = t / T
        local s = L * (x * x * x * (x * (x * 6 - 15) + 10))
        local v = (L / T) * (30 * x * x * (x - 1) * (x - 1))
        return s, v
    end
    local a = (leg.v1 - leg.v0) / T
    return leg.v0 * t + 0.5 * a * t * t, leg.v0 + a * t
end

-- Points of a wide turn (fixed radius) from pos/dir until the nose points at
-- target. Lets any runway direction blend into the scenic loop smoothly.
local function turnToward(pos, dir, target, radius, zFrom, zTo)
    local pts = {}
    local heading = math.atan(dir.y, dir.x)
    local step = math.rad(15)
    local chord = 2 * radius * math.sin(step / 2)
    local p = vector3(pos.x, pos.y, 0.0)
    for _ = 1, 24 do
        local want = math.atan(target.y - p.y, target.x - p.x)
        local diff = (want - heading + math.pi) % (2 * math.pi) - math.pi
        if math.abs(diff) < math.rad(12) then break end
        local s = diff > 0 and step or -step
        heading = heading + s / 2
        p = p + vector3(math.cos(heading), math.sin(heading), 0.0) * chord
        heading = heading + s / 2
        pts[#pts + 1] = p
    end
    for i, q in ipairs(pts) do
        pts[i] = vector3(q.x, q.y, zFrom + (zTo - zFrom) * (i / (#pts + 1)))
    end
    return pts
end

-- Horizontal unit vector of the runway (hold point -> liftoff point).
function LF.RunwayDir()
    local A = Config.Aircraft
    local d = v3(A.liftoffPoint) - v3(A.holdPoint)
    d = vector3(d.x, d.y, 0.0)
    local len = #d
    if len < 1.0 then return vector3(0.0, 1.0, 0.0) end
    return d / len
end

local function build(scenicDuration)
    local A, SF, FD = Config.Aircraft, Config.ScenicFlight, Config.FinalDeparture
    local tl = { scenicTarget = scenicDuration }
    local rdir = LF.RunwayDir()
    local hold, lift = v3(A.holdPoint), v3(A.liftoffPoint)

    -- TAXI: parking -> taxi route -> line-up point -> hold point
    local taxiPts = { A.parking }
    for _, p in ipairs(A.taxiRoute) do taxiPts[#taxiPts + 1] = p end
    local lineUp = hold - rdir * 40.0          -- roll the last 40 m straight down the runway heading
    if #(v3(taxiPts[#taxiPts]) - lineUp) > 15.0 and #(v3(taxiPts[#taxiPts]) - hold) > 15.0 then
        taxiPts[#taxiPts + 1] = lineUp
    end
    taxiPts[#taxiPts + 1] = hold
    tl.TAXIING = { legs = { easeLeg(LF.BuildPath(taxiPts, 2.0), A.taxiSpeed, true) } }

    -- CLIMB points
    local climbPts = { lift }
    if A.autoClimb or #A.climbRoute == 0 then
        climbPts[2] = lift + rdir * 500.0 + vector3(0.0, 0.0, 90.0)
        climbPts[3] = lift + rdir * 1200.0 + vector3(0.0, 0.0, 220.0)
    else
        for _, p in ipairs(A.climbRoute) do climbPts[#climbPts + 1] = p end
    end

    -- SCENIC first (its speed is needed by the climb leg). A lead-in point keeps
    -- the climb heading so the hand-over into the loop has no kink.
    local lastClimb = v3(climbPts[#climbPts])
    local prevClimb = v3(climbPts[#climbPts - 1])
    local cdir = vector3(lastClimb.x - prevClimb.x, lastClimb.y - prevClimb.y, 0.0)
    cdir = #cdir > 0.1 and cdir / #cdir or rdir
    local leadIn = lastClimb + cdir * 600.0
    local scenicPts = { lastClimb, leadIn }
    local first = SF.waypoints[1] and v3(SF.waypoints[1].pos)
    if first then
        -- radius shrinks when the first waypoint is close, so the turn never overshoots it
        local dist = #(vector3(first.x - leadIn.x, first.y - leadIn.y, 0.0))
        local radius = math.max(250.0, math.min(900.0, dist / 3.0))
        for _, p in ipairs(turnToward(leadIn, cdir, first, radius, leadIn.z, first.z)) do
            scenicPts[#scenicPts + 1] = p
        end
    end
    for _, w in ipairs(SF.waypoints) do scenicPts[#scenicPts + 1] = w.pos end
    local scenicPath = LF.BuildPath(scenicPts, 8.0, 4)
    local wanted = scenicPath.length / scenicDuration
    local cruise = math.min(SF.maxSpeed, math.max(SF.minSpeed, wanted))
    tl.cruiseSpeed = cruise
    tl.CRUISING = { legs = { linearLeg(scenicPath, cruise, cruise, false) } }

    -- TAKEOFF: roll along runway (ground), then climb (air)
    local rollPath  = LF.BuildPath({ hold, lift }, 3.0)
    local climbPath = LF.BuildPath(climbPts, 5.0)
    tl.TAKEOFF = { legs = {
        linearLeg(rollPath, 0.0, A.rotateSpeed, true),
        linearLeg(climbPath, A.rotateSpeed, cruise, false),
    } }

    -- FINAL DEPARTURE
    local depPts = { SF.waypoints[#SF.waypoints] and SF.waypoints[#SF.waypoints].pos or lastClimb }
    for _, p in ipairs(FD.waypoints) do depPts[#depPts + 1] = p end
    tl.FINAL_DEPARTURE = { legs = { linearLeg(LF.BuildPath(depPts, 8.0, 2), cruise, FD.speed or 85.0, false) } }

    for state, phase in pairs(tl) do
        if type(phase) == 'table' and phase.legs then
            local d = 0.0
            for _, leg in ipairs(phase.legs) do d = d + leg.duration end
            phase.duration = d
            phase.name = state
        end
    end

    tl.scenicWanted = wanted
    tl.airborne = tl.TAKEOFF.duration + tl.CRUISING.duration + tl.FINAL_DEPARTURE.duration
    return tl
end

function LF.MusicLength()
    local total = 0
    for _, t in ipairs(Config.Music.tracks or {}) do total = total + (tonumber(t.duration) or 0) end
    return total
end

function LF.BuildTimeline()
    local SF = Config.ScenicFlight
    local music = LF.MusicLength()
    if not Config.Music.fitFlightToMusic or music <= 0 then
        return build(SF.duration)
    end
    -- takeoff/departure times depend on the cruise speed, which depends on the
    -- scenic time, so settle it in a few passes
    local scenic = SF.duration
    local tl
    for _ = 1, 6 do
        tl = build(scenic)
        local other = tl.TAKEOFF.duration + tl.FINAL_DEPARTURE.duration
        local nextScenic = math.max(60.0, music - other)
        if not SF.allowDurationOverride then nextScenic = math.min(nextScenic, SF.maxDuration) end
        if math.abs(nextScenic - scenic) < 0.05 then break end
        scenic = nextScenic
    end
    tl.fitToMusic = music
    return tl
end

-- Position/speed on a phase at time t (seconds since the phase began).
-- Returns pos, tangent, speed, ground, finished
function LF.EvalPhase(phase, t)
    local elapsed = 0.0
    for i, leg in ipairs(phase.legs) do
        if t < elapsed + leg.duration or i == #phase.legs then
            local s, v = evalLeg(leg, t - elapsed)
            local pos = LF.SampleAt(leg.path, s)
            local tan = LF.TangentAt(leg.path, s)
            return pos, tan, v, leg.ground, t >= phase.duration, leg, s
        end
        elapsed = elapsed + leg.duration
    end
end

---------------------------------------------------------------------------
-- Layout (locations editable in game with /lastflight setup)
-- A layout is a plain table so it can go through JSON / state bags.
---------------------------------------------------------------------------
local function plain(v, four)
    if not v then return nil end
    local t = { x = v.x + 0.0, y = v.y + 0.0, z = v.z + 0.0 }
    if four then t.w = (v.w or 0.0) + 0.0 end
    return t
end

local function plainList(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = plain(v) end
    return out
end

local function fromPlain(t, four)
    if type(t) ~= 'table' then return nil end
    local x, y, z, w = tonumber(t.x), tonumber(t.y), tonumber(t.z), tonumber(t.w)
    if not x or not y or not z then return nil end
    if math.abs(x) > 12000 or math.abs(y) > 12000 or z < -200 or z > 3000 then return nil end
    if four then return vector4(x, y, z, (w or 0.0) % 360.0) end
    return vector3(x, y, z)
end

local function fromPlainList(list, max)
    if type(list) ~= 'table' then return nil end
    local out = {}
    for i = 1, math.min(#list, max) do
        local v = fromPlain(list[i])
        if not v then return nil end
        out[#out + 1] = v
    end
    return out
end

-- Every editable location: key -> { kind, max points for routes }
LF.LayoutFields = {
    npc          = { kind = 'vec4' },
    safeReturn   = { kind = 'vec4' },
    boardingPoint = { kind = 'vec3' },
    shuttleSpawn = { kind = 'vec4' },
    shuttleRoute = { kind = 'list', max = 40 },
    shuttleDropoff = { kind = 'vec3' },
    cityNpc      = { kind = 'vec4' },
    citySpawn    = { kind = 'vec4' },
    cityRoute    = { kind = 'list', max = 40 },
    cityDropoff  = { kind = 'vec3' },
    tourSpawn    = { kind = 'vec4' },
    tourRoute    = { kind = 'list', max = 250 },
    tourDropoff  = { kind = 'vec3' },
    parking      = { kind = 'vec4' },
    taxiRoute    = { kind = 'list', max = 80 },
    holdPoint    = { kind = 'vec4' },
    liftoffPoint = { kind = 'vec3' },
}

function LF.LayoutFromConfig()
    local SH = Config.Transport.shuttle
    local via = {}
    for i = 1, #SH.waypoints - 1 do via[i] = SH.waypoints[i] end
    local CT = Config.Transport.city
    local cityVia = {}
    for i = 1, #CT.waypoints - 1 do cityVia[i] = CT.waypoints[i] end
    local TC = Config.Tour
    local tourVia = {}
    for i = 1, #TC.waypoints - 1 do tourVia[i] = TC.waypoints[i] end
    return {
        tourSpawn      = plain(TC.spawn, true),
        tourRoute      = plainList(tourVia),
        tourDropoff    = plain(TC.waypoints[#TC.waypoints] or CT.waypoints[#CT.waypoints] or Config.Airport.safeReturn),
        cityNpc        = plain(CT.npc, true),
        citySpawn      = plain(CT.spawn, true),
        cityRoute      = plainList(cityVia),
        cityDropoff    = plain(CT.waypoints[#CT.waypoints] or Config.Airport.safeReturn),
        npc            = plain(Config.Airport.npc.coords, true),
        safeReturn     = plain(Config.Airport.safeReturn, true),
        boardingPoint  = plain(Config.Airport.boardingPoint),
        shuttleSpawn   = plain(SH.spawn, true),
        shuttleRoute   = plainList(via),
        shuttleDropoff = plain(SH.waypoints[#SH.waypoints] or Config.Airport.boardingPoint),
        parking        = plain(Config.Aircraft.parking, true),
        taxiRoute      = plainList(Config.Aircraft.taxiRoute),
        holdPoint      = plain(Config.Aircraft.holdPoint, true),
        liftoffPoint   = plain(Config.Aircraft.liftoffPoint),
    }
end

-- Validates a plain layout. Returns a clean copy or nil, error.
function LF.ValidateLayout(layout)
    if type(layout) ~= 'table' then return nil, 'bad layout' end
    local clean = {}
    for key, f in pairs(LF.LayoutFields) do
        local v = layout[key]
        -- fields added in a later version: take them from config.lua
        if v == nil and LF.DefaultLayout then v = LF.DefaultLayout[key] end
        if f.kind == 'list' then
            local list = fromPlainList(v or {}, f.max)
            if not list then return nil, key .. ' has an invalid point' end
            clean[key] = plainList(list)
        else
            local vec = fromPlain(v, f.kind == 'vec4')
            if not vec then return nil, key .. ' is missing or invalid' end
            clean[key] = plain(vec, f.kind == 'vec4')
        end
    end
    local hold, lift = fromPlain(clean.holdPoint), fromPlain(clean.liftoffPoint)
    local runway = #(vector3(lift.x, lift.y, 0.0) - vector3(hold.x, hold.y, 0.0))
    if runway < 300.0 then return nil, ('takeoff roll is only %dm - put the liftoff point at least 300m down the runway'):format(math.floor(runway)) end
    return clean
end

-- Writes a (validated) layout into Config and rebuilds the timeline.
function LF.ApplyLayout(layout)
    local L = layout
    Config.Airport.npc.coords     = fromPlain(L.npc, true)
    Config.Airport.blip.coords    = fromPlain(L.npc)
    Config.Airport.safeReturn     = fromPlain(L.safeReturn, true)
    Config.Farewell.testReturn    = fromPlain(L.safeReturn, true)
    Config.Airport.boardingPoint  = fromPlain(L.boardingPoint)
    local SH = Config.Transport.shuttle
    SH.spawn = fromPlain(L.shuttleSpawn, true)
    SH.waypoints = fromPlainList(L.shuttleRoute, 40) or {}
    SH.waypoints[#SH.waypoints + 1] = fromPlain(L.shuttleDropoff)
    local CT = Config.Transport.city
    CT.npc   = fromPlain(L.cityNpc, true)
    CT.spawn = fromPlain(L.citySpawn, true)
    CT.waypoints = fromPlainList(L.cityRoute, 40) or {}
    CT.waypoints[#CT.waypoints + 1] = fromPlain(L.cityDropoff)
    local TC = Config.Tour
    TC.spawn = fromPlain(L.tourSpawn, true)
    TC.waypoints = fromPlainList(L.tourRoute, 250) or {}
    TC.waypoints[#TC.waypoints + 1] = fromPlain(L.tourDropoff)
    local A = Config.Aircraft
    A.parking      = fromPlain(L.parking, true)
    A.taxiRoute    = fromPlainList(L.taxiRoute, 80) or {}
    A.liftoffPoint = fromPlain(L.liftoffPoint)
    local hold = fromPlain(L.holdPoint, true)
    A.holdPoint = vector4(hold.x, hold.y, hold.z, 0.0)                            -- RunwayDir() reads this
    A.holdPoint = vector4(hold.x, hold.y, hold.z, LF.HeadingOf(LF.RunwayDir()))   -- always face down the runway
    LF.Timeline = LF.BuildTimeline()
    LF.LayoutVersion = (LF.LayoutVersion or 0) + 1
end

LF.DefaultLayout = LF.LayoutFromConfig()   -- the values in config.lua, before any saved override
LF.LayoutVersion = 0
LF.Timeline = LF.BuildTimeline()

function LF.PrintRoute()
    local tl = LF.Timeline
    print(('^5[lastflight]^7 Route: taxi %.0fs | takeoff %.0fs | scenic %.0fs @ %.1f m/s | departure %.0fs | airborne total %.0fs')
        :format(tl.TAXIING.duration, tl.TAKEOFF.duration, tl.CRUISING.duration, tl.cruiseSpeed,
            tl.FINAL_DEPARTURE.duration, tl.airborne))
    if tl.fitToMusic then
        local diff = tl.airborne - tl.fitToMusic
        if math.abs(diff) > 2 then
            LF.Warn(('Flight is %.0fs %s than the music (%ds). Speed limits or maxDuration stopped an exact fit.')
                :format(math.abs(diff), diff > 0 and 'longer' or 'shorter', tl.fitToMusic))
        else
            print(('^5[lastflight]^7 Flight timed to the music: %ds from takeoff to the final fade.'):format(tl.fitToMusic))
        end
    elseif math.abs(tl.scenicWanted - tl.cruiseSpeed) > 0.05 then
        LF.Warn(('Scenic loop needs %.1f m/s for %ds but speed is clamped to %.1f m/s. Real scenic time: %.0fs. Add/remove waypoints or change min/maxSpeed.')
            :format(tl.scenicWanted, tl.scenicTarget, tl.cruiseSpeed, tl.CRUISING.duration))
    end
end

if IS_SERVER then LF.PrintRoute() end
