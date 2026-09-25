--!strict
--[=[
	@class InstancePool.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local InstancePool = require("InstancePool")
local PoolOverflowPolicy = require("PoolOverflowPolicy")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

local function createPart(name: string?): Part
	local part = Instance.new("Part")
	part.Name = name or "PooledPart"
	return part
end

local function expectThrows(callback: () -> ()): ()
	local ok = pcall(callback)
	expect(ok).toBe(false)
end

describe("InstancePool", function()
	it("requires exactly one creation mechanism", function()
		local template = createPart()

		expectThrows(function()
			InstancePool.new({})
		end)

		expectThrows(function()
			InstancePool.new({
				Template = template,
				Factory = function()
					return createPart()
				end,
			})
		end)

		template:Destroy()
	end)

	it("prewarms template pools with distinct clones", function()
		local template = createPart("Template")
		local container = Instance.new("Folder")
		local pool = InstancePool.new({
			Name = "TemplatePool",
			Template = template,
			InitialCapacity = 2,
			Container = container,
		})

		expect(pool:GetAvailableCount()).toBe(2)
		expect(pool:GetTotalCount()).toBe(2)

		local first = pool:Acquire()
		local second = pool:Acquire()

		expect(first:GetInstance() == template).toBe(false)
		expect(second:GetInstance() == template).toBe(false)
		expect(first:GetInstance() == second:GetInstance()).toBe(false)
		expect(first:GetInstance().Parent == container).toBe(false)

		first:Release()
		second:Release()
		pool:Destroy()
		template:Destroy()
		container:Destroy()
	end)

	it("uses factories and rejects reused factory instances", function()
		local created = 0
		local pool = InstancePool.new({
			Factory = function()
				created += 1
				return createPart()
			end,
		})

		pool:Prewarm(2)
		expect(created).toBe(2)
		pool:Destroy()

		local samePart = createPart()
		local badPool = InstancePool.new({
			Factory = function()
				return samePart
			end,
		})

		badPool:Prewarm(1)
		expectThrows(function()
			badPool:Prewarm(1)
		end)

		badPool:Destroy()
	end)

	it("acquires, releases, and reuses instances with callbacks", function()
		local container = Instance.new("Folder")
		local activeParent = Instance.new("Folder")
		local acquiredContext: any = nil
		local releaseCount = 0
		local pool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 1,
			Container = container,
			OnAcquire = function(instance, context)
				acquiredContext = context
				instance.Parent = context.Parent
			end,
			OnRelease = function(instance)
				releaseCount += 1
				instance:SetAttribute("Released", true)
			end,
		})

		local lease = pool:Acquire({
			Parent = activeParent,
		})
		local instance = lease:GetInstance()

		expect(acquiredContext.Parent).toBe(activeParent)
		expect(instance.Parent).toBe(activeParent)
		expect(pool:GetAvailableCount()).toBe(0)
		expect(pool:GetInUseCount()).toBe(1)

		expect(lease:Release()).toBe(true)
		expect(releaseCount).toBe(1)
		expect(instance.Parent).toBe(container)
		expect(instance:GetAttribute("Released")).toBe(true)

		local nextLease = pool:Acquire()
		expect(nextLease:GetInstance()).toBe(instance)

		nextLease:Release()
		pool:Destroy()
		container:Destroy()
		activeParent:Destroy()
	end)

	it("destroys dirty instances when callbacks fail", function()
		local acquirePool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			OnAcquire = function()
				error("bad acquire")
			end,
		})

		local lease, reason = acquirePool:TryAcquire()
		expect(lease == nil).toBe(true)
		expect(reason).toBe("OnAcquireFailed")
		expect(acquirePool:GetTotalCount()).toBe(0)
		acquirePool:Destroy()

		local releasePool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			OnRelease = function()
				error("bad release")
			end,
		})

		local releaseLease = releasePool:Acquire()
		local instance = releaseLease:GetInstance()

		expect(releaseLease:Release()).toBe(true)
		expect(instance.Parent).toBe(nil)
		expect(releasePool:GetTotalCount()).toBe(0)
		releasePool:Destroy()
	end)

	it("protects against double release, stale leases, and wrong pools", function()
		local pool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 1,
		})

		local firstLease = pool:Acquire()
		expect(firstLease:Release()).toBe(true)
		expect(firstLease:Release()).toBe(false)

		local secondLease = pool:Acquire()
		expect(firstLease:Release()).toBe(false)

		local otherPool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
		})

		expect(otherPool:Release(secondLease)).toBe(false)

		secondLease:Release()
		pool:Destroy()
		otherPool:Destroy()
	end)

	it("supports grow, reject, and temporary overflow policies", function()
		local growPool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 1,
			MaxCapacity = 3,
			ExpandBy = 2,
			OverflowPolicy = PoolOverflowPolicy.Grow,
		})

		local growLeases = {
			growPool:Acquire(),
			growPool:Acquire(),
			growPool:Acquire(),
		}

		expect(growPool:GetTotalCount()).toBe(3)
		local rejectedByCapacity = growPool:TryAcquire()
		expect(rejectedByCapacity == nil).toBe(true)

		for _, lease in growLeases do
			lease:Release()
		end
		growPool:Destroy()

		local rejectPool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 1,
			OverflowPolicy = PoolOverflowPolicy.Reject,
		})

		local rejectLease = rejectPool:Acquire()
		local missingLease, reason = rejectPool:TryAcquire()
		expect(missingLease == nil).toBe(true)
		expect(reason).toBe("PoolExhausted")
		rejectLease:Release()
		rejectPool:Destroy()

		local temporaryPool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 1,
			MaxCapacity = 1,
			OverflowPolicy = PoolOverflowPolicy.Temporary,
		})

		local reusableLease = temporaryPool:Acquire()
		local temporaryLease = temporaryPool:Acquire()
		local temporaryInstance = temporaryLease:GetInstance()

		expect(temporaryPool:GetStats().Temporary).toBe(1)
		temporaryLease:Release()
		expect(temporaryInstance.Parent).toBe(nil)
		expect(temporaryPool:GetStats().Temporary).toBe(0)
		expect(temporaryPool:GetTotalCount()).toBe(1)

		reusableLease:Release()
		temporaryPool:Destroy()
	end)

	it("supports raw Take and Return", function()
		local pool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
		})

		local instance = pool:Take()
		expect(typeof(instance)).toBe("Instance")
		expect(pool:GetInUseCount()).toBe(1)
		expect(pool:Return(instance :: Instance)).toBe(true)
		expect(pool:Return(instance :: Instance)).toBe(false)

		pool:Destroy()
	end)

	it("clears, trims, and destroys with checked-out instances handled safely", function()
		local pool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 3,
		})

		expect(pool:Trim(1)).toBe(2)
		expect(pool:GetAvailableCount()).toBe(1)

		local oldLease = pool:Acquire()
		local oldInstance = oldLease:GetInstance()
		pool:Clear()
		expect(pool:GetAvailableCount()).toBe(0)
		oldLease:Release()
		expect(oldInstance.Parent).toBe(nil)
		expect(pool:GetTotalCount()).toBe(0)

		local newLease = pool:Acquire()
		local newInstance = newLease:GetInstance()
		pool:Destroy()
		expect(pool:IsDestroyed()).toBe(true)
		expect(pool:TryAcquire() == nil).toBe(true)
		newLease:Release()
		expect(newInstance.Parent).toBe(nil)
	end)

	it("tracks external destruction and invalidates active leases", function()
		local pool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 1,
		})

		local availableLease = pool:Acquire()
		local availableInstance = availableLease:GetInstance()
		availableLease:Release()
		availableInstance:Destroy()
		expect(pool:GetAvailableCount()).toBe(0)
		expect(pool:GetTotalCount()).toBe(0)

		local activeLease = pool:Acquire()
		local activeInstance = activeLease:GetInstance()
		activeInstance:Destroy()
		expect(pool:GetInUseCount()).toBe(0)
		expect(activeLease:Release()).toBe(false)

		pool:Destroy()
	end)

	it("cleans lease Maids on release", function()
		local cleaned = false
		local pool = InstancePool.new({
			Factory = function()
				return createPart()
			end,
		})

		local lease = pool:Acquire()
		lease:GetMaid():GiveTask(function()
			cleaned = true
		end)

		lease:Release()
		expect(cleaned).toBe(true)
		pool:Destroy()
	end)

	it("reports internally consistent stats", function()
		local observed: { any } = {}
		local pool = InstancePool.new({
			Name = "Stats",
			Factory = function()
				return createPart()
			end,
			InitialCapacity = 1,
		})

		local connection = pool:ObserveStats(function(stats)
			table.insert(observed, stats)
		end)

		local lease = pool:Acquire()
		lease:Release()

		local stats = pool:GetStats()
		expect(stats.Name).toBe("Stats")
		expect(stats.Available).toBe(pool:GetAvailableCount())
		expect(stats.InUse).toBe(pool:GetInUseCount())
		expect(stats.Reusable).toBe(pool:GetTotalCount())
		expect(stats.AcquiredTotal).toBe(1)
		expect(stats.ReleasedTotal).toBe(1)
		expect(stats.PeakInUse).toBe(1)
		expect(#observed >= 2).toBe(true)

		connection:Disconnect()
		pool:Destroy()
	end)
end)
