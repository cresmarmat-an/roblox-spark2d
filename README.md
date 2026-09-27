# Spark2D

Spark2D makes `ParticleEmitter`-style effects work inside a `ScreenGui`.

Roblox doesn't let a real `ParticleEmitter` live in 2D UI — there's nowhere to put one. Spark2D fakes it: emitter settings live as Attributes on a plain `Folder`, and the runtime plays them back with a pool of recycled `ImageLabel`s. From the player's side it looks and moves like a particle effect. Under the hood it's just Attributes and UI elements you can inspect in the Properties window.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Spark2D = require(ReplicatedStorage.Spark2D):Init()

Spark2D:Emit(healthBar.HitBurst, 20)
```

---

## Features

- **Familiar model** — mirrors `ParticleEmitter`: `Rate`, `Lifetime`, `Speed`, `SpreadAngle`, `Color`/`Transparency`/`Size` sequences, `EmissionDirection`, flipbooks
- **Behaves like the real thing** — `SpreadAngle`, `Drag`, `Squash`, `Rotation`, `Orientation` and `Lifetime` follow the rules a real `ParticleEmitter` uses, measured against one in Studio, so an effect looks the way that emitter does seen from the front
- **Placed from the parent's `AbsolutePosition`, `AbsoluteSize` and `AbsoluteRotation`** — a `UIScale`, a rotated parent or a layout all land particles where they belong
- **No custom instance types** — an effect is a `Folder` tagged `UIParticleEmitter` carrying Attributes, readable and editable in the normal Properties/Attributes window
- **Pooled rendering** — `ImageLabel`s are recycled rather than created and destroyed per particle
- **Adaptive quality** — tracks rolling frame time and scales particle counts back under load, recovering as frame time improves
- **2D-native extras** — trails, a fake `Depth` axis, speed-driven colour, turbulence, velocity inheritance, and a faked `Glow`
- **Two sizing modes** — `Scale` measures particles against the parent GuiObject, `Offset` gives fixed pixel sizes
- **Client-side and self-contained** — one module plus `Cleaner`, no other dependencies

---

## Installation

**[Wally](https://wally.run/package/cresmarmat-an/spark2d)** — add it to your `wally.toml`:

```toml
[dependencies]
Spark2D = "cresmarmat-an/spark2d@LATEST_VERSION"
```

**Roblox Studio** — download `Spark2D.rbxm` from [Releases](https://github.com/cresmarmat-an/roblox-spark2d/releases) and drag it onto `ReplicatedStorage`. It arrives as one module with `Cleaner` inside it:

```
ReplicatedStorage/
   Spark2D
      Cleaner
```

**[Studio plugin](https://create.roblox.com/store/asset/134544269563881/Spark2D)** — a companion plugin builds and previews effects visually instead of setting Attributes by hand, and its INSTALL button places the runtime for you in the same shape. It isn't publicly listed yet; until it is, everything here works from a script.

Leave `Cleaner` where the installer put it. `Spark2D` looks for it as its own child first and falls back to a sibling, which is how the Wally layout resolves — so both arrangements work, but deleting or relocating it does not.

Spark2D drives `PlayerGui` and hooks `RunService`, so `require` it from a **LocalScript**.

---

## Creating an effect

An effect is a `Folder` tagged `UIParticleEmitter`, parented anywhere under a `GuiObject`. Everything else is Attributes — anything you don't set falls back to the default in the [attribute reference](#attribute-reference).

```lua
local CollectionService = game:GetService("CollectionService")

local burst = Instance.new("Folder")
burst.Name = "HitBurst"
burst:SetAttribute("Enabled", false)          -- burst-only; no continuous stream
burst:SetAttribute("EmitCount", 20)
burst:SetAttribute("Lifetime", NumberRange.new(0.4, 0.8))
burst:SetAttribute("Speed", NumberRange.new(8, 14))
burst:SetAttribute("Size", NumberSequence.new(0.15))
burst:SetAttribute("Color", ColorSequence.new(Color3.fromRGB(255, 200, 80)))
burst.Parent = healthBar                       -- a Frame

