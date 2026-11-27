--- RPC wrappers exposed to the frontend via Millennium.callServerMethod.
--- Guardrails: normalise appid unsigned, never return bare nil, log errors.

local json = require("json")
local logger = require("log").logger
local timefreeze = require("timefreeze")

local M = {}

local function normalize_appid(raw)
  local n = tonumber(raw)
  if not n then return nil end
  if n < 0 then
    n = n + 4294967296
  end
  return math.floor(n)
end

local function wrap(name, fn)
  return function(payload)
    local ok_dec, data = pcall(json.decode, payload or "{}")
    if not ok_dec or type(data) ~= "table" then data = {} end

    local ok_run, res = pcall(fn, data)
    if not ok_run then
      logger:error("[rpc] " .. name .. " threw: " .. tostring(res))
      return json.encode({ error = tostring(res) })
    end
    if res == nil then
      return "null"
    end
    if type(res) == "table" and res.error then
      logger:error("[rpc] " .. name .. " error: " .. tostring(res.error))
    end
    return json.encode(res)
  end
end

M.TimefreezeGetStatus = wrap("TimefreezeGetStatus", function(data)
  local appid = normalize_appid(data.appid)
  if not appid or appid <= 0 then return { error = "invalid appid" } end
  return timefreeze.get_status(appid)
end)

M.TimefreezeFreeze = wrap("TimefreezeFreeze", function(data)
  local appid = normalize_appid(data.appid)
  if not appid or appid <= 0 then return { error = "invalid appid" } end
  local latest_buildid = type(data.latestBuildId) == "string" and data.latestBuildId or nil
  local latest_depots = type(data.latestDepots) == "table" and data.latestDepots or nil
  return timefreeze.freeze(appid, latest_buildid, latest_depots)
end)

M.TimefreezeUnfreeze = wrap("TimefreezeUnfreeze", function(data)
  local appid = normalize_appid(data.appid)
  if not appid or appid <= 0 then return { error = "invalid appid" } end
  return timefreeze.unfreeze(appid)
end)

M.TimefreezeSyncFrozen = wrap("TimefreezeSyncFrozen", function(data)
  local appid = normalize_appid(data.appid)
  if not appid or appid <= 0 then return { error = "invalid appid" } end
  local latest_buildid = type(data.latestBuildId) == "string" and data.latestBuildId or nil
  local latest_depots = type(data.latestDepots) == "table" and data.latestDepots or nil
  return timefreeze.sync_frozen(appid, latest_buildid, latest_depots)
end)

M.TimefreezeListFrozen = wrap("TimefreezeListFrozen", function()
  return timefreeze.list_frozen()
end)

M.TimefreezeAddCustomVersion = wrap("TimefreezeAddCustomVersion", function(data)
  local appid = normalize_appid(data.appid)
  if not appid or appid <= 0 then return { error = "invalid appid" } end
  local depot_id = type(data.depotId) == "string" and data.depotId or ""
  local manifest_id = type(data.manifestId) == "string" and data.manifestId or ""
  return timefreeze.add_custom_version(appid, depot_id, manifest_id)
end)

M.TimefreezePurgeCache = wrap("TimefreezePurgeCache", function(data)
  local appid = normalize_appid(data.appid)
  if not appid or appid <= 0 then return { error = "invalid appid" } end
  return timefreeze.purge_cache(appid)
end)

M.TimefreezeDiagnose = wrap("TimefreezeDiagnose", function(data)
  local appid = normalize_appid(data.appid)
  if not appid or appid <= 0 then return { error = "invalid appid" } end
  return timefreeze.diagnose(appid, {
    reason = type(data.reason) == "string" and data.reason:sub(1, 48) or "frontend",
    displayStatus = tonumber(data.displayStatus),
    latestBuildId = type(data.latestBuildId) == "string" and data.latestBuildId or nil,
    latestDepots = type(data.latestDepots) == "table" and data.latestDepots or nil,
  })
end)

M.TimefreezeLog = wrap("TimefreezeLog", function(data)
  local level = tostring(data.level or "info"):lower()
  local msg = tostring(data.message or "")
  if level == "error" then
    logger:error("[frontend] " .. msg)
  elseif level == "warn" then
    logger:warn("[frontend] " .. msg)
  else
    logger:info("[frontend] " .. msg)
  end
  return { ok = true }
end)

return M
