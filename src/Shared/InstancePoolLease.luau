--!strict
--[=[
	A checked-out InstancePool lease.

	@class InstancePoolLease
]=]

local require = require(script.Parent.loader).load(script)

local Maid = require("Maid")

local InstancePoolLease = {}
InstancePoolLease.ClassName = "InstancePoolLease"
InstancePoolLease.__index = InstancePoolLease

export type InstancePoolLease = typeof(setmetatable(
	{} :: {
		_pool: any,
		_instance: Instance?,
		_generation: number,
		_released: boolean,
		_valid: boolean,
		_maid: Maid.Maid,
	},
	InstancePoolLease
))

function InstancePoolLease.new(pool: any, instance: Instance, generation: number): InstancePoolLease
	assert(pool ~= nil, "No pool")
	assert(typeof(instance) == "Instance", "No instance")
	assert(typeof(generation) == "number", "No generation")

	return setmetatable({
		_pool = pool,
		_instance = instance,
		_generation = generation,
		_released = false,
		_valid = true,
		_maid = Maid.new(),
	}, InstancePoolLease) :: any
end

function InstancePoolLease.GetInstance(self: InstancePoolLease): Instance
	assert(self._instance ~= nil, "Lease no longer has an instance")
	return self._instance
end

function InstancePoolLease.GetMaid(self: InstancePoolLease): Maid.Maid
	return self._maid
end

function InstancePoolLease.IsReleased(self: InstancePoolLease): boolean
	return self._released
end

function InstancePoolLease.Release(self: InstancePoolLease): boolean
	if self._released then
		return false
	end

	local pool = self._pool
	if pool == nil then
		self:_markReleased()
		return false
	end

	return pool:_releaseLease(self)
end

function InstancePoolLease.Destroy(self: InstancePoolLease): ()
	self:Release()
end

function InstancePoolLease._getPool(self: InstancePoolLease): any
	return self._pool
end

function InstancePoolLease._getGeneration(self: InstancePoolLease): number
	return self._generation
end

function InstancePoolLease._getInstanceOrNil(self: InstancePoolLease): Instance?
	return self._instance
end

function InstancePoolLease._cleanupForRelease(self: InstancePoolLease): ()
	self._maid:DoCleaning()
end

function InstancePoolLease._markReleased(self: InstancePoolLease): ()
	if self._released then
		return
	end

	self._released = true
	self._valid = false
	self._pool = nil
	self._maid:DoCleaning()
end

function InstancePoolLease._invalidate(self: InstancePoolLease): ()
	self:_markReleased()
	self._instance = nil
end

return InstancePoolLease