CollectionService:AddTag(burst, "UIParticleEmitter")

Spark2D:Emit(burst)
```

The folder needs a `GuiObject` above it to render — `EmissionShape`, `Origin` and `Scale` sizing are all measured against that parent's `AbsoluteSize`. A folder sitting loose under `StarterGui` has nothing to measure against and won't emit.

---

## Attribute reference

Every `UIParticleEmitter` folder is just a bag of Attributes. This is the full list.

#### General

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `Enabled` | bool | `true` | Continuous emission on/off. Doesn't touch particles already in flight — they finish out their `Lifetime` normally either way. |
| `Texture` | string | sparkle asset | Any content ID. |
| `Rate` | number | `20` | Particles per second while `Enabled`. |
| `EmitCount` | number | `20` | Default burst size — used by `Spark2D:Emit()` when you don't pass a count. |
| `MaxParticles` | number | `1000` | Hard cap for this emitter. Also scaled down automatically under load — see `AdaptiveQuality`. |
| `EmitDelay` | number | `0` | Seconds to wait after `Enabled` turns true before the stream actually starts. |
| `EmitDuration` | number | `0` | Seconds the stream stays open after the delay. `0` means it never cuts itself off. |
| `TimeScale` | number | `1` | Per-emitter speed multiplier. There's *also* a global one (`Spark2D:SetTimeScale`) — they multiply together, so it's easy to double up by mistake if you forget one exists. |
| `ZIndex` | number | `2` | Draw order. Glow copies and trail ghosts render one below this automatically. |
| `LockedToGui` | bool | `true` | Mirrors `ParticleEmitter.LockedToPart`. `true`: particles stay glued to their parent GuiObject, so the whole cloud moves, scales and turns with it. `false`: particles are placed once in screen space and left there, drifting on their own — the classic "trail left behind a moving thing" look. |
| `SizingMode` | enum | `Scale` | Decides what the `Size` sequence is measured in. `Scale`: `Size` is a straight fraction of the parent GuiObject's **current** size, exactly like `UDim2.fromScale` — `1` means the particle covers the whole parent, `0.25` means a quarter of it. Particles track the parent live, so a `UIScale` or a responsive layout carries them along, and `SizePixels` plays no part. `Offset`: `Size` is a multiplier on `SizePixels`, giving a fixed pixel size that ignores the parent entirely. |
| `PerfectSquare` | bool | `false` | Forces every particle to render square on screen, the same guarantee a `UIAspectRatioConstraint` gives. Off, a `Size` of `1` on a 200×100 parent is a 200×100 rectangle, and `Squash` stretches particles by design. On, both axes are set from the smaller of the two, so the particle stays square *and* stays inside the box. Applies under both sizing modes. |

#### Emission

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `EmissionShape` | enum | `Circle` | `Point`, `Circle`, `Ring`, `Rectangle`, `Border`, `Line`. `Circle` is a filled circle inscribed in the parent GuiObject; `Ring` is just its edge. Both size themselves off the container automatically, same as `Rectangle`/`Border`. `Point`/`Circle`/`Ring` are centered on `Origin`; `Rectangle`/`Border`/`Line` span the whole parent regardless of `Origin`. |
| `EmissionDirection` | enum | `Top` | `Top`/`Bottom`/`Left`/`Right`/`Front`/`Back`, relative to the parent GuiObject — a rotated parent turns it, like a rotated part. `Front` and `Back` both fold onto the screen's up/down axis, same as `Top`/`Bottom` — there's no depth axis to point along in flat UI. |
| `SpreadAngle` | vector2 | `(0,0)` | Degrees either side of `EmissionDirection`, one axis each, exactly as a `ParticleEmitter` spreads them — and then seen from the front. Only one axis fans particles across the screen: `.Y` for `Top`/`Bottom`/`Front`/`Back`, `.X` for `Left`/`Right`. The other tilts particles toward and away from the viewer, which on a flat screen shows up as some of them travelling a shorter way instead of fanning out. `360` on both covers every direction. |
| `Origin` | vector2 | `(0.5, 0.5)` | Fractional anchor within the parent's bounds for `Point`/`Circle`/`Ring`, and the height of a `Line` — `(0,0)` top-left, `(1,1)` bottom-right. |
| `Lifetime` | range | `1–2` | Seconds. As on a `ParticleEmitter`, a lifetime of `0` emits nothing and nothing lives past 20 seconds. |
| `Speed` | range | `5–5` | Scaled by `PixelsPerStud` to get an actual on-screen speed. |

#### Motion

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `Acceleration` | vector3 | `(0,0,0)` | `X`/`Y` used, `Y` inverted to match screen coordinates (so a normal "gravity" value that's negative in 3D correctly pulls particles *down* the screen). Like a `ParticleEmitter`'s, it's world-space: down stays down the screen however the parent is turned. `Z` points at the viewer and doesn't move anything on a flat screen. |
| `Drag` | number | `0` | `ParticleEmitter`'s drag: a particle's speed halves every `1/Drag` seconds. It slows acceleration too, so gravity settles at a terminal speed instead of building forever. Motion is worked out exactly rather than frame by frame, so it follows the same path at any frame rate. |
| `WindAcceleration` | vector2 | `(0,0)` | A flat push applied to every particle in this emitter, on top of `Acceleration`. |
| `VelocityInheritance` | number | `0` | How much of the parent GuiObject's *own* on-screen motion gets added to a particle's velocity the instant it spawns. Above `0` on something moving (a flying projectile icon, a dragged card), newly spawned particles fling off in the direction it's travelling. |
| `TurbulencePower` / `TurbulenceFrequency` / `TurbulenceSpeed` | number | `0` / `1` / `1` | Perlin-noise wobble layered into acceleration. Power is strength (`0` = off), Frequency is how tightly-packed the noise field is in space, Speed is how fast it evolves over time. |
| `Rotation` / `RotSpeed` | range | `0–0` / `0–0` | Initial spin and spin speed, degrees, turning the way a `ParticleEmitter`'s particles do: counter-clockwise for a positive value on camera-facing particles, clockwise from the direction of travel on velocity-aligned ones. Camera-facing particles keep their own rotation on screen even inside a rotated parent, as billboards do. |
| `Orientation` | enum | `Free` | The `ParticleEmitter` modes, seen from the front. `Free`, `FacingCamera` and `FacingCameraWorldUp` face the viewer and spin by `Rotation`. `VelocityParallel` lays the particle's width along its direction of travel — good for streaks and sparks that should point where they're going. `VelocityPerpendicular` faces the particle along its direction of travel, so, as with a real emitter seen side-on, one crossing the screen shows as a thin sliver and only opens up when `SpreadAngle` tilts it toward the viewer. |

#### Appearance

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `Color` | colorseq | white | |
| `Transparency` | numseq | `0` | |
| `Size` | numseq | `0.2` | The size multiplier over the particle's lifetime. What it multiplies depends on `SizingMode`. Quickest way to see the difference: set `Size` to `1` and toggle `SizingMode` — under `Scale` the particle exactly fills the parent, under `Offset` it's `SizePixels` across. |
| `SizePixels` | number | `100` | How many pixels a `Size` value of `1` maps to. **`Offset` sizing only** — ignored under `Scale`, where `Size` is already a fraction of the parent. A `ParticleEmitter` particle of `Size` `1` is 2 studs across, so `2 × PixelsPerStud` keeps an effect in the same proportions as the real one — which is what the defaults (`100` and `50`) already do. |
| `PixelsPerStud` | number | `50` | Same conversion, but for `Speed` and `Acceleration`. Because there's no real camera distance in a GUI, both of these are just tuning constants — "1 stud" doesn't mean anything fixed on screen. |
| `Squash` | numseq | `0` | `ParticleEmitter`'s squash: positive narrows the particle by `1 + Squash` and makes it that much taller, negative does the reverse, and `-1` mirrors `1`. |
| `Glow` | number | `0` | `0`–`1`. Draws a second copy behind each particle, brightened and scaled up ~1.9x, faded by this amount. It's the closest thing to `LightEmission` that's possible here — GUI has no real additive blend mode, so this is a faked bloom, not the real thing. |

#### Depth

A fake third axis. There's no real perspective in a flat GUI, so this is a per-particle size/speed/fade trick that reads as "distance" without actually being one.

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `Depth` | range | `0–0` | Each particle picks a random value in this range at spawn. Positive shrinks and slows it down (reads as farther away); negative grows and speeds it up (reads as closer). Leave both ends at `0` and this whole system is a no-op. |
| `DepthTransparency` | numseq | `0` | Extra fade layered on top of the normal `Transparency`, scaled by how far into the `Depth` range a given particle landed. Only has any effect once `Depth.Min` and `Depth.Max` actually differ. |

#### Speed Colour

Recolor or fade particles based on how fast they're currently moving, independent of their age-based `Color`/`Transparency`.

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `UseSpeedColor` | bool | `false` | Off by default — the two sequences below do nothing until this is on. |
| `SpeedRange` | range | `0–1000` | The speed window `SpeedColor`/`SpeedTransparency` get mapped across — slowest to fastest you expect a particle to move. |
| `SpeedColor` | colorseq | white | Multiplied against the normal `Color` at the particle's current speed. |
| `SpeedTransparency` | numseq | `0` | Added on top of the normal `Transparency` at the particle's current speed. |

#### Trails

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `TrailEnabled` | bool | `false` | |
| `TrailLifetime` | number | `0.3` | Seconds each fading ghost copy sticks around. |
| `TrailInterval` | number | `0.03` | How often, in seconds, a moving particle drops a ghost behind it. Smaller = denser trail, more instances in flight. |

#### Flipbook

| Attribute | Type | Default | Notes |
|---|---|---|---|
| `FlipbookLayout` | enum | `None` | `None`, `Grid2x2`, `Grid4x4`, `Grid8x8`, `Grid16x16`. |
| `FlipbookMode` | enum | `OneShot` | See below. |
| `FlipbookFramerate` | range | `20–20` | Frames per second, randomized per particle across the range. Ignored entirely in `OneShot` mode. |
| `FlipbookStartRandom` | bool | `false` | Start each particle on a random frame instead of frame 1. |
| `FlipbookResolution` | number | `1024` | The texture's actual pixel width *and* height — it has to be square. This is the one piece of flipbook data Spark2D genuinely can't work out on its own: Roblox doesn't expose an uploaded texture's pixel dimensions to a script, so if this doesn't match your sheet the frame slicing will be off even though everything else is configured correctly. |

`FlipbookMode` behavior, since it's not obvious from the name alone:

- **Loop** — plays through all frames and wraps back to the start, forever, for as long as the particle is alive.
- **OneShot** — plays through the strip exactly once, start to finish, timed to the particle's own `Lifetime` rather than `FlipbookFramerate` (so a shorter-lived particle just plays the animation faster). This is the default, and the right choice for most one-off effects like an impact or a puff — you very rarely want an explosion sprite to loop.
- **PingPong** — plays forward to the last frame, then backward to the first, repeating.
- **Random** — jumps to a random frame each tick at `FlipbookFramerate`, rather than stepping through in order. Good for flickery, chaotic things like static or embers where a fixed sequence would look too mechanical.

---

## Scripting API

Everything below hangs off the module returned by `require()` — a singleton, not something you construct per-effect. One `Spark2D` per client, same as `require`ing any other shared service module.

### `Spark2D:Init(root: Instance?)`

Scans `root` (default: `LocalPlayer.PlayerGui`) for tagged folders, registers them, and starts watching `root` for folders added or removed later. Returns `Spark2D` itself, so it chains:

```lua
local Spark2D = require(ReplicatedStorage.Spark2D):Init()
```

You only need this if you want Spark2D to *discover* effects on its own. If your own code already holds a direct reference to a specific folder and just calls `Emit`/`Enable` on it, you can skip `Init()` entirely — those calls register the folder themselves the first time they see it.

### `Spark2D:Emit(target: Instance?, count: number?)`

Fires one burst. `count` defaults to the folder's `EmitCount` attribute.

`target` accepts three things:

- **a specific folder** — emits just that one.
- **any container** (a `ScreenGui`, a `Frame`, anything) — emits every `UIParticleEmitter` folder found anywhere inside it.
- **nothing** — emits everything Spark2D currently knows about, or if nothing's registered yet, everything tagged under the root passed to `Init()` (or the whole `game` if you never called `Init()` — worth being deliberate about this one, since an untargeted `Emit()` before `Init()` will walk the entire DataModel looking for tagged folders).

```lua
-- one specific effect
Spark2D:Emit(coinPickupGui.Burst, 12)

