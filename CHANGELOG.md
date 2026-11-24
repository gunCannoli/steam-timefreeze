# Changelog

## [Unreleased]

## [0.1.6-beta] - 2026-11-24

### Fixed

- **Immediate Backend Startup Guard**: Added `enforce_frozen_on_startup()` in `backend/main.lua` (`on_load`) so frozen games have `downloading/<appid>`, `temp/<appid>`, and `.patch` caches purged and any dirty/writable `appmanifest` (`StateFlags != 4`, `TargetBuildID != 0`, `BytesToDownload > 0`, `StagedDepots`, or cleared read-only) repaired immediately at Steam boot, before Steam's download manager finishes scanning `steamapps`.
- **Strip `StagedDepots` from Manifests**: Updated `vdf.patch_manifest` to remove leftover `StagedDepots` blocks when freezing, preventing Steam from reviving staged updates on restart for multi-depot games.
- **Pre-Restart Purge & Cancel Settle**: `Timefreeze` now waits 250ms after `PauseAppUpdate` / `RemoveFromDownloadList` / `app_update_cancel` before purging and locking, and **Restart Steam** re-purges/re-locks right before calling `StartRestart`, eliminating the "needs two restarts" race.
- **Reliable Depot Resolution**: `fetchSteamAppInfo` now waits for `app_info_print` console spew to settle (instead of a fixed 900ms cutoff) and falls back to the SteamCMD Web API if `SteamClient.Console` returns branches without public depot manifest GIDs.
- **Per-Depot Patch Cleanup**: `purge_download_cache` now also scans `steamapps/downloading` for per-depot `state_<appid>_*.patch` and `<appid>_*.patch` files.

### Added

- **Detailed Freeze & Sync Diagnostics**: `timefreeze.log` now records exact `sync_frozen` trigger reasons (`not_ro`, `build_mismatch`, `depot_mismatch`), `freeze` depot match counts (`depots=X/Y`, `unmatched=[...]`, `staged_cleared`), `displayStatus` transitions, and `[timefreeze] startup-guard` results.

## [0.1.5-beta] - 2026-11-24

### Added

- **Root & Mirrored Logging**: Comprehensive log file `timefreeze.log` dropped directly at the plugin root (`<Steam>/millennium/plugins/steam-timefreeze/timefreeze.log`) and mirrored to config directory (`<Steam>/millennium/config/steam-timefreeze/timefreeze.log`), capturing ISO timestamps, OS context, RPC calls, manifest operations, and frontend logs via `TimefreezeLog`.
- **Purge Cache & Lock UI Action**: Added dedicated "Purge Cache & Lock" button in the Timefreeze Properties tab when Steam still shows an update cached in memory, giving players a one-click cache purge and re-lock.

### Fixed

- **Cached Update Persistence**: When freezing a game with an already-cached update, Timefreeze now automatically purges stale chunks and metadata in `<library>/steamapps/downloading/<appid>`, `<library>/steamapps/temp/<appid>`, and `.patch` files, and sanitizes all leftover update fields in `appmanifest` (`UpdateResult`, `DownloadType`, `FullValidateBeforeNextUpdate`, `FullValidateAfterNextUpdate`, `StagingSize`) so Steam does not restore the Update button on restart.
- **Up-to-Date Games Freeze & Sync**: Added automatic multi-source PICS resolution with SteamCMD Web API fallback (`https://api.steamcmd.net/v1/info/<appid>`) so games can accurately resolve latest public buildids and depot manifest GIDs even when Steam is running without `-console` / `-dev` flags.
- **Config Storage & Restart Persistence**: Replaced single-directory creation with recursive directory creation (`fs.create_directories` / `platform.mkdir_p`) with writable test fallback to `<plugin_root>/data/`, preventing silent `state.json` write failures across Windows and Linux.
- **Self-Healing State**: If `state.json` is missing or desynced but an `appmanifest_<appid>.acf` is marked read-only with `StateFlags = 4` on disk, `get_status` automatically recovers the frozen entry so games never unexpectedly show as "not frozen" after restarting Steam.
- **Linux & Steam Deck Robustness**:
  - Made `set_readonly` non-fatal when `chmod` fails on non-POSIX / foreign filesystems (e.g. exFAT or NTFS on MicroSD cards and external drives), allowing manifest spoofing and freeze state persistence to succeed regardless of filesystem limitations.
  - Handled Linux case sensitivity by checking both `steamapps` and `SteamApps` directories across libraries for manifests and download/temp caches.
  - Added tilde expansion (`~`) and XDG environment mapping (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`) for Linux path resolution.
  - Added `[host]` diagnostic logging capturing OS distro, Steam Deck (`STEAM_DECK=1`, `/etc/os-release`), and Flatpak container status.

## [0.1.0] - 2026-11-19

### Added

- Initial release of Timefreeze (`steam-timefreeze`): custom **Timefreeze** tab in every Steam game's Properties dialog, version dropdown pre-selected to the currently installed build, one-click manifest freeze/unfreeze with read-only protection, automatic startup sync for frozen games, beta branch switching, and optional SteamDB depot download helper.
