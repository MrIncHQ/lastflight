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
    seatbelt = 'B',       -- fasten the seatbelt (runway, shuttles, farewell car)
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
        buckleTimeout      = 45,    -- the bus leaves when every rider has buckled (B), or this many seconds after the first one did
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
        buckleTimeout      = 45,    -- the bus leaves when every rider has buckled (B), or this many seconds after the first one did
        minWait            = 30,    -- the bus always waits at least this long at the curb so others can join
        joinGrace          = 15,    -- each new rider who asks gets at least this many seconds to get on
        autoBoardPlane     = false, -- false: riders get off and walk to the boarding marker. true: put straight into their seats
        walkGrace          = 45,    -- after drop-off, the plane keeps boarding open this long for riders walking over
    },
}

---------------------------------------------------------------------------
-- FAREWELL HIGHWAY DRIVE (second option at the city pickup NPC)
---------------------------------------------------------------------------
-- A chauffeured luxury car takes one last loop of the island on the highways
-- (no stop lights), then drops everyone at the LSIA check-in desk. Players pick
-- how many are in their group and enough cars are issued to leave together.
-- Move it in game with /lastflight setup (Highway drive section).
Config.Tour = {
    enabled     = true,
    key         = 47,               -- control pressed at the NPC (47 = G). E is still the airport shuttle.
    vehicle     = 'superd',         -- Enus Super Diamond (any 4-door works)
    driver      = 's_m_m_highsec_01',
    seatsPerCar = 3,                -- passengers per car (used to work out how many cars a group needs)
    maxGroup    = 12,               -- biggest group one player can ask for
    maxCars     = 8,                -- all highway cars on the road at once (server-wide)
    nextAfter   = 120,              -- a new car / convoy can be issued once the previous one has been driving this many seconds
    carSpacing  = 8.0,              -- metres between convoy cars at the pickup (lined up behind the first)
    minutes     = 17,               -- shown to players (roughly how long the loop takes)

    spawn = vec4(222.60, -851.80, 28.80, 248.4),   -- first car, behind the airport bus bay (Legion Square)
    -- The highway loop, then the drop-off at the airport (last point).
    -- Recorded in game: Legion Square -> Del Perro Fwy -> Great Ocean Hwy up the
    -- west coast -> Paleto -> Senora Fwy down the east side -> LS Freeway -> LSIA.
    -- Re-record it with /lastflight setup (Highway drive) to change it.
    waypoints = {
        vec3(264.16, -863.47, 28.24),
        vec3(263.71, -891.18, 27.89),
        vec3(218.93, -1016.61, 28.29),
        vec3(196.48, -1026.07, 28.36),
        vec3(155.75, -1012.39, 28.40),
        vec3(134.58, -1000.65, 28.39),
        vec3(121.20, -990.05, 28.34),
        vec3(131.63, -949.79, 28.73),
        vec3(164.01, -842.77, 30.11),
        vec3(145.30, -803.66, 30.21),
        vec3(8.35, -753.06, 30.87),
        vec3(-80.09, -717.41, 33.26),
        vec3(-230.63, -660.56, 32.35),
        vec3(-306.48, -651.18, 32.02),
        vec3(-520.92, -650.07, 32.20),
        vec3(-606.46, -650.62, 30.77),
        vec3(-733.45, -648.70, 29.16),
        vec3(-794.06, -653.21, 27.86),
        vec3(-890.09, -650.53, 26.90),
        vec3(-970.46, -668.10, 23.23),
        vec3(-1071.13, -739.56, 18.24),
        vec3(-1115.82, -712.24, 19.69),
        vec3(-1210.08, -602.53, 26.11),
        vec3(-1241.88, -564.70, 27.56),
        vec3(-1287.08, -521.02, 31.88),
        vec3(-1341.35, -524.01, 30.82),
        vec3(-1416.03, -578.79, 29.50),
        vec3(-1529.93, -643.07, 28.05),
        vec3(-1578.02, -631.63, 29.17),
        vec3(-1693.31, -543.47, 35.80),
        vec3(-1723.65, -554.78, 36.36),
        vec3(-1754.25, -550.83, 35.90),
        vec3(-1845.22, -490.97, 26.06),
        vec3(-1918.76, -440.95, 19.94),
        vec3(-2042.19, -379.79, 9.97),
        vec3(-2113.33, -359.32, 11.91),
        vec3(-2208.96, -340.04, 12.33),
        vec3(-2291.88, -320.52, 12.63),
        vec3(-2482.23, -206.31, 16.94),
        vec3(-2600.96, -132.42, 20.01),
        vec3(-2706.27, -11.71, 14.63),
        vec3(-2947.26, 96.88, 12.63),
        vec3(-3023.39, 201.12, 15.10),
        vec3(-3020.43, 249.17, 14.96),
        vec3(-2981.89, 443.73, 14.09),
        vec3(-2985.40, 570.55, 17.11),
        vec3(-3032.55, 715.45, 21.84),
        vec3(-3116.77, 829.04, 16.00),
        vec3(-3148.75, 920.28, 13.39),
        vec3(-3112.38, 1062.87, 19.36),
        vec3(-3093.21, 1261.37, 19.25),
        vec3(-3048.17, 1396.89, 20.62),
        vec3(-2982.45, 1491.38, 26.91),
        vec3(-3006.08, 1641.71, 31.09),
        vec3(-3036.25, 1789.97, 33.83),
        vec3(-2997.82, 1951.62, 28.48),
        vec3(-2971.95, 2066.55, 39.08),
        vec3(-2906.02, 2144.12, 38.08),
        vec3(-2756.97, 2232.85, 22.14),
        vec3(-2710.90, 2290.80, 17.67),
        vec3(-2675.07, 2479.03, 15.69),
        vec3(-2627.20, 2807.97, 15.69),
        vec3(-2595.46, 3044.39, 15.09),
        vec3(-2567.21, 3329.35, 12.62),
        vec3(-2522.88, 3487.33, 12.87),
        vec3(-2469.51, 3683.52, 13.12),
        vec3(-2400.57, 3888.34, 23.60),
        vec3(-2330.00, 4091.34, 32.88),
        vec3(-2202.56, 4334.20, 49.09),
        vec3(-2149.10, 4439.96, 62.39),
        vec3(-2051.50, 4466.67, 56.61),
        vec3(-1929.71, 4583.55, 56.05),
        vec3(-1760.43, 4751.04, 56.16),
        vec3(-1568.76, 4923.02, 60.50),
        vec3(-1441.08, 5049.92, 60.55),
        vec3(-1294.75, 5232.92, 53.05),
        vec3(-1145.41, 5277.37, 52.18),
        vec3(-1026.37, 5356.25, 42.07),
        vec3(-763.80, 5490.69, 33.87),
        vec3(-585.41, 5640.98, 37.64),
        vec3(-491.64, 5839.97, 33.06),
        vec3(-315.31, 6052.95, 30.22),
        vec3(-149.12, 6219.83, 30.20),
        vec3(90.38, 6458.59, 30.34),
        vec3(225.94, 6554.57, 30.72),
        vec3(375.29, 6565.11, 26.91),
        vec3(583.89, 6533.82, 27.05),
        vec3(802.75, 6490.93, 22.66),
        vec3(1027.13, 6481.43, 19.99),
        vec3(1333.36, 6480.92, 18.94),
        vec3(1573.36, 6407.93, 23.98),
        vec3(1762.95, 6346.83, 35.31),
        vec3(1898.71, 6310.93, 41.00),
        vec3(1988.27, 6153.74, 45.46),
        vec3(2117.08, 6030.20, 49.93),
        vec3(2244.28, 5926.03, 48.93),
        vec3(2340.47, 5819.45, 45.79),
        vec3(2440.75, 5633.18, 44.02),
        vec3(2522.27, 5420.28, 43.55),
        vec3(2608.18, 5099.53, 43.81),
        vec3(2638.37, 4986.13, 43.79),
        vec3(2704.27, 4704.73, 43.35),
        vec3(2747.90, 4495.50, 46.10),
        vec3(2825.34, 4253.65, 49.21),
        vec3(2911.27, 3953.79, 50.81),
        vec3(2877.03, 3681.03, 51.66),
        vec3(2822.53, 3510.50, 53.59),
        vec3(2761.71, 3368.81, 55.12),
        vec3(2654.80, 3171.15, 50.76),
        vec3(2466.12, 2975.43, 39.98),
        vec3(2272.24, 2819.91, 41.48),
        vec3(2103.71, 2689.25, 49.35),
        vec3(1978.63, 2579.10, 53.54),
        vec3(1846.41, 2402.01, 53.71),
        vec3(1782.48, 2194.52, 61.04),
        vec3(1764.14, 2035.58, 67.13),
        vec3(1736.30, 1784.92, 76.49),
        vec3(1681.31, 1409.00, 85.28),
        vec3(1603.00, 1091.97, 80.54),
        vec3(1500.68, 853.72, 76.11),
        vec3(1382.23, 685.87, 78.39),
        vec3(1265.36, 572.49, 79.70),
        vec3(1079.74, 386.31, 82.15),
        vec3(857.17, 140.27, 71.48),
        vec3(759.68, -0.76, 62.01),
        vec3(706.01, -94.89, 53.62),
        vec3(639.04, -206.47, 43.44),
        vec3(596.62, -258.87, 43.05),
        vec3(538.86, -322.33, 42.51),
        vec3(509.34, -392.20, 44.05),
        vec3(505.89, -444.86, 44.90),
        vec3(531.98, -530.19, 44.39),
        vec3(582.07, -586.62, 41.97),
        vec3(674.41, -632.86, 35.16),
        vec3(781.65, -669.23, 38.69),
        vec3(878.54, -741.81, 40.64),
        vec3(923.48, -787.28, 37.53),
        vec3(956.38, -826.68, 34.02),
        vec3(974.81, -853.16, 31.77),
        vec3(997.88, -903.34, 29.66),
        vec3(1027.00, -993.98, 28.98),
        vec3(1046.97, -1246.64, 24.36),
        vec3(1053.20, -1489.87, 27.17),
        vec3(1061.03, -1615.44, 28.28),
        vec3(1104.69, -1767.08, 28.29),
        vec3(1161.57, -1904.28, 33.06),
        vec3(1235.36, -2065.94, 43.35),
        vec3(1323.51, -2300.74, 51.38),
        vec3(1288.57, -2470.65, 46.51),
        vec3(1167.87, -2546.50, 33.81),
        vec3(1069.40, -2568.17, 34.36),
        vec3(770.75, -2621.51, 51.55),
        vec3(546.98, -2660.77, 37.53),
        vec3(357.00, -2663.09, 20.17),
        vec3(148.96, -2645.97, 18.14),
        vec3(22.86, -2608.14, 25.28),
        vec3(-95.65, -2536.64, 40.09),
        vec3(-543.84, -2222.76, 57.93),
        vec3(-761.98, -2069.35, 32.22),
        vec3(-874.89, -1982.15, 26.71),
        vec3(-908.30, -1897.89, 28.95),
        vec3(-888.06, -1819.31, 34.62),
        vec3(-849.16, -1786.40, 36.19),
        vec3(-780.25, -1764.31, 28.31),
        vec3(-762.90, -1797.68, 27.58),
        vec3(-743.09, -1865.37, 26.13),
        vec3(-704.73, -2010.99, 24.45),
        vec3(-704.60, -2062.11, 17.04),
        vec3(-743.69, -2144.73, 12.95),
        vec3(-772.22, -2177.07, 14.64),
        vec3(-840.58, -2232.17, 16.57),
        vec3(-892.82, -2277.26, 18.44),
        vec3(-942.56, -2351.21, 19.14),
        vec3(-1053.14, -2543.60, 19.16),
        vec3(-1092.67, -2614.94, 19.16),
        vec3(-1080.01, -2693.50, 19.14),
        vec3(-1035.75, -2727.45, 19.15),   -- LSIA departures, by the check-in desk (drop-off)
    },
    speed        = 27.0,            -- m/s on freeways / highways (~60 mph)
    citySpeed    = 13.4,            -- m/s on every other road (~30 mph). nil = always use speed
    -- a road counts as highway when GTA's street name contains one of these
    highwayNames = { 'Fwy', 'Freeway', 'Hwy', 'Highway' },
    -- 447 = careful driving that keeps to main roads and highways. (786603, the
    -- shuttle style, also has "shortest path" on, which cuts through side streets.)
    drivingStyle = 447,
    viaRadius    = 40.0,            -- how close counts as "reached" for loop points (driving past one also counts)
    lookahead    = 1,               -- the driver aims this many points past the next one (smoother, no braking at points)
    arriveRadius = 15.0,            -- drop-off
    stagger      = 3,               -- seconds between convoy cars pulling away
    stuckTime          = 20,
    maxStuckRecoveries = 6,
    despawnDelay       = 6,
    buckleTimeout      = 45,        -- leaves when everyone has buckled (B), or this long after the first one did
    minWait            = 20,        -- always waits at least this long at the curb
    joinGrace          = 15,        -- each new rider gets at least this many seconds to get in
    tripTimeout        = 1800,      -- seconds; riders are faded to the drop-off if a car never arrives

    -- Quieter roads for the riders (only on their own screens, only while the car is moving)
    traffic = {
        density    = 0.0,           -- cars: 0.0 = none, 1.0 = normal
        pedDensity = 1.0,           -- people on the sidewalks: 1.0 = leave as normal
        clearAhead = true,          -- remove random NPC traffic around the car
        clearAll   = true,          -- true: every NPC car within clearRadius (empty roads). false: only the box ahead below
        clearRadius = 300.0,
        aheadMin   = 60.0,          -- (clearAll = false) metres ahead where clearing starts, so cars don't visibly pop
        aheadMax   = 220.0,
        width      = 25.0,          -- (clearAll = false) metres either side of the car's path
    },

    -- Music for the drive: starts as the car pulls away, plays back to back, fades out at the
    -- drop-off. Riders change their own volume with the scroll wheel (same as on the jet).
    music = {
        volume = 0.5,
        tracks = {
            { file = 'audio/lastdrive/TheCityWeLeaveBehind.mp3',   duration = 360 },   -- leaving the city
            { file = 'audio/lastdrive/WheretheRoadsRemember.mp3',  duration = 360 },   -- up the west coast
            { file = 'audio/lastdrive/EchoesofSanAndreas.mp3',     duration = 360 },   -- the north and the desert
            { file = 'audio/lastdrive/OneLastRide.mp3',            duration = 289 },   -- the way home
        },
        fadeOut = 4,                -- seconds the music fades over at the drop-off
    },

    -- "Now passing" pop-ups (bottom left, same as on the jet) with a short line underneath.
    -- Shown once each when the car comes within viewRadius metres.
    viewRadius = 250.0,
    viewpoints = {
        { pos = vec3(8.35, -753.06, 30.87),     label = 'Downtown Los Santos',  quote = 'Every street here holds a story we wrote together.' },
        { pos = vec3(-733.45, -648.70, 29.16),  label = 'Little Seoul',         quote = 'The late nights, the loud laughs. They all happened here.' },
        { pos = vec3(-1529.93, -643.07, 28.05), label = 'Del Perro',            quote = 'Some of our best days started with nowhere to be.' },
        { pos = vec3(-2113.33, -359.32, 11.91), label = 'Pacific Bluffs',       quote = 'The ocean was always there, waiting for us to slow down.' },
        { pos = vec3(-3093.21, 1261.37, 19.25), label = 'Chumash',              quote = 'Quiet places remember loud friendships.' },
        { pos = vec3(-2675.07, 2479.03, 15.69), label = 'Lago Zancudo',         quote = 'We crossed so many bridges together. This is one more.' },
        { pos = vec3(-2595.46, 3044.39, 15.09), label = 'Fort Zancudo',         quote = 'For the ones who stood their ground with us.' },
        { pos = vec3(-1568.76, 4923.02, 60.50), label = 'Paleto Forest',        quote = 'Some roads are long so we can say what matters.' },
        { pos = vec3(-149.12, 6219.83, 30.20),  label = 'Paleto Bay',           quote = 'Small towns, big memories.' },
        { pos = vec3(1027.13, 6481.43, 19.99),  label = 'Mount Chiliad',        quote = 'We climbed it once just to watch the sun come up. Worth it.' },
        { pos = vec3(2522.27, 5420.28, 43.55),  label = 'Grapeseed',            quote = 'Home was never one place. It was the people in the car.' },
        { pos = vec3(2822.53, 3510.50, 53.59),  label = 'Sandy Shores',         quote = 'To everyone we lost along the way: you rode with us every mile.' },
        { pos = vec3(2103.71, 2689.25, 49.35),  label = 'Grand Senora Desert',  quote = 'Out here the sky is big enough for every memory.' },
        { pos = vec3(1500.68, 853.72, 76.11),   label = 'Tataviam Mountains',   quote = 'Look back once. Then keep going.' },
        { pos = vec3(759.68, -0.76, 62.01),     label = 'Vinewood Hills',       quote = 'We were never famous. We were something better: together.' },
        { pos = vec3(1053.20, -1489.87, 27.17), label = 'East Los Santos',      quote = 'Thank you for every ride, every rescue, every "one more".' },
        { pos = vec3(546.98, -2660.77, 37.53),  label = 'Port of Los Santos',   quote = 'Ships leave the harbour. The harbour remembers.' },
        { pos = vec3(-942.56, -2351.21, 19.14), label = 'Los Santos International', quote = 'This isn\'t goodbye. It\'s see you on the other side.' },
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

-- After the chime every passenger presses the seatbelt key (B) to buckle up.
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
