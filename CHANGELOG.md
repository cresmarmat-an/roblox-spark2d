# Changelog

## 1.0.3-alpha

An early look at the next version. Effects are measured relative to their
parent now, and several attributes have new names, so read the notes on
upgrading below before switching a game over.

### Changed

- Everything is sized relative to the parent GuiObject. Particles are placed
  with Scale values worked out from the parent's `AbsolutePosition`,
  `AbsoluteSize` and `AbsoluteRotation`, so an effect keeps its proportions on
  every screen size, under a `UIScale` and in layouts, without any setup.
- Sizes, speeds and accelerations are in studs, like `ParticleEmitter`. A stud
  is a fraction of the parent, set by the new `StudSize` and
  `StudSizeRelativeTo` attributes. `SizingMode`, `SizePixels`, `PixelsPerStud`
  and `PerfectSquare` are gone. `Size` is in studs and defaults to `1`.
- The direction is an angle. `EmissionAngle` replaces the six-face
  `EmissionDirection`, so an effect can point any way, not just along the four
  sides of the screen.
- `SpreadAngle` is a single number: how far particles fan out across the
  screen. It's the same either side, and `-360` and `360` both mean every
  direction. The new `DepthSpreadAngle` tilts particles toward and away from the
  viewer, which makes some of them travel less far, the way a real emitter's
  cone looks from the front.
- Clearer attribute names: `BurstCount` (was `EmitCount`), `StartDelay`
  (`EmitDelay`), `StopAfter` (`EmitDuration`), `MoveWithParent`
  (`LockedToGui`), `EmissionOrigin` (`Origin`), `GlowStrength` (`Glow`),
  `TurbulenceStrength` (`TurbulencePower`) and `SpeedColorRange`
  (`SpeedRange`).
- `Acceleration` is a `Vector2`. `WindAcceleration` is gone, since
  `Acceleration` does the same job.
- Emission shapes are `Point`, `Line`, `Rectangle` and `Oval`, with
  `EmissionShapeStyle` choosing between the whole area (`Volume`) and just the
  edge (`Surface`). The oval fills the parent.
- `VelocityPerpendicular` turns particles a quarter turn from
  `VelocityParallel` instead of showing them edge-on. `Free` is now just
  `FacingCamera`, which is the default.

### Added

- `EmissionDirectionMode`: send particles `AwayFromCenter`, `TowardCenter` or
  `AwayFromEdge`, in addition to a fixed `Angle`.
- `ReduceOnLowGraphics` lowers the rate on low graphics settings, the way
  Roblox thins out real particle effects. On by default.
- `ResampleMode` for pixel art textures.
- Particles stop updating while their parent or ScreenGui is hidden.
- Particles are drawn into their own frame inside the folder and never block
  clicks on the UI around them.
- A fast stream spawns particles spread through the frame instead of in one
  clump per frame.
