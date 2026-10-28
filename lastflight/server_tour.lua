-- Farewell highway drive (second option at the city pickup NPC).
--
-- A "group" is one or more chauffeured cars that leave the curb together.
-- The player who asks picks how many people are coming; enough cars are
-- issued for them. Anyone else who asks while a group waits at the curb joins
-- it (if there are seats). Riders can get in any car of their group.
--
-- The asking player's client spawns the cars. Once they leave, each car is
-- driven by one of its own riders' clients (handed over if they drop).
-- A new group can be issued once the previous one has been driving for
-- Config.Tour.nextAfter seconds, up to Config.Tour.maxCars on the road.

local TC = Config.Tour
local Tours = {}           -- [id] = group
local seq = 0
local waiters = {}         -- told "not right now" - notified when a car is available
local lastAsk = {}

local function now() return GetGameTimer() end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function groupOf(src)
    for _, g in pairs(Tours) do
        if g.riders[src] then return g end
    end
end

function LFS.InTour(src) return groupOf(src) ~= nil end

local function boardingGroup()
    for _, g in pairs(Tours) do
        if g.state == 'spawning' or g.state == 'waiting' then return g end
    end
end

local function seatsTotal(g)
    if g.state == 'spawning' then return g.wanted * TC.seatsPerCar end
    local n = 0
    for _, c in pairs(g.cars) do if not c.gone then n = n + g.capacity end end
    return n
end

local function carsOnRoad()
    local n = 0
    for _, g in pairs(Tours) do
        if g.state == 'spawning' then
            n = n + g.wanted
        else
            for _, c in pairs(g.cars) do if not c.gone then n = n + 1 end end
        end
    end
    return n
end

-- ok, secondsToWait, reason
local function canIssue(cars)
    if boardingGroup() then return false, nil, 'boarding' end
    local wait = 0
    for _, g in pairs(Tours) do
        if g.state == 'driving' then
            local left = TC.nextAfter * 1000 - (now() - g.departedAt)
            if left > wait then wait = left end
        end
    end
    if wait > 0 then return false, math.ceil(wait / 1000), 'recent' end
    if carsOnRoad() + cars > TC.maxCars then return false, nil, 'full' end
    return true
end

local function carsFor(size)
    size = math.max(1, math.min(math.floor(tonumber(size) or 1), TC.maxGroup))
    return size, math.max(1, math.min(math.ceil(size / TC.seatsPerCar), TC.maxCars))
end

local function event(g, name, ...)
    for src in pairs(g.riders) do TriggerClientEvent(name, src, g.id, ...) end
end

local function status(g)
    g.lastStatus = now()
    local leaveAt = g.departAt and math.max(g.departAt, g.earliestDepart or 0) or nil
    event(g, 'lastflight:client:tourStatus', {
        state = g.state, buckled = count(g.buckled), riders = count(g.riders),
        leavesIn = (g.state == 'waiting' and leaveAt) and math.max(0, math.ceil((leaveAt - now()) / 1000)) or nil,
    })
end

