--!native
--[[
======================================================================================
	SPARK2D  -  UI particle engine
======================================================================================
	Plays ParticleEmitter-style effects inside a ScreenGui. An effect is a Folder
	tagged "UIParticleEmitter" that holds Attributes, and the engine draws it with
	pooled ImageLabels.

	The GuiObject the folder sits in plays the part a ParticleEmitter would be in.
	Everything is measured off that parent's AbsolutePosition, AbsoluteSize and
	AbsoluteRotation, and particles are placed with Scale values, so a UIScale, a
	different screen size or a layout never throws them off. Sizes and speeds are
	in studs, and a stud is a fraction of the parent (StudSize), so the whole
	effect keeps its proportions to its parent everywhere.
======================================================================================
]]

local RunService			= game:GetService("RunService")
local CollectionService		= game:GetService("CollectionService")
local Players				= game:GetService("Players")

-- Dependencies ship as children of this module in the released .rbxm and in the
-- plugin's install, and as siblings when Wally puts them in _Index. Look for the
-- child first so the same source works in both layouts.
local function dependency(name: string)
	return require(script:FindFirstChild(name) or script.Parent:WaitForChild(name))
end

local Cleaner = dependency("Cleaner")
local Signal = dependency("Signal")
local Pool = dependency("Pool")

--------------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------------
local TAG			= "UIParticleEmitter"
local CONTAINER		= "Spark2DParticles"
local LUT_N			= 32
local MAX_DT		= 1 / 15
local PREALLOC		= 32
local LN2			= math.log(2)
-- ParticleEmitter never lets a particle live longer than this.
local MAX_LIFETIME	= 20

-- Flipbook frames per row for each square grid layout ("None" means no flipbook).
local FLIPBOOK_PER_ROW = {
	Grid2x2 = 2,
	Grid4x4 = 4,
	Grid8x8 = 8,
	Grid16x16 = 16,
}

local DEFAULTS = {
	-- General ------------------------------------------------------------------------
	Enabled				= true,
	Texture				= "rbxasset://textures/particles/sparkles_main.dds",
	Rate				= 20,		-- particles per second
	BurstCount			= 20,		-- how many Emit() fires when no count is given
	MaxParticles		= 1000,
	StartDelay			= 0,		-- seconds after Enabled before emission starts
	StopAfter			= 0,		-- seconds of emission before it stops by itself, 0 = never
	TimeScale			= 1,
	ZIndex				= 2,
	MoveWithParent		= true,		-- ParticleEmitter.LockedToPart
	ReduceOnLowGraphics	= true,
	ResampleMode		= "Default",	-- Default | Pixelated

	-- How big a stud is --------------------------------------------------------------
	StudSize			= 0.1,		-- one stud, as a fraction of StudSizeRelativeTo
	StudSizeRelativeTo	= "ParentHeight",	-- ParentHeight | ParentWidth | ParentSmallerSide | ParentLargerSide | ScreenHeight

	-- Emission -----------------------------------------------------------------------
	EmissionShape		= "Oval",	-- Point | Line | Rectangle | Oval
	EmissionShapeStyle	= "Volume",	-- Volume | Surface
	EmissionOrigin		= Vector2.new(0.5, 0.5),	-- where Point emits from, and where Line sits
	EmissionDirectionMode = "Angle",	-- Angle | AwayFromCenter | TowardCenter | AwayFromEdge
	EmissionAngle		= 0,		-- degrees, 0 = up, clockwise
	SpreadAngle			= 0,		-- degrees either side, across the screen
	DepthSpreadAngle	= 0,		-- degrees either side, toward and away from the viewer
	Lifetime			= NumberRange.new(1, 2),
	Speed				= NumberRange.new(5, 5),	-- studs per second

	-- Motion -------------------------------------------------------------------------
	Acceleration		= Vector2.new(0, 0),	-- studs per second squared, Y up
	Drag				= 0,
	VelocityInheritance	= 0,
	TurbulenceStrength	= 0,
	TurbulenceFrequency	= 1,
	TurbulenceSpeed		= 1,
	Rotation			= NumberRange.new(0, 0),
	RotSpeed			= NumberRange.new(0, 0),
	Orientation			= "FacingCamera",	-- FacingCamera | FacingCameraWorldUp | VelocityParallel | VelocityPerpendicular

	-- Appearance ---------------------------------------------------------------------
	Color				= ColorSequence.new(Color3.new(1, 1, 1)),
	Transparency		= NumberSequence.new(0),
	Size				= NumberSequence.new(1),	-- studs, ParticleEmitter style
	Squash				= NumberSequence.new(0),
	GlowStrength		= 0,

	-- Depth (a fake third axis) ------------------------------------------------------
	Depth				= NumberRange.new(0, 0),
	DepthTransparency	= NumberSequence.new(0),

	-- Colour and transparency by speed -----------------------------------------------
	UseSpeedColor		= false,
	SpeedColor			= ColorSequence.new(Color3.new(1, 1, 1)),
	SpeedTransparency	= NumberSequence.new(0),
	SpeedColorRange		= NumberRange.new(0, 10),	-- studs per second

	-- Trails -------------------------------------------------------------------------
	TrailEnabled		= false,
	TrailLifetime		= 0.3,
	TrailInterval		= 0.03,

	-- Flipbook -----------------------------------------------------------------------
	FlipbookLayout		= "None",	-- None | Grid2x2 | Grid4x4 | Grid8x8 | Grid16x16
	FlipbookMode		= "OneShot",	-- Loop | OneShot | PingPong | Random
	FlipbookFramerate	= NumberRange.new(20, 20),
	FlipbookStartRandom	= false,
	FlipbookResolution	= 1024,
}

