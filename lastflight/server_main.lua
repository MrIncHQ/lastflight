-- Server-authoritative flight manager: tickets, queue, manifest, state machine.
-- Clients only ever *ask*; every request is validated here.

local S = LF.States

LFS = {}                     -- shared with server_admin.lua

local Tickets   = {}         -- [identifier] = ticket
local Flight    = nil        -- current flight session (nil = IDLE, no aircraft)
local flightSeq = 0
local ticketSeq = 0
local purchasing = {}        -- [src] = true while a purchase is processing
local lastAction = {}        -- [src] = GetGameTimer() of last rate-limited action
local Rides     = {}         -- [id] = shared shuttle bus, see "Shared shuttles"
local reconnectBlock = {}    -- [identifier] = os.time() when they may rejoin
local cooldownUntil = 0      -- GetGameTimer() before which no new aircraft spawns

local function now() return GetGameTimer() end

local function rateLimited(src, ms, key)
    local t = now()
    key = key or 'default'
    lastAction[src] = lastAction[src] or {}
    local last = lastAction[src][key]
    if last and t - last < (ms or 500) then return true end
    lastAction[src][key] = t
    return false
end

local function pedCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function countTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function fmtTime(sec)
    sec = math.max(0, math.floor(sec))
    return ('%02d:%02d'):format(sec // 60, sec % 60)
end

local function publishGlobal()
    GlobalState.lastflight = Flight and {
        id = Flight.id, state = Flight.state, netId = Flight.netId,
        boarding = Flight.state == S.BOARDING,
    } or { state = S.IDLE }
end

---------------------------------------------------------------------------
-- Participation history (one-time flights)
---------------------------------------------------------------------------
local function hasCompleted(identifier)
    return GetResourceKvpString('done:' .. identifier) ~= nil
end

local function recordCompletion(identifier)
    SetResourceKvp('done:' .. identifier, tostring(os.time()))
end

function LFS.ClearHistory(target)
    local removed = 0
    if target == 'all' then
        local handle = StartFindKvp('done:')
        local keys = {}
        if handle ~= -1 then
            repeat
                local key = FindKvp(handle)
                if key then keys[#keys + 1] = key end
            until not key
            EndFindKvp(handle)
        end
        for _, key in ipairs(keys) do DeleteResourceKvp(key); removed = removed + 1 end
    else
        local id = target
        if tonumber(target) and GetPlayerName(tonumber(target)) then id = Bridge.Identifier(tonumber(target)) end
        if GetResourceKvpString('done:' .. id) then DeleteResourceKvp('done:' .. id); removed = 1 end
    end
    return removed
end

---------------------------------------------------------------------------
-- Tickets
---------------------------------------------------------------------------
local function ticketOf(src)
    return Tickets[Bridge.Identifier(src)]
end

local function refundTicket(ticket, reason)
    if not ticket then return end
    local src = ticket.src
    Tickets[ticket.identifier] = nil
    if src and GetPlayerName(src) then
        Bridge.Refund(src, ticket.paid, ticket.account)
        Bridge.RemoveTicketItem(src, ticket)
        Bridge.Notify(src, ('Your ticket was refunded ($%d). %s'):format(ticket.paid, reason or ''), 'info')
    end
end

local function waitingTickets()
    local list = {}
    for _, t in pairs(Tickets) do
        if t.status == 'waiting' and t.src and GetPlayerName(t.src) then list[#list + 1] = t end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

---------------------------------------------------------------------------
-- Aircraft entity
---------------------------------------------------------------------------
local function deleteEntity(ent)
    if ent and ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
end

local function cleanupOrphans()
    for _, veh in ipairs(GetAllVehicles()) do
        local st = Entity(veh).state
        if st.lf_aircraft or st.lf_shuttle then DeleteEntity(veh) end
    end
    for _, ped in ipairs(GetAllPeds()) do
        local st = Entity(ped).state
        if st.lf_pilot or st.lf_shuttle then DeleteEntity(ped) end
    end
end

local function spawnAircraft(f)
    local A = Config.Aircraft
    local p = A.parking
    -- spawn a little above the ground and frozen: if the runway collision isn't
    -- loaded yet on the owning client it would otherwise fall through the map
    local veh = CreateVehicleServerSetter(GetHashKey(A.model), 'plane', p.x, p.y, p.z + 1.5, p.w)
    local deadline = now() + 5000
    while (not veh or veh == 0 or not DoesEntityExist(veh)) and now() < deadline do Wait(50) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        LF.Warn('Aircraft failed to spawn (model "' .. A.model .. '").')
        return false
    end

    if SetEntityOrphanMode then pcall(SetEntityOrphanMode, veh, 2) end   -- keep entity when nobody is near
    FreezeEntityPosition(veh, true)
    SetVehicleDoorsLocked(veh, 2)
    Entity(veh).state:set('lf_aircraft', f.id, true)

    f.veh   = veh
    f.netId = NetworkGetNetworkIdFromEntity(veh)

    if A.spawnPilot then
        local ped = CreatePedInsideVehicle(veh, 26, GetHashKey(A.pilotModel), -1, true, true)
        deadline = now() + 3000
        while (not ped or ped == 0 or not DoesEntityExist(ped)) and now() < deadline do Wait(50) end
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            if SetEntityOrphanMode then pcall(SetEntityOrphanMode, ped, 2) end
            Entity(ped).state:set('lf_pilot', f.id, true)
            f.pilot = ped
        else
            LF.Warn('Pilot failed to spawn - the flight continues without a visible pilot.')
        end
    end
    print(('^5[lastflight]^7 Aircraft spawned for flight %d at %.1f, %.1f, %.1f (net %d)'):format(f.id, p.x, p.y, p.z, f.netId))
    f.spawnedAt = now()
    return true
end

-- Qbox's qbx_entitiesblacklist deletes JET (and other planes) the instant they spawn.
local BLACKLIST_HELP = 'Remove the line  [`JET`] = true,  from qbx_smallresources/qbx_entitiesblacklist/config.lua '
    .. '(or whatever model Config.Aircraft.model is) and restart qbx_smallresources.'

local function blacklistActive()
    return GetResourceState('qbx_smallresources') == 'started'
        and GetConvar('qbx:bucketlockdownmode', 'relaxed') == 'inactive'
end

local quickLosses = 0          -- jets deleted by something else right after spawning
local spawnBlocked = false     -- stop the spawn/delete loop until an admin fixes it

local function removeAircraft(f, reason)
    if f.veh and DoesEntityExist(f.veh) then
        print(('^5[lastflight]^7 Aircraft for flight %d removed (%s)'):format(f.id, reason or '?'))
    end
    if f.pilot and DoesEntityExist(f.pilot) then DeleteEntity(f.pilot) end
    if f.veh and DoesEntityExist(f.veh) then DeleteEntity(f.veh) end
end

---------------------------------------------------------------------------
-- Messaging to passengers only
---------------------------------------------------------------------------
local function toPassengers(event, ...)
    if not Flight then return end
    for src in pairs(Flight.passengers) do
        TriggerClientEvent(event, src, ...)
    end
end

local function readyCounts()
    local ready, total = 0, 0
    for _, p in pairs(Flight.passengers) do
        if p.seated then
            total = total + 1
            if p.ready then ready = ready + 1 end
        end
    end
    return ready, total
end

local function broadcastManifest()
    if not Flight then return end
    local ready, total = readyCounts()
    local status, timer = 'Waiting for passengers', nil
    local t = now()

    if Flight.countdownEndsAt then
        status = 'All passengers ready - departing'
        timer = (Flight.countdownEndsAt - t) / 1000
    elseif Flight.state == S.BOARDING then
        if Flight.shuttleHoldUntil then
            status = 'Waiting for the gate shuttle'
            timer = (Flight.shuttleHoldUntil - t) / 1000
        elseif Flight.boardingEndsAt then
            status = 'Boarding - doors close soon'
            timer = (Flight.boardingEndsAt - t) / 1000
        else
            status = 'Boarding - waiting for passengers'
        end
    elseif Flight.state == S.READY_CHECK then
        status = 'Boarding closed - waiting for passengers to be ready'
        timer = Flight.readyEndsAt and (Flight.readyEndsAt - t) / 1000
    end

    for src, p in pairs(Flight.passengers) do
        TriggerClientEvent('lastflight:client:manifest', src, {
            flightId = Flight.id, ready = ready, total = total, status = status,
            timer = timer and math.max(0, timer) or nil, youReady = p.ready == true,
            locked = LF.Locked[Flight.state] == true,
        })
    end
end

---------------------------------------------------------------------------
-- Flight lifecycle
---------------------------------------------------------------------------
local startPhase, closeBoarding, finishFlight, beginCleanup, openNextFlight

local function newFlight()
    flightSeq = flightSeq + 1
    return {
        id = flightSeq, state = S.IDLE, passengers = {}, seats = {}, badSeats = {},
        seatCapacity = nil, controller = nil, groundOffset = nil,
        pendingAudio = nil, pendingFarewell = nil, lastSync = 0,
    }
end

local function capacity()
    local A = Config.Aircraft
    if A.seatMode == 'attach' then return math.min(A.maxPassengers, #A.attachOffsets) end
    local cap = A.maxPassengers
    if Flight.seatCapacity then
        local seats = Flight.seatCapacity
        if A.seatMode == 'auto' then seats = math.max(seats, #A.attachOffsets) end
        cap = math.min(cap, seats)
    end
    return cap
end

local function pickController()
    if Flight.controller and Flight.passengers[Flight.controller] and GetPlayerName(Flight.controller) then
        return
    end
    Flight.controller = nil
    for src, p in pairs(Flight.passengers) do
        if p.seated then Flight.controller = src break end
    end
    if Flight.controller then
        LF.Debug('Controller is now ' .. Flight.controller)
        TriggerClientEvent('lastflight:client:controller', Flight.controller, Flight.id)
    end
end

-- Puts a player back to normal gameplay at the airport (client handles the fade/teleport).
local function restorePlayer(src, msg)
    if GetPlayerName(src) then
        TriggerClientEvent('lastflight:client:restore', src, Config.Airport.safeReturn, msg)
    end
end

-- reason: 'left' | 'unready' | 'cancel' | 'dropped' | 'removed'
local function removePassenger(src, reason, policy)
    if not Flight or not Flight.passengers[src] then return end
    local p = Flight.passengers[src]
    Flight.passengers[src] = nil
    if p.seat and Flight.seats[p.seatKey] == src then Flight.seats[p.seatKey] = nil end
    if Flight.pendingAudio then Flight.pendingAudio[src] = nil end
    if Flight.pendingBuckle then Flight.pendingBuckle[src] = nil end
    if Flight.pendingFarewell then Flight.pendingFarewell[src] = nil end
    if Flight.controller == src then Flight.controller = nil end

    local ticket = Tickets[p.identifier]
    if reason ~= 'dropped' then
        if policy == 'refund' then
            if ticket then refundTicket(ticket, 'You were removed from the flight.')
            elseif p.ticket then
                Bridge.Refund(src, p.ticket.paid, p.ticket.account)
                Bridge.RemoveTicketItem(src, p.ticket)
                Bridge.Notify(src, ('Your ticket was refunded ($%d).'):format(p.ticket.paid), 'info')
            end
        elseif policy == 'requeue' then
            if not ticket and p.ticket then
                Tickets[p.identifier] = p.ticket
                ticket = p.ticket
            end
            if ticket then ticket.status = 'waiting'; ticket.src = src end
        elseif ticket then
            ticket.status = 'waiting'
        end
    elseif ticket then
        ticket.status = 'waiting'   -- keeps the ticket if they reconnect
    end

    LF.Debug(('Passenger %s removed (%s)'):format(src, reason))
    if reason ~= 'dropped' and reason ~= 'left' then
        restorePlayer(src, reason == 'unready' and 'You were not ready in time.' or 'You have been returned to the terminal.')
    end

    -- Empty flight handling
    if countTable(Flight.passengers) == 0 then
        if LF.Locked[Flight.state] then
            LF.Debug('Last passenger left a locked flight - ending')
            beginCleanup('empty')
        else
            Flight.boardingEndsAt, Flight.readyEndsAt, Flight.countdownEndsAt = nil, nil, nil
            if Flight.state == S.READY_CHECK then Flight.state = S.BOARDING; publishGlobal() end
        end
    else
        pickController()
        broadcastManifest()
    end
end

-- Creates the flight right away and spawns the jet in the background, so a
-- ticket purchase never waits on the (slow) aircraft + pilot spawn.
local function ensureFlight()
    if Flight or not Config.Enabled or spawnBlocked then return end
    if now() < cooldownUntil then return end
    local f = newFlight()
    Flight = f
    f.state = S.CLEANUP                        -- blocks re-entry / boarding while spawning
    f.spawning = true
    CreateThread(function()
        local ok = spawnAircraft(f)
        f.spawning = false
        if Flight ~= f then                    -- reset while we were spawning
            removeAircraft(f, 'reset during spawn')
            return
        end
        if not ok then
            Flight = nil
            cooldownUntil = now() + 15000
            publishGlobal()
            return
        end
        f.state = S.BOARDING
        publishGlobal()
        for _, t in ipairs(waitingTickets()) do
            TriggerClientEvent('lastflight:client:boardingOpen', t.src)
        end
    end)
end
openNextFlight = ensureFlight

function closeBoarding()
    if not Flight or Flight.state ~= S.BOARDING then return end
    local _, total = readyCounts()
    for _, t in ipairs(waitingTickets()) do
        Bridge.Notify(t.src, 'Boarding has closed for this flight. You will be on the next one.', 'info')
    end
    if total == 0 then
        Flight.boardingEndsAt = nil
        return
    end
    Flight.state = S.READY_CHECK
    Flight.readyEndsAt = now() + Config.Boarding.readinessTimeout * 1000
    publishGlobal()
    LF.Debug('Boarding closed - READY_CHECK')
    broadcastManifest()
end

local function depart()
    if not Flight or (Flight.state ~= S.READY_CHECK and Flight.state ~= S.BOARDING) then return end
    -- Drop anyone not seated yet (still loading in) so they can't stall the flight.
    for src, p in pairs(Flight.passengers) do
        if not p.seated then removePassenger(src, 'removed', 'requeue') end
    end
    if not Flight or countTable(Flight.passengers) == 0 then return end

    Flight.countdownEndsAt = nil
    for src, p in pairs(Flight.passengers) do
        p.ticket = Tickets[p.identifier]
        Tickets[p.identifier] = nil                 -- ticket consumed at the lock point (stub stays as a keepsake)
    end
    pickController()
    startPhase(S.TAXIING)
end

function startPhase(state, elapsedMs)
    if not Flight then return end
    Flight.state = state
    Flight.phaseStart = now() - (elapsedMs or 0)
    Flight.lastSync = now()
    publishGlobal()
    LF.Debug('Phase -> ' .. state)
    toPassengers('lastflight:client:phase', {
        flightId = Flight.id, state = state, elapsed = elapsedMs or 0,
        netId = Flight.netId, groundOffset = Flight.groundOffset,
    })
end

-- Runway: [optional captain announcement] -> seatbelt chime -> everyone buckles -> TAKEOFF
local function seatbeltSequence()
    Flight.pendingAudio = nil
    Flight.audioDeadline = nil
    toPassengers('lastflight:client:seatbelt', Flight.id, Config.Seatbelt.requireBuckle)
    local id = Flight.id
    local chime = Config.Audio.seatbelt.enabled and Config.Audio.seatbelt.fallbackDuration or 1
    if Config.Seatbelt.requireBuckle then
        Flight.pendingBuckle = {}
        for src in pairs(Flight.passengers) do Flight.pendingBuckle[src] = true end
        -- the tick starts TAKEOFF once everyone is buckled or this passes
        Flight.buckleDeadline = now() + (chime + Config.Seatbelt.timeout) * 1000
        Flight.buckleEarliest = now() + chime * 1000   -- let the chime / warning show first
    else
        SetTimeout((chime + 3) * 1000, function()
            if Flight and Flight.id == id and Flight.state == S.RUNWAY_WAIT then
                startPhase(S.TAKEOFF)
            end
        end)
    end
end
local afterAnnouncement = seatbeltSequence

local function broadcastBuckles()
    local total, done = 0, 0
    for src in pairs(Flight.passengers) do
        total = total + 1
        if not Flight.pendingBuckle[src] then done = done + 1 end
    end
    toPassengers('lastflight:client:buckleStatus', Flight.id, done, total)
end

local function runwaySequence()
    local id = Flight.id
    SetTimeout(1500, function()
        if not Flight or Flight.id ~= id or Flight.state ~= S.RUNWAY_WAIT then return end
        if not Config.Audio.pilot.enabled then return seatbeltSequence() end
        Flight.pendingAudio = {}
        for src in pairs(Flight.passengers) do Flight.pendingAudio[src] = true end
        Flight.audioDeadline = now() + Config.Audio.announcementTimeout * 1000
        toPassengers('lastflight:client:announcement', Flight.id)
    end)
end

local function beginEnding()
    Flight.state = S.ENDING
    publishGlobal()
    Flight.pendingFarewell = {}
    for src in pairs(Flight.passengers) do Flight.pendingFarewell[src] = true end
    Flight.farewellDeadline = now() + (Config.Farewell.displayDuration + Config.Cinematics.fadeDuration + 15) * 1000
    toPassengers('lastflight:client:farewell', Flight.id)
    if countTable(Flight.pendingFarewell) == 0 then beginCleanup('done') end
end

local function completePassenger(src)
    if not Flight or not Flight.passengers[src] then return end
    local p = Flight.passengers[src]
    Flight.passengers[src] = nil
    if Flight.pendingFarewell then Flight.pendingFarewell[src] = nil end
    if Flight.controller == src then Flight.controller = nil end

    local F = Config.Farewell
    local mode = LF.Modes[LF.Mode()]
    if mode.record then recordCompletion(p.identifier) end   -- admin test runs never use up a one-time flight
    -- 'city' = Legion Square shuttle stop (the client snaps to a free spot next to the NPC)
    local back = F.testReturn
    if F.returnTo == 'city' and Config.Transport.city and Config.Transport.city.npc then
        local n = Config.Transport.city.npc
        local r = math.rad(n.w)
        -- 2.5 m behind the NPC (they face the road), on the pavement, facing them
        back = vector4(n.x + math.sin(r) * 2.5, n.y - math.cos(r) * 2.5, n.z, n.w)
    end
    local where = F.returnTo == 'city' and 'Legion Square' or 'the airport'
    if mode.kick and F.disconnectOnCompletion then
        if not F.allowReconnect and F.reconnectCooldown > 0 then
            reconnectBlock[p.identifier] = os.time() + F.reconnectCooldown
        end
        DropPlayer(src, F.disconnectReason)
    elseif LF.Mode() == 'test' then
        TriggerClientEvent('lastflight:client:testReturn', src, back, ('TEST MODE: you are back at %s.'):format(where))
    else
        TriggerClientEvent('lastflight:client:testReturn', src, back,
            'Welcome back to Los Santos. Thank you for flying with us one last time.')
    end

    if Flight.pendingFarewell and countTable(Flight.pendingFarewell) == 0 then
        beginCleanup('done')
    end
end

-- Removes the aircraft, resets and prepares the next flight.
function beginCleanup(reason)
    if not Flight or Flight.cleaning then return end
    local f = Flight
    f.cleaning = true
    f.state = S.CLEANUP
    publishGlobal()
    LF.Debug('Cleanup (' .. tostring(reason) .. ')')

    -- Give test-mode / restored players a moment to be teleported off the jet.
    SetTimeout(3000, function()
        for src in pairs(f.passengers) do
            restorePlayer(src, 'The flight was ended.')
        end
        Wait(1500)
        removeAircraft(f, 'cleanup: ' .. tostring(reason))
        if f.noFollowUp then return end
        if Flight == f then Flight = nil end
        cooldownUntil = now() + Config.Aircraft.cooldown * 1000
        publishGlobal()
        SetTimeout(Config.Aircraft.cooldown * 1000 + 100, function()
            if not Flight and (#waitingTickets() > 0 or Config.Aircraft.spawnOnStart) then
                openNextFlight()
            end
        end)
    end)
end
finishFlight = beginCleanup

---------------------------------------------------------------------------
-- Admin API
---------------------------------------------------------------------------
function LFS.Status()
    local passengers, ready = 0, 0
    if Flight then
        for _, p in pairs(Flight.passengers) do
            passengers = passengers + 1
            if p.ready then ready = ready + 1 end
        end
    end
    local aircraft = 'none'
    if Flight and Flight.veh then
        if DoesEntityExist(Flight.veh) then
            local c = GetEntityCoords(Flight.veh)
            aircraft = ('at %.0f, %.0f, %.0f | net %d | owner %s'):format(c.x, c.y, c.z, Flight.netId, tostring(NetworkGetEntityOwner(Flight.veh)))
        else
            aircraft = 'LOST'
        end
    end
    return {
        state = Flight and Flight.state or S.IDLE, flightId = Flight and Flight.id or 0,
        passengers = passengers, ready = ready, capacity = Flight and capacity() or Config.Aircraft.maxPassengers,
        queue = #waitingTickets(), tickets = countTable(Tickets), aircraft = aircraft,
        controller = Flight and Flight.controller or 'none', shuttles = countTable(Rides),
    }
end

-- policy: 'refund' | 'requeue'
function LFS.Cancel(policy)
    if not Flight then return false end
    local f = Flight
    for src in pairs(f.passengers) do
        removePassenger(src, 'cancel', policy)
        if Flight ~= f then break end
    end
    if Flight == f then beginCleanup('cancel') end
    return true
end

-- respawn: true = put a fresh jet back even if nobody holds a ticket
function LFS.Reset(respawn, reason)
    local hadAircraft = Flight ~= nil and Flight.veh ~= nil
    if Flight then Flight.noFollowUp = true end   -- its cleanup timer must not start a cooldown / respawn
    LFS.Cancel('requeue')
    if Flight then
        removeAircraft(Flight, reason or 'reset')
        Flight = nil
    end
    cleanupOrphans()
    cooldownUntil = 0
    publishGlobal()
    if respawn == nil then respawn = hadAircraft end
    if respawn or #waitingTickets() > 0 or Config.Aircraft.spawnOnStart then
        SetTimeout(5000, function() if not Flight then openNextFlight() end end)
    end
end

-- /lastflight spawn: put the jet out now (for setup / testing)
function LFS.SpawnNow()
    if Flight then return false end
    cooldownUntil = 0
    spawnBlocked, quickLosses = false, 0
    openNextFlight()
    return Flight ~= nil
end

function LFS.ForceDepart()
    if not Flight then return false end
    if Flight.state == S.BOARDING then
        local _, total = readyCounts()
        if total == 0 then return false end
        closeBoarding()
    end
    if Flight.state == S.READY_CHECK then
        for _, p in pairs(Flight.passengers) do if p.seated then p.ready = true end end
        depart()
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Main tick (1 Hz, only does work while a flight exists)
---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(1000)
        local f = Flight
        if f and not f.cleaning and f.state ~= S.CLEANUP then
            local t = now()

            -- Aircraft lost / destroyed
            if not f.veh or not DoesEntityExist(f.veh) or f.destroyed then
                LF.Warn('Aircraft entity lost in state ' .. f.state)
                if not f.destroyed and f.spawnedAt and t - f.spawnedAt < 20000 then
                    quickLosses = quickLosses + 1
                    LF.Warn('The jet was deleted by another resource right after spawning.'
                        .. (blacklistActive() and ' qbx_entitiesblacklist is active - ' .. BLACKLIST_HELP or ''))
                    if quickLosses >= 2 then
                        spawnBlocked = true
                        LF.Warn('Stopped respawning the jet to avoid a spawn/delete loop. Fix the blacklist, then use /'
                            .. Config.Admin.command .. ' spawn.')
                    end
                end
                if LF.Locked[f.state] and f.state ~= S.TAXIING and f.state ~= S.RUNWAY_WAIT then
                    if f.state ~= S.ENDING then beginEnding() end
                else
                    LFS.Cancel('requeue')
                end
                goto continue
            end

            -- Disconnected passengers that slipped through
            for src in pairs(f.passengers) do
                if not GetPlayerName(src) then removePassenger(src, 'dropped') end
            end
            if Flight ~= f then goto continue end

            if f.state == S.BOARDING then
                local ready, total = readyCounts()
                if f.boardingEndsAt and t >= f.boardingEndsAt then
                    -- hold the doors while the gate shuttle brings more passengers (capped)
                    local bringing = LFS.GateShuttleBringing and LFS.GateShuttleBringing()
                    if bringing and not f.shuttleHoldUntil then
                        f.shuttleHoldUntil = t + (Config.Boarding.shuttleHoldMax or 180) * 1000
                        LF.Debug('Holding boarding for the gate shuttle')
                        broadcastManifest()
                    end
                    if not bringing or t >= f.shuttleHoldUntil then
                        f.shuttleHoldUntil = nil
                        closeBoarding()
                    end
                elseif Config.Boarding.closeEarlyWhenAllReady and total > 0 and ready == total
                    and total >= Config.Boarding.minimumPassengers and #waitingTickets() == 0 then
                    closeBoarding()
                end
                if t - f.lastSync > 5000 then f.lastSync = t; broadcastManifest() end

            elseif f.state == S.READY_CHECK then
                local ready, total = readyCounts()
                if total > 0 and ready == total and total >= Config.Boarding.minimumPassengers then
                    if not f.countdownEndsAt then
                        f.countdownEndsAt = t + Config.Boarding.departureCountdown * 1000
                        broadcastManifest()
                    elseif t >= f.countdownEndsAt then
                        depart()
                        goto continue
                    end
                elseif f.countdownEndsAt then
                    f.countdownEndsAt = nil
                    broadcastManifest()
                end

                if not f.countdownEndsAt and f.readyEndsAt and t >= f.readyEndsAt then
                    LF.Debug('Readiness timeout')
                    local policy = Config.Boarding.unreadyPolicy
                    if Config.Boarding.removeUnreadyPassengers then
                        for src, p in pairs(f.passengers) do
                            if not p.ready then removePassenger(src, 'unready', policy) end
                        end
                    else
                        for src in pairs(f.passengers) do removePassenger(src, 'unready', policy) end
                    end
                    if Flight == f then
                        ready, total = readyCounts()
                        if total >= Config.Boarding.minimumPassengers and ready == total and total > 0 then
                            f.countdownEndsAt = t + Config.Boarding.departureCountdown * 1000
                        else
                            -- not enough passengers: reopen boarding with whoever is still aboard
                            f.state = S.BOARDING
                            f.readyEndsAt = nil
                            f.boardingEndsAt = total > 0 and (t + Config.Boarding.boardingDuration * 1000) or nil
                            publishGlobal()
                        end
                        broadcastManifest()
                    end
                elseif t - f.lastSync > 5000 then
                    f.lastSync = t
                    broadcastManifest()
                end

            elseif LF.Moving[f.state] then
                pickController()
                local elapsed = t - f.phaseStart
                local phase = LF.Timeline[f.state]
                if elapsed >= phase.duration * 1000 then
                    if f.state == S.TAXIING then
                        startPhase(S.RUNWAY_WAIT)
                        runwaySequence()
                    elseif f.state == S.TAKEOFF then
                        startPhase(S.CRUISING)
                    elseif f.state == S.CRUISING then
                        startPhase(S.FINAL_DEPARTURE)
                    elseif f.state == S.FINAL_DEPARTURE then
                        beginEnding()
                    end
                elseif t - f.lastSync > 5000 then
                    f.lastSync = t
                    toPassengers('lastflight:client:sync', f.id, f.state, elapsed, f.netId)
                end

            elseif f.state == S.RUNWAY_WAIT then
                if f.pendingAudio and (countTable(f.pendingAudio) == 0 or t >= f.audioDeadline) then
                    afterAnnouncement()
                elseif f.pendingBuckle and t >= f.buckleEarliest
                    and (countTable(f.pendingBuckle) == 0 or t >= f.buckleDeadline) then
                    f.pendingBuckle = nil
                    toPassengers('lastflight:client:buckleDone', f.id)
                    startPhase(S.TAKEOFF)
                end

            elseif f.state == S.ENDING then
                if f.pendingFarewell then
                    if t >= f.farewellDeadline then
                        for src in pairs(f.pendingFarewell) do completePassenger(src) end
                        if Flight == f and not f.cleaning then beginCleanup('farewell-timeout') end
                    elseif countTable(f.pendingFarewell) == 0 then
                        beginCleanup('done')
                    end
                end
            end
        elseif not f and Config.Enabled and #waitingTickets() > 0 and now() >= cooldownUntil then
            openNextFlight()
        end
        ::continue::
    end
end)

---------------------------------------------------------------------------
-- ETA for queued customers (nil = unknown)
---------------------------------------------------------------------------
local function estimateBoarding()
    if not Flight then
        return math.max(0, (cooldownUntil - now()) / 1000)
    end
    if Flight.state == S.BOARDING then
        local _, total = readyCounts()
        if total < capacity() then return 0 end
        return nil
    end
    if not LF.Locked[Flight.state] or Flight.state == S.CLEANUP then return nil end

    local order = { S.TAXIING, S.RUNWAY_WAIT, S.TAKEOFF, S.CRUISING, S.FINAL_DEPARTURE }
    local remaining, counting = 0, false
    local elapsed = (now() - (Flight.phaseStart or now())) / 1000
    for _, st in ipairs(order) do
        local dur = st == S.RUNWAY_WAIT and ((Config.Audio.pilot.enabled and Config.Audio.pilot.fallbackDuration or 0)
            + (Config.Audio.seatbelt.enabled and Config.Audio.seatbelt.fallbackDuration or 1) + (Config.Seatbelt.requireBuckle and Config.Seatbelt.timeout or 1) + 2)
            or LF.Timeline[st].duration
        if st == Flight.state then
            counting = true
            remaining = remaining + math.max(0, dur - elapsed)
        elseif counting then
            remaining = remaining + dur
        end
    end
    if Flight.state == S.ENDING then remaining = Config.Farewell.displayDuration + 5 end
    return remaining + Config.Farewell.displayDuration + 10 + Config.Aircraft.cooldown
end

local function deskInfo(src)
    local ticket = ticketOf(src)
    local status = 'none'
    if Flight and Flight.passengers[src] then
        status = 'aboard'
    elseif ticket then
        local open = Flight and (Flight.state == S.BOARDING or Flight.spawning) and not Flight.cleaning
            and countTable(Flight.passengers) < capacity()
        status = open and 'boarding' or 'queued'
    end
    return {
        price = Config.Tickets.price, flight = Config.Flight.number,
        destination = Config.Flight.destination, airport = Config.Flight.airport,
        status = status, ticketId = ticket and ticket.id or nil,
        eta = (status == 'queued') and estimateBoarding() or nil,
        shuttle = Config.Transport.shuttle.enabled, drive = Config.Transport.driveYourself,
        completed = Config.Farewell.oneTimeParticipation and hasCompleted(Bridge.Identifier(src)) or false,
    }
end

---------------------------------------------------------------------------
-- Net events
---------------------------------------------------------------------------
local function nearNpc(src)
    local c = pedCoords(src)
    local n = Config.Airport.npc.coords
    return c and #(c - vector3(n.x, n.y, n.z)) <= Config.Airport.npc.interactDistance + 4.0
end

RegisterNetEvent('lastflight:server:openDesk', function()
    local src = source
    if not Config.Enabled or rateLimited(src, 300, 'desk') then return end
    if not nearNpc(src) then return end
    TriggerClientEvent('lastflight:client:deskInfo', src, deskInfo(src))
end)

RegisterNetEvent('lastflight:server:ticketStatus', function()
    local src = source
    if rateLimited(src, 300, 'status') then return end
    TriggerClientEvent('lastflight:client:ticketStatus', src, deskInfo(src))
end)

RegisterNetEvent('lastflight:server:buyTicket', function()
    local src = source
    if not Config.Enabled or purchasing[src] then return end
    purchasing[src] = true

    local function finish(ok, msg)
        purchasing[src] = nil
        TriggerClientEvent('lastflight:client:ticketResult', src, ok, msg, deskInfo(src))
    end

    if not nearNpc(src) then return finish(false, 'You are too far from the counter.') end
    local identifier = Bridge.Identifier(src)
    if Tickets[identifier] then return finish(false, 'You already hold a ticket for this flight.') end
    if Flight and Flight.passengers[src] then return finish(false, 'You are already aboard.') end
    if Config.Farewell.oneTimeParticipation and hasCompleted(identifier) then
        return finish(false, 'Our records show you have already taken the last flight.')
    end

    local price = Config.Tickets.price
    local ok, account = Bridge.Charge(src, price)
    if not ok then return finish(false, ('You need $%d to buy a ticket.'):format(price)) end

    ticketSeq = ticketSeq + 1
    local ticket = {
        id = ticketSeq, identifier = identifier, src = src, paid = price,
        account = account, status = 'waiting', purchasedAt = os.time(),
    }
    Tickets[identifier] = ticket
    Bridge.GiveTicketItem(src, ticket)
    LF.Debug(('Ticket #%d sold to %s (%s)'):format(ticket.id, src, account))

    if not Flight then ensureFlight() end
    finish(true, 'Ticket purchased. Have a pleasant flight!')
end)

-- kind: 'gate' (airport desk -> plane, needs a ticket) | 'city' (city pickup -> airport)
RegisterNetEvent('lastflight:server:requestShuttle', function(kind)
    local src = source
    if rateLimited(src, 2000, 'shuttle') then return end
    kind = kind == 'city' and 'city' or 'gate'
    local S2 = Config.Transport.shuttle
    local CT = Config.Transport.city

    if kind == 'city' then
        if not CT.enabled or not Config.Enabled then return end
        local c = pedCoords(src)
        if not c or #(c - vector3(CT.npc.x, CT.npc.y, CT.npc.z)) > CT.interactDistance + 4.0 then return end
        if CT.requireTicket and not ticketOf(src) then
            return Bridge.Notify(src, 'You need a Last Flight ticket for this taxi. Tickets are sold at LSIA.', 'error')
        end
    else
        if not S2.enabled then return end
        if not ticketOf(src) then return Bridge.Notify(src, 'You need a ticket to use the airport shuttle.', 'error') end
        if not nearNpc(src) then return end
    end

    LFS.RequestRide(src, kind)
end)

---------------------------------------------------------------------------
-- Shared shuttles ('city' = Legion Square -> airport, 'gate' = airport desk
-- -> plane). Each bus has an id. The first player to call it spawns it and
-- everyone else who asks while it waits at the curb rides the same bus.
--   gate: one bus at a time - a new one only after the last is deleted
--   city: a new bus may spawn once the previous one has been on the road
--         for Config.Transport.city.respawnAfter seconds (no stacking)
-- The bus is spawned/driven by one rider's client (the "controller"); if that
-- player gets off or drops, another rider's client takes over.
---------------------------------------------------------------------------
local rideSeq = 0
local rideWaiters = { city = {}, gate = {} }     -- told "it just left" - notified when one is available
local gateWalkers, gateWalkUntil = {}, 0         -- riders just dropped at the jet, walking to the marker

local function rideCfg(kind) return kind == 'city' and Config.Transport.city or Config.Transport.shuttle end

local function rideEvent(ride, event, ...)
    for src in pairs(ride.riders) do TriggerClientEvent(event, src, ride.id, ...) end
end

local function rideStatus(ride)
    -- only a real departure time (someone buckled); before that the prompt says "waiting for passengers"
    local leaveAt = ride.departAt and math.max(ride.departAt, ride.earliestDepart or 0) or nil
    rideEvent(ride, 'lastflight:client:rideStatus', {
        state = ride.state, seated = countTable(ride.seated), buckled = countTable(ride.buckled),
        riders = countTable(ride.riders),
        leavesIn = leaveAt and math.max(0, math.ceil((leaveAt - now()) / 1000)) or nil,
    })
end

-- Everyone who asked for this bus is aboard and buckled?
local function rideAllBuckled(ride)
    local any = false
    for src in pairs(ride.riders) do
        if not ride.seated[src] or not ride.buckled[src] then return false end
        any = true
    end
    return any
end

-- The bus of this kind still at the curb (taking passengers), if any
local function boardingRide(kind)
    for _, r in pairs(Rides) do
        if r.kind == kind and (r.state == 'spawning' or r.state == 'waiting') then return r end
    end
end

local function rideOf(src)
    for _, r in pairs(Rides) do
        if r.riders[src] then return r end
    end
end

-- Can a NEW bus of this kind spawn? Returns ok, secondsToWait
local function canSpawnRide(kind)
    for _, r in pairs(Rides) do
        if r.kind == kind then
            if kind ~= 'city' then return false end
            if r.state ~= 'driving' and r.state ~= 'arrived' then return false end
            if r.state == 'driving' then
                local left = (Config.Transport.city.respawnAfter or 20) * 1000 - (now() - r.departedAt)
                if left > 0 then return false, math.ceil(left / 1000) end
            end
        end
    end
    return true
end

local function notifyWaiters(kind)
    for src in pairs(rideWaiters[kind]) do
        if GetPlayerName(src) then
            Bridge.Notify(src, kind == 'city' and 'A new airport shuttle is ready at Legion Square - talk to the driver.'
                or 'The gate shuttle is back at the curb.', 'success')
        end
    end
    rideWaiters[kind] = {}
end

local function endRide(ride, reason)
    if Rides[ride.id] ~= ride then return end
    Rides[ride.id] = nil
    for _, net in ipairs({ ride.ped, ride.veh }) do
        if net then
            local ent = NetworkGetEntityFromNetworkId(net)
            if ent and ent ~= 0 then deleteEntity(ent) end
        end
    end
    rideEvent(ride, 'lastflight:client:rideEnded')
    if canSpawnRide(ride.kind) then notifyWaiters(ride.kind) end
    LF.Debug(('Shuttle %s #%d ended (%s)'):format(ride.kind, ride.id, tostring(reason)))
end

-- Prefers a seated rider; ends the ride when nobody is left.
local function pickRideController(ride)
    if ride.controller and ride.riders[ride.controller] and GetPlayerName(ride.controller) then return end
    ride.controller = nil
    for src in pairs(ride.seated) do ride.controller = src break end
    if not ride.controller and ride.state ~= 'driving' then
        for src in pairs(ride.riders) do ride.controller = src break end
    end
    if not ride.controller then return endRide(ride, 'no riders left') end
    LF.Debug(('Shuttle %s #%d controller -> %s'):format(ride.kind, ride.id, ride.controller))
    TriggerClientEvent('lastflight:client:rideController', ride.controller, ride.id, ride.state, ride.wp or 1)
end

local function removeRider(src, ride)
    if not ride or not ride.riders[src] then return end
    ride.riders[src], ride.seated[src], ride.buckled[src] = nil, nil, nil
    if ride.state == 'spawning' and ride.controller == src then return endRide(ride, 'spawner left') end
    pickRideController(ride)
    if Rides[ride.id] == ride then rideStatus(ride) end
end

function LFS.RequestRide(src, kind)
    if rideOf(src) then return Bridge.Notify(src, 'You are already on the shuttle list - hop on!', 'info') end

    local ride = boardingRide(kind)
    if ride then
        ride.riders[src] = true
        -- give every late joiner time to walk over and get on
        local grace = (rideCfg(kind).joinGrace or 15) * 1000
        ride.earliestDepart = math.max(ride.earliestDepart or 0, now() + grace)
        if ride.state == 'waiting' then
            TriggerClientEvent('lastflight:client:rideJoin', src, ride.id, kind, ride.veh, ride.ped)
        end
        Bridge.Notify(src, 'A shuttle is already waiting at the curb - hop on, it leaves soon.', 'success')
        rideStatus(ride)
        return
    end

    local ok, wait = canSpawnRide(kind)
    if not ok then
        rideWaiters[kind][src] = true
        if kind == 'city' and wait then
            return Bridge.Notify(src, ('The last shuttle just pulled away. A new one will be ready in about %ds - '
                .. 'we will let you know.'):format(wait), 'info')
        end
        return Bridge.Notify(src, 'The shuttle just left with other passengers. It will be back shortly - '
            .. 'we will let you know, or you can make your own way.', 'info')
    end

    rideSeq = rideSeq + 1
    Rides[rideSeq] = {
        id = rideSeq, kind = kind, state = 'spawning', controller = src, riders = { [src] = true },
        seated = {}, buckled = {}, createdAt = now(), wp = 1,
    }
    TriggerClientEvent('lastflight:client:shuttleApproved', src, rideSeq, kind)
end

RegisterNetEvent('lastflight:server:rideSpawned', function(id, vehNet, pedNet, capacity)
    local src = source
    local ride = Rides[id]
    if not ride or ride.state ~= 'spawning' or ride.controller ~= src then return end
    ride.veh, ride.ped = tonumber(vehNet), tonumber(pedNet)
    ride.capacity = math.max(1, math.min(tonumber(capacity) or 8, 32))
    ride.state = 'waiting'
    ride.waitDeadline = now() + 90000
    -- minimum time at the curb so one player can't call it and leave before others can join
    ride.earliestDepart = math.max(ride.earliestDepart or 0, now() + (rideCfg(ride.kind).minWait or 30) * 1000)
    for _, net in ipairs({ ride.veh, ride.ped }) do
        local ent = net and NetworkGetEntityFromNetworkId(net)
        if ent and ent ~= 0 then Entity(ent).state:set('lf_shuttle', ride.kind, true) end
    end
    for rider in pairs(ride.riders) do
        if rider ~= src then TriggerClientEvent('lastflight:client:rideJoin', rider, ride.id, ride.kind, ride.veh, ride.ped) end
    end
    rideStatus(ride)
end)

RegisterNetEvent('lastflight:server:rideSeated', function(id, seated)
    local src = source
    local ride = Rides[id]
    if not ride or not ride.riders[src] or ride.state ~= 'waiting' then return end
    ride.seated[src] = seated == true or nil
    if not seated then ride.buckled[src] = nil end
    if seated and not ride.seatDeadline then
        -- nobody buckles at all (AFK): leave anyway with whoever is seated
        ride.seatDeadline = now() + ((rideCfg(ride.kind).buckleTimeout or 45) + 30) * 1000
    end
    rideStatus(ride)
end)

-- Seated rider pressed the buckle key (G). The bus leaves when everyone is buckled.
RegisterNetEvent('lastflight:server:rideBuckle', function(id)
    local src = source
    local ride = Rides[id]
    if not ride or ride.state ~= 'waiting' or not ride.seated[src] or ride.buckled[src] then return end
    ride.buckled[src] = true
    -- backstop so one AFK rider can't hold the bus forever
    ride.departAt = ride.departAt or (now() + (rideCfg(ride.kind).buckleTimeout or 45) * 1000)
    if rideAllBuckled(ride) or countTable(ride.buckled) >= ride.capacity then ride.departAt = now() end
    rideStatus(ride)
end)

RegisterNetEvent('lastflight:server:rideLeft', function(id)
    removeRider(source, Rides[id])
end)

RegisterNetEvent('lastflight:server:rideProgress', function(id, wp)
    local ride = Rides[id]
    if ride and ride.controller == source then ride.wp = tonumber(wp) or ride.wp end
end)

RegisterNetEvent('lastflight:server:rideBlink', function(id)
    local ride = Rides[id]
    if not ride or ride.controller ~= source then return end
    for rider in pairs(ride.riders) do
        if rider ~= source then TriggerClientEvent('lastflight:client:rideBlink', rider, ride.id) end
    end
end)

RegisterNetEvent('lastflight:server:rideArrived', function(id)
    local ride = Rides[id]
    if not ride or ride.controller ~= source or ride.state ~= 'driving' then return end
    ride.state = 'arrived'
    if ride.kind == 'gate' then
        gateWalkers = {}
        for src in pairs(ride.riders) do gateWalkers[src] = true end
        gateWalkUntil = now() + (Config.Transport.shuttle.walkGrace or 45) * 1000
    end
    rideEvent(ride, 'lastflight:client:rideExit')
    SetTimeout((rideCfg(ride.kind).despawnDelay or 6) * 1000, function()
        endRide(ride, 'arrived')
    end)
end)

RegisterNetEvent('lastflight:server:rideFailed', function(id)
    local ride = Rides[id]
    if not ride or ride.controller ~= source then return end
    rideEvent(ride, 'lastflight:client:rideRescue')
    endRide(ride, 'failed')
end)

-- 1 Hz: departures + safety timeouts
CreateThread(function()
    while true do
        Wait(1000)
        local t = now()
        for _, ride in pairs(Rides) do
            if ride.state == 'spawning' and t - ride.createdAt > 20000 then
                endRide(ride, 'spawn timeout')
            elseif ride.state == 'waiting' then
                if t - (ride.lastStatus or 0) > 5000 then ride.lastStatus = t; rideStatus(ride) end
                if rideAllBuckled(ride) then ride.departAt = math.min(ride.departAt or t, t) end
                if not ride.departAt and ride.seatDeadline and t >= ride.seatDeadline then ride.departAt = t end
                if ride.departAt and t >= ride.departAt and t >= (ride.earliestDepart or 0) then
                    -- leave behind anyone who asked but never got on
                    for src in pairs(ride.riders) do
                        if not ride.seated[src] then
                            ride.riders[src] = nil
                            rideWaiters[ride.kind][src] = true
                            TriggerClientEvent('lastflight:client:rideEnded', src, ride.id)
                            Bridge.Notify(src, 'The shuttle left without you. We will let you know when the next one is ready.', 'info')
                        end
                    end
                    if countTable(ride.seated) == 0 then
                        endRide(ride, 'nobody aboard')
                    else
                        ride.state, ride.departedAt = 'driving', t
                        ride.controller = ride.seated[ride.controller] and ride.controller or nil
                        pickRideController(ride)
                        if Rides[ride.id] == ride then
                            TriggerClientEvent('lastflight:client:rideDepart', ride.controller, ride.id)
                            rideStatus(ride)
                        end
                    end
                elseif not ride.departAt and countTable(ride.seated) == 0 and t >= ride.waitDeadline then
                    rideEvent(ride, 'lastflight:client:rideTimedOut')
                    endRide(ride, 'nobody boarded')
                end
            elseif ride.state == 'driving' and t - ride.departedAt > (ride.kind == 'city' and 600000 or 240000) then
                rideEvent(ride, 'lastflight:client:rideRescue')
                endRide(ride, 'trip timeout')
            end
        end
        -- city: the previous bus has been on the road long enough - tell whoever was waiting
        if next(rideWaiters.city) and canSpawnRide('city') then notifyWaiters('city') end
    end
end)

function LFS.RideCount() return countTable(Rides) end

-- Is the gate shuttle bringing ticket holders (on the way, or just dropped
-- them off and they are walking over)? The plane holds boarding for them.
function LFS.GateShuttleBringing()
    local function waiting(src)
        local tk = ticketOf(src)
        return tk and tk.status == 'waiting'
    end
    for _, ride in pairs(Rides) do
        if ride.kind == 'gate' then
            for src in pairs(ride.riders) do
                if waiting(src) then return true end
            end
        end
    end
    if now() < gateWalkUntil then
        for src in pairs(gateWalkers) do
            if GetPlayerName(src) and waiting(src) then return true end
        end
    end
    return false
end

-- fromShuttle: a rider of the gate shuttle that just arrived at the jet is
-- boarded straight from the bus (no walking to the marker)
RegisterNetEvent('lastflight:server:board', function(fromShuttle)
    local src = source
    if rateLimited(src, 1000, 'board') then return end
    local gate = rideOf(src)
    fromShuttle = fromShuttle == true and gate ~= nil and gate.kind == 'gate' and gate.state == 'arrived'
    if not Flight or Flight.state ~= S.BOARDING or Flight.cleaning then
        return Bridge.Notify(src, 'Boarding is not open right now.', 'error')
    end
    if Flight.passengers[src] then return end

    local ticket = ticketOf(src)
    if not ticket or ticket.status ~= 'waiting' then
        return Bridge.Notify(src, 'You need a ticket from the check-in desk.', 'error')
    end
    if Config.Inventory.requireItemToBoard and not Bridge.HasTicketItem(src) then
        return Bridge.Notify(src, 'Please show your boarding pass.', 'error')
    end
    local c = pedCoords(src)
    if not c then return end
    if not fromShuttle and #(c - Config.Airport.boardingPoint) > Config.Airport.boardingRadius + 6.0 then return end
    if fromShuttle and #(c - Config.Airport.boardingPoint) > 150.0 then return end   -- still has to be at the jet

    if countTable(Flight.passengers) >= capacity() then
        return Bridge.Notify(src, 'This flight is full. You will be on the next one.', 'error')
    end

    -- seat assignment
    local mode, seatKey, seat = 'seat', nil, nil
    if Config.Aircraft.seatMode == 'attach' then mode = 'attach' end
    if mode == 'seat' then
        local limit = Flight.seatCapacity or Config.Aircraft.maxPassengers
        for i = 0, limit - 1 do
            if not Flight.seats['s' .. i] and not Flight.badSeats[i] then seat = i break end
        end
        if not seat then
            if Config.Aircraft.seatMode == 'auto' then mode = 'attach' else
                return Bridge.Notify(src, 'No usable seats left on this aircraft.', 'error')
            end
        else
            seatKey = 's' .. seat
        end
    end
    if mode == 'attach' then
        for i = 1, #Config.Aircraft.attachOffsets do
            if not Flight.seats['a' .. i] then seat = i break end
        end
        if not seat then return Bridge.Notify(src, 'This flight is full. You will be on the next one.', 'error') end
        seatKey = 'a' .. seat
    end

    Flight.seats[seatKey] = src
    Flight.passengers[src] = {
        identifier = ticket.identifier, seat = seat, seatKey = seatKey, mode = mode,
        ready = false, seated = false, joinedAt = now(),
    }
    ticket.status = 'boarded'
    ticket.src = src

    TriggerClientEvent('lastflight:client:board', src, {
        flightId = Flight.id, netId = Flight.netId, seat = seat, mode = mode,
        flight = Config.Flight.number, destination = Config.Flight.destination,
    })

    -- If the client never confirms, free the seat.
    local id = Flight.id
    SetTimeout(15000, function()
        if Flight and Flight.id == id and Flight.passengers[src] and not Flight.passengers[src].seated then
            removePassenger(src, 'removed', 'requeue')
            Bridge.Notify(src, 'Boarding failed. Please try again.', 'error')
        end
    end)
end)

RegisterNetEvent('lastflight:server:seatResult', function(flightId, ok, modelSeats, foundAircraft)
    local src = source
    if not Flight or Flight.id ~= flightId then return end
    local p = Flight.passengers[src]
    if not p or p.seated then return end

    if not ok and foundAircraft == false then
        -- jet not streamed in on their side yet; not the seat's fault
        removePassenger(src, 'left', 'keep')
        return Bridge.Notify(src, 'Could not reach the aircraft. Step closer and try again.', 'error')
    end

    modelSeats = tonumber(modelSeats)
    if modelSeats and not Flight.seatCapacity and modelSeats >= 1 and modelSeats <= 64 then
        Flight.seatCapacity = math.max(0, math.floor(modelSeats) - 1)   -- minus the pilot seat
        LF.Debug(('Aircraft reports %d passenger seats'):format(Flight.seatCapacity))
    end

    if ok then
        p.seated = true
        local ticket = Tickets[p.identifier]
        if ticket then Bridge.TearTicket(src, ticket) end   -- full ticket -> torn stub
        if not Flight.boardingEndsAt and Flight.state == S.BOARDING then
            Flight.boardingEndsAt = now() + Config.Boarding.boardingDuration * 1000
        end
        pickController()
        broadcastManifest()
        return
    end

    -- seat failed: try next seat / attach fallback
    Flight.seats[p.seatKey] = nil
    if p.mode == 'seat' then Flight.badSeats[p.seat] = true end
    local nextSeat, nextMode
    if p.mode == 'seat' then
        local limit = Flight.seatCapacity or Config.Aircraft.maxPassengers
        for i = 0, limit - 1 do
            if not Flight.seats['s' .. i] and not Flight.badSeats[i] then nextSeat, nextMode = i, 'seat' break end
        end
    end
    if not nextSeat and Config.Aircraft.seatMode ~= 'seats' then
        for i = 1, #Config.Aircraft.attachOffsets do
            if not Flight.seats['a' .. i] then nextSeat, nextMode = i, 'attach' break end
        end
    end
    if not nextSeat then
        removePassenger(src, 'removed', 'requeue')
        return Bridge.Notify(src, 'No usable seats left on this aircraft.', 'error')
    end
    p.seat, p.mode = nextSeat, nextMode
    p.seatKey = (nextMode == 'seat' and 's' or 'a') .. nextSeat
    Flight.seats[p.seatKey] = src
    TriggerClientEvent('lastflight:client:board', src, {
        flightId = Flight.id, netId = Flight.netId, seat = nextSeat, mode = nextMode,
        flight = Config.Flight.number, destination = Config.Flight.destination,
    })
end)

RegisterNetEvent('lastflight:server:setReady', function(flightId, ready)
    local src = source
    if rateLimited(src, 400, 'ready') then return end
    if not Flight or Flight.id ~= flightId then return end
    local p = Flight.passengers[src]
    if not p or not p.seated then return end
    if Flight.state ~= S.BOARDING and Flight.state ~= S.READY_CHECK then return end
    ready = ready == true
    if p.ready == ready then return end
    p.ready = ready
    if not ready then Flight.countdownEndsAt = nil end
    broadcastManifest()
end)

RegisterNetEvent('lastflight:server:leave', function(flightId)
    local src = source
    if not Flight or Flight.id ~= flightId or not Flight.passengers[src] then return end
    if LF.Locked[Flight.state] then
        TriggerClientEvent('lastflight:client:reseat', src)   -- can't leave a moving jet
        return
    end
    removePassenger(src, 'left', 'keep')
    Bridge.Notify(src, 'You left the aircraft. Your ticket is still valid while boarding is open.', 'info')
end)

RegisterNetEvent('lastflight:server:groundOffset', function(flightId, offset)
    local src = source
    if not Flight or Flight.id ~= flightId or Flight.controller ~= src then return end
    offset = tonumber(offset)
    if offset and offset > 0 and offset < 20 and not Flight.groundOffset then
        Flight.groundOffset = offset
        toPassengers('lastflight:client:groundOffset', Flight.id, offset)
    end
end)

-- Only the controlling passenger can report the jet destroyed; the tick then recovers.
RegisterNetEvent('lastflight:server:aircraftDestroyed', function(flightId)
    local src = source
    if not Flight or Flight.id ~= flightId or Flight.controller ~= src then return end
    Flight.destroyed = true
end)

RegisterNetEvent('lastflight:server:buckle', function(flightId)
    local src = source
    if not Flight or Flight.id ~= flightId or Flight.state ~= S.RUNWAY_WAIT then return end
    if not Flight.pendingBuckle or not Flight.pendingBuckle[src] then return end
    Flight.pendingBuckle[src] = nil
    broadcastBuckles()
end)

RegisterNetEvent('lastflight:server:audioDone', function(flightId)
    local src = source
    if not Flight or Flight.id ~= flightId or not Flight.pendingAudio then return end
    Flight.pendingAudio[src] = nil
end)

RegisterNetEvent('lastflight:server:farewellDone', function(flightId)
    local src = source
    if not Flight or Flight.id ~= flightId or Flight.state ~= S.ENDING then return end
    if not Flight.pendingFarewell or not Flight.pendingFarewell[src] then return end
    completePassenger(src)
end)

-- A client that (re)loads mid-flight asks where it is.
RegisterNetEvent('lastflight:server:resync', function()
    local src = source
    if rateLimited(src, 2000, 'resync') then return end
    if not Flight or not Flight.passengers[src] then
        TriggerClientEvent('lastflight:client:notAboard', src)
        return
    end
    if LF.Moving[Flight.state] then
        TriggerClientEvent('lastflight:client:phase', src, {
            flightId = Flight.id, state = Flight.state, elapsed = now() - Flight.phaseStart,
            netId = Flight.netId, groundOffset = Flight.groundOffset,
        })
    end
end)

---------------------------------------------------------------------------
-- Players joining / leaving
---------------------------------------------------------------------------
AddEventHandler('playerConnecting', function(_, setKickReason)
    local src = source
    local id = Bridge.Identifier(src)
    local untilTime = reconnectBlock[id]
    if untilTime then
        if os.time() < untilTime then
            setKickReason(('You just took the last flight. You can rejoin in %d seconds.'):format(untilTime - os.time()))
            CancelEvent()
        else
            reconnectBlock[id] = nil
        end
    end
end)

AddEventHandler('playerJoining', function()
    local src = source
    local t = Tickets[Bridge.Identifier(src)]
    if t then t.src = src end
end)

AddEventHandler('playerDropped', function()
    local src = source
    purchasing[src], lastAction[src] = nil, nil
    removeRider(src, rideOf(src))
    rideWaiters.city[src], rideWaiters.gate[src] = nil, nil
    if Flight and Flight.passengers[src] then
        if Flight.state == S.ENDING then
            Flight.passengers[src] = nil
            if Flight.pendingFarewell then
                Flight.pendingFarewell[src] = nil
                if countTable(Flight.pendingFarewell) == 0 then beginCleanup('done') end
            end
        else
            removePassenger(src, 'dropped')
        end
    end
end)

---------------------------------------------------------------------------
-- Resource lifecycle
---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    cleanupOrphans()
    publishGlobal()
    local m = LF.Modes[LF.Mode()]
    print(('%s[lastflight] %s^7 - %s'):format(LF.Mode() == 'test' and '^3' or '^5', m.label, m.desc))
    if blacklistActive() then
        LF.Warn('qbx_entitiesblacklist is active. If "' .. Config.Aircraft.model .. '" is on its list the jet will vanish as soon as it spawns. '
            .. BLACKLIST_HELP)
    end
    if Config.Aircraft.spawnOnStart and Config.Enabled then
        SetTimeout(3000, openNextFlight)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if Config.Tickets.refundOnResourceStop then
        for _, t in pairs(Tickets) do
            if t.src and GetPlayerName(t.src) then
                Bridge.Refund(t.src, t.paid, t.account)
                Bridge.RemoveTicketItem(t.src, t)
            end
        end
    end
    if Flight then removeAircraft(Flight, 'resource stop') end
    for _, ride in pairs(Rides) do endRide(ride, 'resource stop') end
    GlobalState.lastflight = nil
end)

LFS.FormatTime = fmtTime
