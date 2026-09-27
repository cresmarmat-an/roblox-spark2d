--!native
--[[
======================================================================================
	SPARK2D  -  UI Particle Engine (Runtime ModuleScript)
======================================================================================
	Renders standard ParticleEmitter-style data as native 2D particles inside a
	ScreenGui. Emitter data lives as Attributes on a Folder tagged "UIParticleEmitter";
	this engine recycles pooled ImageLabels to draw the particles.

	Two simulations share the one loop. 2D moves particles across the screen
	plane. 3D (SimulationMode = "3D") moves them in X, Y and Z by
	ParticleEmitter's own rules and projects them through a virtual camera, so an
	effect converted from the 3D world looks the way it did there.
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

-- 3D mode mirrors a real ParticleEmitter's hard limits.
local MAX_LIFETIME_3D	= 20
-- A particle whose depth puts it within this fraction of the camera distance
-- in front of the lens (or behind it) isn't drawn: its perspective scale would
-- blow up towards infinity, and a real camera would have clipped it anyway.
local NEAR_CLIP			= 0.05
-- VelocityPerpendicular particles seen exactly edge-on would collapse to zero
-- width and vanish; a real quad still rasterises as a sliver.
local MIN_FORESHORTEN	= 0.03

-- 2D mode: the one screen-plane direction each face emits along.
local DIRECTION_MAP = {
	Top		= Vector2.new(0, -1),
	Bottom	= Vector2.new(0,  1),
	Left	= Vector2.new(-1, 0),
	Right	= Vector2.new(1,  0),
	Front	= Vector2.new(0, -1),
	Back	= Vector2.new(0,  1),
}

-- 3D mode: the frame each face emits from, in the emitter's own space, with
-- the camera's axes as the reference (X right, Y up, Z towards the viewer).
--   L  the face normal particles leave along.
--   U  the axis SpreadAngle.X tilts particles towards.
--   R  the axis SpreadAngle.Y tilts particles towards, and a Cylinder's axis.
-- U and R aren't guesses: they're what a real ParticleEmitter does, measured in
-- Studio. It isn't "X spreads along X" — a Top emitter's SpreadAngle.X fans
-- particles out along Z, and its .Y along X.
local FACE_FRAMES = {
	Top		= { L = Vector3.new(0, 1, 0),	U = Vector3.new(0, 0, 1),	R = Vector3.new(1, 0, 0) },
	Bottom	= { L = Vector3.new(0, -1, 0),	U = Vector3.new(0, 0, 1),	R = Vector3.new(1, 0, 0) },
	Right	= { L = Vector3.new(1, 0, 0),	U = Vector3.new(0, 1, 0),	R = Vector3.new(0, 0, 1) },
	Left	= { L = Vector3.new(-1, 0, 0),	U = Vector3.new(0, 1, 0),	R = Vector3.new(0, 0, 1) },
	Front	= { L = Vector3.new(0, 0, -1),	U = Vector3.new(0, 1, 0),	R = Vector3.new(1, 0, 0) },
	Back	= { L = Vector3.new(0, 0, 1),	U = Vector3.new(0, 1, 0),	R = Vector3.new(1, 0, 0) },
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

	-- Simulation --------------------------------------------------------------------
	-- 2D: the flat engine every effect used before 3D mode existed, unchanged.
	-- 3D: particles move in X, Y and Z by ParticleEmitter's own rules and are
	-- projected onto the screen through a virtual camera.
	SimulationMode		= "2D",		-- 2D | 3D

	-- 3D mode only -------------------------------------------------------------------
	EmitterSize			= Vector3.new(0, 0, 0),	-- studs; the emitting part's Size. Zero = a point, like an Attachment
	EmitterRotation		= Vector3.new(0, 0, 0),	-- degrees; the emitter's orientation relative to the camera
	CameraDistance		= 20,		-- studs from the camera to the emitter; 0 = no perspective
	Shape				= "Box",	-- Box | Sphere | Cylinder | Disc
	ShapeStyle			= "Volume",	-- Volume | Surface
	ShapeInOut			= "Outward",-- Outward | Inward | InAndOut
	ShapePartial		= 1,

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
	Orientation			= "Free",	-- Free | VelocityParallel | VelocityPerpendicular | FacingCamera

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

-- attr(), falling back to the default when the stored value is the wrong type.
-- For the attributes the 3D maths leans on, where a stray string would
-- otherwise surface as an arithmetic error deep inside the update loop.
local function typedAttr(folder, name)
	local v = folder:GetAttribute(name)
	local d = DEFAULTS[name]
	if v == nil or typeof(v) ~= typeof(d) then return d end
	return v
end

-- The combined UIScale acting on children of `base`: every UIScale from `base`
-- up to its LayerCollector, multiplied together.
--
-- AbsoluteSize and AbsolutePosition are post-scale screen pixels, but a
-- particle's offset Position is scaled AGAIN on its way to the screen. Mixing
-- the two squared the scale — a UIScale of 0.5 packed the whole effect into the
-- top-left quarter of its frame. Dividing screen measurements by this factor
-- turns them back into the parent's own unscaled pixels, where offsets live.
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

	-- Precompute screen-space acceleration once (world +Y up -> screen -Y). Z is
	-- toward the viewer, and only 3D mode has anywhere to put it.
	c.accelScreenX =  c.Acceleration.X * c.PixelsPerStud
	c.accelScreenY = -c.Acceleration.Y * c.PixelsPerStud
	c.accelScreenZ =  c.Acceleration.Z * c.PixelsPerStud

	c.is3D = attr(f, "SimulationMode") == "3D"
	-- Scale sizing is a 2D idea: 3D mode sizes particles in studs, like the
	-- ParticleEmitter it copies.
	c.useScaleSizing = (not c.is3D) and c.SizingMode == "Scale"

	if c.is3D then
		local face = FACE_FRAMES[c.EmissionDirection] or FACE_FRAMES.Top
		local rot = typedAttr(f, "EmitterRotation")
		c.face = face
		-- Same convention as BasePart.Orientation, so a value read straight off
		-- a part (relative to the camera) means what it says.
		c.rotCF = CFrame.fromOrientation(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
		c.spreadX = math.rad(c.SpreadAngle.X)
		c.spreadY = math.rad(c.SpreadAngle.Y)
		-- Drag halves a particle's speed every 1/Drag seconds: v = v0 * 2^(-Drag*t).
		c.dragK = c.Drag * LN2
		c.halfSize = typedAttr(f, "EmitterSize") * (0.5 * c.PixelsPerStud)
		c.cameraPx = math.max(0, typedAttr(f, "CameraDistance")) * c.PixelsPerStud
		c.Shape = attr(f, "Shape")
		c.ShapeStyle = attr(f, "ShapeStyle")
		c.ShapeInOut = attr(f, "ShapeInOut")
		c.ShapePartial = clamp(typedAttr(f, "ShapePartial"), 0, 1)
	else
		local base = DIRECTION_MAP[c.EmissionDirection] or DIRECTION_MAP.Top
		c.baseAngle = math.atan2(base.Y, base.X)
		-- A 2D plane has one rotational axis to spread a cone across; 3D has two
		-- (SpreadAngle.X and .Y independently). Blend both into that one axis instead
		-- of reading only .X, so a converted ParticleEmitter that leaned on a wide
		-- SpreadAngle.Y (a tall vertical fan, say) doesn't collapse to looking
		-- identical to a (0, 0) spread just because .Y has nowhere else to go.
		c.spreadRad = math.rad((c.SpreadAngle.X + c.SpreadAngle.Y) * 0.5)
	end

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
-- 3D EMISSION (by Shape) -- returns an offset from the emitter centre and a unit
-- direction, both in camera space (X right, Y up, Z toward the viewer), in pixels
--------------------------------------------------------------------------------------
-- Tilt `L` by up to ±spreadX towards U, then by up to ±spreadY towards R.
-- Stays unit length, and 360 on both axes covers the whole sphere, which is what
-- ParticleEmitter promises for that setting.
local function spreadDirection(c, L, U, R)
	local rx = (math.random() * 2 - 1) * c.spreadX
	local ry = (math.random() * 2 - 1) * c.spreadY
	return (L * math.cos(rx) + U * math.sin(rx)) * math.cos(ry) + R * math.sin(ry)
end

-- Any two axes perpendicular to `n`, for spreading around a direction that
-- isn't one of the six faces (a sphere's or cylinder's surface normal).
local function perpendicularAxes(n)
	local helper = math.abs(n.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
	local a = n:Cross(helper).Unit
	return a, n:Cross(a)
end

-- Where a particle spawns and which way it leaves, following ParticleEmitter's
-- Shape / ShapeStyle / ShapeInOut / ShapePartial. Sampled in the emitter's own
-- space, where the face frames are axis-aligned, so multiplying by halfSize
-- component-wise stretches the unit shape to the emitter's box — then rotated
-- into camera space once at the end.
local function emitShape3D(c)
	local face = c.face
	local L, U, R = face.L, face.U, face.R
	local h = c.halfSize
	local shape = c.Shape
	local surface = c.ShapeStyle == "Surface"
	local pos, dir

	if shape == "Sphere" then
		-- ShapePartial is the cap's angle as a fraction of the full sphere,
		-- measured from the EmissionDirection pole: 1 whole, 0.5 a dome, 0 the
		-- pole alone. cos(theta) uniform is uniform over the cap's area.
		local cosMax = math.cos(math.pi * c.ShapePartial)
		local cosT = 1 - math.random() * (1 - cosMax)
		local sinT = math.sqrt(math.max(0, 1 - cosT * cosT))
		local phi = math.random() * (2 * math.pi)
		local n = L * cosT + (U * math.cos(phi) + R * math.sin(phi)) * sinT
		local r = surface and 1 or math.random() ^ (1 / 3)
		pos = n * h * r
		local a, b = perpendicularAxes(n)
		dir = spreadDirection(c, n, a, b)
	elseif shape == "Cylinder" then
		-- Runs along R, emitting radially from it. ShapePartial tapers the +R
		-- end's radius: 1 is a straight cylinder, 0 a cone.
		local t = math.random() * 2 - 1
		local taper = lerp(1, c.ShapePartial, (t + 1) * 0.5)
		local phi = math.random() * (2 * math.pi)
		local radial = L * math.cos(phi) + U * math.sin(phi)
		local r = surface and 1 or math.sqrt(math.random())
		pos = (radial * (r * taper) + R * t) * h
		dir = spreadDirection(c, radial, R, radial:Cross(R))
	elseif shape == "Disc" then
		-- Lies across the face, through the emitter's centre. ShapePartial is
		-- how far the hole in the middle reaches in: 1 a solid disc, near 0 a
		-- thin rim. Square-root sampling keeps the density even across the area.
		local inner = 1 - c.ShapePartial
		local r = math.sqrt(lerp(inner * inner, 1, math.random()))
		local phi = math.random() * (2 * math.pi)
		pos = (U * math.cos(phi) + R * math.sin(phi)) * h * r
		dir = spreadDirection(c, L, U, R)
	else -- "Box"
		if surface then
			-- Only the emitting face itself.
			pos = (L + U * (math.random() * 2 - 1) + R * (math.random() * 2 - 1)) * h
		else
			pos = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1) * h
		end
		dir = spreadDirection(c, L, U, R)
	end

	local inOut = c.ShapeInOut
	if inOut == "Inward" or (inOut == "InAndOut" and math.random() < 0.5) then
		dir = -dir
	end

	local rot = c.rotCF
	return rot:VectorToWorldSpace(pos), rot:VectorToWorldSpace(dir)
end

-- Perspective scale for a particle `z` pixels toward the viewer, or nil when
-- the camera couldn't see it (level with or behind the lens).
local function perspective(c, z)
	local d = c.cameraPx
	if d <= 0 then return 1 end
	local denom = d - z
	if denom <= d * NEAR_CLIP then return nil end
	return d / denom
end

-- Where a particle is right now, in the coordinate space it lives in: the
-- parent's own unscaled pixels when locked, absolute screen pixels when not.
-- `s` is its perspective scale, `uis` the parent's UIScale factor.
local function particleSpace(p, s, uis)
	local k = p.locked and s or s * uis
	return p.ax + p.posX * k, p.ay + p.posY * k
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
	local baseObj = emitter.base
	if not isRenderable(baseObj) then return end
	local uis = emitter.uiScale or 1
	-- The parent's own unscaled pixels: the space offsets are measured in.
	local size = baseObj.AbsoluteSize / uis

	local life = randRange(c.Lifetime)
	if c.is3D then
		-- ParticleEmitter emits nothing at a zero lifetime, and caps it at 20s.
		if life <= 0 then return end
		life = math.min(life, MAX_LIFETIME_3D)
	elseif life <= 0 then
		life = 0.0001
	end

	local p = getState(emitter)
	p.age, p.life = 0, life

	-- A particle is an anchor plus an offset from it. The anchor is fixed at
	-- spawn; the offset is what moves. In 2D the anchor is the spawn point and
	-- the offset starts at zero. In 3D the anchor is the emitter's centre — the
	-- point the virtual camera looks at — and the offset starts wherever the
	-- Shape put the particle, depth included, so perspective pulls particles
	-- toward and away from the right point.
	--
	-- The anchor is stored in the parent's own pixels when locked, and as an
	-- absolute screen position when not. Stamped onto the particle (p.locked)
	-- rather than re-read live at render time — if LockedToGui gets toggled
	-- while this particle is still alive, its anchor should keep meaning
	-- whatever it meant when it was computed (a local offset vs. an absolute
	-- screen position are not interchangeable), or the particle would jump to a
	-- nonsense position the instant the attribute changes instead of only
	-- affecting particles spawned afterward.
	local ax, ay
	local vx, vy, vz = 0, 0, 0
	local speed = randRange(c.Speed) * c.PixelsPerStud
	if c.is3D then
		local offset, dir = emitShape3D(c)
		ax, ay = c.Origin.X * size.X, c.Origin.Y * size.Y
		-- Camera space is Y-up; the screen is Y-down.
		p.posX, p.posY, p.posZ = offset.X, -offset.Y, offset.Z
		vx, vy, vz = dir.X * speed, -dir.Y * speed, dir.Z * speed
	else
		-- Velocity from base direction +/- spread.
		local ang = c.baseAngle + (math.random() * 2 - 1) * c.spreadRad
		vx = math.cos(ang) * speed
		vy = math.sin(ang) * speed
		ax, ay = emitPosition(c, size)
		p.posX, p.posY, p.posZ = 0, 0, 0
	end
	if c.VelocityInheritance ~= 0 and emitter.baseVel then
		vx += emitter.baseVel.X * c.VelocityInheritance
		vy += emitter.baseVel.Y * c.VelocityInheritance
	end
	p.velX, p.velY, p.velZ = vx, vy, vz

	p.locked = c.LockedToGui
	if not p.locked then
		local ap = baseObj.AbsolutePosition
		ax, ay = ap.X + ax * uis, ap.Y + ay * uis
	end
	p.ax, p.ay = ax, ay

	-- Depth parallax (2D only; 3D has a real depth axis instead).
	local depth = c.is3D and 0 or randRange(c.Depth)
	p.depth = depth
	if depth > 0 then p.depthMul = 1 / (depth + 1)
	elseif depth < 0 then p.depthMul = -depth + 1
	else p.depthMul = 1 end

	p.rot = randRange(c.Rotation)
	p.rotSpeed = randRange(c.RotSpeed)
	-- Where each sequence's envelope lands for this particle. 2D has always
	-- shared one roll across Size, Transparency and Squash; ParticleEmitter
	-- rolls each separately, so 3D does too.
	p.env = math.random() * 2 - 1
	if c.is3D then
		p.envT = math.random() * 2 - 1
		p.envQ = math.random() * 2 - 1
	else
		p.envT, p.envQ = p.env, p.env
	end
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
		local x, y = particleSpace(p, (c.is3D and perspective(c, p.posZ)) or 1, uis)
		Spark2D.ParticleSpawned:Fire(emitter.folder, x, y)
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
-- x, y: a position in the particle's own space (see particleSpace), turned
-- into an offset from the parent here. An unlocked position is absolute screen
-- pixels, so it's measured from the parent's corner and then divided back into
-- the parent's unscaled pixels, the space an offset Position lives in.
--
-- Offsets are whole pixels, and Roblox truncates whatever it's given: every
-- particle came out up to a pixel smaller than it should, and anything left of
-- or above its anchor was pulled a pixel toward it. Rounding keeps the error
-- to half a pixel either way, which matters at the sizes a 3D effect seen from
-- a distance ends up at.
local round = math.round
local function renderImage(c, img, locked, x, y, w, h, rot, absPos, uis, ref, color, trans, rectOff, rectSize)
	img.ImageColor3 = color
	img.ImageTransparency = trans
	img.Rotation = rot
	if rectSize then
		img.ImageRectOffset = rectOff
		img.ImageRectSize = rectSize
	end
	if locked then
		img.Position = UDim2.fromOffset(round(x), round(y))
	else
		img.Position = UDim2.fromOffset(round((x - absPos.X) / uis), round((y - absPos.Y) / uis))
	end
	-- w and h arrive in whichever unit SizingMode implies: a fraction of the
	-- parent GuiObject under Scale, pixels under Offset. Emitting a Scale size as
	-- UDim2.fromScale is what lets Roblox keep particles tracking a parent that
	-- resizes after registration, which an offset size can't do.
	if c.useScaleSizing then
		if c.PerfectSquare then
			-- Square on screen, not square in scale units: 1.0 x 1.0 scale on a
			-- 200x100 parent is a 2:1 rectangle. Convert both axes to pixels, take
			-- the smaller (so the particle stays inside the box the way a
			-- UIAspectRatioConstraint would), then convert back.
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

local function spawnGhost(emitter, p, x, y, w, h, rot, color, trans, rectOff, rectSize)
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
	g.posX, g.posY = x, y
	g.w, g.h, g.rot = w, h, rot
	g.color, g.trans = color, trans
	g.rectOff, g.rectSize = rectOff, rectSize
	table.insert(emitter.ghosts, g)
end

--------------------------------------------------------------------------------------
-- PER-EMITTER UPDATE (hot loop)
--------------------------------------------------------------------------------------
local function refreshReferenceSize(emitter)
	local base = emitter.base
	if base and base:IsA("GuiBase2d") then
		local s = base.AbsoluteSize
		emitter.referenceSize = Vector2.new(math.max(s.X, 1), math.max(s.Y, 1))
	end
end

function Spark2D:_updateEmitter(emitter, dt)
	local c = emitter.config
	local is3D = c.is3D
	local sizeUnit
	if is3D then
		-- A ParticleEmitter's Size is half the quad's width in studs — a Size of
		-- 1 draws a 2-stud square, measured against real parts in Studio.
		sizeUnit = 2 * c.PixelsPerStud
	else
		sizeUnit = c.useScaleSizing and 1 or c.SizePixels
	end
	local particles = emitter.particles
	local base = emitter.base
	local absPos = (base and base.AbsolutePosition) or Vector2.zero
	local uis = emitter.uiScale or 1
	refreshReferenceSize(emitter)
	local ref = emitter.referenceSize
	local hasFlipbook = emitter.hasFlipbook
	local useSpeedColor = c.UseSpeedColor
	local depthActive = (not is3D) and c.Depth.Min ~= c.Depth.Max
	local emitTime = emitter.time

	local windX, windY = c.WindAcceleration.X, c.WindAcceleration.Y
	local tp, tf, ts = c.TurbulencePower, c.TurbulenceFrequency * 0.01, c.TurbulenceSpeed
	local diedSignal = Spark2D.ParticleDied:HasListeners()

	-- 3D motion is integrated exactly rather than stepped: with drag, velocity
	-- relaxes toward a/k along an exponential, so the answer is the same at 30
	-- fps as at 240 and matches the curve a real ParticleEmitter traces.
	local k = is3D and c.dragK or 0
	local decay, reach = 1, dt
	if k ~= 0 then
		decay = math.exp(-k * dt)
		reach = (1 - decay) / k
	end

	for i = #particles, 1, -1 do
		local p = particles[i]
		p.age += dt

		if p.age >= p.life then
			if diedSignal then
				local x, y = particleSpace(p, (is3D and perspective(c, p.posZ)) or 1, uis)
				Spark2D.ParticleDied:Fire(emitter.folder, x, y)
			end
			recycle(emitter, p)
			local n = #particles
			particles[i] = particles[n]
			particles[n] = nil
		else
			-- Acceleration = base + wind + turbulence. Turbulence samples the
			-- noise field where the particle actually is on screen.
			local vx, vy, vz = p.velX, p.velY, p.velZ
			local ax, ay = c.accelScreenX + windX, c.accelScreenY + windY
			if tp ~= 0 then
				local nx, ny = particleSpace(p, 1, uis)
				ax += math.noise(nx * tf, ny * tf, emitTime * ts + p.seed) * tp
				ay += math.noise(nx * tf + 37.1, ny * tf + 11.7, emitTime * ts + p.seed) * tp
			end

			local s = 1
			if is3D then
				local az = c.accelScreenZ
				if k ~= 0 then
					local tx, ty, tz = ax / k, ay / k, az / k
					p.posX += tx * dt + (vx - tx) * reach
					p.posY += ty * dt + (vy - ty) * reach
					p.posZ += tz * dt + (vz - tz) * reach
					vx = tx + (vx - tx) * decay
					vy = ty + (vy - ty) * decay
					vz = tz + (vz - tz) * decay
				else
					p.posX += (vx + 0.5 * ax * dt) * dt
					p.posY += (vy + 0.5 * ay * dt) * dt
					p.posZ += (vz + 0.5 * az * dt) * dt
					vx += ax * dt
					vy += ay * dt
					vz += az * dt
				end
				p.velX, p.velY, p.velZ = vx, vy, vz
				s = perspective(c, p.posZ)
			else
				-- Linear drag, then depth scales apparent movement (parallax).
				vx += (ax - c.Drag * vx) * dt
				vy += (ay - c.Drag * vy) * dt
				p.velX, p.velY = vx, vy
				local dm = p.depthMul
				p.posX += vx * dm * dt
				p.posY += vy * dm * dt
			end
			p.rot += p.rotSpeed * dt

			if not s then
				-- Behind the virtual camera: alive, moving, but not drawable.
				p.image.ImageTransparency = 1
				if p.glow then p.glow.ImageTransparency = 1 end
			else
				local t = p.age / p.life
				local sizeV = sampleNumberE(emitter.sizeLUT, emitter.sizeEnv, t, p.env)
				local transV = sampleNumberE(emitter.transLUT, emitter.transEnv, t, p.envT)
				local squashV = sampleNumberE(emitter.squashLUT, emitter.squashEnv, t, p.envQ)
				local col = sampleColor(emitter.colorLUT, t)

				-- Colour / alpha over speed.
				if useSpeedColor then
					local sp = math.sqrt(vx * vx + vy * vy + vz * vz)
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
				-- part; under Offset it's a multiplier on SizePixels; in 3D it's studs.
				-- Either way the Size sequence is the multiplier and renderImage
				-- applies the unit.
				local diameter = sizeV * sizeUnit * p.depthMul * s
				local w, h
				if is3D then
					-- ParticleEmitter's Squash: positive narrows by (1 + q) and grows
					-- tall by the same factor, negative the other way round, and the
					-- two sides mirror each other.
					local f = 1 + math.abs(squashV)
					if squashV >= 0 then
						w, h = diameter / f, diameter * f
					else
						w, h = diameter * f, diameter / f
					end
				else
					local sq = clamp(squashV, -0.99, 5)
					w = diameter * (1 + sq)
					h = diameter / (1 + sq)
				end

				-- Orientation.
				local finalRot
				local ori = c.Orientation
				if is3D then
					if ori == "VelocityParallel" or ori == "VelocityPerpendicular" then
						-- Width runs along the direction of travel, and a positive
						-- Rotation turns clockwise from there. Moving toward or away
						-- from the camera foreshortens that width: Parallel's quad
						-- contains the velocity, so it shrinks as travel turns
						-- toward the lens; Perpendicular's faces it, so it shrinks
						-- as travel turns across the screen.
						local flat = vx * vx + vy * vy
						local full = flat + vz * vz
						if full > 1e-9 then
							finalRot = p.rot + getAngle(vx, vy)
							local fore
							if ori == "VelocityParallel" then
								fore = math.sqrt(flat / full)
							else
								fore = math.abs(vz) / math.sqrt(full)
							end
							w *= math.max(fore, MIN_FORESHORTEN)
						else
							finalRot = p.rot
						end
					else
						-- A camera-facing ParticleEmitter turns counter-clockwise
						-- for a positive Rotation (measured in Studio, whatever the
						-- docs say); GuiObject.Rotation turns clockwise.
						finalRot = -p.rot
					end
				elseif ori == "VelocityParallel" then
					finalRot = p.rot + getAngle(vx, vy) + 90
				elseif ori == "VelocityPerpendicular" then
					finalRot = p.rot + getAngle(vx, vy)
				elseif ori == "FacingCamera" or ori == "FacingCameraWorldUp" then
					finalRot = 0
				else
					finalRot = p.rot
				end

				local rectOff, rectSize
				if hasFlipbook then
					rectOff, rectSize = computeFlipbook(emitter, p, t)
				end

				local x, y = particleSpace(p, s, uis)

				-- Glow copy (drawn behind, larger, brighter, more transparent).
				if p.glow then
					local gcol = col:Lerp(Color3.new(1, 1, 1), 0.35)
					local gtrans = clamp(1 - (1 - transV) * c.Glow, 0, 1)
					renderImage(c, p.glow, p.locked, x, y, w * 1.9, h * 1.9, finalRot, absPos, uis, ref, gcol, gtrans, rectOff, rectSize)
				end

				renderImage(c, p.image, p.locked, x, y, w, h, finalRot, absPos, uis, ref, col, transV, rectOff, rectSize)

				-- Trails.
				if c.TrailEnabled and p.age >= p.nextTrail then
					spawnGhost(emitter, p, x, y, w, h, finalRot, col, transV, rectOff, rectSize)
					p.nextTrail += c.TrailInterval
				end
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
			renderImage(c, g.image, g.locked, g.posX, g.posY, g.w, g.h, g.rot, absPos, uis, ref, g.color, tr, g.rectOff, g.rectSize)
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
			else
				local c = emitter.config
				local edt = scaled * c.TimeScale
				emitter.time += edt
				emitter.effMax = math.max(1, math.floor(c.MaxParticles * self._quality))
				-- Re-read every frame rather than cached: a UIScale is exactly the
				-- sort of thing that gets tweened.
				emitter.uiScale = uiScaleOf(emitter.base)

				-- Base velocity for VelocityInheritance, in the parent's own pixels
				-- per second like every other velocity.
				local ap = emitter.base.AbsolutePosition
				if emitter.lastBasePos and edt > 0 then
					emitter.baseVel = (ap - emitter.lastBasePos) / (edt * emitter.uiScale)
				else
					emitter.baseVel = Vector2.zero
				end
				emitter.lastBasePos = ap

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
		uiScale = 1,
		effMax = DEFAULTS.MaxParticles,
		cleaner = self._cleaner:Extend(),
	}

	local base = emitter.base
	if self.WarnUnparented and not isRenderable(base) then
		warn(("[Spark2D] '%s' is not (yet) under a GuiObject/ScreenGui; it will render once it is."):format(folder.Name))
	end

	emitter.referenceSize = Vector2.new(100, 100)
	refreshReferenceSize(emitter)

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
			refreshReferenceSize(emitter)
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
		emitter.uiScale = uiScaleOf(emitter.base)
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