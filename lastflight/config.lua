--[[
    LAST FLIGHT TO VICE CITY - config.lua

    Every setting for the resource lives in this file. You should never need to
    edit the other .lua files to change prices, routes, timings, audio or text.

    Coordinates
    -----------
    * vec4(x, y, z, heading) / vec3(x, y, z)
    * Use  /lastflight coords  in game (admin) to print your current position in
      the exact format used below, ready to paste.
    * Use  /lastflight record <name>  to drive/fly a route and record waypoints.
      See README.md for the walkthrough.

    The airport coordinates shipped here are best estimates of LSIA and MUST be
    checked in game on your server (MLOs / map edits can move things). Turn on
    Config.Debug to see every route drawn in the world.
]]

Config = {}

---------------------------------------------------------------------------
-- GENERAL
---------------------------------------------------------------------------
Config.Enabled   = true
Config.Debug     = false            -- prints + draws routes/markers for admins (toggle live: /lastflight debug)

-- 'auto' | 'qbox' | 'qbcore' | 'esx' | 'standalone'
-- auto picks the first one that is running: qbx_core > qb-core > es_extended > standalone
Config.Framework = 'auto'

Config.Flight = {
    number      = 'LS-VI-001',
    destination = 'Vice City',
    airport     = 'LOS SANTOS INTERNATIONAL AIRPORT',
}

---------------------------------------------------------------------------
-- TICKETS / PAYMENT
---------------------------------------------------------------------------
Config.Tickets = {
    price    = 100,                  -- default $100
    accounts = { 'cash', 'bank' },   -- tried in this order. ESX: 'money' is used for 'cash' automatically
    refundOnResourceStop = true,     -- refund unused tickets of online players when the resource stops
}

-- Only used when Config.Framework resolves to 'standalone'.
-- Return true to accept the payment. Leave nil to make tickets free in standalone mode.
Config.Payment = {
    standaloneCharge = nil,   -- function(source, amount) return true end
    standaloneRefund = nil,   -- function(source, amount) end
}

---------------------------------------------------------------------------
-- INVENTORY (boarding pass item)
---------------------------------------------------------------------------
-- 'ox' (default) | 'jaksam' | 'auto' | 'none'
-- auto prefers ox_inventory, then jaksam_inventory.
-- The item is a souvenir / proof of ticket. The SERVER ticket record is what
-- actually lets you board, so dropping or duping the item can't be abused.
Config.Inventory = {
    provider           = 'ox',
    giveTicketItem     = true,
    ticketItem         = 'lastflight_ticket',       -- full ticket, given at purchase
    stubItem           = 'lastflight_ticket_stub',  -- torn-off stub, swapped in when they board (keepsake)
    logbookItem        = 'lastflight_logbook',      -- admin item: using it opens the setup panel (ACE still required)
    requireItemToBoard = false,                     -- true = must have the ticket (or stub) to board
    removeOnRefund     = true,                      -- take the ticket/stub back when a ticket is refunded
}

---------------------------------------------------------------------------
-- NOTIFICATIONS / INTERACTION
---------------------------------------------------------------------------
Config.Notify = {
    provider = 'nui',   -- 'nui' (airline styled toasts) | 'ox_lib' | 'native'
    duration = 6000,
}

Config.Interaction = {
    useTarget = 'auto',   -- 'auto' (ox_target if running) | true | false (E key prompt)
    key       = 38,       -- E
}

Config.Keys = {          -- players can rebind these in GTA Settings > Key Bindings > FiveM
    ready  = 'G',         -- toggle "ready" while seated
    camera = 'H',         -- cycle passenger camera during the scenic flight
}

