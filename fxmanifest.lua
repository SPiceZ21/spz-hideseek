fx_version 'cerulean'
game 'gta5'

name 'spz-hideseek'
description 'SPiceZ Minigame — RC Hide & Seek. Everyone spawns as a tiny RC car in one contained zone; seekers find hiders by proximity. Free to play.'
version '1.2.0'
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
