--!strict
--[[
	Spark2D demo
	============
	Three short examples, built entirely from code so that every attribute that
	matters is visible right here rather than buried in a .rbxmx you have to open
	in Studio to read.

	  1. Ambient: a continuous emitter that just runs
	  2. Burst: a one-off burst fired on click
	  3. Trail: particles left behind by a GuiObject that moves

	Spark2D drives PlayerGui and hooks RunService, which is why this is a
	LocalScript in StarterPlayerScripts rather than a Script on the server.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Spark2D = require(Packages:WaitForChild("Spark2D"))

local EMITTER_TAG = "UIParticleEmitter"

--------------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------------

-- An effect is a plain Folder tagged UIParticleEmitter. The attributes on it are
-- the whole configuration. There is no custom instance type involved, and
-- anything left unset falls back to Spark2D's own default.
local function createEmitter(parent: GuiObject, name: string, attributes: { [string]: any }): Folder
	local folder = Instance.new("Folder")
	folder.Name = name

	for key, value in attributes do
		folder:SetAttribute(key, value)
	end

	folder.Parent = parent
	CollectionService:AddTag(folder, EMITTER_TAG)

	return folder
end

local player = Players.LocalPlayer

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "Spark2DDemo"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = player:WaitForChild("PlayerGui")

local row = Instance.new("Frame")
row.Name = "Row"
row.AnchorPoint = Vector2.new(0.5, 0.5)
row.Position = UDim2.fromScale(0.5, 0.5)
row.Size = UDim2.fromOffset(720, 240)
row.BackgroundTransparency = 1
row.Parent = screenGui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 16)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.VerticalAlignment = Enum.VerticalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = row

local function createCard(order: number, title: string): Frame
	local card = Instance.new("Frame")
	card.Name = title
	card.LayoutOrder = order
	card.Size = UDim2.fromOffset(224, 224)
	card.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	card.BorderSizePixel = 0
	card.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = card

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -10)
	label.Size = UDim2.new(1, -16, 0, 16)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(148, 158, 178)
	label.Text = title
	label.Parent = card

	return card
end

--------------------------------------------------------------------------------------
-- 1. AMBIENT: runs on its own, no script interaction at all
--------------------------------------------------------------------------------------
do
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.44)
	stage.Size = UDim2.fromOffset(120, 120)
	stage.BackgroundTransparency = 1
	stage.Parent = createCard(1, "Ambient")

	-- Enabled = true means it starts emitting the moment Spark2D registers it.
	-- Sizes and speeds are in studs, and a stud is a tenth of the stage's height
	-- by default (StudSize = 0.1), so here a stud is 12 pixels.
	createEmitter(stage, "Embers", {
		Enabled = true,
		Rate = 22,
		EmissionShape = "Oval",
		EmissionAngle = 0, -- straight up
		SpreadAngle = 24,
		Lifetime = NumberRange.new(1.2, 2.0),
		Speed = NumberRange.new(3, 6),
		Acceleration = Vector2.new(0, 3), -- +Y is up the screen
		Size = NumberSequence.new(0.6),
		Color = ColorSequence.new(Color3.fromRGB(120, 190, 255)),
		GlowStrength = 0.4,

		-- Fade in and back out so particles never pop into or out of existence.
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
end

--------------------------------------------------------------------------------------
-- 2. BURST: Enabled = false, so nothing happens until something calls Emit
--------------------------------------------------------------------------------------
do
	local button = Instance.new("TextButton")
	button.Name = "Stage"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.44)
	button.Size = UDim2.fromOffset(120, 120)
	button.BackgroundColor3 = Color3.fromRGB(34, 38, 48)
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 13
	button.TextColor3 = Color3.fromRGB(210, 220, 235)
	button.Text = "CLICK"
	button.Parent = createCard(2, "Burst")

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local burst = createEmitter(button, "Burst", {
		Enabled = false, -- burst only: no continuous stream
		BurstCount = 26,
		EmissionShape = "Point",
		SpreadAngle = 180, -- every direction
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(18, 30),
		Drag = 3, -- loses half its speed every third of a second
		Color = ColorSequence.new(Color3.fromRGB(255, 200, 80)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.7),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})

	-- Emit registers the folder itself the first time it sees it, so this works
	-- whether or not Init() has already run.
	button.Activated:Connect(function()
		Spark2D:Emit(burst)
	end)
end

--------------------------------------------------------------------------------------
-- 3. TRAIL: MoveWithParent = false leaves particles behind a moving parent
--------------------------------------------------------------------------------------
do
	local card = createCard(3, "Trail")

	-- The dot is tiny, and effects are sized relative to their parent, so the
	-- effect lives in a transparent holder around the dot instead. The holder is
	-- what moves.
	local traveller = Instance.new("Frame")
	traveller.Name = "Stage"
	traveller.AnchorPoint = Vector2.new(0.5, 0.5)
	traveller.Position = UDim2.new(0.2, 0, 0.44, 0)
	traveller.Size = UDim2.fromOffset(60, 60)
	traveller.BackgroundTransparency = 1
	traveller.Parent = card

	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(14, 14)
	dot.BackgroundColor3 = Color3.fromRGB(255, 120, 190)
	dot.BorderSizePixel = 0
	dot.Parent = traveller

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	createEmitter(traveller, "Wake", {
		Enabled = true,
		Rate = 40,
		EmissionShape = "Point",
		SpreadAngle = 30,
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(0, 1),
		Color = ColorSequence.new(Color3.fromRGB(255, 120, 190)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(1, 0),
		}),

		-- The point of this card: particles are placed in screen space once and
		-- left there, so the dot draws a wake instead of dragging its cloud along.
		MoveWithParent = false,
	})

	-- Nothing about the tween is Spark2D-specific; the emitter simply follows
	-- whatever its parent GuiObject happens to be doing.
	TweenService:Create(
		traveller,
		TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.new(0.8, 0, 0.44, 0) }
	):Play()
end

--------------------------------------------------------------------------------------

-- Finds every tagged folder under PlayerGui, registers it, and starts watching for
-- more. The three above are already parented, so they start immediately.
Spark2D:Init()
