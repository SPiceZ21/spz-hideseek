fx_version 'cerulean'
game 'gta5'

name 'spz-hideseek'
description 'SPiceZ Minigame — Traffic Hide & Seek. Hiders blend into NPC traffic, seekers find them by proximity. Credit wager, pot split to the winning side.'
version '1.0.0'
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

dependencies {
  'ox_lib',
  'oxmysql',
  'spz-core',
  'spz-identity',
  'spz-progression',
}
