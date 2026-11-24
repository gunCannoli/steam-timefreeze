--- Comprehensive logger for steam-timefreeze.
--- Writes to <plugin_root>/timefreeze.log (dropped at the plugin root as requested)
--- AND mirrors to <Steam>/millennium/config/steam-timefreeze/timefreeze.log.
---
--- Installs a tee over Millennium's built-in `logger` so all existing backend
--- calls write to disk with ISO timestamps, OS context, and immediate flush.
--- Also receives frontend logs via the TimefreezeLog RPC.

local platform = require("platform")

local M = {}

M.MAX_BYTES = 1024 * 1024 -- 1 MiB cap per log file, rotates to .1
M.deps = {
  steam_path = nil,
  plugin_root = nil,
  now = nil,
}

local installed = false
local file_paths = nil

local function now_iso()
  local t = (M.deps.now or os.time)()
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

local function get_steam_path()
  if M.deps.steam_path then return M.deps.steam_path() end
  local ok, millennium = pcall(require, "millennium")
  if ok and millennium and millennium.steam_path then
    return millennium.steam_path()
  end
  return "."
end

--- Locate the plugin root directory.
--- 1. From debug info of this file (e.g. @.../steam-timefreeze/backend/log.lua)
--- 2. Or <Steam>/millennium/plugins/steam-timefreeze
function M.resolve_plugin_root()
  if M.deps.plugin_root then return M.deps.plugin_root end
  local info = debug.getinfo(1, "S")
  if info and type(info.source) == "string" then
    local root = info.source:match("^@?(.*)[/\\]backend[/\\]")
    if root and #root > 0 then
      return (root:gsub("\\", "/"):gsub("/+$", ""))
    end
  end
  local sp = get_steam_path()
  return platform.join(sp, "millennium", "plugins", "steam-timefreeze")
end

--- Return all target log file paths (plugin root + config dir).
function M.target_paths()
  if file_paths then return file_paths end
  local paths = {}
  local seen = {}

  local function add(p)
    if type(p) == "string" and p ~= "" then
      local norm = (p:gsub("\\", "/"):gsub("/+$", ""))
      local key = norm:lower()
      if not seen[key] then
        seen[key] = true
        paths[#paths + 1] = norm
      end
    end
  end

  local p_root = M.resolve_plugin_root()
  if p_root then
    add(platform.join(p_root, "timefreeze.log"))
  end

  local sp = get_steam_path()
  if sp then
    add(platform.join(sp, "millennium", "config", "steam-timefreeze", "timefreeze.log"))
  end

  file_paths = paths
  return file_paths
end

local function rotate_if_needed(path)
  local f = io.open(path, "rb")
  if not f then return end
  local size = f:seek("end") or 0
  f:close()
  if size >= M.MAX_BYTES then
    local rot = path .. ".1"
    os.remove(rot)
    os.rename(path, rot)
  end
end

local function write_raw(line)
  local targets = M.target_paths()
  for _, path in ipairs(targets) do
    pcall(function()
      rotate_if_needed(path)
      local f = io.open(path, "a+b")
      if f then
        f:write(line .. "\n")
        f:flush()
        f:close()
      end
    end)
  end
end

--- Redact passwords, tokens, userids (guardrail 7).
function M.redact(str)
  local s = tostring(str or "")
  s = s:gsub("[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+", "<email>")
  s = s:gsub("([Uu][Ss][Ee][Rr][Dd][Aa][Tt][Aa][\\/])%d+", "%1<id>")
  s = s:gsub("([Uu][Ss][Ee][Rr][%s_]*[Ii]?[Dd]?[%s:=]*)(%d%d%d%d%d+)", "%1<id>")
  s = s:gsub("([Bb]earer%s+)[%w%-%._~%+/=]+", "%1<hidden>")
  s = s:gsub("([Aa]uthorization%s*[:=]%s*)[^\r\n]+", "%1<hidden>")
  return s
end

function M.write(level, msg, extra)
  local ts = now_iso()
  local clean = M.redact(msg)
  local line = string.format("[%s] [%s] %s", ts, level:upper(), clean)
  if extra ~= nil then
    local clean_ex = M.redact(type(extra) == "table" and (pcall(require, "json") and require("json").encode(extra) or tostring(extra)) or tostring(extra))
    line = line .. " | " .. clean_ex
  end
  write_raw(line)
end

function M.info(msg, extra)
  M.write("INFO", msg, extra)
end

function M.warn(msg, extra)
  M.write("WARN", msg, extra)
end

function M.error(msg, extra)
  M.write("ERROR", msg, extra)
end

function M.debug(msg, extra)
  M.write("DEBUG", msg, extra)
end

--- Install the tee over package.loaded["logger"].
function M.install()
  if installed then return end
  installed = true

  local ok, orig = pcall(require, "logger")
  local original = ok and orig or nil

  local tee = {
    info = function(self, msg)
      if original and original.info then pcall(original.info, original, msg) end
      M.info(msg)
    end,
    warn = function(self, msg)
      if original and original.warn then pcall(original.warn, original, msg) end
      M.warn(msg)
    end,
    error = function(self, msg)
      if original and original.error then pcall(original.error, original, msg) end
      M.error(msg)
    end,
    debug = function(self, msg)
      if original and original.debug then pcall(original.debug, original, msg) end
      M.debug(msg)
    end,
  }

  package.loaded["logger"] = tee

  M.info("=== steam-timefreeze logger initialized ===")
  local host = platform.host_info()
  M.info(string.format("[host] os=%s distro=%s deck=%s flatpak=%s", tostring(host.os), tostring(host.distro), tostring(host.deck), tostring(host.flatpak)))
  M.info(string.format("OS=%s, SteamPath=%s, PluginRoot=%s", platform.os_name(), get_steam_path(), tostring(M.resolve_plugin_root())))
  for idx, p in ipairs(M.target_paths()) do
    M.info(string.format("Log target #%d: %s", idx, p))
  end
end

--- Reset state for tests.
function M._reset()
  installed = false
  file_paths = nil
end

return M