---------------------------------------------------------------------------
-- AIRPORT
---------------------------------------------------------------------------
Config.Airport = {
    blip = {
        enabled = true,
        coords  = vec3(-1039.20, -2731.40, 20.17),
        sprite  = 90,       -- airport
        color   = 3,
        scale   = 0.9,
        label   = 'LSIA - Last Flight to Vice City',
    },

    npc = {
        model    = 's_f_y_airhostess_01',
        coords   = vec4(-1039.2, -2731.4, 20.17, 240.0),   -- stand on the spot and use /lastflight coords
        scenario = 'WORLD_HUMAN_STAND_IMPATIENT',            -- nil for none
        interactDistance = 2.5,
        spawnDistance    = 60.0,                            -- ped/desk only exist on your client while you are this close
    },

    -- Native GTA prop placed in front of the NPC.
    desk = {
        enabled   = true,
        model     = 'prop_office_desk_01',
        autoPlace = true,        -- true: placed `distance` metres in front of the NPC, facing them
        distance  = 0.9,
        zOffset   = 0.0,
        coords    = vec4(-1039.9, -2732.2, 20.17, 60.0),   -- only used when autoPlace = false
    },

    -- Where passengers walk/drive to and press E to board.
    boardingPoint  = vec3(-1347.00, -2801.12, 12.94),
    boardingRadius = 3.0,
    boardingBlip   = { sprite = 307, color = 3, scale = 0.8, label = 'Flight LS-VI-001 Boarding' },

    -- Where removed / cancelled / restored passengers are placed.
    safeReturn = vec4(-1037.5, -2737.6, 20.17, 330.0),
}

---------------------------------------------------------------------------
-- GROUND TRANSPORT
---------------------------------------------------------------------------
Config.Transport = {
    driveYourself = true,      -- GPS route to the boarding point

    -- CITY PICKUP: an NPC in the city (default Legion Square). Players talk to
    -- them and an AI taxi drives them to the airport check-in desk.
    -- Move it in game with /lastflight setup (City pickup section).
    city = {
        enabled  = true,
        npcModel = 'a_m_y_business_02',
        npc      = vec4(240.06, -862.77, 29.73, 341.5),     -- Legion Square, on the curb (same spot as the qbx taxi pickup)
        scenario = 'WORLD_HUMAN_CLIPBOARD',
        blip     = { enabled = true, sprite = 513, color = 3, scale = 0.8, label = 'Airport Bus - Last Flight' },
        interactDistance = 2.5,
        spawnDistance    = 60.0,

        vehicle      = 'rentalbus',         -- small shuttle bus
        driver       = 's_m_y_airworker',
        spawn        = vec4(233.78, -856.19, 28.78, 248.4),  -- curbside bay beside the NPC (sit in a car there + "Set here" to fine-tune)
        snapToRoad   = false,       -- true: snap to the nearest road, pulled in to the curb on the NPC's side
        -- Optional via points, then the drop-off at the airport (last point).
        waypoints = {
            vec3(-1035.75, -2727.45, 19.15),                -- LSIA departures, by the check-in desk
        },
        speed        = 18.0,        -- m/s (~40 mph)
        drivingStyle = 786603,
        arriveRadius = 15.0,
        stuckTime          = 25,    -- seconds without moving 3 m (red lights never count) before it re-routes;
                                    -- it backs up at 1.5x and only fades/teleports at 2x this
        maxStuckRecoveries = 5,     -- after this many teleports the passenger is faded to the drop-off
        abandonTime        = 20,
        despawnDelay       = 6,
        requireTicket      = false, -- true = only ticket holders can ride (tickets are sold at the airport)
        respawnAfter       = 20,    -- a NEW bus can be called once the previous one has been driving this many
                                    -- seconds (it is well clear of the stop by then, so they never stack)
        buckleTimeout      = 45,    -- the bus leaves when every rider has buckled (G), or this many seconds after the first one did
        minWait            = 30,    -- the bus always waits at least this long at the curb so others can join
        joinGrace          = 15,    -- each new rider who asks gets at least this many seconds to get on
    },

    -- GATE SHUTTLE: airport desk -> the plane (offered after buying a ticket)
    shuttle = {
        enabled      = true,
        vehicle      = 'rentalbus',          -- small shuttle bus
        driver       = 's_m_y_airworker',
        spawn        = vec4(-1030.16, -2730.53, 19.15, 240.4), -- curb outside departures
        speed        = 12.0,        -- m/s (~27 mph)
        drivingStyle = 786603,      -- normal law-abiding driving
        -- Waypoints the shuttle drives through. The LAST one is the drop-off.
        waypoints = {
            vec3(-1317.96, -2781.07, 12.94),   -- drop-off beside the jet
        },
        arriveRadius       = 10.0,
        stuckTime          = 15,    -- seconds without moving 3 m before it re-routes (teleport only at 2x)
        maxStuckRecoveries = 3,     -- after this many, the passenger is faded and placed at the boarding point
        despawnDelay       = 6,     -- seconds after drop-off before the shuttle is removed
        buckleTimeout      = 45,    -- the bus leaves when every rider has buckled (G), or this many seconds after the first one did
        minWait            = 30,    -- the bus always waits at least this long at the curb so others can join
        joinGrace          = 15,    -- each new rider who asks gets at least this many seconds to get on
        autoBoardPlane     = false, -- false: riders get off and walk to the boarding marker. true: put straight into their seats
        walkGrace          = 45,    -- after drop-off, the plane keeps boarding open this long for riders walking over
    },
}

