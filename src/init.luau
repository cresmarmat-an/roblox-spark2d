--!native
--[[
======================================================================================
	SPARK2D  -  UI Particle Engine (Runtime ModuleScript)
======================================================================================
	Renders standard ParticleEmitter-style data as native 2D particles inside a
	ScreenGui. Emitter data lives as Attributes on a Folder tagged "UIParticleEmitter";
	this engine recycles pooled ImageLabels to draw the particles.

	The parent GuiObject stands in for the part a ParticleEmitter would sit in, and
	the screen is that part seen from the front. Particles move the way a real
	emitter's look from there, by ParticleEmitter's own rules, and everything is
	measured off the parent's AbsolutePosition, AbsoluteSize and AbsoluteRotation —
	so a UIScale, a rotated parent or a layout all land particles where they belong.
======================================================================================
]]

local RunService			= game:GetService("RunService")
local CollectionService		= game:GetService("CollectionService")
local Players				= game:GetService("Players")

-- Cleaner ships as a child of this module in the released .rbxm and in the Studio
-- plugin, and as a sibling when Wally installs it into _Index. Look for the child
-- first so one source works in both shapes.
local Cleaner = require(script:FindFirstChild("Cleaner") or script.Parent:WaitForChild("Cleaner"))

--------------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------------
local TAG		= "UIParticleEmitter"
local LUT_N		= 32
local MAX_DT	= 1 / 15
local PREALLOC	= 32
local LN2		= math.log(2)

-- ParticleEmitter caps a particle's lifetime at 20 seconds.
local MAX_LIFETIME		= 20
-- A VelocityPerpendicular particle crossing the screen is seen exactly edge-on
-- and would collapse to nothing; a real quad still rasterises as a sliver.
local MIN_FORESHORTEN	= 0.03

-- The frame each face emits along, seen from the front: X right, Y up, Z toward
-- the viewer.
--   L  the direction particles leave in.
--   U  the axis SpreadAngle.X tilts them toward.
--   R  the axis SpreadAngle.Y tilts them toward.
-- U and R are what a real ParticleEmitter does, measured in Studio. A Top
-- emitter's SpreadAngle.X tilts particles toward and away from the viewer rather
-- than sideways, which from the front reads as some particles rising more slowly
-- instead of fanning out; its .Y is the one that fans them left and right.
-- A flat screen has no depth to emit along, so Front and Back fold onto up and
-- down, and carry their spread axes over with them.
local EMISSION_FRAMES = {
	Top		= { L = Vector3.new(0, 1, 0),	U = Vector3.zAxis,	R = Vector3.xAxis },
	Front	= { L = Vector3.new(0, 1, 0),	U = Vector3.zAxis,	R = Vector3.xAxis },
	Bottom	= { L = Vector3.new(0, -1, 0),	U = Vector3.zAxis,	R = Vector3.xAxis },
	Back	= { L = Vector3.new(0, -1, 0),	U = Vector3.zAxis,	R = Vector3.xAxis },
	Right	= { L = Vector3.new(1, 0, 0),	U = Vector3.yAxis,	R = Vector3.zAxis },
	Left	= { L = Vector3.new(-1, 0, 0),	U = Vector3.yAxis,	R = Vector3.zAxis },
}

-- Flipbook frames-per-row for each square grid layout ("None" => no flipbook).
local FLIPBOOK_PER_ROW = {
	Grid2x2 = 2,
	Grid4x4 = 4,
	Grid8x8 = 8,
	Grid16x16 = 16,
}

local DEFAULTS = {
	-- Mirrored ParticleEmitter properties -------------------------------------------
	Texture				= "rbxasset://textures/particles/sparkles_main.dds",
	Color				= ColorSequence.new(Color3.new(1, 1, 1)),
	-- A fifth of the parent under the default Scale sizing. Not 1: that now
	-- means "cover the parent completely", which is not a sane starting point.
	Size				= NumberSequence.new(0.2),
	Transparency		= NumberSequence.new(0),
	Squash				= NumberSequence.new(0),
	Lifetime			= NumberRange.new(1, 2),
	Speed				= NumberRange.new(5, 5),
	Rotation			= NumberRange.new(0, 0),
	RotSpeed			= NumberRange.new(0, 0),
	SpreadAngle			= Vector2.new(0, 0),
	Acceleration		= Vector3.new(0, 0, 0),
	Rate				= 20,
	Drag				= 0,
	EmissionDirection	= "Top",

	-- Core Spark2D extras -------------------------------------------------------------
	ZIndex				= 2,
	EmitCount			= 20,
	Enabled				= true,
	MaxParticles		= 1000,
	PixelsPerStud		= 50,
	SizePixels			= 100,
	Origin				= Vector2.new(0.5, 0.5),
	LockedToGui			= true,
	SizingMode			= "Scale",
	PerfectSquare		= false,

	-- Timing ------------------------------------------------------------------------
	EmitDelay			= 0,
	EmitDuration		= 0,		-- 0 = infinite
	TimeScale			= 1,

	-- Motion extras -----------------------------------------------------------------
	VelocityInheritance	= 0,
	WindAcceleration	= Vector2.new(0, 0),
	TurbulencePower		= 0,
	TurbulenceFrequency	= 1,
	TurbulenceSpeed		= 1,

	-- Appearance extras -------------------------------------------------------------
	Glow				= 0,		-- 0 = off, 1 = strong faux-additive bloom
	Orientation			= "Free",	-- Free | FacingCamera | FacingCameraWorldUp | VelocityParallel | VelocityPerpendicular

	-- Depth (the 3D "Z" approximation) ----------------------------------------------
	Depth				= NumberRange.new(0, 0),
	DepthTransparency	= NumberSequence.new(0),

	-- Emission shape ----------------------------------------------------------------
	EmissionShape		= "Circle",	-- Point | Circle | Ring | Rectangle | Border | Line

	-- Colour / alpha over speed -----------------------------------------------------
	UseSpeedColor		= false,
	SpeedColor			= ColorSequence.new(Color3.new(1, 1, 1)),
	SpeedTransparency	= NumberSequence.new(0),
	SpeedRange			= NumberRange.new(0, 1000),

	-- Trails ------------------------------------------------------------------------
	TrailEnabled		= false,
	TrailLifetime		= 0.3,
	TrailInterval		= 0.03,

	-- Flipbook ----------------------------------------------------------------------
	FlipbookLayout		= "None",	-- None | Grid2x2 | Grid4x4 | Grid8x8
	FlipbookMode		= "OneShot",-- Loop | OneShot | PingPong | Random
	FlipbookFramerate	= NumberRange.new(20, 20),
	FlipbookStartRandom	= false,
	FlipbookResolution	= 1024,
}

