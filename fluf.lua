--!strict
local sha1 = require(script.sha1)

-- Returns a BindableEvent that's shared across Luau VMs.
local function uniqueEvent(id)
	local existing: Instance? = script:FindFirstChild(id)
	if existing then
		assert(existing:IsA("BindableEvent"))
		return existing, false
	else
		local event = Instance.new("BindableEvent")
		event.Name = id
		event.Parent = script
		return event, true
	end
end

local function getCallingScriptName()
	local source = debug.info(3, "s")
	-- apparently debug.info can return nil if not in studio
	if source == nil then
		return "Unknown"
	end
	return string.match(source, "^.*%.(%w*)$") or source
end

-- Unique per VM
local hookWorkerQueue = {}
local hookWorker = Instance.new("BindableFunction")
local wasHookWorkerRegistered = false

local function enqueue(workerTask: (...any) -> ())
	if wasHookWorkerRegistered then
		hookWorker:Invoke(workerTask)
	else
		table.insert(hookWorkerQueue, workerTask)
	end
end

local fluf = {}
fluf.verbose = false

-- Prints the message if fluf is in verbose mode, including a unique id for the current thread.
local function flufVerboseLog(message, ...)
	if fluf.verbose then
		local threadId = sha1(tostring(coroutine.running)):sub(1, 8)
		print("[fluf " .. threadId .. "] " .. message, ...)
	end
end

-- Prints the message as a warning if fluf is in verbose mode, including a unique id for the current thread.
local function flufWarn(message)
	if fluf.verbose then
		local threadId = sha1(tostring(coroutine.running)):sub(1, 8)
		warn("[fluf " .. threadId .. "] " .. message)
	end
end

-- Throws an error with the message as body, including a unique id for the current thread.
local function flufError(message)
	local threadId = sha1(tostring(coroutine.running)):sub(1, 8)
	error("[fluf " .. threadId .. "] " .. message, 3)
end

flufVerboseLog("Fluf required from new VM")

type ServiceScript = Script | LocalScript

-- Define a callback that runs when a service is disabled.
function fluf.onDisabled(serviceScript: ServiceScript, f: () -> ())
	flufVerboseLog("Registering on disabled hook for service " .. serviceScript.Name)
	task.spawn(function()
		if not wasHookWorkerRegistered then
			flufWarn("Hook worker was not registered for this VM. Putting hook in queue.")
		end
		local hookWorkerTask = function()
			flufVerboseLog("Started listening for " .. serviceScript.Name .. " disabled")
			repeat
				serviceScript:GetPropertyChangedSignal("Enabled"):Wait()
			until serviceScript.Enabled == false
			f()
		end
		enqueue(hookWorkerTask)
	end)
end

local FlufService = {}
FlufService.__index = FlufService

function fluf.service(serviceScript: ServiceScript)
	return setmetatable({ serviceScript = serviceScript }, FlufService)
end

function FlufService:onDisabled(f)
	fluf.onDisabled(self.serviceScript, f)
end

-- Starts a worker that processes hooks. Hook workers are neccessary
-- because a script can't detect it's own Enabled property being changed.
function fluf.registerHookWorker()
	flufVerboseLog("Registered hook worker from " .. getCallingScriptName())
	wasHookWorkerRegistered = true
	hookWorker.OnInvoke = function(f)
		f()
	end
	for _, hookWorkerTask in hookWorkerQueue do
		hookWorkerTask()
	end
	table.clear(hookWorkerQueue)
end

export type Event<T...> = {
	fire: (T...) -> (),
	connect: (f: (T...) -> ()) -> RBXScriptConnection,
	connectParallel: (f: (T...) -> ()) -> RBXScriptConnection,
}

-- Creates a new event that can be called across VMs.
function fluf.event(): Event<...any>
	local id = sha1(debug.traceback())
	local logId = getCallingScriptName() .. "-" .. id:sub(1, 8)
	flufVerboseLog("Defined event " .. logId)
	local event = uniqueEvent(id)
	local function fire(...)
		flufVerboseLog("Triggering event " .. logId .. "with args", ...)
		event:Fire(...)
	end
	local function connect(f)
		return event.Event:Connect(f)
	end
	local function connectParallel(f)
		return event.Event:ConnectParallel(f)
	end
	return { fire = fire, connect = connect, connectParallel = connectParallel }
end

-- Checks if the current thread is desychronized.
local function isSychronized()
	return pcall(function()
		script.Name = script.Name
	end) == true
end

export type State<T> = {
	get: () -> (T?),
	changed: ((T) -> ()) -> RBXScriptConnection,
	set: (T) -> T,
}

-- Creates a new state object which synchronizes state across definitions.
function fluf.state(): State<any>
	local id = sha1(debug.traceback())
	local logId = getCallingScriptName() .. "-" .. id:sub(1, 8)
	flufVerboseLog("Defined state " .. logId)

	local current = nil
	local setStateLast = false

	-- These are used for syncing state when the same state is defined.
	-- This may be triggered by restarting a script or a seperate Luau VM.
	local newDefinitionId = sha1("NewDefinition" .. debug.traceback())
	local newDefinitionEvent, new = uniqueEvent(newDefinitionId)

	local changedEvent = uniqueEvent(id)
	changedEvent.Event:Connect(function(new)
		if current ~= new then
			flufVerboseLog("State " .. logId .. " received new value", new)
			current = new
		end
		enqueue(function()
			if setStateLast then
				setStateLast = false
				flufVerboseLog("Registering sync source")
				local conns = {}
				conns[1] = newDefinitionEvent.Event:Connect(function()
					flufVerboseLog("New definition detected, syncing state " .. logId)
					changedEvent:Fire(new)
				end)
				conns[2] = changedEvent.Event:Connect(function(new)
					flufVerboseLog("Unregistering sync source")
					for _, conn in conns do
						conn:Disconnect()
					end
				end)
			end
		end)
	end)

	if not new then
		-- Must be fired after changedEvent is connected to.
		flufVerboseLog("Firing new definition event")
		newDefinitionEvent:Fire()
	end

	local function get()
		flufVerboseLog("Getting state " .. logId .. " returned", current)
		return current
	end
	local function changed(f)
		return changedEvent.Event:Connect(f)
	end
	local function changedParallel(f)
		return changedEvent.Event:ConnectParallel(f)
	end
	local function set(new)
		if not isSychronized() then
			flufError("Cannot set state while desychronized")
		end
		flufVerboseLog("State " .. logId .. " set to " .. tostring(new))
		changedEvent:Fire(new)
		setStateLast = true
		return new
	end
	return { get = get, changed = changed, changedParallel = changedParallel, set = set }
end

function fluf.useConnect<T...>(hooks, event: Event<T...>, callback: (T...) -> ())
	hooks.useEffect(function()
		local conn = event.connect(callback)
		return function()
			conn:Disconnect()
		end
	end, { event, callback } :: { any })
end

function fluf.useState<T>(hooks, event: State<T>, callback: (T?) -> ())
	hooks.useEffect(function()
		task.spawn(callback, event.get())
		local conn = event.changed(callback)
		return function()
			conn:Disconnect()
		end
	end, { event, callback } :: { any })
end

function fluf.inlineState<T>(initial: T)
	local state = fluf.state() :: State<T>
	local value = state.get()
	if value == nil then
		return state.set(initial), state.set
	else
		return value, state.set
	end
end

return fluf
