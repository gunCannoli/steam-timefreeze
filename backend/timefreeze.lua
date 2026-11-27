--- Core Timefreeze backend operations: manifest discovery, status, freeze, unfreeze, startup sync,
--- and update cache cleanup/purging for pending updates.

local logger = require("log").logger
local platform = require("platform")
local file_attrs = require("file_attrs")
local vdf = require("vdf")
local state_store = require("state_store")

local M = {}

M.deps = {
  steam_path = nil,
  now = nil,
}

local function get_steam_path()
  if M.deps.steam_path then return M.deps.steam_path() end
  local millennium = require("millennium")
  return millennium.steam_path()
end

local function now_sec()
  if M.deps.now then return M.deps.now() end
  return os.time()
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, tostring(err or "open failed") end
  local raw = f:read("*a")
  f:close()
  return raw, nil
end

local function write_file(path, text)
  local f, err = io.open(path, "wb")
  if not f then return false, tostring(err or "open failed") end
  f:write(text)
  f:flush()
  f:close()
  return true, nil
end

--- Return candidate steamapps directory names (handles Linux case-sensitivity: steamapps vs SteamApps).
local function steamapps_variants(lib_root)
  return {
    platform.join(lib_root, "steamapps"),
    platform.join(lib_root, "SteamApps"),
  }
end

