--!strict
--[=[
	Game-agnostic Roblox Instance pool with lease-based ownership.

	@class InstancePool
]=]

local require = require(script.Parent.loader).load(script)

local Log = require("Log")
local Signal = require("Signal")

local InstancePoolConfigUtils = require("InstancePoolConfigUtils")
local InstancePoolLease = require("InstancePoolLease")
local InstancePoolTypes = require("InstancePoolTypes")
local PoolOverflowPolicy = require("PoolOverflowPolicy")

type InstancePoolConfig = InstancePoolTypes.InstancePoolConfig
type NormalizedInstancePoolConfig = InstancePoolTypes.NormalizedInstancePoolConfig
type InstancePoolStats = InstancePoolTypes.InstancePoolStats
type InstancePoolLease = InstancePoolLease.InstancePoolLease

type RecordState = "Available" | "InUse" | "Temporary" | "Destroyed"

type PoolRecord = {
	Instance: Instance,
	State: RecordState,
	Generation: number,
	PoolGeneration: number,
	Lease: InstancePoolLease?,
	DestroyingConnection: RBXScriptConnection?,
	Temporary: boolean,
	DestroyOnRelease: boolean,
	AcquireTime: number?,
	AcquireTraceback: string?,
}

type MutableStats = {
	CreatedTotal: number,
	AcquiredTotal: number,
	ReleasedTotal: number,
	ReusedTotal: number,
	DestroyedTotal: number,
	PeakInUse: number,
	ExpansionCount: number,
	AcquireFailureCount: number,
}

local InstancePool = {}
InstancePool.ClassName = "InstancePool"
InstancePool.__index = InstancePool

local LOGGER = Log.new({
	name = "InstancePool",
	defaultContext = {
		Package = "InstancePool",
	},
})

export type InstancePool = typeof(setmetatable(
	{} :: {
		_config: NormalizedInstancePoolConfig,
		_available: { PoolRecord },
		_records: { [Instance]: PoolRecord },
		_inUse: { [Instance]: PoolRecord },
		_rawLeases: { [Instance]: InstancePoolLease },
		_destroyed: boolean,
		_poolGeneration: number,
		_reusableCount: number,
		_inUseCount: number,
		_temporaryInUseCount: number,
		_stats: MutableStats,
		_statsChanged: Signal.Signal<InstancePoolStats>,
	},
	InstancePool
))

local function makeMutableStats(): MutableStats
	return {
		CreatedTotal = 0,
		AcquiredTotal = 0,
		ReleasedTotal = 0,
		ReusedTotal = 0,
		DestroyedTotal = 0,
		PeakInUse = 0,
		ExpansionCount = 0,
		AcquireFailureCount = 0,
	}
end

local function countMap(map: { [Instance]: PoolRecord }): number
	local count = 0
	for _ in map do
		count += 1
	end
	return count
end

function InstancePool.new(config: InstancePoolConfig): InstancePool
	local normalizedConfig = InstancePoolConfigUtils.normalizeConfig(config)

	local self: InstancePool = setmetatable({
		_config = normalizedConfig,
		_available = {},
		_records = {},
		_inUse = {},
		_rawLeases = {},
		_destroyed = false,
		_poolGeneration = 0,
		_reusableCount = 0,
		_inUseCount = 0,
		_temporaryInUseCount = 0,
		_stats = makeMutableStats(),
		_statsChanged = Signal.new(),
	}, InstancePool) :: any

	if normalizedConfig.InitialCapacity > 0 then
		self:Prewarm(normalizedConfig.InitialCapacity)
	end

	return self
end

function InstancePool.IsDestroyed(self: InstancePool): boolean
	return self._destroyed
end

function InstancePool.GetAvailableCount(self: InstancePool): number
	return #self._available
end

function InstancePool.GetInUseCount(self: InstancePool): number
	return self._inUseCount
end

function InstancePool.GetTotalCount(self: InstancePool): number
	return self._reusableCount + self._temporaryInUseCount
end

function InstancePool.GetCapacity(self: InstancePool): number
	return self._config.MaxCapacity