-- everything inside a container at once
Spark2D:Emit(hitEffectsFolder)

-- shorthand for Emit(nil)
Spark2D:EmitAll()
```

### `Spark2D:Enable(target)` / `Spark2D:Disable(target)`

Same `target` rules as `Emit`. `Enable` sets `Enabled = true` on the attribute (and registers the folder if it isn't already); `Disable` sets it `false`. This is a *soft* stop — particles already on screen play out their remaining `Lifetime` normally, nothing gets yanked off screen or destroyed. If you want an effect to genuinely go quiet, this is almost always what you want instead of `Stop`.

```lua
-- a torch that's lit while equipped
Spark2D:Enable(torchIcon.Flame)
-- ...later
Spark2D:Disable(torchIcon.Flame)

Spark2D:EnableAll()
Spark2D:DisableAll()
```

### `Spark2D:IsEnabled(folder: Folder): boolean`

Checks Spark2D's own tracked state for that folder, not the live attribute — so this only returns something meaningful for a folder Spark2D has already registered (via `Init`, `Emit`, `Enable`, or `StartEmitter`). Calling it on a folder Spark2D hasn't touched yet returns `false` even if the attribute itself says `true`.

### `Spark2D:SetTimeScale(scale: number)`

A *global* speed multiplier across every emitter, multiplied together with each folder's own `TimeScale` attribute. `0` effectively freezes everything (aging, motion, spawning) without pausing the loop itself.

```lua
-- slow-motion on a big hit
Spark2D:SetTimeScale(0.25)
task.wait(1)
Spark2D:SetTimeScale(1)
```

### `Spark2D:Pause()` / `Spark2D:Resume()`

A harder version of `SetTimeScale(0)` — skips the update loop entirely rather than running it with a zero delta. Good for a cutscene or a menu where you want particles to freeze in place and not cost anything per frame, then pick back up exactly where they left off.

### `Spark2D:StartEmitter(folder: Folder, container: Instance?)`

Registers a folder without touching its `Enabled` attribute or spawning anything — it just gets its object pool warmed up and starts being tracked. Two reasons to reach for this instead of `Emit`/`Enable`:

- **Pre-warming.** Registering ahead of time means the first real `Emit()` call doesn't pay for pool allocation in that frame.
- **A custom `container`.** By default, particles are parented directly under the `UIParticleEmitter` folder itself. Pass a `container` to redirect them somewhere else — useful if you want particles from several different effects landing in one dedicated overlay `Frame` whose `ZIndex`/`ClipsDescendants` you control. This only takes effect on first registration, so call `StartEmitter` with your container *before* the first `Emit`/`Enable` call on that folder, not after.

```lua
Spark2D:StartEmitter(muzzleFlash, effectsOverlay)
```

### `Spark2D:Burst(folder: Folder, count: number?)`

One burst on exactly one folder, registering it if it isn't already. Unlike `Emit`, it skips target resolution entirely — no container walking, and no requirement that the folder carry the `UIParticleEmitter` tag — so it also works for a folder you're driving directly. `count` defaults to `EmitCount`.

### `Spark2D:Stop(folder: Folder)`

A hard teardown for one emitter: disconnects its listeners, destroys every pooled and active `ImageLabel` it owns, forgets about it entirely. The folder and its attributes are untouched — only Spark2D's tracking of it goes away. Register it again later (`Emit`, `Enable`, `StartEmitter`, or a fresh `Init()` scan) and it starts over clean.

### `Spark2D:Destroy()`

Stops every emitter and tears down the whole engine — connections, pools, the update loop, all of it. Call this wherever you'd naturally clean up client state: `Players.LocalPlayer.CharacterRemoving`, leaving a place-based minigame, that kind of thing.

### `Spark2D.ParticleSpawned` / `Spark2D.ParticleDied`

Two events, fired `(folder, x, y)`. These are global across every emitter, not per-folder — filter on `folder` if you only care about one effect.

```lua
local conn = Spark2D.ParticleSpawned:Connect(function(folder, x, y)
	if folder == critHitGui.Burst then
		playCritSound()
	end
end)

