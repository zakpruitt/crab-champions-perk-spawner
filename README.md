# Crab Champions Perk Spawner

An in-game menu for Crab Champions that gives you any perk, weapon mod, ability mod, melee mod or relic at any level. It runs on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) as a Lua mod and works in the lobby, in runs, and in multiplayer.

Meant for private lobbies with friends. Don't use it in public games.

## Installation

1. Download `PerkSpawner-<version>.zip`.
2. In Steam, right-click **Crab Champions → Manage → Browse local files**.
3. Extract the zip into that folder. It contains a `CrabChampions` folder that merges with the one already there.
4. Check that `CrabChampions\Binaries\Win64\dwmapi.dll` now exists, then launch the game.

**Multiplayer:** everyone needs the mod, and the host must have it. Clients send their requests to the host, and the host's copy hands the items out.

**Uninstall:** delete `dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini` and the `Mods` folder from `CrabChampions\Binaries\Win64`.

## Usage

Press **F6** to open or close the menu.

| Input              | Action                                                  |
| ------------------ | ------------------------------------------------------- |
| Click a tab        | Switch category                                         |
| Click an item      | Select it; click it again to give it                    |
| Type letters       | Search (Backspace erases, Delete clears)                |
| Up / Down          | Move selection                                          |
| PgUp / PgDn        | Previous / next page                                    |
| Left / Right       | Previous / next category                                |
| + / -              | Change the level to give                                |
| Enter or **GIVE**  | Give the selected item                                  |

Giving an item you already own adds to its level. Items you own are marked **OWNED** in the list.

## How It Works

- **Host:** writes the item straight into the player state's inventory array, which the game replicates to everyone.
- **Client:** sends `[PerkSpawner] <name> Lv<n> {<asset>}` through the game's chat RPC. The host's mod hooks `ServerSendChatMessage` and grants the item, so the request shows up in chat.
- **UI:** built at runtime from plain UMG widgets. Colors, fonts and anchors are written straight into widget properties, because UE4SS 3.0.1 mangles nested struct parameters such as `FSlateColor` and `FAnchors`.
- **TArray growth:** UE4SS 3.0.1 only grows a TArray when it's indexed two past the end, so the mod reads `Num+2` and then fills in `Num+1`.

## Development

```powershell
# Copy the mod into your game install after editing (UE4SS must already be installed)
.\scripts\install.ps1

# Build dist\PerkSpawner-<version>.zip (downloads UE4SS v3.0.1 on first run)
.\scripts\package.ps1 -Version 1.0.0
```

Logs and Lua errors go to `CrabChampions\Binaries\Win64\UE4SS.log`.

Bundled UE4SS mods that register console commands are turned off in `config/mods.txt`. Crab Champions runs a console command at startup, and that path crashed UE4SS 3.0.1 when a custom command handler was registered.
