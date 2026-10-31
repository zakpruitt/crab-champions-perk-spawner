# Copies the mod and its UE4SS config into the local game install, for testing
# edits. UE4SS itself must already be installed (extract a packaged zip once).
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Crab Champions"
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$binaries = Join-Path $GameDir "CrabChampions\Binaries\Win64"

if (-not (Test-Path (Join-Path $binaries "UE4SS.dll"))) {
    throw "UE4SS not found in $binaries. Extract a packaged zip into the game folder first."
}

Copy-Item (Join-Path $repo "PerkSpawner") (Join-Path $binaries "Mods") -Recurse -Force
Copy-Item (Join-Path $repo "config\mods.txt") (Join-Path $binaries "Mods\mods.txt") -Force
Copy-Item (Join-Path $repo "config\UE4SS-settings.ini") (Join-Path $binaries "UE4SS-settings.ini") -Force

Write-Host "Installed PerkSpawner into $binaries"
