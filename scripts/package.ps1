# Builds dist/PerkSpawner-<version>.zip: UE4SS plus this mod, laid out so it can be
# extracted straight into the Crab Champions install folder.
param(
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"

$ue4ssVersion = "v3.0.1"
$ue4ssUrl = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/$ue4ssVersion/UE4SS_$ue4ssVersion.zip"

$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo "dist"
$work = Join-Path $dist "work"
$ue4ssZip = Join-Path $dist "UE4SS_$ue4ssVersion.zip"
$binaries = Join-Path $work "CrabChampions\Binaries\Win64"
$output = Join-Path $dist "PerkSpawner-$Version.zip"

New-Item -ItemType Directory -Force $dist | Out-Null
if (-not (Test-Path $ue4ssZip)) {
    Write-Host "Downloading UE4SS $ue4ssVersion"
    Invoke-WebRequest -Uri $ue4ssUrl -OutFile $ue4ssZip -UseBasicParsing
}

if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $binaries | Out-Null
Expand-Archive -Path $ue4ssZip -DestinationPath $binaries

# Our load order (bundled console/cheat mods off) and settings.
Copy-Item (Join-Path $repo "config\mods.txt") (Join-Path $binaries "Mods\mods.txt") -Force
Copy-Item (Join-Path $repo "config\UE4SS-settings.ini") (Join-Path $binaries "UE4SS-settings.ini") -Force
Copy-Item (Join-Path $repo "PerkSpawner") (Join-Path $binaries "Mods") -Recurse -Force

if (Test-Path $output) { Remove-Item -Force $output }
Compress-Archive -Path (Join-Path $work "CrabChampions") -DestinationPath $output
Remove-Item -Recurse -Force $work

Write-Host "Built $output"
