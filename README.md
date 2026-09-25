# InstancePool

A game-agnostic Nevermore package for reusing Roblox `Instance` objects safely.

`InstancePool` owns creation, reuse, lifecycle tracking, statistics, and optional
registry lookup. Your game owns object-specific initialization and reset behavior
through callbacks.

## Installation

```sh
pnpm add @hexium-softworks/instancepool
```

## Standalone Usage

Use the core class directly when a system owns its own pool.

```lua
local require = require(script.Parent.loader).load(script)

local InstancePool = require("InstancePool")
local PoolOverflowPolicy = require("PoolOverflowPolicy")

local projectilePool = InstancePool.new({
	Name = "Projectiles",
	Template = projectileTemplate,

	InitialCapacity = 32,
	MaxCapacity = 128,
	ExpandBy = 16,
	Container = pooledInstancesFolder,
	OverflowPolicy = PoolOverflowPolicy.Grow,

	OnAcquire = function(projectile, context)
		projectile.CFrame = context.CFrame
		projectile.Parent = context.Parent
	end,

	OnRelease = function(projectile)
		projectile.AssemblyLinearVelocity = Vector3.zero
		projectile.AssemblyAngularVelocity = Vector3.zero
	end,
})

local lease = projectilePool:Acquire({
	CFrame = spawnCFrame,
	Parent = workspace.Projectiles,
})

local projectile = lease:GetInstance()

lease:Release()
```

## Creation

A pool must define exactly one creation mechanism.

Template cloning:

```lua
local pool = InstancePool.new({
	Template = workspace.ProjectileTemplate,
})
```

Custom factory:

```lua
local pool = InstancePool.new({
	Factory = function()
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		return part
	end,
})
```

Factories must return a fresh `Instance` each time.

## Leases

`Acquire()` returns an `InstancePoolLease`.

```lua
local lease = pool:Acquire()
local instance = lease:GetInstance()

lease:GetMaid():GiveTask(instance.Touched:Connect(function(hit)
	print(hit)
end))

lease:Release()
```

Release cleans the lease Maid before the pool runs `OnRelease`. Double release,
stale release, and wrong-pool release fail safely and return `false`.

`lease:Destroy()` aliases `lease:Release()` for Maid compatibility.

## Raw Convenience API

Systems that prefer raw instances can use:

```lua
local instance = pool:Take()
pool:Return(instance)
```

This is checked against the same ownership records, but leases are the preferred
API because they carry generation and per-use cleanup explicitly.

## Overflow Policies

`PoolOverflowPolicy.Grow` expands by `ExpandBy` when empty until `MaxCapacity`.

`PoolOverflowPolicy.Reject` returns `nil, "PoolExhausted"` from `TryAcquire()`.

`PoolOverflowPolicy.Temporary` creates overflow instances that are destroyed on
release and never enter the reusable queue.

```lua
local lease, reason = pool:TryAcquire()
if not lease then
	warn(reason)
end
```

## Prewarming

```lua
pool:Prewarm(50)
```

For batched prewarming:

```lua
pool:PromisePrewarm(100, {
	BatchSize = 10,
	YieldBetweenBatches = true,
})
```

`PromisePrewarm` uses Nevermore `Promise`; the rest of the package does not
require Promise at module load time.

## Reset Behavior

The core pool does not attempt to reset arbitrary Roblox properties. There is no
universally safe reset for things like `CFrame`, `Transparency`, attributes,
tags, physics velocity, playback state, child instances, or event connections.

Use `OnRelease` for game-specific reset:

```lua
OnRelease = function(part)
	part.CFrame = CFrame.identity
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part:SetAttribute("Owner", nil)
end
```

## Lifecycle

Available instances are parented to `Container` or `nil`. Checked-out instances
are controlled by `OnAcquire` and consumer code.

Methods:

```lua
pool:Trim(targetAvailable)
pool:Clear()
pool:Destroy()
```

`Trim()` destroys available instances only.

`Clear()` destroys all available instances and prevents already checked-out
instances from re-entering the pool when released.

`Destroy()` rejects future acquisition, destroys available instances, disconnects
observers, and marks checked-out instances for destruction when released.

The pool listens to `Instance.Destroying`. If an available or checked-out
instance is destroyed externally, the pool removes it from tracking and
invalidates any active lease.

## Stats

```lua
local stats = pool:GetStats()
local connection = pool:ObserveStats(function(nextStats)
	print(nextStats.InUse)
end)
```

Stats include available, in-use, reusable, temporary, created, acquired,
released, reused, destroyed, peak usage, expansion count, and acquire failures.

## Registry Services

Registries are optional. Use them when multiple systems intentionally share a
pool or when centralized diagnostics are useful.

Server:

```lua
local InstancePoolService = require("InstancePoolService")

function MyService:Init(serviceBag)
	self._poolService = serviceBag:GetService(InstancePoolService)
end

function MyService:Start()
	self._poolService:CreatePool("VFX.Explosions", {
		Factory = function()
			return Instance.new("Part")
		end,
		InitialCapacity = 16,
	})
end
```

Client:

```lua
local InstancePoolServiceClient = require("InstancePoolServiceClient")
```

Server and client registries are independent. They do not replicate pooled
instances or pool state.

Registry methods:

```lua
service:CreatePool(name, config)
service:GetPool(name)
service:FindPool(name)
service:DestroyPool(name)
service:ObservePool(name, callback)
```

Duplicate names are rejected.

## API Reference

Core:

| Method | Description |
| --- | --- |
| `InstancePool.new(config)` | Creates a standalone pool. |
| `Acquire(context?)` | Acquires a lease or errors if unavailable. |
| `TryAcquire(context?)` | Acquires a lease or returns `nil, reason`. |
| `Release(instanceOrLease)` | Releases a checked-out instance or lease. |
| `Take(context?)` | Raw instance convenience acquire. |
| `Return(instance)` | Raw instance convenience release. |
| `Prewarm(count)` | Creates reusable available instances. |
| `PromisePrewarm(count, options?)` | Batched async prewarming. |
| `Trim(targetAvailable)` | Destroys available instances above the target. |
| `Clear()` | Destroys available instances and invalidates pool generation. |
| `Destroy()` | Destroys the pool. |
| `GetStats()` | Returns a read-only stats snapshot. |
| `ObserveStats(callback)` | Observes stats changes. |

Config:

| Field | Description |
| --- | --- |
| `Name` | Human-readable pool name. |
| `Template` | Instance to clone. Mutually exclusive with `Factory`. |
| `Factory` | Function returning a fresh Instance. |
| `InitialCapacity` | Number of instances to prewarm at construction. |
| `MaxCapacity` | Maximum reusable capacity. Defaults to unbounded. |
| `ExpandBy` | Grow batch size. Defaults to `1`. |
| `Container` | Parent for available instances, or `nil`. |
| `OverflowPolicy` | `Grow`, `Reject`, or `Temporary`. |
| `OnAcquire` | Synchronous callback run after checkout. |
| `OnRelease` | Synchronous callback run before reusable return. |
| `LeakWarningSeconds` | Optional retained-lease warning threshold. |
| `CaptureAcquireTracebacks` | Optional traceback capture for leak diagnostics. |