--------------------------------------------------------------------------------------
-- TINY SIGNAL (no external dependency)
--------------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local h = { fn = fn }
	table.insert(self._handlers, h)
	return {
		Disconnect = function()
			local list = self._handlers
			for i = #list, 1, -1 do
				if list[i] == h then table.remove(list, i) break end
			end
		end,
	}
end
function Signal:HasListeners(): boolean
	return #self._handlers > 0
end
function Signal:Fire(...)
	local list = self._handlers
	for i = 1, #list do
		task.spawn(list[i].fn, ...)
	end
end

--------------------------------------------------------------------------------------
-- MATH / SEQUENCE HELPERS
--------------------------------------------------------------------------------------
local function clamp(x, lo, hi)
	if x < lo then return lo elseif x > hi then return hi else return x end
end
local function lerp(a, b, t) return a + (b - a) * t end
local function randRange(r)
	if r.Max <= r.Min then return r.Min end
	return r.Min + math.random() * (r.Max - r.Min)
end
local function getAngle(x, y) return math.deg(math.atan2(y, x)) end

-- NumberSequence -> (value, envelope) at t.
local function evalNumberSequence(seq, t)
	local kp = seq.Keypoints
	if t <= 0 then return kp[1].Value, kp[1].Envelope end
	if t >= 1 then return kp[#kp].Value, kp[#kp].Envelope end
	for i = 1, #kp - 1 do
		local a, b = kp[i], kp[i + 1]
		if t >= a.Time and t <= b.Time then
			local span = b.Time - a.Time
			local alpha = span > 0 and (t - a.Time) / span or 0
			return lerp(a.Value, b.Value, alpha), lerp(a.Envelope, b.Envelope, alpha)
		end
	end
	return kp[#kp].Value, kp[#kp].Envelope
end

local function evalColorSequence(seq, t)
	local kp = seq.Keypoints
	if t <= 0 then return kp[1].Value end
	if t >= 1 then return kp[#kp].Value end
	for i = 1, #kp - 1 do
		local a, b = kp[i], kp[i + 1]
		if t >= a.Time and t <= b.Time then
			local span = b.Time - a.Time
			local alpha = span > 0 and (t - a.Time) / span or 0
			return a.Value:Lerp(b.Value, alpha)
		end
	end
	return kp[#kp].Value
end

-- Build value + envelope LUTs for a NumberSequence.
local function buildNumberLUT(seq)
	local val = table.create(LUT_N)
	local env = table.create(LUT_N)
	for i = 0, LUT_N - 1 do
		local v, e = evalNumberSequence(seq, i / (LUT_N - 1))
		val[i + 1] = v
		env[i + 1] = e
	end
	return val, env
end

local function buildColorLUT(seq)
	local lut = table.create(LUT_N)
	for i = 0, LUT_N - 1 do
		lut[i + 1] = evalColorSequence(seq, i / (LUT_N - 1))
	end
	return lut
end

-- Cheap per-frame samplers (linear interpolation between neighbouring LUT entries).
local function sampleNumber(lut, t)
	local idx = t * (LUT_N - 1)
	local i0 = math.floor(idx)
	local frac = idx - i0
	i0 += 1
	local i1 = i0 + 1
	if i1 > LUT_N then i1 = LUT_N end
	return lerp(lut[i0], lut[i1], frac)
end
-- value + envelope*e (per-particle variance).
local function sampleNumberE(valLut, envLut, t, e)
	local idx = t * (LUT_N - 1)
	local i0 = math.floor(idx)
	local frac = idx - i0
	i0 += 1
	local i1 = i0 + 1
	if i1 > LUT_N then i1 = LUT_N end
	local v = lerp(valLut[i0], valLut[i1], frac)
	local en = lerp(envLut[i0], envLut[i1], frac)
	return v + en * e
end
local function sampleColor(lut, t)
	local idx = t * (LUT_N - 1)
	local i0 = math.floor(idx)
	local frac = idx - i0
	i0 += 1
	local i1 = i0 + 1
	if i1 > LUT_N then i1 = LUT_N end
	return lut[i0]:Lerp(lut[i1], frac)
end

local function attr(folder, name)
	local v = folder:GetAttribute(name)
	if v == nil then return DEFAULTS[name] end
	return v
end

--------------------------------------------------------------------------------------
-- SPARK2D SINGLETON
--------------------------------------------------------------------------------------
local Spark2D = {}
Spark2D._emitters = {}
Spark2D._cleaner = nil
Spark2D._loopStarted = false
Spark2D._root = nil
Spark2D._timeScale = 1
Spark2D._paused = false
Spark2D._quality = 1
Spark2D._avgDt = 1 / 60
Spark2D.AdaptiveQuality = true
-- Warn when a registered folder has nowhere to draw. Right for a running game,
-- wrong for the Studio plugin: previewing an effect that isn't under a GuiObject
-- yet is the simulated screen's whole purpose, so the plugin turns this off.
Spark2D.WarnUnparented = true

-- Public signals ---------------------------------------------------------------------
Spark2D.ParticleSpawned = Signal.new()	-- (folder, x, y)  -- x,y in the same space as the particle
Spark2D.ParticleDied    = Signal.new()	-- (folder, x, y)

--------------------------------------------------------------------------------------
-- CONFIG / LUT BUILD  (runs on register + on AttributeChanged only)
--------------------------------------------------------------------------------------
local function buildConfig(emitter)
	local f = emitter.folder
	local c = emitter.config

	c.Texture			= attr(f, "Texture")
	c.Rate				= attr(f, "Rate")
	c.Drag				= attr(f, "Drag")
	c.EmissionDirection	= attr(f, "EmissionDirection")
	c.Lifetime			= attr(f, "Lifetime")
	c.Speed				= attr(f, "Speed")
	c.Rotation			= attr(f, "Rotation")
	c.RotSpeed			= attr(f, "RotSpeed")
	c.SpreadAngle		= attr(f, "SpreadAngle")
	c.Acceleration		= attr(f, "Acceleration")
	c.ZIndex			= attr(f, "ZIndex")
	c.EmitCount			= attr(f, "EmitCount")
	c.Enabled			= attr(f, "Enabled")
	c.MaxParticles		= attr(f, "MaxParticles")
	c.PixelsPerStud		= attr(f, "PixelsPerStud")
	c.SizePixels		= attr(f, "SizePixels")
	c.Origin			= attr(f, "Origin")
	c.LockedToGui		= attr(f, "LockedToGui")
	c.SizingMode		= attr(f, "SizingMode")
	c.PerfectSquare		= attr(f, "PerfectSquare")
	c.EmitDelay			= attr(f, "EmitDelay")
	c.EmitDuration		= attr(f, "EmitDuration")
	c.TimeScale			= attr(f, "TimeScale")
	c.VelocityInheritance = attr(f, "VelocityInheritance")
	c.WindAcceleration	= attr(f, "WindAcceleration")
	c.TurbulencePower	= attr(f, "TurbulencePower")
	c.TurbulenceFrequency = attr(f, "TurbulenceFrequency")
	c.TurbulenceSpeed	= attr(f, "TurbulenceSpeed")
	c.Glow				= attr(f, "Glow")
	c.Orientation		= attr(f, "Orientation")
	c.Depth				= attr(f, "Depth")
	c.EmissionShape		= attr(f, "EmissionShape")
	c.UseSpeedColor		= attr(f, "UseSpeedColor")
	c.SpeedRange		= attr(f, "SpeedRange")
	c.TrailEnabled		= attr(f, "TrailEnabled")
	c.TrailLifetime		= attr(f, "TrailLifetime")
	c.TrailInterval		= math.max(1 / 240, attr(f, "TrailInterval"))
	c.FlipbookMode		= attr(f, "FlipbookMode")
	c.FlipbookStartRandom = attr(f, "FlipbookStartRandom")
	c.FlipbookFramerate	= attr(f, "FlipbookFramerate")

	-- Precompute screen-space acceleration once (world +Y up -> screen -Y). Z
	-- points at the viewer and doesn't move anything on a flat screen.
	c.accelScreenX =  c.Acceleration.X * c.PixelsPerStud
	c.accelScreenY = -c.Acceleration.Y * c.PixelsPerStud

	c.frame = EMISSION_FRAMES[c.EmissionDirection] or EMISSION_FRAMES.Top
	c.spreadX = math.rad(c.SpreadAngle.X)
	c.spreadY = math.rad(c.SpreadAngle.Y)
	-- ParticleEmitter's drag halves a particle's speed every 1/Drag seconds:
	-- v = v0 * 2^(-Drag * t), which is exponential decay at Drag * ln 2.
	c.dragK = c.Drag * LN2

	-- Sequence LUTs (value + envelope) ----------------------------------------------
	emitter.sizeLUT,   emitter.sizeEnv   = buildNumberLUT(attr(f, "Size"))
	emitter.transLUT,  emitter.transEnv  = buildNumberLUT(attr(f, "Transparency"))
	emitter.squashLUT, emitter.squashEnv = buildNumberLUT(attr(f, "Squash"))
	emitter.colorLUT   = buildColorLUT(attr(f, "Color"))
	emitter.depthTransLUT = buildNumberLUT(attr(f, "DepthTransparency"))
	emitter.speedColorLUT = buildColorLUT(attr(f, "SpeedColor"))
	emitter.speedTransLUT = buildNumberLUT(attr(f, "SpeedTransparency"))

	-- Flipbook ----------------------------------------------------------------------
	local fpr = FLIPBOOK_PER_ROW[attr(f, "FlipbookLayout")]
	if fpr then
		local res = attr(f, "FlipbookResolution")
		if typeof(res) ~= "number" then res = 1024 end	-- guard old Vector2 values
		emitter.hasFlipbook = true
		emitter.fbPerRow = fpr
		emitter.fbCount = fpr * fpr
		emitter.fbFrameWidth = res / fpr
	else
		emitter.hasFlipbook = false
		emitter.fbCount = 1
	end

	-- Keep live images in sync with the (possibly new) texture.
	for _, p in emitter.particles do
		if p.image then p.image.Image = c.Texture end
		if p.glow then p.glow.Image = c.Texture end
	end
end

--------------------------------------------------------------------------------------
-- IS THIS THING ON SCREEN?
--------------------------------------------------------------------------------------
-- "Is this instance still part of something that's rendered?"
--
-- IsDescendantOf(game) alone isn't enough: a PluginGui is rendered but is not
-- parented into the DataModel, so anything living inside one (the Studio
-- plugin's own Edit-tab preview, for instance) would read as destroyed and get
-- torn down on the very first frame. Reaching a LayerCollector — ScreenGui,
-- SurfaceGui, BillboardGui, PluginGui — covers that case, and a genuinely
-- destroyed instance still fails both tests, so nothing leaks.
local function isMounted(inst)
	return inst:IsDescendantOf(game) or inst:FindFirstAncestorWhichIsA("LayerCollector") ~= nil
end

local function isRenderable(base)
	return base ~= nil
		and isMounted(base)
		and base:IsA("GuiBase2d")
end

--------------------------------------------------------------------------------------
-- WHERE THE PARENT IS ON SCREEN
--------------------------------------------------------------------------------------
-- The combined UIScale acting on children of `base`: every UIScale from `base`
-- up to its LayerCollector, multiplied together. A particle's offset Position is
-- in the parent's own unscaled pixels and gets multiplied by this on its way to
-- the screen.
local function uiScaleOf(base)
	local s = 1
	local inst = base
	while inst do
		local u = inst:FindFirstChildWhichIsA("UIScale")
		if u then s *= u.Scale end
		if inst:IsA("LayerCollector") then break end
		inst = inst.Parent
	end
	-- A UIScale of 0 hides everything anyway; just don't divide by it.
	return math.max(s, 1e-4)
end

-- Read the parent's placement off its Absolute properties, once per frame.
--
-- AbsolutePosition and AbsoluteSize are the parent's box in screen pixels —
-- UIScale and any rotated ancestors already applied — and AbsoluteRotation is
-- how far it's turned about that box's centre. Together they say exactly where
-- any point inside the parent lands on screen, which is what lets unlocked
-- particles stay put in screen space and world-space forces point the right way
-- inside a scaled or rotated parent.
--
-- AbsoluteSize and AbsolutePosition alone aren't enough to place a particle,
-- because an offset Position is scaled AGAIN on its way to the screen: mixing
-- the two squared the scale, and a UIScale of 0.5 packed the whole effect into
-- the top-left quarter of its frame. Dividing by the UIScale factor turns
-- screen measurements back into the parent's own pixels, where offsets live.
local function refreshView(emitter)
	local base = emitter.base
	local pos, size = base.AbsolutePosition, base.AbsoluteSize
	local s = uiScaleOf(base)
	local rot = base.AbsoluteRotation
	local rad = math.rad(rot)
	emitter.uiScale = s
	emitter.rotation = rot
	emitter.cos, emitter.sin = math.cos(rad), math.sin(rad)
	emitter.halfW, emitter.halfH = size.X * 0.5, size.Y * 0.5
	emitter.centerX, emitter.centerY = pos.X + size.X * 0.5, pos.Y + size.Y * 0.5
	emitter.localSize = size / s
	emitter.referenceSize = Vector2.new(math.max(size.X, 1), math.max(size.Y, 1))
end

-- A point in the parent's own pixels (from its top-left) -> screen pixels.
local function toScreen(e, lx, ly)
	local x = lx * e.uiScale - e.halfW
	local y = ly * e.uiScale - e.halfH
	return e.centerX + x * e.cos - y * e.sin, e.centerY + x * e.sin + y * e.cos
end

-- Screen pixels -> a point in the parent's own pixels. The inverse of toScreen.
local function toLocal(e, sx, sy)
	local x, y = sx - e.centerX, sy - e.centerY
	local s = e.uiScale
	return (x * e.cos + y * e.sin + e.halfW) / s, (y * e.cos - x * e.sin + e.halfH) / s
end

--------------------------------------------------------------------------------------
-- POOLING  (a single ImageLabel pool serves particles, glow copies and ghosts)
--------------------------------------------------------------------------------------
local function getImage(emitter)
	local img = table.remove(emitter.imagePool)
	if not img then
		img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.BorderSizePixel = 0
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.ScaleType = Enum.ScaleType.Stretch
		img.Archivable = false
		img.Name = "Spark2DParticle"
		emitter.cleaner:Add(img)
	end
	img.Image = emitter.config.Texture
	img.ImageRectOffset = Vector2.zero
	img.ImageRectSize = Vector2.zero
	-- Start invisible: this image still carries whatever Position/Size/Rotation it
	-- had from its PREVIOUS particle (or Roblox's raw new-Instance defaults, which
	-- is a zero-size box pinned to the top-left corner). Emit() calls spawnParticle()
	-- directly, outside the per-frame update loop, so without this there is a real
	-- gap where that stale pose is visible before _updateEmitter()'s next pass calls
	-- renderImage() and sets the real position/size/rotation. Fully transparent means
	-- that gap renders nothing instead of a flash of the leftover pose.
	img.ImageTransparency = 1
	img.Visible = true
	return img
end

local function recycleImage(emitter, img)
	if img then
		img.ImageTransparency = 1
		img.Parent = nil
		table.insert(emitter.imagePool, img)
	end
end

local function getState(emitter)
	local p = table.remove(emitter.statePool)
	if not p then p = {} end
	return p
end

local function recycle(emitter, p)
	recycleImage(emitter, p.image)
	if p.glow then recycleImage(emitter, p.glow) end
	p.image, p.glow = nil, nil
	table.insert(emitter.statePool, p)
end

--------------------------------------------------------------------------------------
-- EMISSION POSITION (by shape) -- returns LOCAL pixel coords within the base GuiObject
--------------------------------------------------------------------------------------
local function emitPosition(c, size)
	local shape = c.EmissionShape
	local ox = c.Origin.X * size.X
	local oy = c.Origin.Y * size.Y
	if shape == "Point" then
		return ox, oy
	elseif shape == "Ring" then
		-- Circular equivalent of Border: edge of the circle inscribed in the
		-- container (centered on Origin), same "driven by container size, no
		-- separate radius to keep in sync" idea Border already uses.
		local r = math.min(size.X, size.Y) * 0.5
		local a = math.random() * (2 * math.pi)
		return ox + math.cos(a) * r, oy + math.sin(a) * r
	elseif shape == "Rectangle" then
		return math.random() * size.X, math.random() * size.Y
	elseif shape == "Border" then
		local vertical = math.random() < (size.Y / (size.X + size.Y + 1e-6))
		local sideA = math.random(0, 1)
		if vertical then
			return size.X * sideA, math.random() * size.Y
		else
			return math.random() * size.X, size.Y * sideA
		end
	elseif shape == "Line" then
		return math.random() * size.X, oy
	else -- "Circle" (default) — filled circle inscribed in the container, centered on Origin.
		local r = math.min(size.X, size.Y) * 0.5
		local rr = r * math.sqrt(math.random())
		local a = math.random() * (2 * math.pi)
		return ox + math.cos(a) * rr, oy + math.sin(a) * rr
	end
end

--------------------------------------------------------------------------------------
-- EMISSION DIRECTION -- a unit direction in the parent's frame: X right, Y down,
-- plus how much of it points at the viewer
--------------------------------------------------------------------------------------
-- Tilt the face's direction by up to ±SpreadAngle.X toward U and ±SpreadAngle.Y
-- toward R, as a ParticleEmitter does, then look at it from the front. Whatever
-- tilted toward or away from the viewer can't move a particle on a flat screen,
-- so it only shortens the on-screen motion — exactly how the real emitter's
-- cone looks from in front of the part. 360 on both axes covers every direction.
--
-- The part pointing at the viewer is returned too: it never moves anything, but
-- it decides how much of a velocity-aligned particle faces the camera.
local function emitDirection(c)
	local f = c.frame
	local rx = (math.random() * 2 - 1) * c.spreadX
	local ry = (math.random() * 2 - 1) * c.spreadY
	local d = (f.L * math.cos(rx) + f.U * math.sin(rx)) * math.cos(ry) + f.R * math.sin(ry)
	-- The screen is Y-down.
	return d.X, -d.Y, d.Z
end

--------------------------------------------------------------------------------------
-- SPAWN
--------------------------------------------------------------------------------------
local function spawnParticle(emitter)
	local c = emitter.config
	if #emitter.particles >= emitter.effMax then return end

	-- Emit() and Burst() reach this function directly, outside the update loop
	-- that normally gates on renderability — so this is where a folder parented
	-- to something that isn't a GuiObject (a Part, a Script, ServerStorage) has
	-- to be caught. Reading AbsoluteSize off one of those is a hard error, not
	-- nil, and there's nowhere to draw a particle anyway.
	if not isRenderable(emitter.base) then return end

	-- As on a ParticleEmitter: a zero lifetime emits nothing, and nothing lives
	-- past 20 seconds.
	local life = math.min(randRange(c.Lifetime), MAX_LIFETIME)
	if life <= 0 then return end

	local p = getState(emitter)
	p.age, p.life = 0, life

	-- Velocity from the face direction +/- spread, in the parent's own pixels.
	local dx, dy, dz = emitDirection(c)
	local speed = randRange(c.Speed) * c.PixelsPerStud
	local vx, vy, vz = dx * speed, dy * speed, dz * speed

	-- A particle lives in one of two spaces, stamped onto it (p.locked) at spawn
	-- rather than re-read live at render time — if LockedToGui gets toggled
	-- while this particle is still alive, its stored position and velocity
	-- should keep meaning whatever they meant when they were computed, or the
	-- particle would jump to a nonsense position the instant the attribute
	-- changes instead of only affecting particles spawned afterward.
	--   Locked:   the parent's own pixels and frame. The renderer carries the
	--             particle along as the parent moves, scales or turns — which is
	--             exactly what LockedToPart does to a part's particles.
	--   Unlocked: absolute screen pixels. Placed once, then left behind.
	local lx, ly = emitPosition(c, emitter.localSize)
	local inherit = c.VelocityInheritance
	p.locked = c.LockedToGui
	if p.locked then
		p.x, p.y = lx, ly
		if inherit ~= 0 then
			vx += emitter.inheritLocalX * inherit
			vy += emitter.inheritLocalY * inherit
		end
	else
		p.x, p.y = toScreen(emitter, lx, ly)
		-- The emission direction turns with the parent, like a rotated part's.
		local s, cs, sn = emitter.uiScale, emitter.cos, emitter.sin
		vx, vy = (vx * cs - vy * sn) * s, (vx * sn + vy * cs) * s
		vz *= s
		if inherit ~= 0 then
			vx += emitter.inheritScreenX * inherit
			vy += emitter.inheritScreenY * inherit
		end
	end
	p.vx, p.vy, p.vz = vx, vy, vz

	-- Depth parallax.
	local depth = randRange(c.Depth)
	p.depth = depth
	if depth > 0 then p.depthMul = 1 / (depth + 1)
	elseif depth < 0 then p.depthMul = -depth + 1
	else p.depthMul = 1 end

	p.rot = randRange(c.Rotation)
	p.rotSpeed = randRange(c.RotSpeed)
	-- Where each sequence's envelope lands for this particle. ParticleEmitter
	-- rolls every sequence separately, so a particle that comes out large isn't
	-- also, by coincidence, the most transparent.
	p.envS = math.random() * 2 - 1
	p.envT = math.random() * 2 - 1
	p.envQ = math.random() * 2 - 1
	p.seed = math.random() * 1000
	p.nextTrail = c.TrailInterval

	-- Flipbook per-particle bookkeeping.
	p.fbFramerate = randRange(c.FlipbookFramerate)
	p.fbStart = c.FlipbookStartRandom and math.random(1, emitter.fbCount) or 1
	p.fbFrame = p.fbStart
	p.fbLastStep = -1

	-- Glow copy (opt-in).
	if c.Glow > 0 then
		local g = getImage(emitter)
		g.ZIndex = c.ZIndex - 1
		g.Parent = emitter.particleParent
		p.glow = g
	else
		p.glow = nil
	end

	local img = getImage(emitter)
	img.ZIndex = c.ZIndex
	img.Parent = emitter.particleParent
	p.image = img

	table.insert(emitter.particles, p)

	if Spark2D.ParticleSpawned:HasListeners() then
		Spark2D.ParticleSpawned:Fire(emitter.folder, p.x, p.y)
	end
	return p
end

--------------------------------------------------------------------------------------
-- FLIPBOOK FRAME (Emitter2D-style maths)
--------------------------------------------------------------------------------------
local function computeFlipbook(emitter, p, t)
	local fpr = emitter.fbPerRow
	local fc = emitter.fbCount
	local fw = emitter.fbFrameWidth
	local mode = emitter.config.FlipbookMode
	local frame

	if mode == "Loop" then
		local fss = p.fbStart + 1 + math.floor(p.age * p.fbFramerate)
		frame = 1 + ((fss - 1) % fc)
	elseif mode == "Random" then
		local step = math.floor(p.age * p.fbFramerate)
		if step ~= p.fbLastStep then
			p.fbLastStep = step
			p.fbFrame = math.random(1, fc)
		end
		frame = p.fbFrame
	elseif mode == "PingPong" then
		local fss = p.fbStart + 1 + math.floor(p.age * p.fbFramerate)
		frame = 1 + ((fss - 1) % fc)
		if math.floor((fss - 1) / fc) % 2 == 1 then
			frame = 1 + (fc - frame)
		end
	else -- "OneShot": play the strip once across the lifetime
		frame = p.fbStart + math.ceil(t * (1 + fc - p.fbStart)) - 1
	end

	frame = clamp(frame, 1, fc)
	local fx = 1 + ((frame - 1) % fpr)
	local fy = math.ceil(frame / fpr)
	return Vector2.new((fx - 1) * fw, (fy - 1) * fw), Vector2.new(fw, fw)
end

--------------------------------------------------------------------------------------
-- RENDER TRANSFORM (shared by particles, glow copies and ghosts)
--------------------------------------------------------------------------------------
-- x, y: a position in the particle's own space — the parent's pixels if locked,
-- the screen's if not — turned into the offset Position the image needs.
-- `screenRot` is the rotation the particle should have ON SCREEN; the image
-- inherits the parent's AbsoluteRotation, so that is taken back off.
--
-- Offsets are whole pixels, and Roblox truncates whatever it's given: every
-- particle came out up to a pixel smaller than it should, and anything left of
-- or above the parent's corner was pulled a pixel toward it. Rounding keeps the
-- error to half a pixel either way.
local round = math.round
local function renderImage(c, emitter, img, locked, x, y, w, h, screenRot, color, trans, rectOff, rectSize)
	img.ImageColor3 = color
	img.ImageTransparency = trans
	img.Rotation = screenRot - emitter.rotation
	if rectSize then
		img.ImageRectOffset = rectOff
		img.ImageRectSize = rectSize
	end
	if not locked then
		x, y = toLocal(emitter, x, y)
	end
	img.Position = UDim2.fromOffset(round(x), round(y))
	-- w and h arrive in whichever unit SizingMode implies: a fraction of the
	-- parent GuiObject under Scale, pixels under Offset. Emitting a Scale size as
	-- UDim2.fromScale is what lets Roblox keep particles tracking a parent that
	-- resizes after registration, which an offset size can't do.
	if c.SizingMode == "Scale" then
		if c.PerfectSquare then
			-- Square on screen, not square in scale units: 1.0 x 1.0 scale on a
			-- 200x100 parent is a 2:1 rectangle. Convert both axes to pixels, take
			-- the smaller (so the particle stays inside the box the way a
			-- UIAspectRatioConstraint would), then convert back.
			local ref = emitter.referenceSize
			local side = math.min(w * ref.X, h * ref.Y)
			img.Size = UDim2.fromScale(side / ref.X, side / ref.Y)
		else
			img.Size = UDim2.fromScale(w, h)
		end
	elseif c.PerfectSquare then
		local side = round(math.min(w, h))
		img.Size = UDim2.fromOffset(side, side)
	else
		img.Size = UDim2.fromOffset(round(w), round(h))
	end
end

--------------------------------------------------------------------------------------
-- GHOST (trail) helpers
--------------------------------------------------------------------------------------
local function getGhost(emitter)
	local g = table.remove(emitter.ghostPool)
	if not g then g = {} end
	return g
end

local function spawnGhost(emitter, p, w, h, screenRot, color, trans, rectOff, rectSize)
	local c = emitter.config
	if #emitter.ghosts >= emitter.effMax then return end
	local g = getGhost(emitter)
	local img = getImage(emitter)
	img.ZIndex = c.ZIndex - 1
	img.Parent = emitter.particleParent
	g.image = img
	g.age = 0
	g.life = c.TrailLifetime
	g.locked = p.locked
	g.x, g.y = p.x, p.y
	g.w, g.h, g.rot = w, h, screenRot
	g.color, g.trans = color, trans
	g.rectOff, g.rectSize = rectOff, rectSize
	table.insert(emitter.ghosts, g)
end

--------------------------------------------------------------------------------------
-- PER-EMITTER UPDATE (hot loop)
--------------------------------------------------------------------------------------
function Spark2D:_updateEmitter(emitter, dt)
	local c = emitter.config
	local sizeUnit = (c.SizingMode == "Scale") and 1 or c.SizePixels
	local particles = emitter.particles
	local hasFlipbook = emitter.hasFlipbook
	local useSpeedColor = c.UseSpeedColor
	local depthActive = c.Depth.Min ~= c.Depth.Max
	local emitTime = emitter.time
	local s, cs, sn, parentRot = emitter.uiScale, emitter.cos, emitter.sin, emitter.rotation

	local windX, windY = c.WindAcceleration.X, c.WindAcceleration.Y
	local tp, tf, ts = c.TurbulencePower, c.TurbulenceFrequency * 0.01, c.TurbulenceSpeed
	local diedSignal = Spark2D.ParticleDied:HasListeners()

	-- Motion is integrated exactly rather than stepped: with drag, velocity
	-- relaxes toward a/k along an exponential, so the path is the same at 30 fps
	-- as at 240 and matches the curve a real ParticleEmitter traces — gravity
	-- included, which drag caps at a terminal speed.
	local k = c.dragK
	local decay, reach = 1, dt
	if k ~= 0 then
		decay = math.exp(-k * dt)
		reach = (1 - decay) / k
	end

	for i = #particles, 1, -1 do
		local p = particles[i]
		p.age += dt

		if p.age >= p.life then
			if diedSignal then Spark2D.ParticleDied:Fire(emitter.folder, p.x, p.y) end
			recycle(emitter, p)
			local n = #particles
			particles[i] = particles[n]
			particles[n] = nil
		else
			local locked = p.locked

			-- Acceleration = base + wind + turbulence. Like ParticleEmitter's, it
			-- acts in world space — down the screen stays down the screen however
			-- the parent is turned — so it's carried into the particle's own space:
			-- the parent's frame for a locked particle, screen pixels otherwise.
			local ax, ay = c.accelScreenX + windX, c.accelScreenY + windY
			if tp ~= 0 then
				ax += math.noise(p.x * tf, p.y * tf, emitTime * ts + p.seed) * tp
				ay += math.noise(p.x * tf + 37.1, p.y * tf + 11.7, emitTime * ts + p.seed) * tp
			end
			if locked then
				ax, ay = ax * cs + ay * sn, ay * cs - ax * sn
			else
				ax, ay = ax * s, ay * s
			end

			-- Depth scales apparent movement + size (parallax).
			local dm = p.depthMul
			local vx, vy = p.vx, p.vy
			if k ~= 0 then
				local tx, ty = ax / k, ay / k
				p.x += (tx * dt + (vx - tx) * reach) * dm
				p.y += (ty * dt + (vy - ty) * reach) * dm
				vx = tx + (vx - tx) * decay
				vy = ty + (vy - ty) * decay
				p.vz *= decay
			else
				p.x += (vx + 0.5 * ax * dt) * dt * dm
				p.y += (vy + 0.5 * ay * dt) * dt * dm
				vx += ax * dt
				vy += ay * dt
			end
			p.vx, p.vy = vx, vy
			p.rot += p.rotSpeed * dt

			local t = p.age / p.life
			local sizeV = sampleNumberE(emitter.sizeLUT, emitter.sizeEnv, t, p.envS)
			local transV = sampleNumberE(emitter.transLUT, emitter.transEnv, t, p.envT)
			local squashV = sampleNumberE(emitter.squashLUT, emitter.squashEnv, t, p.envQ)
			local col = sampleColor(emitter.colorLUT, t)

			-- Colour / alpha over speed, measured in the parent's own pixels so a
			-- UIScale doesn't shift it.
			local vz = p.vz
			if useSpeedColor then
				local sp = math.sqrt(vx * vx + vy * vy + vz * vz)
				if not locked then sp /= s end
				local sr = c.SpeedRange
				local st = clamp((sp - sr.Min) / math.max(sr.Max - sr.Min, 1e-6), 0, 1)
				local sc = sampleColor(emitter.speedColorLUT, st)
				col = Color3.new(col.R * sc.R, col.G * sc.G, col.B * sc.B)
				transV = clamp(transV + sampleNumber(emitter.speedTransLUT, st), 0, 1)
			end

			-- Depth fade.
			if depthActive then
				local ratio = (p.depth - c.Depth.Min) / math.max(c.Depth.Max - c.Depth.Min, 1e-6)
				local dtv = sampleNumber(emitter.depthTransLUT, t) * ratio
				transV = clamp(transV + (1 - transV) * dtv, 0, 1)
			end

			-- Under Scale, Size reads as a straight fraction of the parent (1 = the
			-- parent's full size, like UDim2.fromScale) and SizePixels plays no
			-- part; under Offset it's a multiplier on SizePixels. Either way the
			-- Size sequence is the multiplier and renderImage applies the unit.
			local diameter = sizeV * sizeUnit * dm

			-- ParticleEmitter's Squash: positive narrows the particle by (1 + q)
			-- and makes it that much taller, negative the other way round, and the
			-- two sides mirror each other.
			local w, h
			local f = 1 + math.abs(squashV)
			if squashV >= 0 then
				w, h = diameter / f, diameter * f
			else
				w, h = diameter * f, diameter / f
			end

			-- Orientation, as a rotation on screen.
			local screenRot
			local ori = c.Orientation
			local flat = vx * vx + vy * vy
			local full = flat + vz * vz
			if (ori == "VelocityParallel" or ori == "VelocityPerpendicular") and full > 1e-9 then
				-- Width runs along the direction of travel, and a positive Rotation
				-- turns clockwise from there. Travel toward or away from the viewer
				-- foreshortens that width: a Parallel particle contains its
				-- velocity, so it thins as travel turns toward the camera; a
				-- Perpendicular one faces along it, so it's seen edge-on while
				-- crossing the screen and opens up as it turns toward the camera.
				local travel = getAngle(vx, vy)
				if locked then travel += parentRot end
				screenRot = travel + p.rot
				local fore
				if ori == "VelocityParallel" then
					fore = math.sqrt(flat / full)
				else
					fore = math.abs(vz) / math.sqrt(full)
				end
				w *= math.max(fore, MIN_FORESHORTEN)
			else
				-- Camera-facing, which is every other mode. A ParticleEmitter turns
				-- these counter-clockwise for a positive Rotation (measured in
				-- Studio, whatever the docs say) and keeps them upright on screen
				-- however its part is turned.
				screenRot = -p.rot
			end

			local rectOff, rectSize
			if hasFlipbook then
				rectOff, rectSize = computeFlipbook(emitter, p, t)
			end

			-- Glow copy (drawn behind, larger, brighter, more transparent).
			if p.glow then
				local gcol = col:Lerp(Color3.new(1, 1, 1), 0.35)
				local gtrans = clamp(1 - (1 - transV) * c.Glow, 0, 1)
				renderImage(c, emitter, p.glow, locked, p.x, p.y, w * 1.9, h * 1.9, screenRot, gcol, gtrans, rectOff, rectSize)
			end

			renderImage(c, emitter, p.image, locked, p.x, p.y, w, h, screenRot, col, transV, rectOff, rectSize)

			-- Trails.
			if c.TrailEnabled and p.age >= p.nextTrail then
				spawnGhost(emitter, p, w, h, screenRot, col, transV, rectOff, rectSize)
				p.nextTrail += c.TrailInterval
			end
		end
	end

	-- Update ghosts.
	local ghosts = emitter.ghosts
	for i = #ghosts, 1, -1 do
		local g = ghosts[i]
		g.age += dt
		local gt = g.age / g.life
		if gt >= 1 then
			recycleImage(emitter, g.image)
			g.image = nil
			table.insert(emitter.ghostPool, g)
			local n = #ghosts
			ghosts[i] = ghosts[n]
			ghosts[n] = nil
		else
			local tr = clamp(g.trans + (1 - g.trans) * gt, 0, 1)
			renderImage(c, emitter, g.image, g.locked, g.x, g.y, g.w, g.h, g.rot, g.color, tr, g.rectOff, g.rectSize)
		end
	end
end

--------------------------------------------------------------------------------------
-- MASTER LOOP
--------------------------------------------------------------------------------------
function Spark2D:_update(dt)
	if self._paused then return end

	-- Adaptive quality (rolling average frame time -> quality multiplier).
	if self.AdaptiveQuality then
		self._avgDt = self._avgDt * 0.9 + dt * 0.1
		if self._avgDt > (1 / 45) then
			self._quality = math.max(0.25, self._quality - 0.02)
		else
			self._quality = math.min(1, self._quality + 0.01)
		end
	else
		self._quality = 1
	end

	local scaled = dt * self._timeScale
	if scaled > MAX_DT then scaled = MAX_DT end

	for folder, emitter in self._emitters do
		if not isMounted(folder) then
			self:Stop(folder)
		else
			emitter.base = folder.Parent
			local renderable = isRenderable(emitter.base)
			emitter.renderable = renderable

			if not renderable then
				-- Not being drawn: clear everything and idle.
				if #emitter.particles > 0 or #emitter.ghosts > 0 then
					for i = #emitter.particles, 1, -1 do recycle(emitter, emitter.particles[i]); emitter.particles[i] = nil end
					for i = #emitter.ghosts, 1, -1 do recycleImage(emitter, emitter.ghosts[i].image); emitter.ghosts[i].image = nil; table.insert(emitter.ghostPool, emitter.ghosts[i]); emitter.ghosts[i] = nil end
				end
				emitter.emitAge = 0
				emitter.lastCenter = nil
			else
				local c = emitter.config
				local edt = scaled * c.TimeScale
				emitter.time += edt
				emitter.effMax = math.max(1, math.floor(c.MaxParticles * self._quality))
				-- Re-read every frame rather than cached: position, size, UIScale
				-- and rotation are all exactly the sort of thing that gets tweened.
				refreshView(emitter)

				-- The parent's own velocity, for VelocityInheritance: its centre's
				-- motion across the screen, and the same in its own frame.
				local cx, cy = emitter.centerX, emitter.centerY
				local last = emitter.lastCenter
				local ivx, ivy = 0, 0
				if last and edt > 0 then
					ivx, ivy = (cx - last.X) / edt, (cy - last.Y) / edt
				end
				emitter.lastCenter = Vector2.new(cx, cy)
				emitter.inheritScreenX, emitter.inheritScreenY = ivx, ivy
				local s, cs, sn = emitter.uiScale, emitter.cos, emitter.sin
				emitter.inheritLocalX = (ivx * cs + ivy * sn) / s
				emitter.inheritLocalY = (ivy * cs - ivx * sn) / s

				-- Emission (rate) gated by Enabled + EmitDelay/EmitDuration.
				if c.Enabled then
					emitter.emitAge += edt
					local past = emitter.emitAge - c.EmitDelay
					local within = (c.EmitDuration <= 0) or (emitter.emitAge < c.EmitDelay + c.EmitDuration)
					if past >= 0 and within and c.Rate > 0 then
						emitter.rateAccum += c.Rate * edt
						while emitter.rateAccum >= 1 do
							emitter.rateAccum -= 1
							spawnParticle(emitter)
						end
					end
				else
					emitter.emitAge = 0
					emitter.rateAccum = 0
				end

				self:_updateEmitter(emitter, edt)
			end
		end
	end
end

function Spark2D:_ensureLoop()
	if self._loopStarted then return end
	self._loopStarted = true
	-- RunService:IsEdit() requires PluginSecurity, so it only works when this
	-- module is required from the plugin. Spark2D:Init() is also meant to run from
	-- a normal in-game LocalScript, which does not have that permission and would
	-- error the first time this line ran. IsStudio() + IsRunning() need no special
	-- permission and give the identical result in every case.
	local isEditMode = RunService:IsStudio() and not RunService:IsRunning()
	local signal = isEditMode and RunService.Heartbeat or RunService.RenderStepped
	self._cleaner:Connect(signal, function(dt)
		self:_update(dt)
	end)
end

--------------------------------------------------------------------------------------
-- REGISTER
--------------------------------------------------------------------------------------
function Spark2D:_register(folder, container)
	self._cleaner = self._cleaner or Cleaner.new()

	local emitter = {
		folder = folder,
		base = folder.Parent,
		particleParent = container or folder,
		config = {},
		particles = {},
		ghosts = {},
		imagePool = {},
		statePool = {},
		ghostPool = {},
		rateAccum = 0,
		emitAge = 0,
		time = 0,
		effMax = DEFAULTS.MaxParticles,
		cleaner = self._cleaner:Extend(),

		-- Placeholder view until the parent can be measured: an unscaled,
		-- unrotated 100x100 box at the origin.
		uiScale = 1,
		rotation = 0,
		cos = 1,
		sin = 0,
		halfW = 50,
		halfH = 50,
		centerX = 50,
		centerY = 50,
		localSize = Vector2.new(100, 100),
		referenceSize = Vector2.new(100, 100),
		inheritScreenX = 0,
		inheritScreenY = 0,
		inheritLocalX = 0,
		inheritLocalY = 0,
	}

	local base = emitter.base
	if self.WarnUnparented and not isRenderable(base) then
		warn(("[Spark2D] '%s' is not (yet) under a GuiObject/ScreenGui; it will render once it is."):format(folder.Name))
	end
	if isRenderable(base) then
		refreshView(emitter)
	end

	buildConfig(emitter)

	local batch = math.min(emitter.config.MaxParticles, PREALLOC)
	for _ = 1, batch do
		table.insert(emitter.imagePool, getImage(emitter))
	end

	emitter.cleaner:Connect(folder.AttributeChanged, function()
		buildConfig(emitter)
	end)
	emitter.cleaner:Connect(folder.AncestryChanged, function()
		if not isMounted(folder) then
			self:Stop(folder)
		else
			emitter.base = folder.Parent
			emitter.lastCenter = nil
			if isRenderable(emitter.base) then
				refreshView(emitter)
			end
		end
	end)

	self._emitters[folder] = emitter
	self:_ensureLoop()
	return emitter
end

--------------------------------------------------------------------------------------
-- TARGET RESOLUTION
--------------------------------------------------------------------------------------
local function collectTagged(inst, out, seen)
	if inst:IsA("Folder") and CollectionService:HasTag(inst, TAG) and not seen[inst] then
		seen[inst] = true
		table.insert(out, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("Folder") and CollectionService:HasTag(d, TAG) and not seen[d] then
			seen[d] = true
			table.insert(out, d)
		end
	end
end

function Spark2D:_resolve(target)
	local out, seen = {}, {}
	if target == nil then
		for folder in self._emitters do
			if not seen[folder] then seen[folder] = true; table.insert(out, folder) end
		end
		if #out == 0 then
			collectTagged(self._root or game, out, seen)
		end
	else
		collectTagged(target, out, seen)
	end
	return out
end

function Spark2D:_ensure(folder, container)
	local emitter = self._emitters[folder]
	if not emitter then
		emitter = self:_register(folder, container)
	end
	return emitter
end

--------------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------------
function Spark2D:Init(root)
	self._cleaner = self._cleaner or Cleaner.new()
	root = root or (Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui"))
	if not root then
		warn("[Spark2D] Init: no root provided and PlayerGui is unavailable.")
		return self
	end
	self._root = root

	for _, inst in CollectionService:GetTagged(TAG) do
		if inst:IsA("Folder") and inst:IsDescendantOf(root) then
			self:_ensure(inst)
		end
	end
	self._cleaner:Connect(CollectionService:GetInstanceAddedSignal(TAG), function(inst)
		if inst:IsA("Folder") and self._root and inst:IsDescendantOf(self._root) then
			self:_ensure(inst)
		end
	end)
	self._cleaner:Connect(CollectionService:GetInstanceRemovedSignal(TAG), function(inst)
		self:Stop(inst)
	end)

	self:_ensureLoop()
	return self
end

-- Everything a burst from outside the update loop needs refreshed first, since
-- the loop may not have run for this emitter yet (or at all).
local function prepareBurst(self, emitter)
	emitter.effMax = math.max(1, math.floor(emitter.config.MaxParticles * self._quality))
	if isRenderable(emitter.base) then
		refreshView(emitter)
	end
end

-- Burst. target = Folder | container | nil(=all). count defaults to EmitCount.
function Spark2D:Emit(target, count)
	for _, folder in self:_resolve(target) do
		local emitter = self:_ensure(folder)
		prepareBurst(self, emitter)
		local n = count or emitter.config.EmitCount or 1
		for _ = 1, n do
			spawnParticle(emitter)
		end
	end
end

-- One burst on exactly one folder, registering it if it isn't already.
--
-- Emit() goes through target resolution, which only ever finds folders carrying
-- the UIParticleEmitter tag. Burst skips that entirely and acts on the folder it
-- is handed, so it also works for a folder you drive directly without tagging —
-- which is how the Studio plugin's Edit-tab preview fires its own bursts.
function Spark2D:Burst(folder, count)
	local emitter = self:_ensure(folder)
	prepareBurst(self, emitter)
	local n = count or emitter.config.EmitCount or 1
	for _ = 1, n do
		spawnParticle(emitter)
	end
end

-- Start continuous emission (Enabled = true + register).
function Spark2D:Enable(target)
	for _, folder in self:_resolve(target) do
		folder:SetAttribute("Enabled", true)
		self:_ensure(folder)
	end
end

-- Soft stop (Enabled = false): stop spawning, live particles finish. Not a teardown.
function Spark2D:Disable(target)
	for _, folder in self:_resolve(target) do
		folder:SetAttribute("Enabled", false)
	end
end

function Spark2D:EmitAll()	self:Emit(nil) end
function Spark2D:EnableAll()	self:Enable(nil) end
function Spark2D:DisableAll()	self:Disable(nil) end

function Spark2D:IsEnabled(folder)
	local e = self._emitters[folder]
	return e ~= nil and e.config.Enabled == true
end

-- Global controls.
function Spark2D:SetTimeScale(scale)
	self._timeScale = math.max(0, scale or 1)
end
function Spark2D:Pause()	self._paused = true end
function Spark2D:Resume()	self._paused = false end

-- Back-compat alias.
Spark2D.StartEmitter = Spark2D._ensure

-- Hard teardown of one emitter (disconnect + destroy its pooled/active images).
function Spark2D:Stop(folder)
	local emitter = self._emitters[folder]
	if not emitter then return end
	self._emitters[folder] = nil
	emitter.cleaner:Destroy()
end

function Spark2D:Destroy()
	for folder in self._emitters do
		self:Stop(folder)
	end
	self._emitters = {}
	if self._cleaner then
		self._cleaner:Destroy()
		self._cleaner = nil
	end
	self._loopStarted = false
	self._root = nil
end

return Spark2D
