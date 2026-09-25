--!strict
--[=[
	Validation helpers for InstancePool configs.

	@class InstancePoolConfigUtils
]=]

local require = require(script.Parent.loader).load(script)

local PoolOverflowPolicy = require("PoolOverflowPolicy")
local InstancePoolTypes = require("InstancePoolTypes")

type InstancePoolConfig = InstancePoolTypes.InstancePoolConfig
type NormalizedInstancePoolConfig = InstancePoolTypes.NormalizedInstancePoolConfig

local InstancePoolConfigUtils = {}

local DEFAULT_NAME = "InstancePool"
local DEFAULT_INITIAL_CAPACITY = 0
local DEFAULT_EXPAND_BY = 1
local DEFAULT_MAX_CAPACITY = math.huge

local VALID_OVERFLOW_POLICIES: { [string]: boolean } = {
	[PoolOverflowPolicy.Grow] = true,
	[PoolOverflowPolicy.Reject] = true,
	[PoolOverflowPolicy.Temporary] = true,
}

local function assertInteger(value: number, fieldName: string): ()
	assert(value == value, string.format("%s must not be NaN", fieldName))
	assert(value >= 0, string.format("%s must be non-negative", fieldName))
	assert(value % 1 == 0, string.format("%s must be an integer", fieldName))
end

local function normalizeName(name: any): string
	if name == nil then
		return DEFAULT_NAME
	end

	assert(typeof(name) == "string", "Name must be a string")
	assert(#name > 0, "Name must not be empty")
	return name
end

function InstancePoolConfigUtils.normalizeConfig(config: InstancePoolConfig): NormalizedInstancePoolConfig
	assert(typeof(config) == "table", "InstancePool config must be a table")

	local hasTemplate = config.Template ~= nil
	local hasFactory = config.Factory ~= nil
	assert(hasTemplate ~= hasFactory, "InstancePool config requires exactly one of Template or Factory")

	if config.Template ~= nil then
		assert(typeof(config.Template) == "Instance", "Template must be an Instance")
		assert(config.Template.Archivable, "Template must be Archivable so it can be cloned")
	end

	if config.Factory ~= nil then
		assert(typeof(config.Factory) == "function", "Factory must be a function")
	end

	local initialCapacity = config.InitialCapacity or DEFAULT_INITIAL_CAPACITY
	assert(typeof(initialCapacity) == "number", "InitialCapacity must be a number")
	assertInteger(initialCapacity, "InitialCapacity")

	local maxCapacity = if config.MaxCapacity == nil then DEFAULT_MAX_CAPACITY else config.MaxCapacity
	assert(typeof(maxCapacity) == "number", "MaxCapacity must be a number")
	assert(maxCapacity == math.huge or maxCapacity % 1 == 0, "MaxCapacity must be an integer or math.huge")
	assert(maxCapacity >= 0, "MaxCapacity must be non-negative")
	assert(initialCapacity <= maxCapacity, "InitialCapacity cannot exceed MaxCapacity")

	local expandBy = config.ExpandBy or DEFAULT_EXPAND_BY
	assert(typeof(expandBy) == "number", "ExpandBy must be a number")
	assert(expandBy == expandBy, "ExpandBy must not be NaN")
	assert(expandBy > 0, "ExpandBy must be positive")
	assert(expandBy % 1 == 0, "ExpandBy must be an integer")

	if config.Container ~= nil then
		assert(typeof(config.Container) == "Instance", "Container must be an Instance or nil")
	end

	if config.OnAcquire ~= nil then
		assert(typeof(config.OnAcquire) == "function", "OnAcquire must be a function")
	end

	if config.OnRelease ~= nil then
		assert(typeof(config.OnRelease) == "function", "OnRelease must be a function")
	end

	if config.LeakWarningSeconds ~= nil then
		assert(typeof(config.LeakWarningSeconds) == "number", "LeakWarningSeconds must be a number")
		assert(config.LeakWarningSeconds > 0, "LeakWarningSeconds must be positive")
	end

	if config.CaptureAcquireTracebacks ~= nil then
		assert(typeof(config.CaptureAcquireTracebacks) == "boolean", "CaptureAcquireTracebacks must be a boolean")
	end

	local overflowPolicy = config.OverflowPolicy or PoolOverflowPolicy.Grow
	assert(typeof(overflowPolicy) == "string", "OverflowPolicy must be a string")
	assert(VALID_OVERFLOW_POLICIES[overflowPolicy] == true, string.format("Unsupported OverflowPolicy %q", overflowPolicy))

	return {
		Name = normalizeName(config.Name),
		Template = config.Template,
		Factory = config.Factory,
		InitialCapacity = initialCapacity,
		MaxCapacity = maxCapacity,
		ExpandBy = expandBy,
		Container = config.Container,
		OverflowPolicy = overflowPolicy,
		OnAcquire = config.OnAcquire,
		OnRelease = config.OnRelease,
		LeakWarningSeconds = config.LeakWarningSeconds,
		CaptureAcquireTracebacks = config.CaptureAcquireTracebacks == true,
	}
end

return InstancePoolConfigUtils