--------------------------------------------------------------------------------------
-- OLDER ATTRIBUTE NAMES
--------------------------------------------------------------------------------------
-- Effects saved before 1.0.3 use these names. They are read when the new name
-- isn't set, so an old effect keeps playing. The Studio plugin rewrites folders
-- to the new names the first time it sees them.
local RENAMED = {
	BurstCount = "EmitCount",
	StartDelay = "EmitDelay",
	StopAfter = "EmitDuration",
	MoveWithParent = "LockedToGui",
	EmissionOrigin = "Origin",
	GlowStrength = "Glow",
	TurbulenceStrength = "TurbulencePower",
	SpeedColorRange = "SpeedRange",
}

-- The old six-face EmissionDirection, as an angle.
local FACE_ANGLES = {
	Top = 0, Front = 0, Right = 90, Bottom = 180, Back = 180, Left = 270,
}

-- Old shapes that are now a shape plus a style.
local OLD_SHAPES = {
	Circle = { "Oval", "Volume" },
	Ring = { "Oval", "Surface" },
	Border = { "Rectangle", "Surface" },
}

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
-- Screen angle of a vector, in degrees clockwise from +X (the way GuiObject.Rotation turns).
local function screenAngle(x, y) return math.deg(math.atan2(y, x)) end

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

-- Build value + envelope lookup tables for a NumberSequence.
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

-- Cheap per-frame samplers (linear interpolation between neighbouring entries).
local function sampleNumber(lut, t)
	local idx = t * (LUT_N - 1)
	local i0 = math.floor(idx)
	local frac = idx - i0
	i0 += 1
	local i1 = i0 + 1
	if i1 > LUT_N then i1 = LUT_N end
	return lerp(lut[i0], lut[i1], frac)
end
-- value + envelope * e, where e is the particle's own roll in [-1, 1].
local function sampleNumberE(valLut, envLut, t, e)
	local idx = t * (LUT_N - 1)
	local i0 = math.floor(idx)
	local frac = idx - i0
	i0 += 1
	local i1 = i0 + 1
	if i1 > LUT_N then i1 = LUT_N end
	return lerp(valLut[i0], valLut[i1], frac) + lerp(envLut[i0], envLut[i1], frac) * e
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

-- An attribute's value, or its default when it's missing or the wrong type. A
-- wrong type would otherwise surface as an error deep inside the update loop.
local function attr(folder, name)
	local default = DEFAULTS[name]
	local v = folder:GetAttribute(name)
	if v ~= nil and typeof(v) == typeof(default) then return v end
	local old = RENAMED[name]
	if old then
		v = folder:GetAttribute(old)
		if v ~= nil and typeof(v) == typeof(default) then return v end
	end
	return default
end

-- Graphics quality scaling. Roblox thins out real particle effects on low
-- graphics settings; this does the same to the emission rate. "Automatic" (0)
-- counts as full quality, since the real level can't be read from a script.
local function graphicsRateScale()
	local ok, level = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
	end)
	if not ok or level <= 0 then return 1 end
	return 0.85 ^ (10 - math.min(level, 10))
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
-- wrong for the Studio plugin, whose preview exists to show effects that aren't
-- under a GuiObject yet, so the plugin turns this off.
Spark2D.WarnUnparented = true

-- Public signals. x and y are where the particle is, in its own space: studs
-- from the parent's centre when it moves with the parent, screen pixels when not.
Spark2D.ParticleSpawned = Signal.new()	-- (folder, x, y)
Spark2D.ParticleDied    = Signal.new()	-- (folder, x, y)

