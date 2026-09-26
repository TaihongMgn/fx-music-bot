# Connect the bot to azraelkaxi.top. Does not start a local Mumble server.
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\local\connect-azrael.ps1
#
# If the server asks for a password:
#   powershell -ExecutionPolicy Bypass -File scripts\local\connect-azrael.ps1 -Password 'your-server-password'

param(
    [string]$Password = '',
    [string]$BotName = 'fx-bot',
    [string]$BotAdmin = 'SuperUser;ChatGPT'
)

$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\stop.ps1"
& "$PSScriptRoot\start.ps1" `
    -MumbleHost 'azraelkaxi.top' `
    -MumblePort 64738 `
    -ServerPassword $Password `
    -BotName $BotName `
    -BotAdmin $BotAdmin `
    -SkipLocalMumble
