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

return M