---------------------------------------------------------------------------
-- AIRCRAFT
---------------------------------------------------------------------------
Config.Aircraft = {
    model       = 'jet',
    pilotModel  = 's_m_m_pilot_01',
    spawnPilot  = true,
    spawnOnStart = false,           -- false: the jet spawns when the first ticket is sold (no idle entity)

    -- Set in game with /lastflight setup (exported with "Copy as config").
    parking = vec4(-1345.90, -2804.10, 12.94, 111.6),

    -- Seating
    --  'auto'   : use real vehicle seats (count detected in game), fall back to 'attach' if a seat fails
    --  'seats'  : only real seats
    --  'attach' : players are attached inside the fuselage (works for any model, any count)
    seatMode      = 'auto',
    maxPassengers = 8,              -- hard cap. Real capacity = min(this, usable seats detected)
    attachOffsets = {               -- used by 'attach' mode / fallback, relative to the aircraft
        vec3(-1.2,  10.0, 1.0), vec3(1.2,  10.0, 1.0),
        vec3(-1.2,   6.0, 1.0), vec3(1.2,   6.0, 1.0),
        vec3(-1.2,   2.0, 1.0), vec3(1.2,   2.0, 1.0),
        vec3(-1.2,  -2.0, 1.0), vec3(1.2,  -2.0, 1.0),
        vec3(-1.2,  -6.0, 1.0), vec3(1.2,  -6.0, 1.0),
        vec3(-1.2, -10.0, 1.0), vec3(1.2, -10.0, 1.0),
    },

    cooldown = 15,                  -- seconds between a flight finishing and the next jet spawning

    -- Movement
    taxiSpeed    = 7.0,             -- m/s peak-ish ground speed
    rotateSpeed  = 72.0,            -- m/s at liftoff
    gearUpHeight = 40.0,            -- metres above ground before the gear retracts
    maxBank      = 25.0,            -- degrees
    bankFactor   = 2.2,             -- degrees of bank per degree/sec of turn
    bankDirection = 1,              -- flip to -1 if the jet leans the wrong way in turns

    -- Parking -> runway hold point (ground). Parking position is added automatically as the first point.
    taxiRoute = {
        vec3(-1397.08, -2806.19, 12.94),
        vec3(-1469.29, -2797.68, 12.94),
        vec3(-1552.76, -2757.73, 12.95),
        vec3(-1576.36, -2746.22, 12.94),
        vec3(-1603.52, -2789.02, 12.97),
        vec3(-1644.20, -2773.66, 12.94),
        vec3(-1668.32, -2796.96, 12.94),
        vec3(-1689.70, -2834.15, 12.94),
        vec3(-1676.20, -2909.93, 12.96),
        vec3(-1661.37, -2946.42, 12.94),
    },
    holdPoint = vec4(-1625.03, -2976.81, 12.94, 240.0),

    -- Takeoff roll along the runway from the hold point to liftoff (ground).
    -- The runway direction is taken from holdPoint -> liftoffPoint.
    liftoffPoint = vec3(-1102.73, -3278.37, 12.99),
    -- true: climb straight out along the runway direction (recommended - follows
    -- the runway if you move it with /lastflight setup). false: use climbRoute.
    autoClimb = true,
    -- Climb out (air), only used when autoClimb = false. The scenic loop starts after the last of these.
    climbRoute = {
        vec3(-2050.0, -2630.0,  90.0),
        vec3(-2450.0, -2350.0, 220.0),
        vec3(-2650.0, -1900.0, 320.0),
        vec3(-2680.0, -1500.0, 360.0),
    },
}