end

function InstancePool.GetStats(self: InstancePool): InstancePoolStats
	return {
		Name = self._config.Name,
		Available = #self._available,
		InUse = self._inUseCount,
		Reusable = self._reusableCount,
		Temporary = self._temporaryInUseCount,
		CreatedTotal = self._stats.CreatedTotal,
		AcquiredTotal = self._stats.AcquiredTotal,
		ReleasedTotal = self._stats.ReleasedTotal,
		ReusedTotal = self._stats.ReusedTotal,
		DestroyedTotal = self._stats.DestroyedTotal,
		PeakInUse = self._stats.PeakInUse,
		ExpansionCount = self._stats.ExpansionCount,
		AcquireFailureCount = self._stats.AcquireFailureCount,
	}
end

function InstancePool.ObserveStats(self: InstancePool, callback: (InstancePoolStats) -> ()): any
	assert(typeof(callback) == "function", "callback must be a function")

	callback(self:GetStats())
	return self._statsChanged:Connect(callback)
end

function InstancePool.Prewarm(self: InstancePool, count: number): number
	assert(typeof(count) == "number", "count must be a number")
	assert(count >= 0 and count % 1 == 0, "count must be a non-negative integer")
	assert(not self._destroyed, "Cannot prewarm a destroyed pool")

	local created = 0
	for _ = 1, count do
		if self._reusableCount >= self._config.MaxCapacity then
			break
		end

		local record = self:_createRecord(false)
		self:_enqueueAvailable(record)
		created += 1
	end

	if created > 0 then
		self:_fireStatsChanged()
	end

	return created
end

function InstancePool.PromisePrewarm(self: InstancePool, count: number, options: { BatchSize: number?, YieldBetweenBatches: boolean? }?): any
	local Promise = require("Promise")
	local batchSize = if options and options.BatchSize then options.BatchSize else 10
	local yieldBetweenBatches = if options and options.YieldBetweenBatches ~= nil then options.YieldBetweenBatches else true

	assert(typeof(batchSize) == "number", "BatchSize must be a number")
	assert(batchSize > 0 and batchSize % 1 == 0, "BatchSize must be a positive integer")

	return Promise.spawn(function(resolve: (number) -> (), reject: (any) -> ())
		local created = 0
		local remaining = count

		while remaining > 0 and not self._destroyed do
			local batchCount = math.min(batchSize, remaining)
			local ok, batchCreatedOrError = pcall(function()
				return self:Prewarm(batchCount)
			end)

			if not ok then
				reject(batchCreatedOrError)
				return
			end

			local batchCreated = batchCreatedOrError :: number
			created += batchCreated
			remaining -= batchCount

			if batchCreated < batchCount then
				break
			end

			if yieldBetweenBatches and remaining > 0 then
				task.wait()
			end
		end

		resolve(created)
	end)
end

function InstancePool.TryAcquire(self: InstancePool, context: any?): (InstancePoolLease?, string?)
	if self._destroyed then
		self:_countAcquireFailure()
		return nil, "PoolDestroyed"
	end

	local record = self:_popAvailable()
	local source = if record then "available" else "created"

	if not record then
		record = self:_createRecordForOverflow()
	end

	if not record then
		self:_countAcquireFailure()
		return nil, "PoolExhausted"
	end

	return self:_acquireRecord(record, context, source)
end

function InstancePool.Acquire(self: InstancePool, context: any?): InstancePoolLease
	local lease, reason = self:TryAcquire(context)
	assert(lease ~= nil, reason or "Unable to acquire instance from pool")
	return lease :: InstancePoolLease
end

function InstancePool.Take(self: InstancePool, context: any?): Instance?
	local lease = self:TryAcquire(context)
	if not lease then
		return nil
	end

	local instance = lease:GetInstance()
	self._rawLeases[instance] = lease
	return instance
end

