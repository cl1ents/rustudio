-- Engine API domain "services": the CoreScript-only services written in Luau
-- (services_core.rs routes their calls here). Roblox's apps run these in the
-- engine; rustudio keeps them inside the one DataModel:
-- - MessageBusService: the app's publish / subscribe bus. Message ids read
--   "<domain>.<name>", protocol ones "<protocol>.<method>.Request" /
--   ".Response" (the form Roblox's own MessageBus errors print:
--   "unsubscribing from a message id not subscribed to:
--   PermissionsProtocol.HasPermissions.Response", devforum.roblox.com/t/2659679).
--   Nothing outside the DataModel answers: `Call` returns nil and requests
--   without a handler get no response.
-- - LocalStorageService / AppStorageService: string items, kept for the Play
--   session (Roblox keeps them on disk); loaded from the start.
local rs = ...
local M = {}

local function fail(msg) error(msg, 0) end
local function str_arg(v, i)
	if type(v) ~= "string" then fail(string.format("Argument %d missing or nil", i)) end
	return v
end

------------------------------------------------------------ MessageBusService
local subscribers = {} -- mid -> { [connection] = { fn = callback, once = bool } }
local last = {} -- mid -> last published params
local owner = {} -- connection -> mid
local handlers = {} -- "<protocol>.<method>" -> request handler

local function deliver(mid, params)
	local list = subscribers[mid]
	if not list then return end
	for conn, sub in pairs(list) do
		if sub.once then
			list[conn] = nil
			owner[conn] = nil
		end
		task.spawn(sub.fn, params)
	end
end

local function subscribe(mid, fn, once, sticky)
	if type(fn) ~= "function" then fail("Argument 2 missing or nil") end
	local conn = rs.new_object("MessageBusConnection")
	subscribers[mid] = subscribers[mid] or {}
	subscribers[mid][conn] = { fn = fn, once = once == true }
	owner[conn] = mid
	if sticky and last[mid] ~= nil then
		deliver(mid, last[mid])
	end
	return conn
end

local function request_id(protocol, method) return protocol .. "." .. method .. ".Request" end
local function response_id(protocol, method) return protocol .. "." .. method .. ".Response" end

M["MessageBusService.GetMessageId"] = function(self, domain, name)
	return str_arg(domain, 1) .. "." .. str_arg(name, 2)
end
M["MessageBusService.GetProtocolMethodRequestMessageId"] = function(self, protocol, method)
	return request_id(str_arg(protocol, 1), str_arg(method, 2))
end
M["MessageBusService.GetProtocolMethodResponseMessageId"] = function(self, protocol, method)
	return response_id(str_arg(protocol, 1), str_arg(method, 2))
end
M["MessageBusService.Subscribe"] = function(self, mid, fn, once, sticky)
	return subscribe(str_arg(mid, 1), fn, once, sticky)
end
M["MessageBusService.SubscribeToProtocolMethodRequest"] = function(self, protocol, method, fn, once, sticky)
	return subscribe(request_id(str_arg(protocol, 1), str_arg(method, 2)), fn, once, sticky)
end
M["MessageBusService.SubscribeToProtocolMethodResponse"] = function(self, protocol, method, fn, once, sticky)
	return subscribe(response_id(str_arg(protocol, 1), str_arg(method, 2)), fn, once, sticky)
end
M["MessageBusService.Publish"] = function(self, mid, params)
	str_arg(mid, 1)
	last[mid] = params
	deliver(mid, params)
end
M["MessageBusService.GetLast"] = function(self, mid)
	return last[str_arg(mid, 1)]
end
M["MessageBusService.Call"] = function(self, key)
	str_arg(key, 1)
	return nil
end
M["MessageBusService.PublishProtocolMethodRequest"] = function(self, protocol, method, message)
	str_arg(protocol, 1)
	str_arg(method, 2)
	local mid = request_id(protocol, method)
	last[mid] = message
	deliver(mid, message)
	local handler = handlers[protocol .. "." .. method]
	if handler then
		task.spawn(function()
			local response = handler(message)
			M["MessageBusService.PublishProtocolMethodResponse"](self, protocol, method, response, 0)
		end)
	end
end
M["MessageBusService.PublishProtocolMethodResponse"] = function(self, protocol, method, message, code)
	local mid = response_id(str_arg(protocol, 1), str_arg(method, 2))
	last[mid] = message
	deliver(mid, message)
end
M["MessageBusService.SetRequestHandler"] = function(self, protocol, method, fn)
	handlers[str_arg(protocol, 1) .. "." .. str_arg(method, 2)] = fn
end
M["MessageBusService.MakeRequest"] = function(self, protocol, method, message, callback)
	str_arg(protocol, 1)
	str_arg(method, 2)
	if type(callback) == "function" then
		subscribe(response_id(protocol, method), callback, true, false)
	end
	M["MessageBusService.PublishProtocolMethodRequest"](self, protocol, method, message)
end
M["MessageBusConnection.Disconnect"] = function(self)
	local mid = owner[self]
	if mid and subscribers[mid] then subscribers[mid][self] = nil end
	owner[self] = nil
end

------------------------------------------------------------ LocalStorageService
local stores = {} -- service -> { key -> value }

local function items(self)
	stores[self] = stores[self] or {}
	return stores[self]
end

M["LocalStorageService.GetItem"] = function(self, key)
	return items(self)[str_arg(key, 1)] or ""
end
M["LocalStorageService.SetItem"] = function(self, key, value)
	str_arg(key, 1)
	value = tostring(value)
	items(self)[key] = value
	rs.fire(self, "ItemWasSet", key, value)
end
M["LocalStorageService.Flush"] = function(self) end
M["LocalStorageService.WhenLoaded"] = function(self, fn)
	if type(fn) ~= "function" then fail("Argument 1 missing or nil") end
	task.spawn(fn)
end

------------------------------------------------------------ StarterGui
-- SetCore / GetCore run what the CoreScripts registered (RobloxScriptSecurity
-- RegisterSetCore / RegisterGetCore). Once any is registered, an unknown
-- name fails with Roblox's message ("SetCore: SendNotification has not been
-- registered by the CoreScripts"); with no CoreScripts running they keep
-- rustudio's old answers (nothing / nil).
local set_core, get_core = {}, {}
M["StarterGui.RegisterSetCore"] = function(self, name, fn)
	if type(fn) ~= "function" then fail("Argument 2 missing or nil") end
	set_core[str_arg(name, 1)] = fn
end
M["StarterGui.RegisterGetCore"] = function(self, name, fn)
	if type(fn) ~= "function" then fail("Argument 2 missing or nil") end
	get_core[str_arg(name, 1)] = fn
end
M["StarterGui.SetCore"] = function(self, name, ...)
	local f = set_core[str_arg(name, 1)]
	if f then
		f(...)
	elseif next(set_core) ~= nil then
		fail(string.format("SetCore: %s has not been registered by the CoreScripts", name))
	end
end
M["StarterGui.GetCore"] = function(self, name)
	local f = get_core[str_arg(name, 1)]
	if f then return f() end
	if next(get_core) ~= nil then
		fail(string.format("GetCore: %s has not been registered by the CoreScripts", name))
	end
	return nil
end

------------------------------------------------------------ RunService
-- The client build the CoreScripts report in telemetry and version checks.
-- rustudio is no Roblox build: empty strings (estimate), no Team Create
-- viewer or team test, and the Roblox GUI focus kept as set.
local gui_focused = false
M["RunService.GetRobloxVersion"] = function() return "" end
M["RunService.GetCoreScriptVersion"] = function() return "" end
M["RunService.GetRobloxClientChannel"] = function() return "" end
M["RunService.IsTeamCreateViewer"] = function() return false end
M["RunService.IsTeamTest"] = function() return false end
M["RunService.GetRobloxGuiFocused"] = function() return gui_focused end
M["RunService.SetRobloxGuiFocused"] = function(self, on)
	on = on == true
	if on ~= gui_focused then
		gui_focused = on
		rs.fire(self, "RobloxGuiFocusedChanged", on)
	end
end

------------------------------------------------------------ UserInputService
-- A desktop at the top device level (estimate: rustudio runs on desktops).
M["UserInputService.GetDeviceType"] = function() return Enum.DeviceType.Desktop end
M["UserInputService.GetDeviceLevel"] = function() return Enum.DeviceLevel.High end

------------------------------------------------------------ Player
-- The block list the CoreScripts keep on the local player (the web block
-- list isn't fetched: it starts empty, estimate), and friend status
-- (no friends web call here: NotFriend, estimate).
local blocked, block_ready = {}, false
M["Player.GetBlockListInitialized"] = function() return block_ready end
M["Player.SetBlockListInitialized"] = function(self)
	block_ready = true
	rs.fire(self, "BlockListChanged")
end
M["Player.AddToBlockList"] = function(self, ids)
	if type(ids) ~= "table" then fail("Argument 1 missing or nil") end
	for _, id in ids do blocked[tonumber(id)] = true end
	rs.fire(self, "BlockListChanged")
end
M["Player.UpdatePlayerBlocked"] = function(self, id, on)
	blocked[tonumber(id)] = if on then true else nil
	rs.fire(self, "BlockListChanged")
end
M["Player.HasBlockedPlayer"] = function(self, id) return blocked[tonumber(id)] == true end
M["Player.GetFriendStatus"] = function(self, other)
	if other == self then return Enum.FriendStatus.Unknown end
	return Enum.FriendStatus.NotFriend
end
M["Player.GetUnder13"] = function() return false end

------------------------------------------------------------ RbxAnalyticsService
-- Roblox's telemetry: a Play session has no analytics backend, so the
-- reports go nowhere and the ids are empty (stubs, as for AnalyticsService).
for _, n in { "AddGlobalPointsField", "AddGlobalPointsTag", "RemoveGlobalPointsField", "RemoveGlobalPointsTag",
	"ReleaseRBXEventStream", "ReportCounter", "ReportInfluxSeries", "ReportStats", "ReportToDiagByCountryCode",
	"SendEventDeferred", "SendEventImmediately", "SetRBXEvent", "SetRBXEventStream", "TrackEvent", "TrackEventWithArgs",
	"UpdateHeartbeatObject" } do
	M["RbxAnalyticsService." .. n] = function() end
end
for _, n in { "GetClientId", "GetSessionId", "GetPlaySessionId" } do
	M["RbxAnalyticsService." .. n] = function() return "" end
end

------------------------------------------------------------ IXPService
-- Roblox's experiment layers. No experiment backend in a Play session: every
-- layer reads as loaded with no variables, so callers take their defaults
-- (estimate; the real service fetches assignments for the user).
local ixp_layers = { User = {}, Creator = {}, BrowserTracker = {} }
for kind, layers in ixp_layers do
	M["IXPService.Get" .. kind .. "LayerLoadingStatus"] = function() return Enum.IXPLoadingStatus.Initialized end
	M["IXPService.Get" .. kind .. "LayerVariables"] = function(self, name) str_arg(name, 1) return {} end
	M["IXPService.Get" .. kind .. "StatusForLayer"] = function(self, name)
		str_arg(name, 1)
		return Enum.IXPLoadingStatus.Initialized
	end
	M["IXPService.Log" .. kind .. "LayerExposure"] = function(self, name) str_arg(name, 1) end
	if kind ~= "BrowserTracker" then
		M["IXPService.Register" .. kind .. "Layers"] = function(self, list)
			if type(list) == "table" then
				for _, name in list do layers[tostring(name)] = true end
			end
		end
		M["IXPService.GetRegistered" .. kind .. "LayersToStatus"] = function()
			local out = {}
			for name in layers do out[name] = Enum.IXPLoadingStatus.Initialized end
			return out
		end
		M["IXPService.Initialize" .. kind .. "Layers"] = function(self)
			rs.fire(self, "On" .. kind .. "LayerLoadingStatusChanged", Enum.IXPLoadingStatus.Initialized)
		end
		M["IXPService.Clear" .. kind .. "Layers"] = function() table.clear(layers) end
	end
end
M["IXPService.LogFlagLinkedUserLayerExposure"] = function(self, name) str_arg(name, 1) end

return M