---------------------------------------------------------------------------
-- SCENIC FLIGHT  (circles the whole main island, clockwise from LSIA)
---------------------------------------------------------------------------
Config.ScenicFlight = {
    -- 10 minutes (timer starts at cruise, after the climb).
    -- Ignored while Config.Music.fitFlightToMusic = true (the music sets the length).
    duration              = 600,
    maxDuration           = 600,    -- enforced unless allowDurationOverride = true
    allowDurationOverride = false,
    enableCameraToggle    = false,  -- true: passengers can press H to cycle orbit / wing / chase views
    enableLandmarkCameras = false,  -- true: short automatic wide shots at landmarks (interrupts free look)
    allowFreeLook         = true,   -- passengers look around freely with the mouse for the whole loop

    -- The speed is calculated so the loop takes `duration`. It is clamped to
    -- this range so the jet never crawls or rockets; if it clamps, the real
    -- duration changes and the server console tells you.
    minSpeed = 35.0,
    maxSpeed = 95.0,

    -- z = altitude. camera = 'landmark' triggers a short wide shot near that point.
    -- Points without a label just shape the curve.
    waypoints = {
        { pos = vec3(-2650.0,  -900.0, 380.0), label = 'Pacific Ocean' },
        { pos = vec3(-2550.0,  -100.0, 400.0), label = 'Pacific Bluffs', camera = 'landmark' },
        { pos = vec3(-3150.0,  1000.0, 420.0), label = 'Chumash' },
        { pos = vec3(-2950.0,  2600.0, 450.0) },
        { pos = vec3(-2600.0,  3400.0, 480.0), label = 'Fort Zancudo', camera = 'landmark' },
        { pos = vec3(-1800.0,  5000.0, 530.0), label = 'North-West Coast' },
        { pos = vec3(-1000.0,  6100.0, 570.0) },
        { pos = vec3( -300.0,  6600.0, 600.0), label = 'Paleto Bay', camera = 'landmark' },
        { pos = vec3(  700.0,  6350.0, 700.0), label = 'Mount Chiliad', camera = 'landmark' },
        { pos = vec3( 2000.0,  6500.0, 650.0), label = 'North Coast' },
        { pos = vec3( 3300.0,  5650.0, 550.0), label = 'Mount Gordo' },
        { pos = vec3( 3800.0,  4600.0, 480.0) },
        { pos = vec3( 3750.0,  3700.0, 450.0), label = 'Humane Labs', camera = 'landmark' },
        { pos = vec3( 3500.0,  3250.0, 430.0) },
        { pos = vec3( 2850.0,  3500.0, 380.0) },
        { pos = vec3( 2050.0,  3950.0, 330.0), label = 'Alamo Sea', camera = 'landmark' },
        { pos = vec3( 1450.0,  3800.0, 320.0) },
        { pos = vec3( 1550.0,  3250.0, 320.0), label = 'Sandy Shores', camera = 'landmark' },
        { pos = vec3( 1200.0,  2400.0, 380.0), label = 'Grand Senora Desert' },
        { pos = vec3(  720.0,  1250.0, 520.0), label = 'Vinewood Sign', camera = 'landmark' },
        { pos = vec3(  -60.0,  -700.0, 480.0), label = 'Downtown Los Santos', camera = 'landmark' },
        { pos = vec3(  300.0, -1900.0, 450.0), label = 'Final view of Los Santos' },
    },
}