-- later
conn:Disconnect()
```

`x, y` are in whatever coordinate space that particular folder's `LockedToGui` puts it in — local offsets from the parent GuiObject when `true`, absolute screen pixels when `false`. Worth checking which one you're dealing with before doing anything positional with these numbers.

### `Spark2D.WarnUnparented`

A plain boolean field, `true` by default. When a folder is registered with nothing renderable above it, Spark2D warns once in the output. That's usually what you want in a game, where an unparented effect is a bug. Set it `false` if you're deliberately registering folders before they're parented.

### `Spark2D.AdaptiveQuality`

A plain boolean field, not a method — `true` by default. When on, Spark2D tracks a rolling average frame time and, if it creeps past roughly 45fps worth of frame budget, gradually scales every emitter's effective `MaxParticles` down (to a floor of 25%), recovering gradually once frame time improves. Set it to `false` if you'd rather particle counts stayed exactly as configured no matter what else is happening on screen:

```lua
Spark2D.AdaptiveQuality = false
```

---

## Recipes

A few complete, working patterns.

**A one-off burst on damage taken**, reusing the same folder every time rather than creating one per hit:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Spark2D = require(ReplicatedStorage.Spark2D)

local healthBar = script.Parent -- a Frame
local hitBurst = healthBar:WaitForChild("HitBurst") -- a UIParticleEmitter folder, Enabled = false

local function onDamage(amount)
	Spark2D:Emit(hitBurst, 20)
end
```