--- Return all Steam library root paths (main Steam root + libraryfolders.vdf entries).
---@return string[]
function M.library_roots()
  local root = platform.join(get_steam_path())
  local roots = { root }
  local seen = { [root:lower()] = true }

  for _, sa in ipairs(steamapps_variants(root)) do
    local lf_path = platform.join(sa, "libraryfolders.vdf")
    local raw = read_file(lf_path)
    if raw then
      for _, lib in ipairs(vdf.library_paths(raw)) do
        local key = lib:lower()
        if not seen[key] then
          seen[key] = true
          roots[#roots + 1] = lib
        end
      end
      break
    end
  end
  return roots
end

--- Locate appmanifest_<appid>.acf across all Steam libraries.
--- Checks both steamapps and SteamApps subdirectories for Linux case sensitivity.
---@param appid number
---@return string|nil, string|nil
function M.find_manifest(appid)
  local fname = "appmanifest_" .. tostring(appid) .. ".acf"
  for _, lib in ipairs(M.library_roots()) do
    for _, sa in ipairs(steamapps_variants(lib)) do
      local candidate = platform.join(sa, fname)
      local f = io.open(candidate, "rb")
      if f then
        f:close()
        return candidate, lib
      end
    end
  end
  return nil, nil
end

--- Check if a file or directory exists (using fs.exists with fallback).
local function path_exists(path)
  local ok_fs, fs = pcall(require, "fs")
  if ok_fs and fs and fs.exists then
    local ok, ex = pcall(fs.exists, path)
    if ok and ex ~= nil then return ex == true end
  end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  local probe = path .. "/.probe"
  local f_dir = io.open(probe, "wb")
  if f_dir then
    f_dir:close()
    os.remove(probe)
    return true
  end
  return false
end

--- Recursively remove a path (file or folder) using Millennium fs if available, fallback os.remove.
local function safe_remove_path(target)
  local ok_fs, fs = pcall(require, "fs")
  if ok_fs and fs then
    if fs.remove_all then
      local ok = pcall(fs.remove_all, target)
      if ok and not (fs.exists and fs.exists(target)) then return true end
    end
    if fs.remove then
      local ok = pcall(fs.remove, target)
      if ok and not (fs.exists and fs.exists(target)) then return true end
    end
  end
  local ok = os.remove(target)
  return ok == true
end

--- Purge any pending update downloads, staging folders, or patch state for this appid.
--- Steam caches in-progress updates in steamapps/downloading/<appid>, steamapps/temp/<appid>,
--- and patch metadata files. If these are left on disk, Steam on restart restores the Update button!
---@param appid number
---@param library_hint string|nil
---@return integer count number of items removed
function M.purge_download_cache(appid, library_hint)
  local str_id = tostring(appid)
  local count = 0
  local search_roots = library_hint and { library_hint } or M.library_roots()
  local ok_fs, fs = pcall(require, "fs")

  for _, lib in ipairs(search_roots) do
    for _, sa in ipairs(steamapps_variants(lib)) do
      local targets = {
        platform.join(sa, "downloading", str_id),
        platform.join(sa, "temp", str_id),
        platform.join(sa, "downloading", str_id .. ".patch"),
        platform.join(sa, "downloading", "state_" .. str_id .. ".patch"),
      }
      local seen_targets = {}
      for _, t in ipairs(targets) do
        seen_targets[t] = true
      end

      -- Also catch per-depot patch/state files (e.g. state_<appid>_<depotid>.patch)
      local dl_dir = platform.join(sa, "downloading")
      if ok_fs and fs and fs.list and path_exists(dl_dir) then
        local ok_list, entries = pcall(fs.list, dl_dir)
        if ok_list and type(entries) == "table" then
          local p1 = "^" .. str_id .. "[_%.].*%.patch$"
          local p2 = "^state_" .. str_id .. "[_%.].*%.patch$"
          for _, item in ipairs(entries) do
            local name = type(item) == "table" and tostring(item.name or "") or tostring(item)
            if name ~= "" and (name:match(p1) or name:match(p2)) then
              local full = platform.join(dl_dir, name)
              if not seen_targets[full] then
                seen_targets[full] = true
                targets[#targets + 1] = full
              end
            end
          end
        end
      end

      for _, t in ipairs(targets) do
        if path_exists(t) then
          local ok = safe_remove_path(t)
          if ok then
            count = count + 1
            logger:info("[timefreeze] purged download cache target: " .. t)
          else
            logger:warn("[timefreeze] failed to purge download cache target: " .. t)
          end
        end
      end
    end
  end
  return count
end

local function depots_to_manifest_map(installed_depots)
  local out = {}
  if type(installed_depots) ~= "table" then return out end
  for depot_id, info in pairs(installed_depots) do
    if type(info) == "table" and type(info.manifest) == "string" and info.manifest ~= "" then
      out[tostring(depot_id)] = info.manifest
    elseif type(info) == "string" and info ~= "" then
      out[tostring(depot_id)] = info
    end
  end
  return out
end

--- depotId -> dlcappid for every DLC depot named in any of the given InstalledDepots tables
--- (state.json from 0.1.6 and older lacks dlcappid, so the live manifest is merged in too).
local function depots_dlc_map(...)
  local out = {}
  for _, installed_depots in ipairs({ ... }) do
    if type(installed_depots) == "table" then
      for depot_id, info in pairs(installed_depots) do
        if type(info) == "table" and type(info.dlcappid) == "string" and info.dlcappid ~= "" then
          out[tostring(depot_id)] = info.dlcappid
        end
      end
    end
  end
  return out
end

local function record_history(entry, buildid, date_sec, depots)
  if type(buildid) ~= "string" or buildid == "" or buildid == "0" then return end
  if type(entry.history) ~= "table" then entry.history = {} end
  for _, item in ipairs(entry.history) do
    if type(item) == "table" and tostring(item.buildid) == buildid then
      if (tonumber(item.date) or 0) == 0 and (tonumber(date_sec) or 0) > 0 then
        item.date = tonumber(date_sec)
      end
      return
    end
  end
  entry.history[#entry.history + 1] = {
    buildid = buildid,
    date = tonumber(date_sec) or 0,
    depots = depots_to_manifest_map(depots),
    seenAt = now_sec(),
  }
end

local function build_status(appid, manifest_path, manifest, entry, is_ro)
  local frozen = type(entry) == "table" and entry.frozen == true
  local installed_build = frozen and tostring(entry.realBuildId or manifest.buildid) or manifest.buildid
  local installed_date = frozen and (tonumber(entry.realLastUpdated) or manifest.lastUpdated) or manifest.lastUpdated
  local installed_depots = frozen and (entry.realDepots or manifest.installedDepots) or manifest.installedDepots
  local history = (type(entry) == "table" and type(entry.history) == "table") and entry.history or {}
  local custom_versions = (type(entry) == "table" and type(entry.customVersions) == "table") and entry.customVersions or {}

  return {
    found = true,
    appid = appid,
    name = manifest.name,
    manifestPath = manifest_path,
    frozen = frozen,
    frozenAt = frozen and (tonumber(entry.frozenAt) or 0) or 0,
    readonly = is_ro == true,
    installedBuildId = installed_build,
    installedDate = installed_date,
    installedDepots = depots_to_manifest_map(installed_depots),
    installedDepotDlc = depots_dlc_map(installed_depots, manifest.installedDepots),
    manifestBuildId = manifest.buildid,
    targetBuildId = manifest.targetBuildId,
    stateFlags = manifest.stateFlags,
    bytesToDownload = manifest.bytesToDownload,
    autoUpdateBehavior = manifest.autoUpdateBehavior,
    betakey = manifest.betakey,
    spoofedBuildId = frozen and tostring(entry.spoofedBuildId or "") or "",
    history = history,
    customVersions = custom_versions,
  }
end

--- Read current status for an installed Steam game.
--- Includes self-healing if state.json was desynced but the manifest is read-only on disk.
---@param appid number
---@return table
function M.get_status(appid)
  local manifest_path, lib_root = M.find_manifest(appid)
  if not manifest_path then
    logger:info("[timefreeze] get_status: manifest not found for appid=" .. tostring(appid))
    return {
      found = false,
      appid = appid,
      frozen = false,
      readonly = false,
      history = {},
    }
  end

  local raw, err = read_file(manifest_path)
  if not raw then
    logger:error("[timefreeze] failed to read manifest for appid=" .. tostring(appid) .. ": " .. tostring(err))
    return { error = "Could not read appmanifest: " .. tostring(err) }
  end

  local manifest = vdf.parse_manifest(raw)
  if not manifest then
    logger:error("[timefreeze] parse_manifest failed for appid=" .. tostring(appid))
    return { error = "Could not parse appmanifest" }
  end

  local is_ro = file_attrs.is_readonly(manifest_path)
  local state = state_store.load()
  local key = tostring(appid)
  local entry = state.games[key]

  -- Self-healing fallback: if entry is missing from state.json, but the manifest file is read-only
  -- on disk and StateFlags is 4, restore frozen entry so restarting Steam never loses the freeze badge!
  if (type(entry) ~= "table" or not entry.frozen) and is_ro == true and manifest.stateFlags == 4 then
    logger:info("[timefreeze] self-healing: detected read-only manifest for appid=" .. tostring(appid) .. ", auto-restoring frozen state")
    entry = {
      appid = appid,
      name = manifest.name,
      frozen = true,
      frozenAt = now_sec(),
      realBuildId = manifest.buildid,
      spoofedBuildId = manifest.buildid,
      realLastUpdated = manifest.lastUpdated,
      realAutoUpdateBehavior = tostring(manifest.autoUpdateBehavior),
      realDepots = manifest.installedDepots,
      history = {},
    }
    record_history(entry, manifest.buildid, manifest.lastUpdated, manifest.installedDepots)
    state.games[key] = entry
    state_store.save(state)
  end

  -- Record currently installed build in local history if not frozen (so we only log true builds)
  if not (type(entry) == "table" and entry.frozen == true) and manifest.buildid ~= "" then
    if type(entry) ~= "table" then
      entry = { appid = appid, name = manifest.name, frozen = false, history = {} }
      state.games[key] = entry
    end
    local before = #(entry.history or {})
    record_history(entry, manifest.buildid, manifest.lastUpdated, manifest.installedDepots)
    if #(entry.history or {}) ~= before then
      state_store.save(state)
    end
  end

  return build_status(appid, manifest_path, manifest, entry, is_ro)
end

--- Freeze an installed game at its currently installed build.
--- Spoofs appmanifest buildid & InstalledDepots to latest_buildid / latest_depots,
--- purges pending download and staging caches, wipes all update/resume flags,
--- and sets the file Read-Only.
---@param appid number
---@param latest_buildid string|nil
---@param latest_depots table<string, string>|nil
---@return table
function M.freeze(appid, latest_buildid, latest_depots)
  local manifest_path, lib_root = M.find_manifest(appid)
  if not manifest_path then
    return { error = "Game is not installed (appmanifest not found)." }
  end

  local raw, rerr = read_file(manifest_path)
  if not raw then
    return { error = "Could not read appmanifest: " .. tostring(rerr) }
  end

  local manifest = vdf.parse_manifest(raw)
  if not manifest then
    return { error = "Could not parse appmanifest." }
  end

  local state = state_store.load()
  local key = tostring(appid)
  local entry = state.games[key]

  if type(entry) ~= "table" then
    entry = { appid = appid, name = manifest.name, frozen = false, history = {} }
  end

  -- Preserve the TRUE installed build/depots on first freeze; never overwrite them with a spoofed build
  if not entry.frozen then
    state_store.save_backup(appid, raw, true)
    entry.name = manifest.name
    entry.realBuildId = manifest.buildid
    entry.realLastUpdated = manifest.lastUpdated
    entry.realAutoUpdateBehavior = tostring(manifest.autoUpdateBehavior)
    entry.realDepots = manifest.installedDepots
    record_history(entry, manifest.buildid, manifest.lastUpdated, manifest.installedDepots)
  end

  local spoof_build = (type(latest_buildid) == "string" and latest_buildid ~= "" and latest_buildid ~= "0")
    and latest_buildid
    or (manifest.targetBuildId ~= "" and manifest.targetBuildId ~= "0" and manifest.targetBuildId)
    or manifest.buildid

  -- Build depot manifest replacements for installed depots only
  local depot_updates = {}
  local real_depots = entry.realDepots or manifest.installedDepots or {}
  local depots_total = 0
  local depots_spoofed = 0
  local depots_unmatched = {}
  local depots_kept = 0
  local prev_spoof = (entry.frozen and type(entry.spoofedDepots) == "table") and entry.spoofedDepots or {}
  local dlc_of = depots_dlc_map(real_depots, manifest.installedDepots)
  for depot_id, _ in pairs(real_depots) do
    local d = tostring(depot_id)
    depots_total = depots_total + 1
    local gid = type(latest_depots) == "table" and latest_depots[d] or nil
    if type(gid) == "string" and gid ~= "" then
      depot_updates[d] = gid
      depots_spoofed = depots_spoofed + 1
    elseif type(prev_spoof[d]) == "string" and prev_spoof[d] ~= "" then
      -- Fallback: a later freeze with less app info (Web API down, console off) keeps the earlier
      -- spoof instead of putting the real, outdated manifest back (which re-arms Steam's update).
      depot_updates[d] = prev_spoof[d]
      depots_kept = depots_kept + 1
    else
      depots_unmatched[#depots_unmatched + 1] = dlc_of[d] and (d .. "(dlc " .. dlc_of[d] .. ")") or d
    end
  end
  table.sort(depots_unmatched)
  if #depots_unmatched > 0 then
    logger:warn(string.format(
      "[timefreeze] freeze appid=%d: %d depot(s) have no latest manifest and keep the installed one, so Steam may still show Update: [%s]",
      appid, #depots_unmatched, table.concat(depots_unmatched, ",")))
  end

  -- Comprehensive sanitization of all update/download/resume flags
  local top_updates = {
    StateFlags = "4",
    BytesToDownload = "0",
    BytesDownloaded = "0",
    BytesToStage = "0",
    BytesStaged = "0",
    TargetBuildID = "0",
    ScheduledAutoUpdate = "0",
    AutoUpdateBehavior = "1",
    UpdateResult = "0",
    DownloadType = "0",
    FullValidateBeforeNextUpdate = "0",
    FullValidateAfterNextUpdate = "0",
    StagingSize = "0",
    buildid = spoof_build,
  }

  local patched = vdf.patch_manifest(raw, top_updates, depot_updates, { StagedDepots = true })

  -- Purge leftover downloading/staging files so Steam doesn't revive a paused update on startup
  local purged = M.purge_download_cache(appid, lib_root)

  -- Ensure writable before writing
  file_attrs.set_readonly(manifest_path, false)
  local wok, werr = write_file(manifest_path, patched)
  if not wok then
    logger:error("[timefreeze] write failed for appid=" .. tostring(appid) .. ": " .. tostring(werr))
    return { error = "Could not write appmanifest: " .. tostring(werr) }
  end

  local rook, roerr = file_attrs.set_readonly(manifest_path, true)
  if not rook then
    logger:warn(string.format("[timefreeze] set_readonly warning for appid=%d: %s (non-fatal; filesystem may be exFAT/NTFS, manifest spoofing still active)", appid, tostring(roerr)))
  end

  entry.frozen = true
  entry.frozenAt = now_sec()
  entry.spoofedBuildId = spoof_build
  entry.spoofedDepots = depot_updates
  entry.readonly = rook == true
  state.games[key] = entry
  local sok, serr = state_store.save(state)
  if not sok then
    logger:warn("[timefreeze] state_store.save failed for appid=" .. tostring(appid) .. ": " .. tostring(serr))
  end

  logger:info(string.format(
    "[timefreeze] frozen appid=%d real=%s spoof=%s target_arg=%s state_flags=%s->4 depots=%d/%d kept=%d unmatched=[%s] staged_cleared=%s ro=%s purged=%d",
    appid,
    tostring(entry.realBuildId),
    tostring(spoof_build),
    tostring(latest_buildid or ""),
    tostring(manifest.stateFlags),
    depots_spoofed,
    depots_total,
    depots_kept,
    table.concat(depots_unmatched, ","),
    tostring(manifest.hasStagedDepots == true),
    tostring(rook == true),
    purged
  ))

  local updated_manifest = vdf.parse_manifest(patched) or manifest
  return build_status(appid, manifest_path, updated_manifest, entry, rook == true)
end

--- Unfreeze a game: remove Read-Only and restore the real buildid & depot manifests.
---@param appid number
---@return table
function M.unfreeze(appid)
  local manifest_path = M.find_manifest(appid)
  if not manifest_path then
    return { error = "Game is not installed (appmanifest not found)." }
  end

  local state = state_store.load()
  local key = tostring(appid)
  local entry = state.games[key]

  local rok, rerr = file_attrs.set_readonly(manifest_path, false)
  if not rok then
    logger:warn(string.format("[timefreeze] clear readonly warning for appid=%d: %s (attempting write anyway)", appid, tostring(rerr)))
  end

  local raw, read_err = read_file(manifest_path)
  if not raw then
    return { error = "Could not read appmanifest: " .. tostring(read_err) }
  end

  local patched = raw
  if type(entry) == "table" and entry.frozen then
    local top_updates = {}
    if type(entry.realBuildId) == "string" and entry.realBuildId ~= "" then
      top_updates.buildid = entry.realBuildId
    end
    if tonumber(entry.realLastUpdated) and tonumber(entry.realLastUpdated) > 0 then
      top_updates.LastUpdated = tostring(entry.realLastUpdated)
    end
    if type(entry.realAutoUpdateBehavior) == "string" and entry.realAutoUpdateBehavior ~= "" then
      top_updates.AutoUpdateBehavior = entry.realAutoUpdateBehavior
    end
    local depot_restore = depots_to_manifest_map(entry.realDepots)
    patched = vdf.patch_manifest(raw, top_updates, depot_restore)
    local wok, werr = write_file(manifest_path, patched)
    if not wok then
      return { error = "Could not restore appmanifest: " .. tostring(werr) }
    end
    entry.frozen = false
    entry.spoofedBuildId = nil
    entry.spoofedDepots = nil
    state.games[key] = entry
    state_store.save(state)
    logger:info("[timefreeze] unfrozen appid=" .. tostring(appid) .. " restored=" .. tostring(entry.realBuildId))
  end

  local updated_manifest = vdf.parse_manifest(patched)
  if not updated_manifest then
    return { error = "Could not parse restored appmanifest." }
  end
  return build_status(appid, manifest_path, updated_manifest, entry, false)
end

--- Refresh a frozen game's spoofed manifest if Valve pushed a newer build or read-only was cleared.
---@param appid number
---@param latest_buildid string|nil
---@param latest_depots table<string, string>|nil
---@return table
function M.sync_frozen(appid, latest_buildid, latest_depots)
  local state = state_store.load()
  local entry = state.games[tostring(appid)]
  if type(entry) ~= "table" or not entry.frozen then
    return { synced = false, reason = "not_frozen" }
  end

  local manifest_path = M.find_manifest(appid)
  if not manifest_path then
    return { synced = false, reason = "not_installed" }
  end

  local is_ro = file_attrs.is_readonly(manifest_path)
  local reasons = {}
  if not is_ro then
    reasons[#reasons + 1] = "not_ro"
  end
  if type(latest_buildid) == "string" and latest_buildid ~= "" and latest_buildid ~= tostring(entry.spoofedBuildId or "") then
    reasons[#reasons + 1] = string.format("build_mismatch(%s->%s)", tostring(entry.spoofedBuildId or ""), latest_buildid)
  end
  if type(latest_depots) == "table" and type(entry.realDepots) == "table" then
    local cur_spoof = type(entry.spoofedDepots) == "table" and entry.spoofedDepots or {}
    for depot_id, _ in pairs(entry.realDepots) do
      local d = tostring(depot_id)
      local gid = latest_depots[d]
      if type(gid) == "string" and gid ~= "" and gid ~= cur_spoof[d] then
        reasons[#reasons + 1] = string.format("depot_mismatch(%s:%s->%s)", d, tostring(cur_spoof[d] or "nil"), gid)
        break
      end
    end
  end

  if #reasons == 0 then
    return { synced = false, reason = "up_to_date" }
  end

  logger:info(string.format("[timefreeze] auto-syncing appid=%d to latest_buildid=%s reasons=[%s]", appid, tostring(latest_buildid), table.concat(reasons, ",")))
  local res = M.freeze(appid, latest_buildid, latest_depots)
  if res.error then
    return { synced = false, error = res.error }
  end
  return { synced = true, status = res }
end

--- Immediate backend startup guard (runs in on_load before Steam's download manager finishes booting).
--- Purges any leftover download/temp caches and repairs dirty/writable frozen manifests.
---@return integer repaired_count
function M.enforce_frozen_on_startup()
  local state = state_store.load()
  local repaired = 0
  local frozen_ids = {}
  for _, entry in pairs(state.games) do
    if type(entry) == "table" and entry.frozen == true and tonumber(entry.appid) then
      frozen_ids[#frozen_ids + 1] = tostring(entry.appid)
    end
  end
  table.sort(frozen_ids)
  logger:info(string.format("[timefreeze] startup-guard: %d frozen game(s) [%s], %d library root(s)",
    #frozen_ids, table.concat(frozen_ids, ","), #M.library_roots()))
  for _, entry in pairs(state.games) do
    if type(entry) == "table" and entry.frozen == true and tonumber(entry.appid) then
      local appid = tonumber(entry.appid)
      local manifest_path, lib_root = M.find_manifest(appid)
      if manifest_path then
        local purged = M.purge_download_cache(appid, lib_root)
        local raw = read_file(manifest_path)
        local manifest = raw and vdf.parse_manifest(raw) or nil
        local is_ro = file_attrs.is_readonly(manifest_path) == true

        if manifest then
          local dirty = {}
          if not is_ro then dirty[#dirty + 1] = "not_ro" end
          if manifest.stateFlags ~= 4 then dirty[#dirty + 1] = "StateFlags=" .. tostring(manifest.stateFlags) end
          if manifest.targetBuildId ~= "0" and manifest.targetBuildId ~= "" then dirty[#dirty + 1] = "TargetBuildID=" .. tostring(manifest.targetBuildId) end
          if manifest.bytesToDownload > 0 then dirty[#dirty + 1] = "BytesToDownload=" .. tostring(manifest.bytesToDownload) end
          if manifest.hasStagedDepots then dirty[#dirty + 1] = "StagedDepots" end
          if type(entry.spoofedBuildId) == "string" and entry.spoofedBuildId ~= "" and manifest.buildid ~= entry.spoofedBuildId then
            dirty[#dirty + 1] = string.format("buildid=%s!=%s", tostring(manifest.buildid), tostring(entry.spoofedBuildId))
          end

          if #dirty > 0 then
            local spoof_depots = type(entry.spoofedDepots) == "table" and entry.spoofedDepots or {}
            local res = M.freeze(appid, entry.spoofedBuildId, spoof_depots)
            repaired = repaired + 1
            logger:info(string.format("[timefreeze] startup-guard repaired appid=%d reasons=[%s] purged=%d err=%s", appid, table.concat(dirty, ","), purged, tostring(res.error or "none")))
          else
            logger:info(string.format("[timefreeze] startup-guard ok appid=%d buildid=%s ro=%s purged=%d", appid, tostring(manifest.buildid), tostring(is_ro), purged))
          end
          -- Steam's content_log still holds the last session: why it wanted to update this game.
          local ok_diag, err_diag = pcall(M.diagnose, appid, { reason = "startup", latestDepots = entry.spoofedDepots })
          if not ok_diag then logger:warn("[timefreeze] startup diagnose failed: " .. tostring(err_diag)) end
        else
          logger:warn(string.format("[timefreeze] startup-guard appid=%d manifest unparsable", appid))
        end
      else
        logger:warn(string.format("[timefreeze] startup-guard manifest missing for frozen appid=%d", appid))
      end
    end
  end
  return repaired
end

M.CONTENT_LOG_TAIL_BYTES = 768 * 1024
M.CONTENT_LOG_MAX_LINES = 14

--- Steam's own record of why it wants to update an app: `<Steam>/logs/content_log.txt` lines
--- `AppID <id> state changed : Update Required,...`, `config changed : updated depots a,b`,
--- `update started/canceled`, and `Downloading N chunks for depot <d>`. Same file on every OS.
---@param appid number
---@param depot_ids table<string, boolean>|nil
---@return table { found, lines, updatedDepots }
function M.read_content_log(appid, depot_ids)
  local out = { found = false, lines = {}, updatedDepots = {} }
  local path = platform.join(get_steam_path(), "logs", "content_log.txt")
  local f = io.open(path, "rb")
  if not f then return out end
  out.found = true
  local size = f:seek("end") or 0
  local start = math.max(0, size - M.CONTENT_LOG_TAIL_BYTES)
  f:seek("set", start)
  local text = f:read("*a") or ""
  f:close()

  local needle = "AppID " .. tostring(appid) .. " "
  local matched = {}
  for line in text:gmatch("[^\r\n]+") do
    local hit = line:find(needle, 1, true) ~= nil
    if not hit and depot_ids then
      local d = line:match("chunks for depot (%d+)")
      hit = d ~= nil and depot_ids[d] == true
    end
    if hit then
      matched[#matched + 1] = line
      local list = line:match(needle .. "config changed : updated depots ([%d,]+)")
      if list then
        out.updatedDepots = {}
        for d in list:gmatch("%d+") do out.updatedDepots[#out.updatedDepots + 1] = d end
      end
    end
  end
  local first = math.max(1, #matched - M.CONTENT_LOG_MAX_LINES + 1)
  for i = first, #matched do out.lines[#out.lines + 1] = matched[i] end
  return out
end

local function cache_presence(appid, lib_root)
  local present = {}
  for _, sa in ipairs(steamapps_variants(lib_root)) do
    if path_exists(platform.join(sa, "downloading", tostring(appid))) then present[#present + 1] = "downloading" end
    if path_exists(platform.join(sa, "temp", tostring(appid))) then present[#present + 1] = "temp" end
  end
  return present
end

--- Log everything needed to tell why Steam shows Update for a game: the manifest's update fields,
--- every installed depot (file / spoofed / real / latest manifest), leftover caches, and Steam's own
--- content_log lines for the app. Lines carry ids, flags and counts; no paths, names or keys.
---@param appid number
---@param opts table|nil { reason, displayStatus, latestBuildId, latestDepots }
---@return table
function M.diagnose(appid, opts)
  opts = type(opts) == "table" and opts or {}
  local reason = tostring(opts.reason or "manual")
  local tag = string.format("[diag] appid=%d", appid)
  local manifest_path, lib_root = M.find_manifest(appid)
  if not manifest_path then
    logger:warn(string.format("%s reason=%s manifest not found in %d library root(s)", tag, reason, #M.library_roots()))
    return { found = false }
  end
  local raw = read_file(manifest_path)
  local manifest = raw and vdf.parse_manifest(raw) or nil
  if not manifest then
    logger:warn(string.format("%s reason=%s manifest unreadable or unparsable", tag, reason))
    return { found = true, error = "unparsable" }
  end

  local state = state_store.load()
  local entry = state.games[tostring(appid)]
  local frozen = type(entry) == "table" and entry.frozen == true
  local is_ro = file_attrs.is_readonly(manifest_path)
  local spoof = (frozen and type(entry.spoofedDepots) == "table") and entry.spoofedDepots or {}
  local real = frozen and depots_to_manifest_map(entry.realDepots) or {}
  local latest = type(opts.latestDepots) == "table" and opts.latestDepots or {}
  local latest_known = next(latest) ~= nil

  logger:info(string.format(
    "%s reason=%s frozen=%s ro=%s display=%s StateFlags=%d buildid=%s spoof=%s real=%s latest=%s TargetBuildID=%s BytesToDownload=%d BytesToStage=%d UpdateResult=%s AutoUpdate=%d staged=%s lang=%s beta=%s depots=%d shared=%d caches=[%s]",
    tag, reason, tostring(frozen), tostring(is_ro), tostring(opts.displayStatus or "?"),
    manifest.stateFlags, manifest.buildid,
    frozen and tostring(entry.spoofedBuildId or "") or "-",
    frozen and tostring(entry.realBuildId or "") or "-",
    tostring(opts.latestBuildId or "?"),
    manifest.targetBuildId, manifest.bytesToDownload, manifest.bytesToStage, manifest.updateResult,
    manifest.autoUpdateBehavior, tostring(manifest.hasStagedDepots), manifest.language, manifest.betakey,
    (function() local n = 0 for _ in pairs(manifest.installedDepots) do n = n + 1 end return n end)(),
    manifest.sharedDepotCount, table.concat(cache_presence(appid, lib_root), ",")))

  local depot_ids = {}
  local stale = {}
  local ids = {}
  for d in pairs(manifest.installedDepots) do ids[#ids + 1] = d end
  table.sort(ids)
  for _, d in ipairs(ids) do
    local info = manifest.installedDepots[d]
    depot_ids[d] = true
    local want = latest[d]
    local verdict
    if not latest_known then
      verdict = "latest-unknown"
    elseif type(want) ~= "string" or want == "" then
      verdict = info.dlcappid and "UNRESOLVED(dlc app info needed)" or "UNRESOLVED"
    elseif want == info.manifest then
      verdict = "ok"
    else
      verdict = "STALE"
    end
    if verdict ~= "ok" and verdict ~= "latest-unknown" then stale[#stale + 1] = d end
    logger:info(string.format("%s depot=%s dlc=%s file=%s spoof=%s real=%s latest=%s -> %s",
      tag, d, tostring(info.dlcappid or "-"), info.manifest, tostring(spoof[d] or "-"), tostring(real[d] or "-"),
      tostring(want or "?"), verdict))
  end

  local cl = M.read_content_log(appid, depot_ids)
  if not cl.found then
    logger:info(string.format("%s content_log.txt not found under <Steam>/logs", tag))
  else
    for _, line in ipairs(cl.lines) do
      logger:info(tag .. " steam: " .. line)
    end
    if #cl.updatedDepots > 0 then
      local uncovered = {}
      for _, d in ipairs(cl.updatedDepots) do
        if not manifest.installedDepots[d] then uncovered[#uncovered + 1] = d end
      end
      logger:info(string.format("%s steam last asked to update depots=[%s] not-in-manifest=[%s]",
        tag, table.concat(cl.updatedDepots, ","), table.concat(uncovered, ",")))
    elseif #cl.lines == 0 then
      logger:info(tag .. " no content_log lines for this app in the recent tail")
    end
  end

  return {
    found = true,
    frozen = frozen,
    readonly = is_ro == true,
    stateFlags = manifest.stateFlags,
    staleDepots = stale,
    steamUpdatedDepots = cl.updatedDepots,
  }
end

--- Save a custom SteamDB depot+manifest entry so it appears in the version dropdown.
---@param appid number
---@param depot_id string
---@param manifest_id string
---@return table
function M.add_custom_version(appid, depot_id, manifest_id)
  if type(depot_id) ~= "string" or not depot_id:match("^%d+$") then
    return { error = "Depot ID must be numeric." }
  end
  if type(manifest_id) ~= "string" or not manifest_id:match("^%d+$") then
    return { error = "Manifest ID must be numeric." }
  end

  local state = state_store.load()
  local key = tostring(appid)
  local entry = state.games[key]
  if type(entry) ~= "table" then
    entry = { appid = appid, name = "", frozen = false, history = {}, customVersions = {} }
    state.games[key] = entry
  end
  if type(entry.customVersions) ~= "table" then
    entry.customVersions = {}
  end

  local found_existing = false
  for _, item in ipairs(entry.customVersions) do
    if type(item) == "table" and tostring(item.depotId) == depot_id and tostring(item.manifestId) == manifest_id then
      item.addedAt = now_sec()
      found_existing = true
      break
    end
  end
  if not found_existing then
    entry.customVersions[#entry.customVersions + 1] = {
      depotId = depot_id,
      manifestId = manifest_id,
      addedAt = now_sec(),
    }
  end

  state_store.save(state)
  logger:info("[timefreeze] added custom version appid=" .. tostring(appid) .. " depot=" .. depot_id)
  return M.get_status(appid)
end

--- List all currently frozen appids (for startup auto-sync).
---@return table
function M.list_frozen()
  local state = state_store.load()
  local appids = {}
  for _, entry in pairs(state.games) do
    if type(entry) == "table" and entry.frozen == true and tonumber(entry.appid) then
      appids[#appids + 1] = tonumber(entry.appid)
    end
  end
  table.sort(appids)
  return { appids = appids }
end

--- Direct trigger to purge downloading caches and re-assert clean manifest state.
---@param appid number
---@return table
function M.purge_cache(appid)
  local manifest_path, lib_root = M.find_manifest(appid)
  if not manifest_path then
    return { error = "Game is not installed." }
  end
  local purged = M.purge_download_cache(appid, lib_root)
  logger:info(string.format("[timefreeze] manual purge for appid=%d: removed %d item(s)", appid, purged))
  return M.get_status(appid)
end

return M
