--!strict
--[=[
	Optional server-side InstancePool registry service.

	@class InstancePoolService
]=]

local require = require(script.Parent.loader).load(script)

local Maid = require("Maid")
local ServiceBag = require("ServiceBag")

local InstancePoolRegistry = require("InstancePoolRegistry")
local InstancePoolTypes = require("InstancePoolTypes")

type ServiceBag = ServiceBag.ServiceBag
type InstancePoolConfig = InstancePoolTypes.InstancePoolConfig

local InstancePoolService = {}
InstancePoolService.ServiceName = "InstancePoolService"

export type InstancePoolService = typeof(setmetatable(
	{} :: {
		_serviceBag: ServiceBag,
		_maid: Maid.Maid,
		_registry: InstancePoolRegistry.InstancePoolRegistry,
	},
	{} :: typeof({ __index = InstancePoolService })
))

function InstancePoolService.Init(self: InstancePoolService, serviceBag: ServiceBag): ()
	assert(not self._serviceBag, "Already initialized")
	self._serviceBag = assert(serviceBag, "No serviceBag")
	self._maid = Maid.new()
	self._registry = self._maid:Add(InstancePoolRegistry.new("Server"))
end

function InstancePoolService.Start(_self: InstancePoolService): () end

function InstancePoolService.CreatePool(self: InstancePoolService, name: string, config: InstancePoolConfig): any
	return self._registry:CreatePool(name, config)
end

function InstancePoolService.GetPool(self: InstancePoolService, name: string): any
	return self._registry:GetPool(name)
end

function InstancePoolService.FindPool(self: InstancePoolService, name: string): any
	return self._registry:FindPool(name)
end

function InstancePoolService.DestroyPool(self: InstancePoolService, name: string): boolean
	return self._registry:DestroyPool(name)
end

function InstancePoolService.ObservePool(self: InstancePoolService, name: string, callback: (any?) -> ()): any
	return self._registry:ObservePool(name, callback)
end

function InstancePoolService.Destroy(self: InstancePoolService): ()
	self._maid:DoCleaning()
end

return InstancePoolService
