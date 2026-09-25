--!strict
--[=[
	@class InstancePoolRegistry.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local InstancePoolRegistry = require("InstancePoolRegistry")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

local function createPart(): Part
	return Instance.new("Part")
end

describe("InstancePoolRegistry", function()
	it("creates, finds, observes, and destroys pools", function()
		local registry = InstancePoolRegistry.new("Test")
		local observed: { any } = {}

		local connection = registry:ObservePool("Projectiles.Arrows", function(pool)
			table.insert(observed, pool or "nil")
		end)

		expect(observed[1]).toBe("nil")

		local pool = registry:CreatePool("Projectiles.Arrows", {
			Factory = function()
				return createPart()
			end,
		})

		expect(registry:FindPool("Projectiles.Arrows")).toBe(pool)
		expect(registry:GetPool("Projectiles.Arrows")).toBe(pool)
		expect(observed[2]).toBe(pool)

		local duplicateOk = pcall(function()
			registry:CreatePool("Projectiles.Arrows", {
				Factory = function()
					return createPart()
				end,
			})
		end)
		expect(duplicateOk).toBe(false)

		expect(registry:DestroyPool("Projectiles.Arrows")).toBe(true)
		expect(pool:IsDestroyed()).toBe(true)
		expect(registry:FindPool("Projectiles.Arrows") == nil).toBe(true)
		expect(observed[3]).toBe("nil")

		connection:Disconnect()
		registry:Destroy()
	end)

	it("destroys all registered pools when destroyed", function()
		local registry = InstancePoolRegistry.new("Test")
		local first = registry:CreatePool("One", {
			Factory = function()
				return createPart()
			end,
		})
		local second = registry:CreatePool("Two", {
			Factory = function()
				return createPart()
			end,
		})

		registry:Destroy()

		expect(first:IsDestroyed()).toBe(true)
		expect(second:IsDestroyed()).toBe(true)
	end)
end)