**A continuously-running effect toggled by game state**, like a buff icon that should visibly pulse the whole time it's active:

```lua
local Spark2D = require(ReplicatedStorage.Spark2D)
local aura = buffIcon:WaitForChild("Aura") -- Enabled starts false

local function setBuffActive(active)
	if active then
		Spark2D:Enable(aura)
	else
		Spark2D:Disable(aura) -- lets particles already in flight finish naturally
	end
end
```

**Cleaning up when a piece of UI goes away.** Spark2D doesn't automatically stop an emitter just because its folder gets destroyed later in the same frame it was spawning — call `Stop` explicitly when you know you're done with it:

```lua
local Spark2D = require(ReplicatedStorage.Spark2D)

local function closePopup(popupGui)
	for _, folder in popupGui:GetDescendants() do
		if folder:IsA("Folder") and folder:HasTag("UIParticleEmitter") then
			Spark2D:Stop(folder)
		end
	end
	popupGui:Destroy()
end
```

**Slow-motion on a big moment**, using the global time scale so you don't have to touch every effect's own `TimeScale`:

```lua
local Spark2D = require(ReplicatedStorage.Spark2D)

local function bulletTimeHit()
	Spark2D:SetTimeScale(0.2)
	Spark2D:Emit(killcamFlash)
	task.delay(1.5, function()
		Spark2D:SetTimeScale(1)
	end)
end
```

