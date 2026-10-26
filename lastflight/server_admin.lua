-- /lastflight admin command. Uses the server's normal admins (see Config.Admin).

local function allowed(src)
    return Bridge.IsAdmin(src)
end

local function reply(src, msg)
    if src == 0 then
        print('[lastflight] ' .. msg)
    else
        TriggerClientEvent('chat:addMessage', src, { color = { 90, 200, 255 }, args = { 'lastflight', msg } })
        TriggerClientEvent('lastflight:client:console', src, msg)
    end
end

local help = 'setup | logbook [id] | spawn | status | reset | cancel [refund|requeue] | depart | debug | mode <test|return|kick> | clearhistory <id|all> | coords | record <start|add|print|stop>'

RegisterCommand(Config.Admin.command, function(src, args)
    local sub = (args[1] or 'status'):lower()

    if sub == 'status' then
        if Config.Admin.statusRequiresAce and not allowed(src) then return reply(src, 'No permission.') end
        local s = LFS.Status()
        reply(src, ('Flight #%s | state %s | passengers %d/%d (ready %d) | queue %d | tickets %d | aircraft %s | controller %s | shuttles %d | mode %s')
            :format(s.flightId, s.state, s.passengers, s.capacity, s.ready, s.queue, s.tickets,
                s.aircraft, tostring(s.controller), s.shuttles, LF.Modes[LF.Mode()].label))
        return
    end

    if not allowed(src) then return reply(src, 'No permission.') end

    if sub == 'reset' then
        LFS.Reset()
        reply(src, 'Flight reset. Passengers restored, aircraft removed, queue kept.')

    elseif sub == 'cancel' then
        local policy = (args[2] == 'refund' or args[2] == 'requeue') and args[2] or Config.Admin.cancelPolicy
        if LFS.Cancel(policy) then
            reply(src, 'Flight cancelled (' .. policy .. ').')
        else
            reply(src, 'No active flight.')
        end

    elseif sub == 'spawn' then
        if LFS.SpawnNow() then reply(src, 'Jet spawned at the parking spot.')
        else reply(src, 'A jet is already out (see /' .. Config.Admin.command .. ' status), or it failed to spawn - check the server console.') end

    elseif sub == 'depart' then
        reply(src, LFS.ForceDepart() and 'Forcing departure.' or 'Nothing to depart (need a seated passenger while boarding).')

    elseif sub == 'debug' then
        Config.Debug = not Config.Debug
        TriggerClientEvent('lastflight:client:debug', src == 0 and -1 or src, Config.Debug)
        reply(src, 'Debug ' .. (Config.Debug and 'ON' or 'OFF'))

    elseif sub == 'mode' or sub == 'testmode' then
        -- /lastflight mode test | return | kick   (testmode on/off still works)
        local a = (args[2] or ''):lower()
        local map = { test = 'test', on = 'test', ['return'] = 'live_return', live_return = 'live_return',
                      kick = 'live_kick', off = 'live_kick', live_kick = 'live_kick', live = 'live_kick' }
        if not map[a] then
            return reply(src, 'Current: ' .. LF.Modes[LF.Mode()].label .. '. Usage: /' .. Config.Admin.command .. ' mode test | return | kick')
        end
        LFS.SetMode(src, map[a])   -- saved on the server, survives restarts

    elseif sub == 'clearhistory' then
        if not args[2] then return reply(src, 'Usage: /' .. Config.Admin.command .. ' clearhistory <server id | identifier | all>') end
        reply(src, ('Cleared %d participation record(s).'):format(LFS.ClearHistory(args[2])))

    elseif sub == 'setup' then
        if src == 0 then return reply(src, 'Run this in game.') end
        LFS.OpenSetup(src)

    elseif sub == 'logbook' then
        if src == 0 and not args[2] then return reply(src, 'Usage: lastflight logbook <server id>') end
        LFS.GiveLogbook(src, args[2])

    elseif sub == 'coords' or sub == 'record' then
        if src == 0 then return reply(src, 'Run this in game.') end
        TriggerClientEvent('lastflight:client:devtool', src, sub, args[2])

    else
        reply(src, help)
    end
end, false)
