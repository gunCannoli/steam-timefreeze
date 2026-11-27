--- Comprehensive logger for steam-timefreeze.
--- Writes to <plugin_root>/timefreeze.log (dropped at the plugin root as requested)
--- AND mirrors to <Steam>/millennium/config/steam-timefreeze/timefreeze.log.
---
--- Installs a tee over Millennium's built-in `logger` so all existing backend
--- calls write to disk with ISO timestamps, OS context, and immediate flush.
--- Also receives frontend logs via the TimefreezeLog RPC.

local platform = require("platform")

-- Millennium's own logger, captured when this module loads. Every backend module logs through
-- `M.logger` (below), never through a `require("logger")` of its own: a module that captured
-- `logger` at load time kept Millennium's original after `install()` swapped package.loaded,
-- so up to 0.1.6 nothing but the init lines ever reached timefreeze.log.
local ok_orig, original_logger = pcall(require, "logger")
if not ok_orig or type(original_logger) ~= "table" then original_logger = nil end

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

local function escape_pattern(p)
  return (p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local home_pattern = nil
local function home_prefix_pattern()
  if home_pattern ~= nil then return home_pattern end
  local ok, h = pcall(platform.home)
  if ok and type(h) == "string" and #h > 3 then
    home_pattern = escape_pattern(h)
  else
    home_pattern = false
  end
  return home_pattern
end

--- Redact passwords, tokens, userids and the home folder (guardrail 7: no user names in logs).
function M.redact(str)
  local s = tostring(str or "")
  local hp = home_prefix_pattern()
  if hp then s = s:gsub(hp, "~") end
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

local function tee_method(name, writer)
  return function(_, msg)
    if original_logger and original_logger[name] then pcall(original_logger[name], original_logger, msg) end
    -- File writes start at install() (on_load), so offline tests never drop a log in the source tree.
    if installed then writer(msg) end
  end
end

--- The logger every backend module uses: Millennium's console log plus timefreeze.log.
M.logger = {
  info = tee_method("info", function(m) M.info(m) end),
  warn = tee_method("warn", function(m) M.warn(m) end),
  error = tee_method("error", function(m) M.error(m) end),
  debug = tee_method("debug", function(m) M.debug(m) end),
}

--- Plugin version from plugin.json, so every report names the build it came from.
function M.plugin_version()
  local root = M.resolve_plugin_root()
  local f = root and io.open(platform.join(root, "plugin.json"), "rb")
  if not f then return "unknown" end
  local raw = f:read("*a") or ""
  f:close()
  return raw:match('"version"%s*:%s*"([^"]+)"') or "unknown"
end

--- Start writing to disk and route any later `require("logger")` through the tee.
function M.install()
  if installed then return end
  installed = true
  package.loaded["logger"] = M.logger

  M.info("=== steam-timefreeze " .. M.plugin_version() .. " logger initialized ===")
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
  home_pattern = nil
end

return M