---

## Troubleshooting

**The `require` never returns.** `Spark2D` needs `Cleaner` either as its own child (how the `.rbxm` and the plugin install it) or as a sibling (how Wally installs it). If `Cleaner` was deleted, or moved somewhere that is neither, the `WaitForChild` never completes.

**Nothing renders.** The folder needs a `GuiObject` (or a `ScreenGui`/`SurfaceGui`/`BillboardGui`) somewhere above it in the hierarchy — a folder sitting directly under `StarterGui` won't emit anything. Spark2D warns once in the output when it registers a folder that isn't parented correctly yet.

**Nothing renders, and there's no warning either.** Check you're requiring from a **LocalScript**. Spark2D drives `PlayerGui` and hooks `RunService`; it does nothing useful on the server.

**An effect ported from a 3D `ParticleEmitter` moves too fast or too slow.** `PixelsPerStud`. There's no camera distance in a flat GUI, so "1 stud" from the original effect doesn't correspond to any fixed number of pixels — the numeric values carry over faithfully, but you still have to pick a scale.

**An effect ported from 3D is enormous.** Sizing mode. A 3D emitter's `Size` values are stud-scaled, and under the default `Scale` sizing a `Size` of `1` already means "the parent's whole size" — so a `Size` of `3` is three times the parent and fills the screen. Either scale the `Size` sequence down, or switch `SizingMode` to `Offset` and set `SizePixels` to twice `PixelsPerStud`, which keeps the real emitter's proportions.