--------------------------------------------------------------------------------------
-- CONFIG / LUT BUILD  (runs on register and when an attribute changes)
--------------------------------------------------------------------------------------
local function buildConfig(emitter)
	local f = emitter.folder
	local c = emitter.config

	c.Enabled			= attr(f, "Enabled")
	c.Texture			= attr(f, "Texture")
	c.Rate				= attr(f, "Rate")
	c.BurstCount		= attr(f, "BurstCount")
	c.MaxParticles		= attr(f, "MaxParticles")
	c.StartDelay		= attr(f, "StartDelay")
	c.StopAfter			= attr(f, "StopAfter")
	c.TimeScale			= attr(f, "TimeScale")
	c.ZIndex			= attr(f, "ZIndex")
	c.MoveWithParent	= attr(f, "MoveWithParent")
	c.ReduceOnLowGraphics = attr(f, "ReduceOnLowGraphics")
	c.ResampleMode		= attr(f, "ResampleMode")
	c.StudSize			= math.max(0, attr(f, "StudSize"))
	c.StudSizeRelativeTo = attr(f, "StudSizeRelativeTo")
	c.EmissionShapeStyle = attr(f, "EmissionShapeStyle")
	c.EmissionOrigin	= attr(f, "EmissionOrigin")
	c.EmissionDirectionMode = attr(f, "EmissionDirectionMode")
	c.Lifetime			= attr(f, "Lifetime")
	c.Speed				= attr(f, "Speed")
	c.Drag				= attr(f, "Drag")
	c.VelocityInheritance = attr(f, "VelocityInheritance")
	c.TurbulenceStrength = attr(f, "TurbulenceStrength")
	c.TurbulenceFrequency = attr(f, "TurbulenceFrequency")
	c.TurbulenceSpeed	= attr(f, "TurbulenceSpeed")
	c.Rotation			= attr(f, "Rotation")
	c.RotSpeed			= attr(f, "RotSpeed")
	c.GlowStrength		= attr(f, "GlowStrength")
	c.Depth				= attr(f, "Depth")
	c.UseSpeedColor		= attr(f, "UseSpeedColor")
	c.SpeedColorRange	= attr(f, "SpeedColorRange")
	c.TrailEnabled		= attr(f, "TrailEnabled")
	c.TrailLifetime		= attr(f, "TrailLifetime")
	c.TrailInterval		= math.max(1 / 240, attr(f, "TrailInterval"))
	c.FlipbookMode		= attr(f, "FlipbookMode")
	c.FlipbookStartRandom = attr(f, "FlipbookStartRandom")
	c.FlipbookFramerate	= attr(f, "FlipbookFramerate")

	-- Shape. The old Circle, Ring and Border shapes are a shape plus a style now.
	local shape = attr(f, "EmissionShape")
	local oldShape = OLD_SHAPES[shape]
	if oldShape then
		shape = oldShape[1]
		if f:GetAttribute("EmissionShapeStyle") == nil then
			c.EmissionShapeStyle = oldShape[2]
		end
	end
	c.EmissionShape = shape

	-- Direction. An old folder has a face name in EmissionDirection and a Vector2
	-- SpreadAngle, spread the ParticleEmitter way: one axis fans across the screen
	-- and the other tilts toward the viewer. Top and Bottom fan with .Y, Left and
	-- Right with .X.
	local face = f:GetAttribute("EmissionDirection")
	local angle = f:GetAttribute("EmissionAngle")
	if typeof(angle) ~= "number" then
		angle = (typeof(face) == "string" and FACE_ANGLES[face]) or DEFAULTS.EmissionAngle
	end
	c.EmissionAngle = angle
	local spread = f:GetAttribute("SpreadAngle")
	local depthSpread = attr(f, "DepthSpreadAngle")
	if typeof(spread) == "Vector2" then
		if face == "Left" or face == "Right" then
			spread, depthSpread = spread.X, spread.Y
		else
			spread, depthSpread = spread.Y, spread.X
		end
	elseif typeof(spread) ~= "number" then
		spread = DEFAULTS.SpreadAngle
	end
	c.spread = math.rad(math.abs(spread))
	c.depthSpread = math.rad(math.abs(depthSpread))

	-- Acceleration is a Vector2 now, Y up. An old Vector3 keeps its X and Y.
	local accel = f:GetAttribute("Acceleration")
	if typeof(accel) == "Vector3" then
		accel = Vector2.new(accel.X, accel.Y)
	elseif typeof(accel) ~= "Vector2" then
		accel = DEFAULTS.Acceleration
	end
	c.accelX, c.accelY = accel.X, -accel.Y

	local orientation = attr(f, "Orientation")
	if orientation == "Free" then orientation = "FacingCamera" end
	c.Orientation = orientation

	-- ParticleEmitter's drag halves a particle's speed every 1/Drag seconds, so it's
	-- exponential decay at Drag * ln 2.
	c.dragK = c.Drag * LN2

	-- Sequence lookup tables ---------------------------------------------------------
	emitter.sizeLUT,   emitter.sizeEnv   = buildNumberLUT(attr(f, "Size"))
	emitter.transLUT,  emitter.transEnv  = buildNumberLUT(attr(f, "Transparency"))
	emitter.squashLUT, emitter.squashEnv = buildNumberLUT(attr(f, "Squash"))
	emitter.colorLUT   = buildColorLUT(attr(f, "Color"))
	emitter.depthTransLUT = buildNumberLUT(attr(f, "DepthTransparency"))
	emitter.speedColorLUT = buildColorLUT(attr(f, "SpeedColor"))
	emitter.speedTransLUT = buildNumberLUT(attr(f, "SpeedTransparency"))

	-- Flipbook -----------------------------------------------------------------------
	local fpr = FLIPBOOK_PER_ROW[attr(f, "FlipbookLayout")]
	if fpr then
		emitter.hasFlipbook = true
		emitter.fbPerRow = fpr
		emitter.fbCount = fpr * fpr
		emitter.fbFrameWidth = attr(f, "FlipbookResolution") / fpr
	else
		emitter.hasFlipbook = false
		emitter.fbCount = 1
	end

	-- Keep the container and live images in step with the new settings.
	local resample = Enum.ResamplerMode[c.ResampleMode == "Pixelated" and "Pixelated" or "Default"]
	c.resample = resample
	if emitter.container then
		emitter.container.ZIndex = c.ZIndex
	end
	for _, p in emitter.particles do
		for _, img in { p.image, p.glow } do
			img.Image = c.Texture
			img.ResampleMode = resample
		end
	end
end