function InstancePool.Return(self: InstancePool, instance: Instance): boolean
	assert(typeof(instance) == "Instance", "instance must be an Instance")

	local lease = self._rawLeases[instance]
	if not lease then
		LOGGER.Warn("Attempted to return an instance that was not checked out through Take", {
			Pool = self._config.Name,
			Instance = instance.Name,
		})
		return false
	end

	self._rawLeases[instance] = nil
	return lease:Release()
end

function InstancePool.Release(self: InstancePool, instanceOrLease: Instance | InstancePoolLease): boolean
	if typeof(instanceOrLease) == "Instance" then
		local record = self._records[instanceOrLease]
		if not record or not record.Lease then
			LOGGER.Warn("Attempted to release an instance that is not checked out", {
				Pool = self._config.Name,
			})
			return false
		end

		self._rawLeases[instanceOrLease] = nil
		return record.Lease:Release()
	end

	local lease = instanceOrLease :: InstancePoolLease
	if (lease :: any).ClassName ~= "InstancePoolLease" then
		error("Release expects an Instance or InstancePoolLease", 2)
	end

	if lease:_getPool() ~= self then
		LOGGER.Warn("Attempted to release a lease into the wrong pool", {
			Pool = self._config.Name,
		})
		return false
	end

	return lease:Release()
end

function InstancePool.Trim(self: InstancePool, targetAvailable: number): number
	assert(typeof(targetAvailable) == "number", "targetAvailable must be a number")
	assert(targetAvailable >= 0 and targetAvailable % 1 == 0, "targetAvailable must be a non-negative integer")

	local destroyed = 0
	while #self._available > targetAvailable do
		local record = table.remove(self._available)
		if record then
			self:_destroyRecord(record)
			destroyed += 1
		end
	end

	if destroyed > 0 then
		self:_fireStatsChanged()
	end

	return destroyed
end

function InstancePool.Clear(self: InstancePool): ()
	if self._destroyed then
		return
	end

	self._poolGeneration += 1
	self:Trim(0)

	for _, record in self._inUse do
		record.DestroyOnRelease = true
	end
end

function InstancePool.Destroy(self: InstancePool): ()
	if self._destroyed then
		return
	end

	self._destroyed = true
	self:Trim(0)

	for _, record in self._inUse do
		record.DestroyOnRelease = true
	end

	self._statsChanged:Destroy()
end

function InstancePool._createInstance(self: InstancePool): Instance
	local instance: Instance

	if self._config.Template then
		instance = self._config.Template:Clone()
	else
		local factory = self._config.Factory
		assert(factory ~= nil, "No factory")
		instance = factory()
		assert(typeof(instance) == "Instance", "Factory must return an Instance")
		assert(self._records[instance] == nil, "Factory returned an Instance that is already managed by this pool")
	end

	self._stats.CreatedTotal += 1
	return instance
end

function InstancePool._createRecord(self: InstancePool, temporary: boolean): PoolRecord
	local instance = self:_createInstance()
	local record: PoolRecord = {
		Instance = instance,
		State = if temporary then "Temporary" else "Available",
		Generation = 0,
		PoolGeneration = self._poolGeneration,
		Lease = nil,
		DestroyingConnection = nil,
		Temporary = temporary,
		DestroyOnRelease = temporary,
		AcquireTime = nil,
		AcquireTraceback = nil,
	}

	self._records[instance] = record
	if temporary then
		self._temporaryInUseCount += 1
	else
		self._reusableCount += 1
		instance.Parent = self._config.Container
	end

	record.DestroyingConnection = instance.Destroying:Connect(function()
		self:_handleExternalDestroy(record)
	end)

	return record
end

function InstancePool._createRecordForOverflow(self: InstancePool): PoolRecord?
	if self._config.OverflowPolicy == PoolOverflowPolicy.Reject then
		return nil
	end

	if self._config.OverflowPolicy == PoolOverflowPolicy.Temporary then
		return self:_createRecord(true)
	end

	local capacityLeft = self._config.MaxCapacity - self._reusableCount
	if capacityLeft <= 0 then
		return nil
	end

	local expandCount = math.min(self._config.ExpandBy, capacityLeft)
	for _ = 1, expandCount do
		local record = self:_createRecord(false)
		self:_enqueueAvailable(record)
	end

	self._stats.ExpansionCount += 1
	return self:_popAvailable()