local function nearNpc(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local n = Config.Transport.city.npc
    return #(GetEntityCoords(ped) - vector3(n.x, n.y, n.z)) <= Config.Transport.city.interactDistance + 4.0
end

local function deleteNet(net)
    if not net then return end
    local ent = NetworkGetEntityFromNetworkId(net)
    if ent and ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
end

local function removeCar(c)
    if c.gone then return end
    c.gone = true
    deleteNet(c.ped)
    deleteNet(c.veh)
end

local function notifyWaiters()
    if not next(waiters) or not canIssue(1) then return end
    for src in pairs(waiters) do
        if GetPlayerName(src) then
            Bridge.Notify(src, 'A farewell car is free at Legion Square - talk to the driver.', 'info')
        end
    end
    waiters = {}
end

local function endGroup(g, reason)
    if Tours[g.id] ~= g then return end
    Tours[g.id] = nil
    for _, c in pairs(g.cars) do removeCar(c) end
    event(g, 'lastflight:client:tourEnded')
    LF.Debug(('Highway drive #%d ended (%s)'):format(g.id, tostring(reason)))
    notifyWaiters()
end

local function carRiders(g, idx)
    local list = {}
    for src, i in pairs(g.seatOf) do
        if i == idx then list[#list + 1] = src end
    end
    return list
end

local function liveCars(g)
    local n = 0
    for _, c in pairs(g.cars) do if not c.gone then n = n + 1 end end
    return n
end

-- Gives car idx a driver client from its own riders, or removes it if empty.
local function pickController(g, idx, delay)
    local c = g.cars[idx]
    if not c or c.gone then return end
    if c.controller and g.seatOf[c.controller] == idx and GetPlayerName(c.controller) then return end
    c.controller = nil
    local riders = carRiders(g, idx)
    for _, src in ipairs(riders) do
        if src == g.leader then c.controller = src break end
    end
    c.controller = c.controller or riders[1]
    if not c.controller then
        removeCar(c)
        if liveCars(g) == 0 then endGroup(g, 'no cars left') end
        return
    end
    TriggerClientEvent('lastflight:client:tourDrive', c.controller, g.id, idx, c.wp or 1, delay or 0)
end

local function removeRider(src, g)
    if not g or not g.riders[src] then return end
    local idx = g.seatOf[src]
    g.riders[src], g.seatOf[src], g.buckled[src] = nil, nil, nil
    if g.state == 'spawning' and g.leader == src then return endGroup(g, 'leader left') end
    if count(g.riders) == 0 then return endGroup(g, 'no riders left') end
    if g.state == 'driving' and idx then pickController(g, idx) end
    if Tours[g.id] == g then status(g) end
end

local function depart(g)
    g.state, g.departedAt = 'driving', now()
    -- anyone who never got in is dropped from the group
    for src in pairs(g.riders) do
        if not g.seatOf[src] then
            g.riders[src] = nil
            g.buckled[src] = nil
            waiters[src] = true
            TriggerClientEvent('lastflight:client:tourEnded', src, g.id)
            Bridge.Notify(src, 'The farewell drive left without you.', 'info')
        end
    end
    local order = 0
    for idx, c in ipairs(g.cars) do
        if not c.gone then
            if #carRiders(g, idx) == 0 then
                removeCar(c)
            else
                c.wp = 1
                pickController(g, idx, order * TC.stagger)
                order = order + 1
            end
        end
    end
    if Tours[g.id] ~= g then return end
    if liveCars(g) == 0 then return endGroup(g, 'nobody aboard') end
    status(g)
end

local function info(src)
    local g = boardingGroup()
    local i = {
        seatsPerCar = TC.seatsPerCar, maxGroup = TC.maxGroup, maxCars = TC.maxCars, minutes = TC.minutes,
    }
    if g then
        i.joinable = count(g.riders) < seatsTotal(g)
        i.seatsFree = math.max(0, seatsTotal(g) - count(g.riders))
        i.waiting = true
    else
        local ok, wait, reason = canIssue(1)
        i.ok, i.wait, i.reason = ok, wait, reason
        i.carsFree = math.max(0, TC.maxCars - carsOnRoad())
    end
    return i
end

RegisterNetEvent('lastflight:server:tourInfo', function()
    local src = source
    if not TC.enabled or not Config.Enabled or not nearNpc(src) then return end
    TriggerClientEvent('lastflight:client:tourInfo', src, info(src))
end)

RegisterNetEvent('lastflight:server:tourRequest', function(size)
    local src = source
    if not TC.enabled or not Config.Enabled then return end
    if lastAsk[src] and now() - lastAsk[src] < 2000 then return end
    lastAsk[src] = now()
    if not nearNpc(src) then return end
    if groupOf(src) then return Bridge.Notify(src, 'You are already booked on the farewell drive - get in!', 'info') end
    if LFS.InRide and LFS.InRide(src) then
        return Bridge.Notify(src, 'You are already on the airport shuttle list.', 'error')
    end

    -- a group is waiting at the curb: join it
    local g = boardingGroup()
    if g then
        if count(g.riders) >= seatsTotal(g) then
            waiters[src] = true
            return Bridge.Notify(src, 'The farewell cars at the curb are full. You will be told when the next one is free.', 'error')
        end
        g.riders[src] = true
        g.earliestDepart = math.max(g.earliestDepart or 0, now() + TC.joinGrace * 1000)
        if g.state == 'waiting' then
            TriggerClientEvent('lastflight:client:tourJoin', src, g.id, g.carList, false)
        end
        Bridge.Notify(src, 'Joining the farewell drive waiting at the curb.', 'success')
        status(g)
        return
    end

    local wanted
    size, wanted = carsFor(size)
    local ok, wait, reason = canIssue(wanted)
    if not ok and reason == 'full' and wanted > 1 then
        -- not enough room for the whole convoy: issue what fits
        wanted = math.max(0, TC.maxCars - carsOnRoad())
        ok = wanted > 0
    end
    if not ok then
        waiters[src] = true
        if reason == 'recent' then
            return Bridge.Notify(src, ('The last farewell car just left. The next one can go in %ds.'):format(wait), 'info')
        end
        return Bridge.Notify(src, 'Every farewell car is out on the highway. You will be told when one is free.', 'info')
    end

    waiters[src] = nil
    seq = seq + 1
    Tours[seq] = {
        id = seq, state = 'spawning', leader = src, size = size, wanted = wanted,
        riders = { [src] = true }, seatOf = {}, buckled = {}, cars = {}, carList = {},
        capacity = TC.seatsPerCar, createdAt = now(),
    }
    LF.Debug(('Highway drive #%d: %d people, %d car(s)'):format(seq, size, wanted))
    TriggerClientEvent('lastflight:client:tourSpawn', src, seq, wanted)
end)

RegisterNetEvent('lastflight:server:tourSpawned', function(id, list, capacity)
    local src = source
    local g = Tours[id]
    if not g or g.state ~= 'spawning' or g.leader ~= src or type(list) ~= 'table' then return end
    for i = 1, math.min(#list, g.wanted) do
        local c = list[i]
        if type(c) == 'table' and tonumber(c.veh) and tonumber(c.ped) then
            g.cars[#g.cars + 1] = { veh = tonumber(c.veh), ped = tonumber(c.ped) }
            g.carList[#g.carList + 1] = { veh = tonumber(c.veh), ped = tonumber(c.ped) }
            for _, net in ipairs({ c.veh, c.ped }) do
                local ent = NetworkGetEntityFromNetworkId(tonumber(net))
                if ent and ent ~= 0 then Entity(ent).state:set('lf_shuttle', 'tour', true) end
            end
        end
    end
    if #g.cars == 0 then
        Bridge.Notify(src, 'The farewell car is unavailable right now.', 'error')
        return endGroup(g, 'spawn failed')
    end
    g.capacity = math.max(1, math.min(tonumber(capacity) or TC.seatsPerCar, 8))
    g.state = 'waiting'
    g.waitDeadline = now() + 90000
    g.earliestDepart = math.max(g.earliestDepart or 0, now() + TC.minWait * 1000)
    for rider in pairs(g.riders) do
        TriggerClientEvent('lastflight:client:tourJoin', rider, g.id, g.carList, rider == src)
    end
    status(g)
end)

RegisterNetEvent('lastflight:server:tourSeated', function(id, idx)
    local src = source
    local g = Tours[id]
    if not g or not g.riders[src] or g.state ~= 'waiting' then return end
    idx = tonumber(idx)
    if idx and (not g.cars[idx] or g.cars[idx].gone) then return end
    if g.seatOf[src] ~= idx then g.buckled[src] = nil end   -- got out / swapped cars: buckle again
    g.seatOf[src] = idx
    if idx and not g.seatDeadline then
        g.seatDeadline = now() + (TC.buckleTimeout + 30) * 1000
    end
    status(g)
end)

RegisterNetEvent('lastflight:server:tourBuckle', function(id)
    local src = source
    local g = Tours[id]
    if not g or g.state ~= 'waiting' or not g.seatOf[src] or g.buckled[src] then return end
    g.buckled[src] = true
    g.departAt = g.departAt or (now() + TC.buckleTimeout * 1000)
    status(g)
end)

RegisterNetEvent('lastflight:server:tourLeft', function(id)
    removeRider(source, Tours[id])
end)

local function controllerOf(src, id, idx)
    local g = Tours[id]
    local c = g and g.cars[tonumber(idx) or -1]
    if not c or c.gone or c.controller ~= src then return nil end
    return g, c, tonumber(idx)
end

RegisterNetEvent('lastflight:server:tourProgress', function(id, idx, wp)
    local g, c = controllerOf(source, id, idx)
    if c then c.wp = tonumber(wp) or c.wp end
end)

RegisterNetEvent('lastflight:server:tourBlink', function(id, idx)
    local src = source
    local g, c, i = controllerOf(src, id, idx)
    if not c then return end
    for _, rider in ipairs(carRiders(g, i)) do
        if rider ~= src then TriggerClientEvent('lastflight:client:tourBlink', rider, g.id, i) end
    end
end)

local function finishCar(g, i, eventName, delay)
    local riders = carRiders(g, i)
    for _, rider in ipairs(riders) do TriggerClientEvent(eventName, rider, g.id, i) end
    SetTimeout(delay, function()
        if Tours[g.id] ~= g then return end
        removeCar(g.cars[i])
        for _, rider in ipairs(riders) do
            if g.seatOf[rider] == i then g.riders[rider], g.seatOf[rider], g.buckled[rider] = nil, nil, nil end
        end
        if liveCars(g) == 0 or count(g.riders) == 0 then endGroup(g, 'all cars done') end
    end)
end

RegisterNetEvent('lastflight:server:tourArrived', function(id, idx)
    local g, c, i = controllerOf(source, id, idx)
    if not c or c.arrived then return end
    c.arrived = true
    finishCar(g, i, 'lastflight:client:tourExit', TC.despawnDelay * 1000)
end)

RegisterNetEvent('lastflight:server:tourFailed', function(id, idx)
    local g, c, i = controllerOf(source, id, idx)
    if not c or c.arrived then return end
    c.arrived = true
    finishCar(g, i, 'lastflight:client:tourRescue', 0)
end)

CreateThread(function()
    while true do
        Wait(1000)
        local t = now()
        for _, g in pairs(Tours) do
            if g.state == 'spawning' then
                if t - g.createdAt > 20000 then endGroup(g, 'spawn timeout') end
            elseif g.state == 'waiting' then
                if t - (g.lastStatus or 0) > 5000 then status(g) end
                local seated = count(g.seatOf)
                if seated > 0 and count(g.buckled) >= count(g.riders) then g.departAt = math.min(g.departAt or t, t) end
                if not g.departAt and g.seatDeadline and t >= g.seatDeadline then g.departAt = t end
                if g.departAt and t >= g.departAt and t >= (g.earliestDepart or 0) then
                    depart(g)
                elseif not g.departAt and seated == 0 and t >= g.waitDeadline then
                    event(g, 'lastflight:client:tourTimedOut')
                    endGroup(g, 'nobody got in')
                end
            elseif g.state == 'driving' and t - g.departedAt > TC.tripTimeout * 1000 then
                for i, c in ipairs(g.cars) do
                    if not c.gone then
                        for _, rider in ipairs(carRiders(g, i)) do
                            TriggerClientEvent('lastflight:client:tourRescue', rider, g.id, i)
                        end
                    end
                end
                endGroup(g, 'trip timeout')
            end
        end
        notifyWaiters()
    end
end)

function LFS.TourCount() return count(Tours) end

AddEventHandler('playerDropped', function()
    local src = source
    waiters[src], lastAsk[src] = nil, nil
    removeRider(src, groupOf(src))
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, g in pairs(Tours) do endGroup(g, 'resource stop') end
end)