--------------------------------------------------------------------------------------
-- IS THIS THING ON SCREEN?
--------------------------------------------------------------------------------------
-- "Is this instance still part of something that's rendered?"
--
-- IsDescendantOf(game) alone isn't enough: a PluginGui is rendered but isn't in
-- the DataModel, so anything inside one (like the plugin's preview) would look
-- destroyed and be torn down on the first frame. Reaching a LayerCollector
-- covers that case, and a destroyed instance still fails both tests.
local function isMounted(inst)
	return inst:IsDescendantOf(game) or inst:FindFirstAncestorWhichIsA("LayerCollector") ~= nil
end

local function isRenderable(base)
	return base ~= nil and isMounted(base) and base:IsA("GuiBase2d")
end

-- False while the parent, anything above it, or its ScreenGui is hidden. There's
-- no point simulating particles nobody can see.
local function isShown(base)
	local inst = base
	while inst do
		if inst:IsA("GuiObject") then
			if not inst.Visible then return false end
		elseif inst:IsA("LayerCollector") then
			return inst.Enabled
		end
		inst = inst.Parent
	end
	return true
end

--------------------------------------------------------------------------------------
-- WHERE THE PARENT IS ON SCREEN
--------------------------------------------------------------------------------------
-- Read the parent's placement off its Absolute properties, once per frame.
-- AbsolutePosition and AbsoluteSize are its box on screen, with UIScale and any
-- rotated ancestors already applied, and AbsoluteRotation is how far it's turned
-- about the middle of that box. That is all it takes to put any point of the
-- parent on screen and back, and since particles are placed with Scale values,
-- nothing else (UIScale included) needs to be known.
local function refreshView(emitter)
	local base = emitter.base
	local c = emitter.config
	local pos, size = base.AbsolutePosition, base.AbsoluteSize
	local rot = base.AbsoluteRotation
	local rad = math.rad(rot)
	local w, h = math.max(size.X, 1), math.max(size.Y, 1)
	emitter.width, emitter.height = w, h
	emitter.halfW, emitter.halfH = w * 0.5, h * 0.5
	emitter.centerX, emitter.centerY = pos.X + size.X * 0.5, pos.Y + size.Y * 0.5
	emitter.rotation = rot
	emitter.cos, emitter.sin = math.cos(rad), math.sin(rad)

	-- One stud in screen pixels.
	local mode = c.StudSizeRelativeTo
	local reference
	if mode == "ParentWidth" then
		reference = w
	elseif mode == "ParentSmallerSide" then
		reference = math.min(w, h)
	elseif mode == "ParentLargerSide" then
		reference = math.max(w, h)
	elseif mode == "ScreenHeight" then
		local layer = emitter.layer
		reference = (layer and layer.AbsoluteSize.Y) or h
	else
		reference = h
	end
	emitter.studPx = reference * c.StudSize
end

-- A point in the parent's own frame, in screen pixels from its top-left corner,
-- to a point on screen.
local function toScreen(e, lx, ly)
	local x, y = lx - e.halfW, ly - e.halfH
	return e.centerX + x * e.cos - y * e.sin, e.centerY + x * e.sin + y * e.cos
end

-- The reverse: a point on screen to the parent's own frame.
local function toLocal(e, sx, sy)
	local x, y = sx - e.centerX, sy - e.centerY
	return x * e.cos + y * e.sin + e.halfW, y * e.cos - x * e.sin + e.halfH
end

--------------------------------------------------------------------------------------
-- POOLS  (one image pool serves particles, glow copies and trail ghosts)
--------------------------------------------------------------------------------------
local function newImage(): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = "Spark2DParticle"
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.ScaleType = Enum.ScaleType.Stretch
	img.Interactable = false
	img.Archivable = false
	img.ImageTransparency = 1
	return img
end

local function getImage(emitter)
	local img = emitter.imagePool:Acquire()
	img.Image = emitter.config.Texture
	img.ResampleMode = emitter.config.resample
	img.ImageRectOffset = Vector2.zero
	img.ImageRectSize = Vector2.zero
	-- The image still has the pose of whatever particle used it last. It stays
	-- invisible until the next update places it, so that pose never flashes.
	img.ImageTransparency = 1
	return img
end

local function recycle(emitter, p)
	emitter.imagePool:Release(p.image)
	if p.glow then emitter.imagePool:Release(p.glow) end
	emitter.statePool:Release(p)
end

-- The frame particles are drawn into. It fills the parent, so a Scale position on
-- a particle is a fraction of the parent, and it keeps particles from ever
-- blocking clicks on the UI around them.
local function makeContainer(emitter)
	local frame = Instance.new("Frame")
	frame.Name = CONTAINER
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Interactable = false
	frame.Archivable = false
	frame.ZIndex = emitter.config.ZIndex or DEFAULTS.ZIndex
	frame.Parent = emitter.particleParent
	emitter.cleaner:Add(frame)
	return frame
end

--------------------------------------------------------------------------------------
-- EMISSION
--------------------------------------------------------------------------------------
-- Where a particle spawns, as a fraction of the parent (0 to 1 on each axis),
-- plus the direction the edge faces there (degrees clockwise from up) for
-- AwayFromEdge. nil means "no edge here", and the caller picks at random.
local function emitPoint(c, w, h)
	local shape = c.EmissionShape
	local surface = c.EmissionShapeStyle == "Surface"
	if shape == "Point" then
		return c.EmissionOrigin.X, c.EmissionOrigin.Y, nil
	elseif shape == "Line" then
		return math.random(), c.EmissionOrigin.Y, (math.random() < 0.5) and 0 or 180
	elseif shape == "Rectangle" then
		local u, v
		if surface then
			-- Pick a side in proportion to its length, then a point along it.
			local side = math.random() * (w + h) * 2
			if side < w then
				u, v = side / w, 0
			elseif side < w * 2 then
				u, v = (side - w) / w, 1
			elseif side < w * 2 + h then
				u, v = 0, (side - w * 2) / h
			else
				u, v = 1, (side - w * 2 - h) / h
			end
		else
			u, v = math.random(), math.random()
		end
		-- The nearest edge's outward direction.
		local left, right, top, bottom = u * w, (1 - u) * w, v * h, (1 - v) * h
		local nearest = math.min(left, right, top, bottom)
		local edge = (nearest == top and 0) or (nearest == right and 90) or (nearest == bottom and 180) or 270
		return u, v, edge
	else -- "Oval": the ellipse that fills the parent
		local a = math.random() * (2 * math.pi)
		local r = surface and 0.5 or 0.5 * math.sqrt(math.random())
		local ox, oy = math.cos(a), math.sin(a)
		-- An ellipse's normal leans toward its flatter sides.
		local nx, ny = ox / w, oy / h
		return 0.5 + ox * r, 0.5 + oy * r, math.deg(math.atan2(nx, -ny))
	end
end

--------------------------------------------------------------------------------------
-- SPAWN
--------------------------------------------------------------------------------------
local function spawnParticle(emitter, preAge)
	local c = emitter.config
	if #emitter.particles >= emitter.effMax then return nil end

	-- Emit() and Burst() reach here directly, outside the update loop that
	-- normally checks renderability, so a folder under something that isn't a
	-- GuiObject has to be caught here too.
	if not isRenderable(emitter.base) then return nil end

	-- As on a ParticleEmitter: a zero lifetime emits nothing, and nothing lives
	-- past 20 seconds.
	local life = math.min(randRange(c.Lifetime), MAX_LIFETIME)
	if life <= 0 then return nil end
	-- A StudSize of 0 makes everything zero-sized, and nothing can be placed.
	if emitter.studPx <= 0 then return nil end

	local p = emitter.statePool:Acquire()
	p.age, p.life = 0, life
	-- A particle spawned partway through the frame has already been alive for a
	-- little while by the time the frame is drawn. Without this, a fast stream
	-- clumps into one bunch per frame.
	p.firstStep = preAge or 0

	local w, h, studPx = emitter.width, emitter.height, emitter.studPx
	local u, v, edge = emitPoint(c, w, h)
	local lx, ly = u * w, v * h

	-- Direction, in degrees clockwise from up in the parent's own frame.
	local mode = c.EmissionDirectionMode
	local angle = c.EmissionAngle
	if mode == "AwayFromCenter" or mode == "TowardCenter" then
		local dx, dy = lx - emitter.halfW, ly - emitter.halfH
		if dx * dx + dy * dy > 1e-6 then
			angle += math.deg(math.atan2(dx, -dy))
		else
			angle += math.random() * 360
		end
		if mode == "TowardCenter" then angle += 180 end
	elseif mode == "AwayFromEdge" then
		angle += edge or math.random() * 360
	end

	-- Spread across the screen, and toward or away from the viewer. The second
	-- one can't move a particle anywhere a flat screen can show, so it shortens
	-- the on-screen speed instead, the way a real emitter's cone looks from in
	-- front of the part.
	angle += math.deg((math.random() * 2 - 1) * c.spread)
	local speed = randRange(c.Speed) * math.cos((math.random() * 2 - 1) * c.depthSpread)
	local rad = math.rad(angle)
	local vx, vy = math.sin(rad) * speed, -math.cos(rad) * speed

	-- A particle lives in one of two spaces, fixed at spawn so toggling
	-- MoveWithParent later doesn't make live particles jump.
	--   Moves with parent: studs from the parent's centre, in the parent's own
	--     frame. Drawing it relative to the parent carries it along as the parent
	--     moves, resizes or turns, which is what LockedToPart does.
	--   Doesn't: a point on screen, in pixels. Placed once and left behind.
	-- Velocities are always studs per second.
	local inherit = c.VelocityInheritance
	p.locked = c.MoveWithParent
	if p.locked then
		p.x, p.y = (lx - emitter.halfW) / studPx, (ly - emitter.halfH) / studPx
		if inherit ~= 0 then
			vx += emitter.inheritLocalX * inherit
			vy += emitter.inheritLocalY * inherit
		end
	else
		p.x, p.y = toScreen(emitter, lx, ly)
		-- The emission direction turns with the parent, like a rotated part's.
		local cs, sn = emitter.cos, emitter.sin
		vx, vy = vx * cs - vy * sn, vx * sn + vy * cs
		if inherit ~= 0 then
			vx += emitter.inheritScreenX * inherit
			vy += emitter.inheritScreenY * inherit
		end
	end
	p.vx, p.vy = vx, vy
	p.travel = screenAngle(vx, vy)

	-- Depth parallax.
	local depth = randRange(c.Depth)
	p.depth = depth
	if depth > 0 then p.depthMul = 1 / (depth + 1)
	elseif depth < 0 then p.depthMul = -depth + 1
	else p.depthMul = 1 end

	p.rot = randRange(c.Rotation)
	p.rotSpeed = randRange(c.RotSpeed)
	-- Each sequence gets its own envelope roll, as on a ParticleEmitter.
	p.envS = math.random() * 2 - 1
	p.envT = math.random() * 2 - 1
	p.envQ = math.random() * 2 - 1
	p.seed = math.random() * 1000
	p.nextTrail = c.TrailInterval

	-- Flipbook bookkeeping.
	p.fbFramerate = randRange(c.FlipbookFramerate)
	p.fbStart = c.FlipbookStartRandom and math.random(1, emitter.fbCount) or 1
	p.fbFrame = p.fbStart
	p.fbLastStep = -1

	if c.GlowStrength > 0 then
		local g = getImage(emitter)
		g.ZIndex = c.ZIndex - 1
		p.glow = g
	else
		p.glow = nil
	end

	local img = getImage(emitter)
	img.ZIndex = c.ZIndex
	p.image = img

	table.insert(emitter.particles, p)
	Spark2D.ParticleSpawned:Fire(emitter.folder, p.x, p.y)
	return p
end

--------------------------------------------------------------------------------------
-- FLIPBOOK FRAME
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
-- DRAW  (shared by particles, glow copies and trail ghosts)
--------------------------------------------------------------------------------------
-- x, y is a position in the particle's own space (see spawnParticle). w and h are
-- screen pixels. screenRot is the rotation the particle should have on screen;
-- the image already turns with the parent, so that part is taken back off.
--
-- Everything is set as Scale, a fraction of the parent, so Roblox does the
-- UIScale and layout maths itself. The pixel values are rounded first: a
-- particle drifting across fractional pixels shimmers as Roblox rounds it
-- differently from frame to frame.
local round = math.round
local function draw(emitter, img, locked, x, y, w, h, screenRot, color, trans, rectOff, rectSize)
	local lx, ly
	if locked then
		local studPx = emitter.studPx
		lx, ly = emitter.halfW + x * studPx, emitter.halfH + y * studPx
	else
		lx, ly = toLocal(emitter, x, y)
	end
	local pw, ph = emitter.width, emitter.height
	img.Position = UDim2.fromScale(round(lx) / pw, round(ly) / ph)
	img.Size = UDim2.fromScale(round(w) / pw, round(h) / ph)
	img.Rotation = screenRot - emitter.rotation
	img.ImageColor3 = color
	img.ImageTransparency = trans
	if rectSize then
		img.ImageRectOffset = rectOff
		img.ImageRectSize = rectSize
	end
end

--------------------------------------------------------------------------------------
-- TRAIL GHOSTS
--------------------------------------------------------------------------------------
local function spawnGhost(emitter, p, w, h, screenRot, color, trans, rectOff, rectSize)
	local c = emitter.config
	if #emitter.ghosts >= emitter.effMax then return end
	local g = emitter.ghostPool:Acquire()
	local img = getImage(emitter)
	img.ZIndex = c.ZIndex - 1
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
	local particles = emitter.particles
	local hasFlipbook = emitter.hasFlipbook
	local useSpeedColor = c.UseSpeedColor
	local depthActive = c.Depth.Min ~= c.Depth.Max
	local emitTime = emitter.time
	local studPx, cs, sn = emitter.studPx, emitter.cos, emitter.sin
	local parentRot = emitter.rotation
	local ori = c.Orientation
	local velocityAligned = ori == "VelocityParallel" or ori == "VelocityPerpendicular"
	local tp, tf, ts = c.TurbulenceStrength, c.TurbulenceFrequency, c.TurbulenceSpeed

	-- Motion is integrated exactly rather than stepped. With drag, velocity
	-- relaxes toward a/k along an exponential, so the path is the same at 30 fps
	-- as at 240, and gravity levels off at a terminal speed like a real emitter's.
	local k = c.dragK
	local frameDecay, frameReach = 1, dt
	if k ~= 0 then
		frameDecay = math.exp(-k * dt)
		frameReach = (1 - frameDecay) / k
	end

	for i = #particles, 1, -1 do
		local p = particles[i]
		local step, decay, reach = dt, frameDecay, frameReach
		if p.firstStep then
			step = p.firstStep
			p.firstStep = nil
			if k ~= 0 then
				decay = math.exp(-k * step)
				reach = (1 - decay) / k
			else
				reach = step
			end
		end
		p.age += step

		if p.age >= p.life then
			Spark2D.ParticleDied:Fire(emitter.folder, p.x, p.y)
			recycle(emitter, p)
			local n = #particles
			particles[i] = particles[n]
			particles[n] = nil
		else
			local locked = p.locked

			-- Acceleration and turbulence act in world space, so down stays down
			-- the screen however the parent is turned. For a particle that moves
			-- with the parent, that means turning them into the parent's frame.
			local ax, ay = c.accelX, c.accelY
			if tp ~= 0 then
				local nx, ny = p.x, p.y
				if not locked then nx, ny = nx / studPx, ny / studPx end
				ax += math.noise(nx * tf, ny * tf, emitTime * ts + p.seed) * tp
				ay += math.noise(nx * tf + 37.1, ny * tf + 11.7, emitTime * ts + p.seed) * tp
			end
			if locked then
				ax, ay = ax * cs + ay * sn, ay * cs - ax * sn
			end

			-- Displacement in studs. Depth scales apparent movement (parallax).
			local vx, vy = p.vx, p.vy
			local dx, dy
			if k ~= 0 then
				local tx, ty = ax / k, ay / k
				dx = tx * step + (vx - tx) * reach
				dy = ty * step + (vy - ty) * reach
				vx = tx + (vx - tx) * decay
				vy = ty + (vy - ty) * decay
			else
				dx = (vx + 0.5 * ax * step) * step
				dy = (vy + 0.5 * ay * step) * step
				vx += ax * step
				vy += ay * step
			end
			local dm = p.depthMul
			if locked then
				p.x += dx * dm
				p.y += dy * dm
			else
				p.x += dx * dm * studPx
				p.y += dy * dm * studPx
			end
			p.vx, p.vy = vx, vy
			p.rot += p.rotSpeed * step

			local t = p.age / p.life
			local sizeV = sampleNumberE(emitter.sizeLUT, emitter.sizeEnv, t, p.envS)
			local transV = sampleNumberE(emitter.transLUT, emitter.transEnv, t, p.envT)
			local squashV = sampleNumberE(emitter.squashLUT, emitter.squashEnv, t, p.envQ)
			local col = sampleColor(emitter.colorLUT, t)

			if useSpeedColor then
				local sr = c.SpeedColorRange
				local st = clamp((math.sqrt(vx * vx + vy * vy) - sr.Min) / math.max(sr.Max - sr.Min, 1e-6), 0, 1)
				local sc = sampleColor(emitter.speedColorLUT, st)
				col = Color3.new(col.R * sc.R, col.G * sc.G, col.B * sc.B)
				transV = clamp(transV + sampleNumber(emitter.speedTransLUT, st), 0, 1)
			end

			if depthActive then
				local ratio = (p.depth - c.Depth.Min) / math.max(c.Depth.Max - c.Depth.Min, 1e-6)
				local dtv = sampleNumber(emitter.depthTransLUT, t) * ratio
				transV = clamp(transV + (1 - transV) * dtv, 0, 1)
			end

			-- Size is in studs, ParticleEmitter style: a Size of 1 is a particle
			-- 2 studs across. Squash narrows it by (1 + q) and makes it that much
			-- taller for positive q, the other way round for negative.
			local diameter = math.max(sizeV, 0) * 2 * studPx * dm
			local f = 1 + math.abs(squashV)
			local w, h
			if squashV >= 0 then
				w, h = diameter / f, diameter * f
			else
				w, h = diameter * f, diameter / f
			end

			-- Rotation on screen.
			local screenRot
			if velocityAligned then
				if vx * vx + vy * vy > 1e-9 then
					p.travel = screenAngle(vx, vy)
				end
				local travel = p.travel
				if locked then travel += parentRot end
				-- Parallel lays the particle's width along its travel, the way a
				-- real emitter does. Perpendicular turns it a quarter turn from that.
				if ori == "VelocityParallel" then
					screenRot = travel + p.rot
				else
					screenRot = travel + 90 + p.rot
				end
			else
				-- Camera-facing. A ParticleEmitter turns these counter-clockwise for
				-- a positive Rotation (measured in Studio, whatever the docs say),
				-- and keeps them upright however its part is turned.
				screenRot = -p.rot
			end

			local rectOff, rectSize
			if hasFlipbook then
				rectOff, rectSize = computeFlipbook(emitter, p, t)
			end

			if p.glow then
				local gcol = col:Lerp(Color3.new(1, 1, 1), 0.35)
				local gtrans = clamp(1 - (1 - transV) * c.GlowStrength, 0, 1)
				draw(emitter, p.glow, locked, p.x, p.y, w * 1.9, h * 1.9, screenRot, gcol, gtrans, rectOff, rectSize)
			end
			draw(emitter, p.image, locked, p.x, p.y, w, h, screenRot, col, transV, rectOff, rectSize)

			if c.TrailEnabled and p.age >= p.nextTrail then
				spawnGhost(emitter, p, w, h, screenRot, col, transV, rectOff, rectSize)
				p.nextTrail += c.TrailInterval
			end
		end
	end

	-- Trail ghosts.
	local ghosts = emitter.ghosts
	for i = #ghosts, 1, -1 do
		local g = ghosts[i]
		g.age += dt
		local gt = g.age / g.life
		if gt >= 1 then
			emitter.imagePool:Release(g.image)
			emitter.ghostPool:Release(g)
			local n = #ghosts
			ghosts[i] = ghosts[n]
			ghosts[n] = nil
		else
			local tr = clamp(g.trans + (1 - g.trans) * gt, 0, 1)
			draw(emitter, g.image, g.locked, g.x, g.y, g.w, g.h, g.rot, g.color, tr, g.rectOff, g.rectSize)
		end
	end
end

-- Drop every live particle and ghost, keeping their images for reuse.
local function clearParticles(emitter)
	for i = #emitter.particles, 1, -1 do
		recycle(emitter, emitter.particles[i])
		emitter.particles[i] = nil
	end
	for i = #emitter.ghosts, 1, -1 do
		local g = emitter.ghosts[i]
		emitter.imagePool:Release(g.image)
		emitter.ghostPool:Release(g)
		emitter.ghosts[i] = nil
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
	local graphics = graphicsRateScale()

	for folder, emitter in self._emitters do
		if not isMounted(folder) then
			self:Stop(folder)
		else
			emitter.base = folder.Parent
			if not (isRenderable(emitter.base) and isShown(emitter.base)) then
				-- Not being drawn: clear everything and idle.
				if #emitter.particles > 0 or #emitter.ghosts > 0 then
					clearParticles(emitter)
				end
				emitter.emitAge = 0
				emitter.lastCenter = nil
			else
				local c = emitter.config
				local edt = scaled * c.TimeScale
				emitter.time += edt
				emitter.effMax = math.max(1, math.floor(c.MaxParticles * self._quality))
				-- Re-read every frame: position, size, UIScale and rotation are all
				-- the kind of thing that gets tweened.
				refreshView(emitter)

				-- The parent's own velocity, for VelocityInheritance: how fast its
				-- centre crosses the screen, in studs per second, both as seen on
				-- screen and in the parent's own frame.
				local cx, cy = emitter.centerX, emitter.centerY
				local last = emitter.lastCenter
				local ivx, ivy = 0, 0
				if last and edt > 0 and emitter.studPx > 0 then
					ivx = (cx - last.X) / (edt * emitter.studPx)
					ivy = (cy - last.Y) / (edt * emitter.studPx)
				end
				emitter.lastCenter = Vector2.new(cx, cy)
				emitter.inheritScreenX, emitter.inheritScreenY = ivx, ivy
				local cs, sn = emitter.cos, emitter.sin
				emitter.inheritLocalX = ivx * cs + ivy * sn
				emitter.inheritLocalY = ivy * cs - ivx * sn

				-- Emission, gated by Enabled, StartDelay and StopAfter.
				if c.Enabled then
					emitter.emitAge += edt
					local past = emitter.emitAge - c.StartDelay
					local within = (c.StopAfter <= 0) or (emitter.emitAge < c.StartDelay + c.StopAfter)
					local rate = c.Rate
					if c.ReduceOnLowGraphics then rate *= graphics end
					if past >= 0 and within and rate > 0 and edt > 0 then
						emitter.rateAccum += rate * edt
						while emitter.rateAccum >= 1 do
							emitter.rateAccum -= 1
							-- What's left in the accumulator is how far past this
							-- particle's spawn time the frame already is.
							spawnParticle(emitter, emitter.rateAccum / rate)
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
	-- RunService:IsEdit() needs plugin security, which a normal LocalScript
	-- doesn't have. IsStudio() and IsRunning() give the same answer without it.
	local isEditMode = RunService:IsStudio() and not RunService:IsRunning()
	local signal = isEditMode and RunService.Heartbeat or RunService.RenderStepped
	self._cleaner:Connect(signal, function(dt)
		self:_update(dt)
	end)
end

--------------------------------------------------------------------------------------
-- REGISTER
--------------------------------------------------------------------------------------
-- Things that only change when the folder moves in the hierarchy.
local function refreshAncestry(emitter)
	local base = emitter.base
	emitter.lastCenter = nil
	emitter.layer = nil
	if base then
		emitter.layer = base:IsA("LayerCollector") and base or base:FindFirstAncestorWhichIsA("LayerCollector")
	end
	if isRenderable(base) then
		refreshView(emitter)
	end
end

function Spark2D:_register(folder, container)
	self._cleaner = self._cleaner or Cleaner.new()
	local cleaner = self._cleaner:Extend()

	local emitter = {
		folder = folder,
		base = folder.Parent,
		particleParent = container or folder,
		config = {},
		particles = {},
		ghosts = {},
		rateAccum = 0,
		emitAge = 0,
		time = 0,
		effMax = DEFAULTS.MaxParticles,
		cleaner = cleaner,

		-- Stand-in view until the parent can be measured: an unrotated
		-- 100 x 100 box at the origin.
		width = 100,
		height = 100,
		halfW = 50,
		halfH = 50,
		centerX = 50,
		centerY = 50,
		rotation = 0,
		cos = 1,
		sin = 0,
		studPx = 10,
		inheritScreenX = 0,
		inheritScreenY = 0,
		inheritLocalX = 0,
		inheritLocalY = 0,
	}

	emitter.imagePool = cleaner:Add(Pool.new(newImage, {
		-- Every image is destroyed with the emitter, whether it's in use or not.
		Initialize = function(img) cleaner:Add(img) end,
		Reset = function(img) img.ImageTransparency = 1 end,
		Parent = function() return emitter.container end,
		UnparentOnRelease = true,
	}))
	emitter.statePool = cleaner:Add(Pool.new(function() return {} end, { Reset = table.clear }))
	emitter.ghostPool = cleaner:Add(Pool.new(function() return {} end, { Reset = table.clear }))

	if self.WarnUnparented and not isRenderable(emitter.base) then
		warn(("[Spark2D] '%s' is not (yet) under a GuiObject/ScreenGui; it will render once it is."):format(folder.Name))
	end

	buildConfig(emitter)
	emitter.container = makeContainer(emitter)
	refreshAncestry(emitter)
	emitter.imagePool:Prewarm(math.min(emitter.config.MaxParticles, PREALLOC))

	cleaner:Connect(folder.AttributeChanged, function()
		buildConfig(emitter)
	end)
	cleaner:Connect(folder.AncestryChanged, function()
		if not isMounted(folder) then
			self:Stop(folder)
		else
			emitter.base = folder.Parent
			refreshAncestry(emitter)
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

-- A burst from outside the update loop needs the view refreshed first, since the
-- loop may not have run for this emitter yet.
local function prepareBurst(self, emitter)
	emitter.effMax = math.max(1, math.floor(emitter.config.MaxParticles * self._quality))
	if isRenderable(emitter.base) then
		refreshView(emitter)
	end
end

-- Burst. target = Folder | container | nil (all). count defaults to BurstCount.
function Spark2D:Emit(target, count)
	for _, folder in self:_resolve(target) do
		local emitter = self:_ensure(folder)
		prepareBurst(self, emitter)
		for _ = 1, count or emitter.config.BurstCount or 1 do
			spawnParticle(emitter)
		end
	end
end

-- One burst on exactly one folder, registering it if needed. Unlike Emit() it
-- doesn't look for the tag, so it works on a folder you drive directly, which is
-- how the Studio plugin's preview fires its bursts.
function Spark2D:Burst(folder, count)
	local emitter = self:_ensure(folder)
	prepareBurst(self, emitter)
	for _ = 1, count or emitter.config.BurstCount or 1 do
		spawnParticle(emitter)
	end
end

-- Start continuous emission (Enabled = true, and register).
function Spark2D:Enable(target)
	for _, folder in self:_resolve(target) do
		folder:SetAttribute("Enabled", true)
		self:_ensure(folder)
	end
end

-- Soft stop (Enabled = false): no new particles, live ones finish. Not a teardown.
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

-- Older name for _ensure.
Spark2D.StartEmitter = Spark2D._ensure

-- Hard teardown of one emitter: disconnect everything and destroy its images.
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
