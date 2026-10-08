fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'bsd_sentinel_agent'
author 'BlackStone Development'
version '0.1.0'
description 'Sentinel agent: sends this server\'s health, players and money events to Sentinel'

-- Server-side only. Nothing is sent to players' game clients.
server_scripts {
    'server/sha256.lua',
    'server/util.lua',
    'server/key.lua',
    'server/scrub.lua',
    'server/transport.lua',
    'server/collectors.lua',
    'server/adapters/qbcore.lua',
    'server/main.lua',
}
