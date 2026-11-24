--- Persistent state and manifest backup store at:
--- <Steam folder>/millennium/config/steam-timefreeze/
--- with fallback to <plugin_root>/data/ if config is unwritable.

local json = require("json")
local platform = require("platform")

local M = {}

M.deps = {
  steam_path = nil,
  plugin_root = nil,
}

local function get_steam_path()
  if M.deps.steam_path then return M.deps.steam_path() end
  local ok, millennium = pcall(require, "millennium")
  if ok and millennium and millennium.steam_path then
    return millennium.steam_path()
  end
  return "."
end

local function get_plugin_root()
  if M.deps.plugin_root then return M.deps.plugin_root end
  local ok, log_mod = pcall(require, "log")
  if ok and log_mod and log_mod.resolve_plugin_root then
    return log_mod.resolve_plugin_root()
  end
  local sp = get_steam_path()
  return platform.join(sp, "millennium", "plugins", "steam-timefreeze")
end

function M.data_dir()
  local root = get_steam_path()
  local dir = platform.join(root, "millennium", "config", "steam-timefreeze")
  platform.mkdir_p(dir)

  -- Test writability
  local test_p = platform.join(dir, ".write_test")
  local f = io.open(test_p, "wb")
  if f then
    f:close()
    os.remove(test_p)
    return dir
  end

  -- Fallback to plugin root / data
  local fallback = platform.join(get_plugin_root(), "data")
  platform.mkdir_p(fallback)
  return fallback
end

function M.state_path()
  return platform.join(M.data_dir(), "state.json")
end

function M.backup_path(appid)
  return platform.join(M.data_dir(), "backup_" .. tostring(appid) .. ".acf")
end

---@return table
function M.load()
  local p = M.state_path()
  local f = io.open(p, "rb")
  if not f then
    -- Try checking fallback path in case data_dir switched
    local alt = platform.join(get_plugin_root(), "data", "state.json")
    f = io.open(alt, "rb")
    if not f then
      return { version = 1, games = {} }
    end
  end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then
    return { version = 1, games = {} }
  end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return { version = 1, games = {} }
  end
  if type(decoded.games) ~= "table" then
    decoded.games = {}
  end
  return decoded
end

---@param state table
---@return boolean, string|nil
function M.save(state)
  local ok, encoded = pcall(json.encode, state)
  if not ok or type(encoded) ~= "string" then
    return false, "json encode failed"
  end

  local p = M.state_path()
  local f, err = io.open(p, "wb")
  if not f then
    -- Attempt fallback location
    local alt_dir = platform.join(get_plugin_root(), "data")
    platform.mkdir_p(alt_dir)
    local alt_p = platform.join(alt_dir, "state.json")
    local f_alt, err_alt = io.open(alt_p, "wb")
    if f_alt then
      f_alt:write(encoded)
      f_alt:flush()
      f_alt:close()
      return true, nil
    end
    return false, string.format("write failed at primary (%s) and fallback (%s)", tostring(err), tostring(err_alt))
  end
  f:write(encoded)
  f:flush()
  f:close()
  return true, nil
end

--- Save a raw backup of appmanifest_<appid>.acf if one does not exist yet (or when force=true).
---@param appid number
---@param raw_text string
---@param force boolean|nil
---@return boolean
function M.save_backup(appid, raw_text, force)
  local bp = M.backup_path(appid)
  if not force then
    local existing = io.open(bp, "rb")
    if existing then
      existing:close()
      return true
    end
  end
  local f = io.open(bp, "wb")
  if not f then return false end
  f:write(raw_text)
  f:flush()
  f:close()
  return true
end

return M
