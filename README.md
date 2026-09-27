# Spark2D

Spark2D makes `ParticleEmitter`-style effects work inside a `ScreenGui`.

Roblox won't let a real `ParticleEmitter` live in 2D UI, so Spark2D fakes it. An effect is a plain `Folder` holding Attributes, and the runtime plays it back with a pool of recycled `ImageLabel`s. It moves the way a real particle effect does, and you can inspect every setting in the Properties window.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Spark2D = require(ReplicatedStorage.Spark2D):Init()

Spark2D:Emit(healthBar.HitBurst, 20)
```

---

## Features

- Uses the settings you already know from `ParticleEmitter`: `Rate`, `Lifetime`, `Speed`, `Size`, `Squash`, `Drag`, `Rotation`, `Orientation`, the `Color` and `Transparency` sequences and flipbooks.
- Those settings behave the way a real `ParticleEmitter` does when you look at it from the front. Drag, squash, rotation direction and the spread were all measured against real emitters in Studio.
- Everything is sized relative to the GuiObject the effect sits in, so it keeps its proportions on any screen, under a `UIScale` and inside layouts.
- Works in rotated frames. Gravity still points down the screen and particles stay upright.
- Extras that suit UI: trails, a fake depth effect, colour by speed, turbulence, velocity inheritance and a glow.
- Particles never block clicks, stop updating while their GUI is hidden, and thin out on low graphics settings.
- Client-side and small: one module plus three helper packages (`Cleaner`, `Signal`, `Pool`).

---

## Installation

**[Wally](https://wally.run/package/cresmarmat-an/spark2d)**: add it to your `wally.toml`.

```toml
[dependencies]
Spark2D = "cresmarmat-an/spark2d@LATEST_VERSION"
```

Wally installs its dependencies, [Cleaner](https://github.com/cresmarmat-an/roblox-cleaner), [Signal](https://github.com/cresmarmat-an/roblox-signal) and [Pool](https://github.com/cresmarmat-an/roblox-pool), for you.

**Roblox Studio**: download `Spark2D.rbxm` from [Releases](https://github.com/cresmarmat-an/roblox-spark2d/releases) and drag it onto `ReplicatedStorage`. It comes as one module with its dependencies inside:

```
ReplicatedStorage/
   Spark2D
      Cleaner
      Signal
      Pool
```

**[Studio plugin](https://create.roblox.com/store/asset/134544269563881/Spark2D)**: builds and previews effects visually, converts real `ParticleEmitter`s, and its INSTALL RUNTIME button places the module in the same layout. It isn't publicly listed yet. Everything here also works from a script.

Leave the three dependencies where the installer put them. `Spark2D` looks for each one as its own child first and then as a sibling, which is how Wally lays them out.

Spark2D drives `PlayerGui` and uses `RunService`, so `require` it from a **LocalScript**.

---

## Creating an effect

An effect is a `Folder` tagged `UIParticleEmitter`, parented under a `GuiObject`. Everything else is Attributes, and anything you don't set uses the default listed in the [attribute reference](#attribute-reference).

```lua
local CollectionService = game:GetService("CollectionService")

local burst = Instance.new("Folder")
burst.Name = "HitBurst"
burst:SetAttribute("Enabled", false)          -- burst only, no continuous stream
burst:SetAttribute("BurstCount", 20)
burst:SetAttribute("EmissionShape", "Point")
burst:SetAttribute("SpreadAngle", 180)        -- every direction
burst:SetAttribute("Lifetime", NumberRange.new(0.4, 0.8))
burst:SetAttribute("Speed", NumberRange.new(8, 14))
burst:SetAttribute("Size", NumberSequence.new(0.3))
burst:SetAttribute("Color", ColorSequence.new(Color3.fromRGB(255, 200, 80)))
burst.Parent = healthBar                       -- a Frame

CollectionService:AddTag(burst, "UIParticleEmitter")