- Spark2D now uses the [Signal](https://github.com/cresmarmat-an/roblox-signal)
  and [Pool](https://github.com/cresmarmat-an/roblox-pool) packages alongside
  [Cleaner](https://github.com/cresmarmat-an/roblox-cleaner). The release
  `.rbxm` includes all three.

### Upgrading

- Old attribute names are still read when the new one isn't set, including the
  old `EmissionDirection`, a `Vector2` `SpreadAngle`, a `Vector3`
  `Acceleration` and the `Circle`, `Ring` and `Border` shapes.
- Sizes don't carry over by themselves. The Studio plugin converts every effect
  in a place when it opens it, measuring each parent so the effect keeps its
  size. Effects built from scripts need their sizes and speeds set in studs.

## 1.0.2

### Changed

Effects now move and look the way a real `ParticleEmitter` does, seen from the
front. Each rule below was measured against real emitters in Studio.

- **`SpreadAngle`** spreads on two separate axes, as `ParticleEmitter` does,
  instead of averaging them into one fan. Only one axis fans particles across
  the screen (`.Y` for `Top`/`Bottom`/`Front`/`Back`, `.X` for `Left`/`Right`).
  The other tilts them toward or away from the viewer, which shortens how far
  they travel on screen.
- **`Drag`** halves a particle's speed every `1/Drag` seconds and slows
  acceleration too, so gravity settles at a terminal speed. Motion is
  integrated exactly, so the path no longer depends on frame rate.
- **`Squash`** narrows particles and makes them taller for positive values,
  and widens them for negative ones, with `-1` mirroring `1`. It used to do the
  reverse, and collapsed as it approached `-1`.
- **`Rotation`/`RotSpeed`** turn camera-facing particles counter-clockwise for
  positive values, and **`FacingCamera`** spins by `Rotation` like `Free`
  instead of pinning particles upright. `FacingCameraWorldUp` is accepted too.
- **`VelocityParallel`** lays a particle's width along its direction of travel,
  and **`VelocityPerpendicular`** shows it edge-on while it crosses the screen.
  Both are foreshortened as `SpreadAngle` tilts particles toward the viewer.
- **`Lifetime`**: a lifetime of `0` emits nothing, and nothing lives past 20
  seconds.
- Each particle rolls its `Size`, `Transparency` and `Squash` envelopes
  separately rather than sharing one roll.

### Fixed

- **Rotated parents.** Placement is worked out from the parent's
  `AbsolutePosition`, `AbsoluteSize` and `AbsoluteRotation`. Emission turns with
  the parent like a rotated part's. Unlocked particles stay where they were
  emitted while the parent turns. Acceleration stays world-space, so down is
  still down the screen. Camera-facing particles stay upright on screen rather
  than turning with the parent.
- `VelocityInheritance` is turned into the parent's own frame before it's
  added, so inside a rotated parent particles are flung the way the parent is
  actually moving on screen.

## 1.0.1

### Fixed

- **Effects under a `UIScale` only filled part of their frame** ([#1](https://github.com/cresmarmat-an/roblox-spark2d/issues/1)).
  Spark2D measured the parent in on-screen pixels, which already include the
  `UIScale`, then placed particles with offsets the `UIScale` shrank a second
  time. A scale of `0.5` packed an effect into the top-left quarter of its
  frame. Emission areas, motion and inherited velocity are now all worked out in
  the parent's own unscaled pixels, whether the `UIScale` sits on the parent, on
  an ancestor or on the `ScreenGui`, and with `LockedToGui` on or off.
- Particle positions and pixel sizes are rounded to the nearest pixel rather
  than truncated, which had made every particle up to a pixel too small and
  pulled those left of or above their anchor a pixel toward it.

## 1.0.0

First release.

- Renders `ParticleEmitter`-style effects inside a `ScreenGui`. An effect is a
  plain `Folder` tagged `UIParticleEmitter` carrying Attributes, drawn with a
  pool of recycled `ImageLabel`s.
- Mirrors the `ParticleEmitter` property set: `Rate`, `Lifetime`, `Speed`,
  `SpreadAngle`, `EmissionDirection`, `EmitDelay`/`EmitDuration`, `Drag`,
  `Acceleration`, `Rotation`/`RotSpeed`, `Squash`, and the `Color`,
  `Transparency` and `Size` sequences.
- Six emission shapes: `Point`, `Circle`, `Ring`, `Rectangle`, `Border` and
  `Line`. All are measured against the parent GuiObject, so they resize with it.
- Two sizing modes. `Scale` reads `Size` as a fraction of the parent, tracking
  it live through `UIScale` and responsive layouts; `Offset` reads it as a
  multiplier on `SizePixels` for a fixed pixel size.
- Effects that only make sense in 2D: trails, a fake `Depth` axis, speed-driven
  colour and transparency, Perlin turbulence, velocity inheritance from a moving
  parent, and a faked `Glow` standing in for `LightEmission`.
- Flipbook playback across square grids from 2×2 to 16×16, in `Loop`,
  `OneShot`, `PingPong` and `Random` modes.
- `AdaptiveQuality` watches rolling frame time and scales every emitter's
  effective `MaxParticles` down to a floor of 25% under load, recovering as
  frame time improves.
- `Init`, `Emit`, `Enable`/`Disable`, `IsEnabled`, `SetTimeScale`,
  `Pause`/`Resume`, `StartEmitter`, `Burst`, `Stop` and `Destroy` make up the
  API, alongside the `ParticleSpawned` and `ParticleDied` events.