end

function InstancePool._enqueueAvailable(self: InstancePool, record: PoolRecord): ()
	if record.State == "Destroyed" then
		return
	end

	record.State = "Available"
	record.Lease = nil
	record.AcquireTime = nil
	record.AcquireTraceback = nil
	record.Instance.Parent = self._config.Container
	table.insert(self._available, record)
end

function InstancePool._popAvailable(self: InstancePool): PoolRecord?
	while #self._available > 0 do
		local record = table.remove(self._available)
		if record and record.State == "Available" and self._records[record.Instance] == record then
			return record
		end
	end

	return nil
end

function InstancePool._removeAvailableRecord(self: InstancePool, targetRecord: PoolRecord): ()
	for index, record in self._available do
		if record == targetRecord then
			table.remove(self._available, index)
			return
		end
	end
end

function InstancePool._acquireRecord(
	self: InstancePool,
	record: PoolRecord,
	context: any?,
	source: string
): (InstancePoolLease?, string?)
	record.Generation += 1
	record.PoolGeneration = self._poolGeneration
	record.State = if record.Temporary then "Temporary" else "InUse"
	record.DestroyOnRelease = record.Temporary
	record.AcquireTime = os.clock()
	record.AcquireTraceback = if self._config.CaptureAcquireTracebacks then debug.traceback(nil, 2) else nil

	self._inUse[record.Instance] = record
	self._inUseCount += 1
	if self._inUseCount > self._stats.PeakInUse then
		self._stats.PeakInUse = self._inUseCount
	end

	local lease = InstancePoolLease.new(self, record.Instance, record.Generation)
	record.Lease = lease

	local onAcquire = self._config.OnAcquire
	if onAcquire then
		local ok, err = pcall(onAcquire, record.Instance, context)
		if not ok then
			LOGGER.Error("OnAcquire failed; destroying pooled instance", {
				Pool = self._config.Name,
				Error = tostring(err),
			})
			self:_removeInUseRecord(record)
			lease:_invalidate()
			self:_destroyRecord(record)
			self:_countAcquireFailure()
			self:_fireStatsChanged()
			return nil, "OnAcquireFailed"
		end
	end

	self._stats.AcquiredTotal += 1
	if source == "available" then
		self._stats.ReusedTotal += 1
	end

	self:_scheduleLeakWarning(record)
	self:_fireStatsChanged()

	return lease, nil
end

function InstancePool._releaseLease(self: InstancePool, lease: InstancePoolLease): boolean
	if lease:IsReleased() then
		LOGGER.Warn("Attempted to release an already released lease", {
			Pool = self._config.Name,
		})
		return false
	end

	if lease:_getPool() ~= self then
		LOGGER.Warn("Attempted to release a lease into the wrong pool", {
			Pool = self._config.Name,
		})
		return false
	end

	local instance = lease:_getInstanceOrNil()
	if not instance then
		lease:_markReleased()
		return false
	end

	local record = self._records[instance]
	if not record or self._inUse[instance] ~= record then
		LOGGER.Warn("Attempted to release an instance that is not in use", {
			Pool = self._config.Name,
			Instance = instance.Name,
		})
		lease:_markReleased()
		return false
	end

	if record.Generation ~= lease:_getGeneration() then
		LOGGER.Warn("Rejected stale pool lease", {
			Pool = self._config.Name,
			Instance = instance.Name,
		})
		lease:_markReleased()
		return false
	end

	self._rawLeases[instance] = nil
	lease:_cleanupForRelease()
	self:_removeInUseRecord(record)
	self._stats.ReleasedTotal += 1

	local shouldDestroy = self._destroyed
		or record.DestroyOnRelease
		or record.PoolGeneration ~= self._poolGeneration
		or record.Temporary

	if shouldDestroy then
		lease:_markReleased()
		self:_destroyRecord(record)
		self:_fireStatsChanged()
		return true
	end

	instance.Parent = self._config.Container

	local onRelease = self._config.OnRelease
	if onRelease then
		local ok, err = pcall(onRelease, instance)
		if not ok then
			LOGGER.Error("OnRelease failed; destroying dirty pooled instance", {
				Pool = self._config.Name,
				Error = tostring(err),
			})
			lease:_markReleased()
			self:_destroyRecord(record)
			self:_fireStatsChanged()
			return true
		end
	end

	if self._records[instance] ~= record or record.State == "Destroyed" then
		lease:_markReleased()
		self:_fireStatsChanged()
		return true
	end

	lease:_markReleased()
	self:_enqueueAvailable(record)
	self:_fireStatsChanged()
	return true
