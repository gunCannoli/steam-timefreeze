--- steam-timefreeze backend entry point.

local millennium = require("millennium")
local logger = require("logger")
local platform = require("platform")
local log = require("log")
local RPC = require("rpc")

TimefreezeGetStatus = RPC.TimefreezeGetStatus
TimefreezeFreeze = RPC.TimefreezeFreeze
TimefreezeUnfreeze = RPC.TimefreezeUnfreeze
TimefreezeSyncFrozen = RPC.TimefreezeSyncFrozen
TimefreezeListFrozen = RPC.TimefreezeListFrozen
TimefreezeAddCustomVersion = RPC.TimefreezeAddCustomVersion
TimefreezePurgeCache = RPC.TimefreezePurgeCache
TimefreezeLog = RPC.TimefreezeLog

local function on_load()
  log.install()
  logger:info(string.format("[startup] steam-timefreeze loaded (os=%s)", platform.os_name()))
  millennium.ready()
end

local function on_frontend_loaded()
  logger:info("[startup] steam-timefreeze frontend loaded")
end

local function on_unload()
  logger:info("[shutdown] steam-timefreeze unloaded")
end

return {
  on_load = on_load,
  on_frontend_loaded = on_frontend_loaded,
  on_unload = on_unload,
}
