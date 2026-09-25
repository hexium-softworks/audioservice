--!strict
--[=[
	Optional client-side InstancePool registry service.

	@class InstancePoolServiceClient
]=]

local require = require(script.Parent.loader).load(script)

local Maid = require("Maid")
local ServiceBag = require("ServiceBag")

local InstancePoolRegistry = require("InstancePoolRegistry")
local InstancePoolTypes = require("InstancePoolTypes")

type ServiceBag = ServiceBag.ServiceBag
type InstancePoolConfig = InstancePoolTypes.InstancePoolConfig

local InstancePoolServiceClient = {}
InstancePoolServiceClient.ServiceName = "InstancePoolServiceClient"

export type InstancePoolServiceClient = typeof(setmetatable(
	{} :: {
		_serviceBag: ServiceBag,
		_maid: Maid.Maid,
		_registry: InstancePoolRegistry.InstancePoolRegistry,
	},
	{} :: typeof({ __index = InstancePoolServiceClient })
))

function InstancePoolServiceClient.Init(self: InstancePoolServiceClient, serviceBag: ServiceBag): ()
	assert(not self._serviceBag, "Already initialized")
	self._serviceBag = assert(serviceBag, "No serviceBag")
	self._maid = Maid.new()
	self._registry = self._maid:Add(InstancePoolRegistry.new("Client"))
end

function InstancePoolServiceClient.Start(_self: InstancePoolServiceClient): () end

function InstancePoolServiceClient.CreatePool(
	self: InstancePoolServiceClient,
	name: string,
	config: InstancePoolConfig
): any
	return self._registry:CreatePool(name, config)
end

function InstancePoolServiceClient.GetPool(self: InstancePoolServiceClient, name: string): any
	return self._registry:GetPool(name)
end

function InstancePoolServiceClient.FindPool(self: InstancePoolServiceClient, name: string): any
	return self._registry:FindPool(name)
end

function InstancePoolServiceClient.DestroyPool(self: InstancePoolServiceClient, name: string): boolean
	return self._registry:DestroyPool(name)
end

function InstancePoolServiceClient.ObservePool(
	self: InstancePoolServiceClient,
	name: string,
	callback: (any?) -> ()
): any
	return self._registry:ObservePool(name, callback)
end

function InstancePoolServiceClient.Destroy(self: InstancePoolServiceClient): ()
	self._maid:DoCleaning()
end

return InstancePoolServiceClient
