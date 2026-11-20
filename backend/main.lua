--- steam-timefreeze backend entry point.

local millennium = require("millennium")
local logger = require("logger")
local platform = require("platform")
local RPC = require("rpc")

TimefreezeGetStatus = RPC.TimefreezeGetStatus
TimefreezeFreeze = RPC.TimefreezeFreeze
TimefreezeUnfreeze = RPC.TimefreezeUnfreeze
TimefreezeSyncFrozen = RPC.TimefreezeSyncFrozen
TimefreezeListFrozen = RPC.TimefreezeListFrozen
TimefreezeAddCustomVersion = RPC.TimefreezeAddCustomVersion

local function on_load()
  logger:info("[startup] steam-timefreeze loaded (os=" .. platform.os_name() .. ")")
  millennium.ready()
end

local function on_frontend_loaded()
end

local function on_unload()
  logger:info("[shutdown] steam-timefreeze unloaded")
end

return {
  on_load = on_load,
  on_frontend_loaded = on_frontend_loaded,
  on_unload = on_unload,
}