---------------------------------------------------------------------------
-- FINAL DEPARTURE (over the ocean toward Vice City)
---------------------------------------------------------------------------
Config.FinalDeparture = {
    speed     = 85.0,     -- m/s the jet accelerates to while leaving
    waypoints = {         -- starts from the last scenic waypoint
        vec3(  800.0, -3400.0, 550.0),
        vec3( 1700.0, -5200.0, 700.0),
        vec3( 2900.0, -7400.0, 900.0),
    },
}

---------------------------------------------------------------------------
-- AUDIO  (all audio files go in the lastflight/audio/ folder)
---------------------------------------------------------------------------
Config.Audio = {
    -- Optional captain announcement at the runway, before the seatbelt chime.
    pilot    = { enabled = false, file = 'audio/pilot.mp3', volume = 0.9, fallbackDuration = 20 },
    -- Optional chime with the seatbelt warning at the runway (off: on-screen warning only).
    seatbelt = { enabled = false, file = 'audio/seatbelt.mp3', volume = 0.7, fallbackDuration = 3 },
    musicFadeDuration    = 6,    -- seconds the music fades at the very end (with the screen fade)
    announcementTimeout  = 120,  -- hard cap (s) the server waits for everyone's announcement to finish
}

-- After the chime every passenger presses the READY key (G) to buckle up.
-- Takeoff starts when everyone is buckled, or after `timeout` seconds.
Config.Seatbelt = {
    requireBuckle = true,
    timeout       = 20,
}

-- Music starts the moment the takeoff roll begins and the tracks play back to back.
-- `duration` must be the real length of each song in seconds (5:59 = 359).
Config.Music = {
    volume = 0.5,
    tracks = {
        { file = 'audio/OneLastSunset.mp3',     duration = 359 },   -- 5:59, takeoff + circling the island
        { file = 'audio/WelcometoLeonida.mp3',  duration = 240 },   -- 4:00, ends the journey
    },
    -- true: the airborne part (takeoff + island loop + departure) is timed to
    -- last exactly as long as all tracks together, so the last song ends as the
    -- screen fades. This overrides ScenicFlight.duration.
    fitFlightToMusic = true,
}

---------------------------------------------------------------------------
-- CINEMATICS
---------------------------------------------------------------------------
Config.Cinematics = {
    enabled        = true,
    transitionTime = 1800,         -- ms blend between shots

    -- Shot(s) while taxiing to the runway. offset is relative to the jet (x = right, y = forward, z = up)
    -- One slow follow shot by default; add more entries to cut between angles.
    taxiShots = {
        { offset = vec3(40.0, -70.0, 14.0), duration = 120000, fov = 50.0 },
    },

    -- Shots during the takeoff roll/climb.
    --  type 'runway'  : fixed camera beside the runway (along = metres from hold point, side = metres right)
    --  type 'attached': follows the jet using offset
    takeoffShots = {
        { type = 'runway',   along = 520.0, side = 70.0,  height = 4.0,   duration = 7000, fov = 40.0 },  -- front three-quarter
        { type = 'attached', offset = vec3(-60.0, 5.0, 3.0),              duration = 6000, fov = 50.0 },  -- side tracking
        { type = 'attached', offset = vec3(6.0, -70.0, -1.5),             duration = 5000, fov = 55.0 },  -- low rear rotation
        { type = 'runway',   along = 900.0, side = -160.0, height = 25.0, duration = 7000, fov = 45.0 },  -- wide liftoff
        { type = 'attached', offset = vec3(-260.0, 220.0, 120.0),         duration = 9000, fov = 50.0 },  -- long distance over LS
    },

    thirdPersonAltitude = 150.0,   -- metres above ground: switch to the passenger's own 3rd-person view
    landmarkShotDuration = 8,      -- seconds
    landmarkRadius       = 700.0,  -- metres from the landmark waypoint that triggers its shot

    finalCamFovStart = 35.0,       -- final shot slowly widens from this...
    finalCamFovEnd   = 75.0,       -- ...to this
    fadeDuration     = 6,          -- seconds to fade to black at the end
}

