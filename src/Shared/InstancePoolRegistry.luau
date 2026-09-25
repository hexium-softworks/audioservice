--!strict
--[=[
	Shared registry implementation used by server and client services.

	@class InstancePoolRegistry
]=]

local require = require(script.Parent.loader).load(script)

local Log = require("Log")
local Signal = require("Signal")

local InstancePool = require("InstancePool")
local InstancePoolTypes = require("InstancePoolTypes")

type InstancePoolConfig = InstancePoolTypes.InstancePoolConfig
type InstancePool = InstancePool.InstancePool

local InstancePoolRegistry = {}
InstancePoolRegistry.ClassName = "InstancePoolRegistry"
InstancePoolRegistry.__index = InstancePoolRegistry

local LOGGER = Log.new({
	name = "InstancePoolRegistry",
	defaultContext = {
		Package = "InstancePool",
	},
})

export type InstancePoolRegistry = typeof(setmetatable(
	{} :: {
		_name: string,
		_pools: { [string]: InstancePool },
		_signals: { [string]: Signal.Signal<InstancePool?> },
	},
	InstancePoolRegistry
))

function InstancePoolRegistry.new(name: string): InstancePoolRegistry
	return setmetatable({
		_name = name,
		_pools = {},
		_signals = {},
	}, InstancePoolRegistry) :: any
end

function InstancePoolRegistry.CreatePool(
	self: InstancePoolRegistry,
	name: string,
	config: InstancePoolConfig
): InstancePool
	assert(typeof(name) == "string" and #name > 0, "Pool name must be a non-empty string")
	assert(self._pools[name] == nil, string.format("Pool %q is already registered", name))

	local poolConfig = table.clone(config) :: any
	poolConfig.Name = poolConfig.Name or name

	local pool = InstancePool.new(poolConfig)
	self._pools[name] = pool
	self:_firePoolChanged(name, pool)

	LOGGER.Info("Registered instance pool", {
		Registry = self._name,
		Pool = name,
	})

	return pool
end

function InstancePoolRegistry.GetPool(self: InstancePoolRegistry, name: string): InstancePool
	local pool = self:FindPool(name)
	assert(pool ~= nil, string.format("Pool %q is not registered", name))
	return pool :: InstancePool
end

function InstancePoolRegistry.FindPool(self: InstancePoolRegistry, name: string): InstancePool?
	assert(typeof(name) == "string", "Pool name must be a string")
	return self._pools[name]
end

function InstancePoolRegistry.DestroyPool(self: InstancePoolRegistry, name: string): boolean
	assert(typeof(name) == "string", "Pool name must be a string")

	local pool = self._pools[name]
	if not pool then
		return false
	end

	self._pools[name] = nil
	pool:Destroy()
	self:_firePoolChanged(name, nil)
	return true
end

function InstancePoolRegistry.ObservePool(
	self: InstancePoolRegistry,
	name: string,
	callback: (InstancePool?) -> ()
): any
	assert(typeof(name) == "string", "Pool name must be a string")
	assert(typeof(callback) == "function", "callback must be a function")

	local signal = self:_getSignal(name)
	callback(self._pools[name])
	return signal:Connect(callback)
end

function InstancePoolRegistry.Destroy(self: InstancePoolRegistry): ()
	for name, pool in self._pools do
		self._pools[name] = nil
		pool:Destroy()
		self:_firePoolChanged(name, nil)
	end

	for name, signal in self._signals do
		self._signals[name] = nil
		signal:Destroy()
	end
end

function InstancePoolRegistry._getSignal(self: InstancePoolRegistry, name: string): Signal.Signal<InstancePool?>
	local signal = self._signals[name]
	if not signal then
		signal = Signal.new()
		self._signals[name] = signal
	end

	return signal
end

function InstancePoolRegistry._firePoolChanged(self: InstancePoolRegistry, name: string, pool: InstancePool?): ()
	local signal = self._signals[name]
	if signal and signal:GetConnectionCount() > 0 then
		signal:Fire(pool)
	end
end

return InstancePoolRegistry
