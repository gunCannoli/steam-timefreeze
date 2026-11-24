--- OS-agnostic path and environment helpers (guardrail 23).
--- Paths are built with "/" only (Windows accepts it).
--- Handles Linux XDG folders, Steam Deck, Flatpak, and tilde expansion.

local M = {}

M.deps = {
  getenv = nil,
  is_windows = nil,
}

local function env(name)
  local v = (M.deps.getenv or os.getenv)(name)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function slashes(p)
  local s = tostring(p or ""):gsub("\\", "/"):gsub("/+$", "")
  -- Expand leading ~ on Linux
  if not M.is_windows() then
    if s == "~" then
      local h = M.home()
      if h ~= "" then return h end
    elseif s:match("^~[/\\]") then
      local h = M.home()
      if h ~= "" then
        s = h .. s:sub(2)
      end
    end
  end
  return s
end

---@return boolean
function M.is_windows()
  if M.deps.is_windows ~= nil then return M.deps.is_windows end
  return package.config:sub(1, 1) == "\\"
end

---@return string
function M.os_name()
  return M.is_windows() and "windows" or "linux"
end

---@return string
function M.home()
  return slashes(M.is_windows() and (env("USERPROFILE") or "") or (env("HOME") or ""))
end

local ROOTS = {
  APPDATA = function()
    local x = env("XDG_CONFIG_HOME")
    if x then return slashes(x) end
    local h = M.home()
    return h ~= "" and (h .. "/.config") or nil
  end,
  LOCALAPPDATA = function()
    local x = env("XDG_DATA_HOME")
    if x then return slashes(x) end
    local h = M.home()
    return h ~= "" and (h .. "/.local/share") or nil
  end,
  USERPROFILE = function()
    local h = M.home()
    return h ~= "" and h or nil
  end,
}

--- Read environment variable; on Linux APPDATA/LOCALAPPDATA map to XDG counterparts.
---@param name string
---@return string|nil
function M.getenv(name)
  local map = ROOTS[name]
  if map and not M.is_windows() then return map() end
  return env(name)
end

---@param ... string
---@return string
function M.join(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    local s = slashes(part)
    if s ~= "" then
      out[#out + 1] = (#out > 0) and s:gsub("^/+", "") or s
    end
  end
  return table.concat(out, "/")
end

--- Recursively create directories (OS-agnostic).
---@param dir string
---@return boolean, string|nil
function M.mkdir_p(dir)
  if type(dir) ~= "string" or dir == "" then return false, "empty path" end
  local ok_fs, fs = pcall(require, "fs")
  if ok_fs and fs then
    if fs.is_directory and fs.is_directory(dir) then return true end
    if fs.create_directories then
      local ok, err = pcall(fs.create_directories, dir)
      if ok then return true end
    end
    if fs.create_directory then
      local ok, err = pcall(fs.create_directory, dir)
      if ok then return true end
    end
  end

  -- Fallback: step through path segments
  local norm = slashes(dir)
  local prefix = ""
  if norm:match("^%a:") then
    prefix = norm:sub(1, 2)
    norm = norm:sub(3)
  elseif norm:match("^/") then
    prefix = "/"
    norm = norm:sub(2)
  end

  local cur = prefix
  for seg in norm:gmatch("[^/]+") do
    cur = (cur == "" or cur == "/") and (cur .. seg) or (cur .. "/" .. seg)
    if ok_fs and fs and fs.create_directory then
      pcall(fs.create_directory, cur)
    end
  end
  return true
end

--- Inspect Linux / Steam Deck host characteristics for diagnostic logs.
---@return table
function M.host_info()
  local info = {
    os = M.os_name(),
    flatpak = false,
    deck = false,
    distro = "windows",
  }
  if M.is_windows() then
    return info
  end

  -- Flatpak check
  local f_fp = io.open("/.flatpak-info", "rb")
  if f_fp then
    f_fp:close()
    info.flatpak = true
  end

  -- Distro / Steam Deck check from /etc/os-release
  local f_os = io.open("/etc/os-release", "rb")
  if f_os then
    local content = f_os:read("*a") or ""
    f_os:close()
    local pretty = content:match('PRETTY_NAME="([^"]+)"') or content:match("PRETTY_NAME=([^\r\n]+)")
    local id = content:match('ID="?([^"%s\r\n]+)"?')
    info.distro = pretty or id or "linux"
    if content:find("steamos", 1, true) or content:find("SteamOS", 1, true) or env("STEAM_DECK") == "1" then
      info.deck = true
    end
  else
    info.distro = "generic-linux"
  end

  return info
end

return M
