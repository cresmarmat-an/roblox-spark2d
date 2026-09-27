# Changelog

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

### Added

- **3D mode.** Set `SimulationMode` to `3D` and particles move in X, Y and Z and
  are projected onto the screen through a virtual camera, so an effect copied
  from a real `ParticleEmitter` looks the way it did in the world. It follows
  `ParticleEmitter`'s own rules, measured against real emitters in Studio:
  - `Front`/`Back` point away from and toward the viewer, and each
    `SpreadAngle` axis spreads on its own axis rather than being averaged.
  - `Acceleration.Z` is used.
  - `Drag` halves speed every `1/Drag` seconds and damps acceleration too,
    integrated exactly, so the result doesn't depend on frame rate.
  - `Squash`, `Rotation` direction and the `VelocityParallel` /
    `VelocityPerpendicular` orientations match `ParticleEmitter`, including
    foreshortening as particles travel toward the camera.
  - `Size` is in studs, with a `Size` of `1` drawing a 2-stud particle.
  - Lifetimes are capped at 20 seconds.
- New 3D attributes: `EmitterSize` and `EmitterRotation` describe the emitting
  part and its orientation relative to the camera; `Shape`, `ShapeStyle`,
  `ShapeInOut` and `ShapePartial` work as they do on `ParticleEmitter`; and
  `CameraDistance` sets the strength of the perspective (`0` turns it off).
- `FacingCameraWorldUp` is accepted as an `Orientation`.

2D mode stays the default and, apart from the two fixes above, behaves exactly
as before, so existing effects look the same.

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