---------------------------------------------------------------------------
-- BOARDING / READINESS
---------------------------------------------------------------------------
Config.Boarding = {
    boardingDuration        = 120,   -- seconds the doors stay open after the FIRST passenger boards
    readinessTimeout        = 60,    -- seconds after boarding closes for everyone to press ready
    minimumPassengers       = 1,
    removeUnreadyPassengers = true,  -- false: flight is cancelled instead when someone times out
    unreadyPolicy           = 'requeue', -- 'refund' or 'requeue' (keep ticket for next flight)
    closeEarlyWhenAllReady  = true,  -- close boarding early when every ticket holder is aboard and ready
    shuttleHoldMax          = 180,   -- max extra seconds boarding stays open while the gate shuttle brings ticket holders
    departureCountdown      = 10,    -- seconds after the last ready before the doors lock and taxi starts
}

---------------------------------------------------------------------------
-- FAREWELL
---------------------------------------------------------------------------
Config.Farewell = {
    message          = 'ENJOY YOUR TIME IN GTA VI',
    -- Shown under the main message. \n starts a new line.
    subMessage       = 'Take a moment to look back on every memory we made in Los Santos.\n'
                    .. 'The late nights, the chaos, the friends who rode beside us,\n'
                    .. 'and the ones we lost along the way. They are on this flight with us.\n'
                    .. 'Thank you for the memories.',
    font             = "'Pricedown', 'Bebas Neue', 'Oswald', sans-serif",
    color            = '#ffffff',
    displayDuration  = 14,     -- seconds the message stays on the black screen (long enough to read)
    disconnectOnCompletion = true,
    disconnectReason = 'Thank you for every memory we made in Los Santos. For the friends beside us and the ones we lost along the way, this one is for you. Enjoy your new adventure in GTA VI.',
    allowReconnect   = true,   -- false: player can't rejoin for reconnectCooldown seconds (never permanent)
    reconnectCooldown = 60,
    oneTimeParticipation = false, -- true: each player can only complete the flight once (server access is never affected)

    -- TESTING: when true nobody is disconnected. After the farewell the player is
    -- placed back at the ticket desk (testReturn) so you can fly again right away.
    -- What happens after the farewell (switch it in game: /lastflight setup -> mode box):
    --   'test'        - admin testing: nobody kicked, back to returnTo, flights are NOT recorded
    --   'live_return' - live event, nobody kicked: back to returnTo, flights ARE recorded
    --   'live_kick'   - live event: players are disconnected with disconnectReason
    -- The choice made in game is saved on the server and overrides this value.
    mode       = 'test',
    -- Where test-mode players (and anyone when disconnectOnCompletion = false) come back:
    --   'city'    = Legion Square, next to the airport-shuttle NPC (Config.Transport.city)
    --   'airport' = the LSIA return spot (testReturn / "Return spawn" in /lastflight setup)
    returnTo   = 'city',
    testReturn = vec4(-1037.5, -2737.6, 20.17, 330.0),
}

---------------------------------------------------------------------------
-- ADMINISTRATION
---------------------------------------------------------------------------
-- Who counts as a flight admin: your normal server admins. No extra server.cfg
-- lines are needed. Anyone with one of `serverAdminAces` (Qbox/default cfx admins
-- have 'admin' / 'command'), a QBCore 'admin'/'god' permission, or an ESX
-- 'admin'/'superadmin' group is allowed. The optional `ace` below also works.
Config.Admin = {
    command           = 'lastflight',
    serverAdminAces   = { 'admin', 'command', 'god' },
    ace               = 'lastflight.admin',   -- optional extra ACE (add_ace group.mod lastflight.admin allow)
    statusRequiresAce = true,
    cancelPolicy      = 'refund',   -- 'refund' or 'requeue' for /lastflight cancel

    -- In-game location editor: /lastflight setup
    -- Saved locations are stored on the server and override the values in this
    -- file until you press "Factory reset" in the editor.
    setupKey      = 'F7',   -- reopen the editor panel while moving around
    setupPointKey = 'F6',   -- add a point to the route you are recording
    autoRecordSpacing = 15.0, -- metres between points when auto-record is on
}