Spark2D:Emit(burst)
```

The folder needs a `GuiObject` (or a `ScreenGui`) above it to draw anything. Particles are drawn into a frame inside the folder that covers the parent, so they sit exactly where the parent is.

---

## How sizing works

Particles are measured in **studs**, just like a real `ParticleEmitter`. The difference is that a stud isn't a fixed number of pixels. It's a fraction of the parent:

- `StudSize` is how big one stud is, as a fraction of `StudSizeRelativeTo`.
- `StudSizeRelativeTo` picks what that fraction is of. The default is `ParentHeight`, so with the default `StudSize` of `0.1` the parent is 10 studs tall.

So on a 200 pixel tall frame, a stud is 20 pixels. A particle with a `Size` of `1` is 2 studs (40 pixels) across, as it would be on a real emitter, and a `Speed` of `5` crosses half the frame each second. Make the frame bigger and the whole effect grows with it. Put a `UIScale` above it and the effect scales along with the rest of your UI.

To make an effect bigger or smaller without changing how it moves, change `StudSize`. To make it follow the screen instead of its parent, set `StudSizeRelativeTo` to `ScreenHeight`.

If the parent is small, like an icon, wrap the effect in its own transparent frame and size that frame to how big the effect should be. The icon stays as it is and you control the effect's area directly.

---

## Attribute reference

Every `UIParticleEmitter` folder is a set of Attributes. Names that match a `ParticleEmitter` property mean the same thing and behave the same way.

#### General

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `Enabled` | bool | `true` | Turns the continuous stream on and off. Particles already on screen finish their `Lifetime` either way. |
| `Texture` | string | sparkle asset | Any content ID. |
| `Rate` | number | `20` | Particles per second while `Enabled`. |
| `BurstCount` | number | `20` | How many particles `Spark2D:Emit()` fires when you don't pass a count. |
| `MaxParticles` | number | `1000` | The most particles this effect can have at once. See also `AdaptiveQuality`. |
| `StartDelay` | number | `0` | Seconds to wait after `Enabled` turns on before emitting. |
| `StopAfter` | number | `0` | Seconds of emission before it stops by itself. `0` means never. |
| `TimeScale` | number | `1` | Speeds this effect up or slows it down. Multiplies with the global `Spark2D:SetTimeScale`. |
| `ZIndex` | number | `2` | Draw order. The glow and trail copies draw one step below this. |
| `MoveWithParent` | bool | `true` | Like `ParticleEmitter.LockedToPart`. On: particles move, resize and turn with the parent. Off: particles stay where they were emitted, which leaves a trail behind a moving parent. |
| `ReduceOnLowGraphics` | bool | `true` | Lowers the emission rate on low graphics settings, the way Roblox thins out real particle effects. |
| `ResampleMode` | enum | `Default` | `Default` or `Pixelated`. Use `Pixelated` for pixel art textures. |

#### Scale

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `StudSize` | number | `0.1` | How big one stud is, as a fraction of `StudSizeRelativeTo`. Every size, speed and acceleration is in studs. |
| `StudSizeRelativeTo` | enum | `ParentHeight` | `ParentHeight`, `ParentWidth`, `ParentSmallerSide`, `ParentLargerSide` or `ScreenHeight`. |

#### Emission

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `EmissionShape` | enum | `Oval` | Where particles spawn: `Point`, `Line`, `Rectangle` (fills the parent) or `Oval` (the oval that fits the parent). |
| `EmissionShapeStyle` | enum | `Volume` | For `Rectangle` and `Oval`. `Volume` spawns anywhere inside, `Surface` only on the edge. |
| `EmissionOrigin` | vector2 | `(0.5, 0.5)` | For `Point`, where the point is. For `Line`, how far down the parent the line sits. `(0, 0)` is the top left, `(1, 1)` the bottom right. |
| `EmissionDirectionMode` | enum | `Angle` | How the direction is picked. `Angle` uses `EmissionAngle`. `AwayFromCenter` and `TowardCenter` aim along the line from the centre to the spawn point. `AwayFromEdge` aims out of the nearest edge. |
| `EmissionAngle` | number | `0` | Direction in degrees, clockwise from straight up. `90` is right, `180` is down. In the other direction modes it's added on top as an offset. |
| `SpreadAngle` | number | `0` | Degrees of random spread either side of the direction, across the screen. `180` or more sends particles every way. Negative values count the same as positive ones. |
| `DepthSpreadAngle` | number | `0` | Degrees of random tilt toward or away from the viewer. A flat screen can't show that motion, so tilted particles simply travel less far. A real emitter's cone looks like this from the front. |
| `Lifetime` | range | `1` to `2` | Seconds. As on a `ParticleEmitter`, `0` emits nothing and nothing lives past 20 seconds. |
| `Speed` | range | `5` to `5` | Studs per second. |

#### Motion

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `Acceleration` | vector2 | `(0, 0)` | Studs per second squared, with Y pointing up, so negative Y is gravity. It always acts in screen directions, however the parent is rotated. |
| `Drag` | number | `0` | Like `ParticleEmitter.Drag`: a particle loses half its speed every `1/Drag` seconds. It slows acceleration too, so gravity levels off at a top speed. |
| `VelocityInheritance` | number | `0` | How much of the parent's own movement a particle takes when it spawns. `1` means all of it. |
| `TurbulenceStrength` | number | `0` | Adds a random wobble, in studs per second squared. `0` turns it off. |
| `TurbulenceFrequency` | number | `1` | How tight the wobble pattern is, per stud. |
| `TurbulenceSpeed` | number | `1` | How quickly the wobble pattern changes over time. |
| `Rotation` / `RotSpeed` | range | `0` to `0` | Starting angle and spin speed in degrees, like `ParticleEmitter`. A positive value turns camera-facing particles counter-clockwise, which is what real emitters do. |
| `Orientation` | enum | `FacingCamera` | `FacingCamera` and `FacingCameraWorldUp` just spin by `Rotation`. `VelocityParallel` lines the particle's width up with its direction of travel. `VelocityPerpendicular` turns it a quarter turn from that. |

#### Appearance

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `Color` | colorseq | white | Colour over the particle's life. |
| `Transparency` | numseq | `0` | Transparency over the particle's life. |
| `Size` | numseq | `1` | Size over the particle's life, in studs. As on a real emitter, a `Size` of `1` is a particle 2 studs across. |
| `Squash` | numseq | `0` | Like `ParticleEmitter.Squash`. Positive values make the particle narrower and taller by `1 + Squash`, negative values wider and flatter. |
| `GlowStrength` | number | `0` | `0` to `1`. Draws a larger, brighter copy behind each particle. GUI has no additive blending, so this stands in for `LightEmission`. |

#### Depth

A fake third axis. Each particle picks a random depth when it spawns, and particles further away are drawn smaller and move slower.

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `Depth` | range | `0` to `0` | Positive values push particles away (smaller, slower), negative values bring them closer (bigger, faster). `0` to `0` turns it off. |
| `DepthTransparency` | numseq | `0` | Extra fade for particles further back in the `Depth` range. |

#### Colour by speed

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `UseSpeedColor` | bool | `false` | Turns the two sequences below on. |
| `SpeedColorRange` | range | `0` to `10` | The speeds, in studs per second, that `SpeedColor` and `SpeedTransparency` are spread across. |
| `SpeedColor` | colorseq | white | Multiplied into `Color` depending on how fast the particle is going. |
| `SpeedTransparency` | numseq | `0` | Added to `Transparency` depending on how fast the particle is going. |

#### Trails

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `TrailEnabled` | bool | `false` | Moving particles leave fading copies behind them. |
| `TrailLifetime` | number | `0.3` | Seconds each copy lasts. |
| `TrailInterval` | number | `0.03` | Seconds between copies. Smaller makes a denser trail. |

#### Flipbook

| Attribute | Type | Default | What it does |
|---|---|---|---|
| `FlipbookLayout` | enum | `None` | `None`, `Grid2x2`, `Grid4x4`, `Grid8x8` or `Grid16x16`. |
| `FlipbookMode` | enum | `OneShot` | `OneShot` plays the frames once over the particle's life. `Loop` repeats them. `PingPong` plays forward then backward. `Random` jumps to a random frame each step. |
| `FlipbookFramerate` | range | `20` to `20` | Frames per second, picked per particle. `OneShot` ignores it. |
| `FlipbookStartRandom` | bool | `false` | Start each particle on a random frame. |
| `FlipbookResolution` | number | `1024` | The texture's width and height in pixels. The sheet has to be square, and Roblox doesn't tell scripts a texture's size, so this has to be right for the frames to line up. |

---

## Scripting API

`require()` returns one shared `Spark2D` object for the whole client.

### `Spark2D:Init(root: Instance?)`

Finds every tagged folder under `root` (by default `LocalPlayer.PlayerGui`), starts them, and keeps watching for folders added or removed later. It returns `Spark2D`, so you can chain it:

```lua
local Spark2D = require(ReplicatedStorage.Spark2D):Init()
```

You only need it if you want Spark2D to find effects by itself. `Emit`, `Enable` and `StartEmitter` register a folder the first time they see it.

### `Spark2D:Emit(target: Instance?, count: number?)`

Fires one burst. `count` defaults to the folder's `BurstCount`. `target` can be:

- a folder, to emit just that effect;
- any container (a `Frame`, a `ScreenGui`), to emit every tagged folder inside it;
- nothing, to emit everything Spark2D knows about. If nothing is registered yet, it searches under the root passed to `Init()`, or the whole game if you never called `Init()`, so be deliberate with that one.

```lua
Spark2D:Emit(coinPickupGui.Burst, 12)   -- one effect
Spark2D:Emit(hitEffectsFolder)          -- everything inside a container
Spark2D:EmitAll()                       -- same as Emit(nil)
```

### `Spark2D:Enable(target)` / `Spark2D:Disable(target)`

Same targets as `Emit`. `Enable` sets `Enabled` to true and registers the folder. `Disable` sets it to false. Particles already on screen finish normally, so this is the gentle way to stop an effect.

```lua
Spark2D:Enable(torchIcon.Flame)
Spark2D:Disable(torchIcon.Flame)
Spark2D:EnableAll()
Spark2D:DisableAll()
```

### `Spark2D:IsEnabled(folder: Folder): boolean`

Whether a folder Spark2D has registered is currently enabled. It returns `false` for folders Spark2D hasn't seen yet.

### `Spark2D:SetTimeScale(scale: number)`

A global speed multiplier for every effect, on top of each folder's own `TimeScale`. `0` freezes everything.

```lua
Spark2D:SetTimeScale(0.25)   -- slow motion
task.wait(1)
Spark2D:SetTimeScale(1)
```

### `Spark2D:Pause()` / `Spark2D:Resume()`

Stops and restarts the update loop entirely. Particles freeze in place and cost nothing until you resume.

### `Spark2D:StartEmitter(folder: Folder, container: Instance?)`

Registers a folder without changing `Enabled` or spawning anything. Use it to warm up an effect's pool before its first burst, or to draw its particles somewhere else by passing a `container`. The container should cover the same area as the folder's parent. It only applies the first time the folder is registered.

```lua
Spark2D:StartEmitter(muzzleFlash, effectsOverlay)
```

### `Spark2D:Burst(folder: Folder, count: number?)`

One burst on exactly one folder. Unlike `Emit` it doesn't look for the tag, so it works on a folder you drive yourself.

### `Spark2D:Stop(folder: Folder)`

Stops one effect for good: disconnects it and destroys its particles. The folder and its attributes are left alone, and registering it again starts it fresh.

### `Spark2D:Destroy()`

Stops every effect and shuts the engine down.

### `Spark2D.ParticleSpawned` / `Spark2D.ParticleDied`

Signals fired with `(folder, x, y)` for every particle of every effect, so check `folder` if you only care about one. When the effect moves with its parent, `x, y` are studs from the parent's centre. Otherwise they're screen pixels.

```lua
local conn = Spark2D.ParticleSpawned:Connect(function(folder, x, y)
	if folder == critHitGui.Burst then
		playCritSound()
	end
end)
conn:Disconnect()
```

### `Spark2D.WarnUnparented`

`true` by default. Spark2D prints a warning when it registers a folder that has nothing to draw into. Set it to `false` if you register folders before parenting them on purpose.

### `Spark2D.AdaptiveQuality`

`true` by default. If frames start taking longer than about 1/45 of a second, Spark2D slowly lowers every effect's particle limit, down to a quarter, and raises it again once things recover. Set it to `false` to keep limits exactly as configured.

---

## Recipes

**A burst when the player takes damage**, reusing one folder:

```lua
local Spark2D = require(ReplicatedStorage.Spark2D)
local hitBurst = healthBar:WaitForChild("HitBurst")   -- Enabled = false