**Particles only fill part of their frame under a `UIScale`.** Fixed in 1.0.1. Spark2D measured the parent in on-screen pixels, which already include the `UIScale`, then placed particles with offsets that the `UIScale` shrank a second time — a scale of `0.5` packed the effect into the top-left quarter. Update the runtime.

**An effect built on 1.0.0 looks different after updating.** 1.0.2 made the flat simulation follow a real `ParticleEmitter`'s rules, and a few differ from what 1.0.0 did:
- `SpreadAngle`: only one axis fans particles across the screen now (`.Y` for `Top`/`Bottom`, `.X` for `Left`/`Right`); the other shortens their travel instead. Put the fan you want on that axis.
- `Rotation`/`RotSpeed` on camera-facing particles turn the other way — negate them to get the old direction back.
- `FacingCamera` spins by `Rotation` like `Free` instead of staying upright; set `Rotation` and `RotSpeed` to `0` for upright particles.
- `VelocityParallel` lines the particle's width up with its travel instead of its height; a streak texture drawn vertically wants turning 90°, or `Rotation` set to `90`.
- `Squash` narrows for positive values instead of widening, and `Drag` is gentler — a particle keeps half its speed after `1/Drag` seconds.

**Particles got much bigger after updating Spark2D.** `Scale` sizing changed meaning. `Size` used to be multiplied by `SizePixels` and then divided by the parent's size; it's now read directly as a fraction of the parent. An effect built under the old behaviour wants its `Size` sequence divided by roughly the parent's size in pixels — or switch it to `Offset`, where `SizePixels` works exactly as it always did.

**A flipbook plays as a static image, or the frames look sliced wrong.** Two different causes, worth telling apart:
- If it's fully static, `FlipbookLayout` is `None`, or the sheet isn't one of the supported square grids (2×2 through 16×16).
- If it's animating but the frames are cut wrong, `FlipbookResolution` doesn't match the texture's real pixel dimensions. Fix the number on the folder directly.

**`Emit` does nothing for a folder that isn't under a `GuiObject`.** Working as intended: there's no `GuiObject` to measure against and nowhere to draw, so no particle is spawned.

**`IsEnabled` returns `false` for something I know is enabled.** It's reporting Spark2D's tracked state, not the live attribute — the folder needs to have been registered at least once (`Init`, `Emit`, `Enable`, or `StartEmitter`) before this means anything.

**Particles from one effect are triggering `ParticleSpawned` handlers meant for another.** The event is global by design — always check the `folder` argument against the specific folder you care about.

**Effects play twice as fast (or twice as slow) as expected after calling `SetTimeScale`.** Check whether the folder *also* has a non-`1` `TimeScale` attribute set — the global and per-emitter scales multiply together, so it's easy to stack them without meaning to.

**Toggling `LockedToGui` doesn't seem to do anything.** It only has a visible effect once the parent GuiObject actually *moves* while particles are alive — with `LockedToGui = true` the cloud moves with it, with `false` particles stay behind at the spot they were emitted. If you're testing on a parent that never moves, both settings look identical, because there's nothing for either of them to disagree about yet. Animate or drag the parent's `Position` while `Enabled` (or right after an `Emit`) to actually see the difference.
