--- Core Timefreeze backend operations: manifest discovery, status, freeze, unfreeze, startup sync.

local logger = require("logger")
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
  f:close()
  return true, nil
end

--- Return all Steam library root paths (main Steam root + libraryfolders.vdf entries).
---@return string[]
function M.library_roots()
  local root = platform.join(get_steam_path())
  local roots = { root }
  local seen = { [root:lower()] = true }

  local lf_path = platform.join(root, "steamapps", "libraryfolders.vdf")
  local raw = read_file(lf_path)
  if raw then
    for _, lib in ipairs(vdf.library_paths(raw)) do
      local key = lib:lower()
      if not seen[key] then
        seen[key] = true
        roots[#roots + 1] = lib
      end
    end
  end
  return roots
end

--- Locate appmanifest_<appid>.acf across all Steam libraries.
---@param appid number
---@return string|nil, string|nil
function M.find_manifest(appid)
  local fname = "appmanifest_" .. tostring(appid) .. ".acf"
  for _, lib in ipairs(M.library_roots()) do
    local candidate = platform.join(lib, "steamapps", fname)
    local f = io.open(candidate, "rb")
    if f then
      f:close()
      return candidate, lib
    end
  end
  return nil, nil
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
---@param appid number
---@return table
function M.get_status(appid)
  local manifest_path = M.find_manifest(appid)
  if not manifest_path then
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
    return { error = "Could not parse appmanifest" }
  end

  local is_ro = file_attrs.is_readonly(manifest_path)
  local state = state_store.load()
  local key = tostring(appid)
  local entry = state.games[key]

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
--- sets StateFlags = "4", clears pending update fields, and sets file Read-Only.
---@param appid number
---@param latest_buildid string|nil
---@param latest_depots table<string, string>|nil
---@return table
function M.freeze(appid, latest_buildid, latest_depots)
  local manifest_path = M.find_manifest(appid)
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
  if type(latest_depots) == "table" then
    for depot_id, _ in pairs(real_depots) do
      local gid = latest_depots[tostring(depot_id)]
      if type(gid) == "string" and gid ~= "" then
        depot_updates[tostring(depot_id)] = gid
      end
    end
  end

  local top_updates = {
    StateFlags = "4",
    BytesToDownload = "0",
    BytesDownloaded = "0",
    BytesToStage = "0",
    BytesStaged = "0",
    TargetBuildID = "0",
    ScheduledAutoUpdate = "0",
    AutoUpdateBehavior = "1",
    buildid = spoof_build,
  }

  local patched = vdf.patch_manifest(raw, top_updates, depot_updates)

  -- Ensure writable before writing
  file_attrs.set_readonly(manifest_path, false)
  local wok, werr = write_file(manifest_path, patched)
  if not wok then
    logger:error("[timefreeze] write failed for appid=" .. tostring(appid) .. ": " .. tostring(werr))
    return { error = "Could not write appmanifest: " .. tostring(werr) }
  end

  local rook, roerr = file_attrs.set_readonly(manifest_path, true)
  if not rook then
    logger:error("[timefreeze] set_readonly failed for appid=" .. tostring(appid) .. ": " .. tostring(roerr))
    return { error = "Updated manifest, but could not set read-only: " .. tostring(roerr) }
  end

  entry.frozen = true
  entry.frozenAt = now_sec()
  entry.spoofedBuildId = spoof_build
  entry.spoofedDepots = depot_updates
  state.games[key] = entry
  state_store.save(state)

  logger:info("[timefreeze] frozen appid=" .. tostring(appid) .. " real=" .. tostring(entry.realBuildId) .. " spoof=" .. tostring(spoof_build))

  local updated_manifest = vdf.parse_manifest(patched) or manifest
  return build_status(appid, manifest_path, updated_manifest, entry, true)
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
    logger:error("[timefreeze] clear readonly failed for appid=" .. tostring(appid) .. ": " .. tostring(rerr))
    return { error = "Could not clear read-only attribute: " .. tostring(rerr) }
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
  local need_sync = (not is_ro)
  if type(latest_buildid) == "string" and latest_buildid ~= "" and latest_buildid ~= tostring(entry.spoofedBuildId or "") then
    need_sync = true
  end
  if not need_sync and type(latest_depots) == "table" and type(entry.realDepots) == "table" then
    local cur_spoof = type(entry.spoofedDepots) == "table" and entry.spoofedDepots or {}
    for depot_id, _ in pairs(entry.realDepots) do
      local d = tostring(depot_id)
      local gid = latest_depots[d]
      if type(gid) == "string" and gid ~= "" and gid ~= cur_spoof[d] then
        need_sync = true
        break
      end
    end
  end

  if not need_sync then
    return { synced = false, reason = "up_to_date" }
  end

  local res = M.freeze(appid, latest_buildid, latest_depots)
  if res.error then
    return { synced = false, error = res.error }
  end
  return { synced = true, status = res }
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

return M