end

function InstancePool._removeInUseRecord(self: InstancePool, record: PoolRecord): ()
	if self._inUse[record.Instance] == record then
		self._inUse[record.Instance] = nil
		self._inUseCount = math.max(0, self._inUseCount - 1)
	end
end

function InstancePool._destroyRecord(self: InstancePool, record: PoolRecord): ()
	if record.State == "Destroyed" then
		return
	end

	self:_removeAvailableRecord(record)
	self:_removeInUseRecord(record)
	self._rawLeases[record.Instance] = nil
	self._records[record.Instance] = nil

	if record.DestroyingConnection then
		record.DestroyingConnection:Disconnect()
		record.DestroyingConnection = nil
	end

	if record.Lease then
		record.Lease:_invalidate()
		record.Lease = nil
	end

	if record.Temporary then
		self._temporaryInUseCount = math.max(0, self._temporaryInUseCount - 1)
	else
		self._reusableCount = math.max(0, self._reusableCount - 1)
	end

	record.State = "Destroyed"
	self._stats.DestroyedTotal += 1
	record.Instance:Destroy()
end

function InstancePool._handleExternalDestroy(self: InstancePool, record: PoolRecord): ()
	if record.State == "Destroyed" or self._records[record.Instance] ~= record then
		return
	end

	LOGGER.Warn("Pooled instance was destroyed externally", {
		Pool = self._config.Name,
		Instance = record.Instance.Name,
		ClassName = record.Instance.ClassName,
	})

	self:_removeAvailableRecord(record)
	self:_removeInUseRecord(record)
	self._rawLeases[record.Instance] = nil
	self._records[record.Instance] = nil

	if record.DestroyingConnection then
		record.DestroyingConnection:Disconnect()
		record.DestroyingConnection = nil
	end

	if record.Lease then
		record.Lease:_invalidate()
		record.Lease = nil
	end

	if record.Temporary then
		self._temporaryInUseCount = math.max(0, self._temporaryInUseCount - 1)
	else
		self._reusableCount = math.max(0, self._reusableCount - 1)
	end

	record.State = "Destroyed"
	self._stats.DestroyedTotal += 1
	self:_fireStatsChanged()
end

function InstancePool._scheduleLeakWarning(self: InstancePool, record: PoolRecord): ()
	local warningSeconds = self._config.LeakWarningSeconds
	if not warningSeconds then
		return
	end

	local generation = record.Generation
	task.delay(warningSeconds, function()
		if self._destroyed then
			return
		end

		if self._inUse[record.Instance] == record and record.Generation == generation then
			LOGGER.Warn("Pool lease has been retained longer than expected", {
				Pool = self._config.Name,
				Instance = record.Instance.Name,
				ClassName = record.Instance.ClassName,
				LeaseAge = os.clock() - (record.AcquireTime or os.clock()),
				Generation = generation,
				AcquireTraceback = record.AcquireTraceback,
			})
		end
	end)
end

function InstancePool._countAcquireFailure(self: InstancePool): ()
	self._stats.AcquireFailureCount += 1
	self:_fireStatsChanged()
end

function InstancePool._fireStatsChanged(self: InstancePool): ()
	if self._statsChanged:GetConnectionCount() > 0 then
		self._statsChanged:Fire(self:GetStats())
	end
end

function InstancePool._debugCountInUse(self: InstancePool): number
	return countMap(self._inUse)
end

return InstancePool
