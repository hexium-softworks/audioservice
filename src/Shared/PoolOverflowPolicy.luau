--!strict
--[=[
	Overflow policies for InstancePool.

	@class PoolOverflowPolicy
]=]

local PoolOverflowPolicy = table.freeze({
	Grow = "Grow",
	Reject = "Reject",
	Temporary = "Temporary",
})

export type PoolOverflowPolicy = "Grow" | "Reject" | "Temporary"

return PoolOverflowPolicy
