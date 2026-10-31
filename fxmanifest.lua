fx_version 'cerulean'
game 'gta5'

name 'spz-cyclone'
description 'SPiceZ Minigame - Cyclone. Everyone drives on one big single-colour deck in the sky; a roaming cyclone lifts cars and throws them off. One round, last car standing wins. Free to play.'
version '1.1.2'
author 'SPiceZ-Core'
lua54 'yes'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
}

client_scripts {
  'client/main.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua',
}

-- The deck uses spz-colorrush's streamed tiles (Config.TileModel), so that
-- resource must be started first; there is no stream/ folder here.
dependencies {
  'ox_lib',
  'oxmysql',
  'spz-core',
  'spz-identity',
  'spz-progression',
  'spz-minigames',   -- shared in-game HUD
  'spz-colorrush',   -- deck tile models
}
