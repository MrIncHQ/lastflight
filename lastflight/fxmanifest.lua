fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'lastflight'
description 'Last Flight to Vice City - a multiplayer cinematic farewell flight out of Los Santos'
version '1.0.0'

dependency '/onesync'

shared_scripts {
    'config.lua',
    'shared.lua',
}

client_scripts {
    'client_main.lua',
    'client_airport.lua',
    'client_transport.lua',
    'client_tour.lua',
    'client_cameras.lua',
    'client_flight.lua',
    'client_setup.lua',
}

server_scripts {
    'server_bridge.lua',
    'server_main.lua',
    'server_tour.lua',
    'server_setup.lua',
    'server_admin.lua',
}

ui_page 'index.html'

files {
    'index.html',
    'style.css',
    'app.js',
    'audio/*.mp3',
    'audio/lastdrive/*.mp3',
    'audio/*.ogg',
}
