# Changelog

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