local function onDamage(amount)
	Spark2D:Emit(hitBurst, 20)
end
```

**An effect that runs while a buff is active:**

```lua
local aura = buffIcon:WaitForChild("Aura")   -- Enabled starts false

local function setBuffActive(active)
	if active then
		Spark2D:Enable(aura)
	else
		Spark2D:Disable(aura)   -- particles in flight finish normally
	end
end
```

**Sparks flying off the edges of a button**, using the edge direction mode:

```lua
sparks:SetAttribute("EmissionShape", "Rectangle")
sparks:SetAttribute("EmissionShapeStyle", "Surface")
sparks:SetAttribute("EmissionDirectionMode", "AwayFromEdge")
sparks:SetAttribute("SpreadAngle", 20)
sparks:SetAttribute("Acceleration", Vector2.new(0, -20))
```

**Cleaning up when a popup closes:**

```lua
local function closePopup(popupGui)
	for _, folder in popupGui:GetDescendants() do
		if folder:IsA("Folder") and folder:HasTag("UIParticleEmitter") then
			Spark2D:Stop(folder)
		end
	end
	popupGui:Destroy()
end
```

---

## Upgrading from 1.0.2 or earlier

1.0.3 renamed several attributes so they say what they do, and measures everything in studs relative to the parent instead of pixels.

- Old names still work at runtime: `EmitCount`, `EmitDelay`, `EmitDuration`, `LockedToGui`, `Origin`, `Glow`, `TurbulencePower` and `SpeedRange` are read when the new name isn't set. So are the old face-based `EmissionDirection`, a `Vector2` `SpreadAngle`, a `Vector3` `Acceleration`, and the `Circle`, `Ring` and `Border` shapes.
- Sizes don't carry over by themselves, because pixels and parent-relative studs aren't the same thing. The Studio plugin converts every effect in a place the first time it opens it, measuring each parent so the effect keeps its size. Effects built by scripts need their `Size`, `Speed` and `Acceleration` set with studs in mind, plus a `StudSize` if the default doesn't fit.

---

## Troubleshooting

**The `require` never returns.** Spark2D is waiting for `Cleaner`, `Signal` or `Pool`. Each one has to be the module's child (the `.rbxm` and plugin layout) or its sibling (the Wally layout).

**Nothing shows up.** The folder needs a `GuiObject` or `ScreenGui` above it, and every GuiObject above it has to be visible. Spark2D warns once when it registers a folder that isn't parented properly. Also check you're requiring it from a **LocalScript**.

**The effect is too big or too small.** Change `StudSize`. It scales sizes and speeds together, so the effect keeps its look.

**The effect changes size when the UI does.** That's the parent-relative sizing at work. If you want it tied to the screen instead, set `StudSizeRelativeTo` to `ScreenHeight`.

**`SpreadAngle` doesn't seem to fan particles out.** Check you didn't put the spread in `DepthSpreadAngle`, which shortens how far particles travel instead of spreading them across the screen.

**A flipbook shows one frame, or the frames are cut wrong.** A single frame means `FlipbookLayout` is `None`. Frames cut wrong means `FlipbookResolution` doesn't match the texture's real size.

**`Emit` does nothing on a folder that isn't under a GuiObject.** There's nowhere to draw, so no particles are made.

**`IsEnabled` returns `false` for an effect I enabled.** The folder hasn't been registered yet. Call `Init`, `Emit`, `Enable` or `StartEmitter` first.

**Effects run too fast or too slow after `SetTimeScale`.** The global time scale multiplies with each folder's own `TimeScale`, so check both.

**`MoveWithParent` doesn't seem to do anything.** You only see a difference when the parent moves while particles are alive.
