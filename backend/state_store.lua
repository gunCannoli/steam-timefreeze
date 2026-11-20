--- Persistent state and manifest backup store at:
--- <Steam folder>/millennium/config/steam-timefreeze/

local json = require("json")
local fs = require("fs")
local platform = require("platform")

local M = {}

M.deps = {
  steam_path = nil,
}

local function get_steam_path()
  if M.deps.steam_path then return M.deps.steam_path() end
  local millennium = require("millennium")
  return millennium.steam_path()
end

function M.data_dir()
  local root = get_steam_path()
  local dir = platform.join(root, "millennium", "config", "steam-timefreeze")
  pcall(fs.create_directory, dir)
  return dir
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
    return { version = 1, games = {} }
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
  local p = M.state_path()
  local ok, encoded = pcall(json.encode, state)
  if not ok or type(encoded) ~= "string" then
    return false, "json encode failed"
  end
  local f, err = io.open(p, "wb")
  if not f then
    return false, tostring(err or "open failed")
  end
  f:write(encoded)
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
  f:close()
  return true
end

return M
