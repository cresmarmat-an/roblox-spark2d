# Changelog

## 1.0.2

### Changed

Effects now move and look the way a real `ParticleEmitter` does, seen from the
front. Each rule below was measured against real emitters in Studio.

- **`SpreadAngle`** spreads on two separate axes, as `ParticleEmitter` does,
  instead of averaging them into one fan. Only one axis fans particles across
  the screen — `.Y` for `Top`/`Bottom`/`Front`/`Back`, `.X` for `Left`/`Right`
  — and the other tilts them toward or away from the viewer, which shortens how
  far they travel on screen.
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
  time — a scale of `0.5` packed an effect into the top-left quarter of its
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
- Six emission shapes — `Point`, `Circle`, `Ring`, `Rectangle`, `Border` and
  `Line` — all measured against the parent GuiObject, so they resize with it.
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
