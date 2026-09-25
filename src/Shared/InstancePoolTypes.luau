--!strict
--[=[
	Shared type definitions for InstancePool.

	@class InstancePoolTypes
]=]

local InstancePoolTypes = {}

export type PoolOverflowPolicy = "Grow" | "Reject" | "Temporary"

export type InstancePoolConfig = {
	Name: string?,
	Template: Instance?,
	Factory: (() -> Instance)?,
	InitialCapacity: number?,
	MaxCapacity: number?,
	ExpandBy: number?,
	Container: Instance?,
	OverflowPolicy: PoolOverflowPolicy?,
	OnAcquire: ((Instance, any?) -> ())?,
	OnRelease: ((Instance) -> ())?,
	LeakWarningSeconds: number?,
	CaptureAcquireTracebacks: boolean?,
}

export type NormalizedInstancePoolConfig = {
	Name: string,
	Template: Instance?,
	Factory: (() -> Instance)?,
	InitialCapacity: number,
	MaxCapacity: number,
	ExpandBy: number,
	Container: Instance?,
	OverflowPolicy: PoolOverflowPolicy,
	OnAcquire: ((Instance, any?) -> ())?,
	OnRelease: ((Instance) -> ())?,
	LeakWarningSeconds: number?,
	CaptureAcquireTracebacks: boolean,
}

export type InstancePoolStats = {
	Name: string,
	Available: number,
	InUse: number,
	Reusable: number,
	Temporary: number,
	CreatedTotal: number,
	AcquiredTotal: number,
	ReleasedTotal: number,
	ReusedTotal: number,
	DestroyedTotal: number,
	PeakInUse: number,
	ExpansionCount: number,
	AcquireFailureCount: number,
}

return InstancePoolTypes
