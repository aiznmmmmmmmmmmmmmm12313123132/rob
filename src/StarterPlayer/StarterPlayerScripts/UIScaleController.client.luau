--!strict
--[[
	UIScaleController (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > UIScaleController

	Keeps the HUD on-screen and readable on phones, tablets, PCs and TVs.

	  1. Measures the safe area: Roblox's top bar (GuiService:GetGuiInset()),
	     device cutouts such as notches and the home indicator, and on console
	     a TV overscan margin.
	  2. Snaps each HUD element's AnchorPoint to the screen edge it sits on,
	     without moving it, so scaling up grows it inward, never off-screen.
	  3. Moves each element inside the safe area and scales it with one UIScale
	     value derived from the screen size, aspect ratio and device.

	Managed elements are the top-level GuiObjects of the ScreenGuis named in
	MANAGED_SCREEN_GUIS, e.g. HUD > RollButton, HUD > UpgradesButton,
	HUD > BackpackButton, SettingsGui > SettingsButton. To leave one alone,
	give it the attribute AutoScale = false.

	Who owns the UIScale: if an element has no UIScale, one named "AutoScale"
	is added and driven directly. If it already has one (e.g. for a hover
	animation), only that UIScale's "BaseScale" attribute is written, and the
	script animating it multiplies its tween targets by it (SettingsController
	does this). Otherwise the two would fight over UIScale.Scale.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InputManager = require(ReplicatedStorage:WaitForChild("Source"):WaitForChild("InputManager") :: ModuleScript)

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

-- Rename "HUD" to your main HUD ScreenGui's name; add any other HUD ScreenGuis.
local MANAGED_SCREEN_GUIS = { "HUD", "SettingsGui" }

-- The screen size your HUD's Offset values were designed at. A safe area of
-- exactly this size renders the HUD at 1:1.
local REFERENCE_RESOLUTION = Vector2.new(1280, 720)

-- Per device: a multiplier on the fitted scale, then clamped to [min, max].
-- The phone floor keeps buttons finger-sized even on small screens.
local PLATFORM_RULES: { [string]: { multiplier: number, min: number, max: number } } = {
	Desktop = { multiplier = 1, min = 0.75, max = 2 },
	Mobile = { multiplier = 1.2, min = 0.8, max = 1.3 },
	Console = { multiplier = 1.1, min = 1, max = 2 },
}

-- Fraction of the screen kept clear on every edge of a TV (a 90% title-safe
-- area), because many TVs crop the picture's edges.
local TV_SAFE_MARGIN = 0.05

local OPT_OUT_ATTRIBUTE = "AutoScale"
local BASE_SCALE_ATTRIBUTE = "BaseScale"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type Insets = { left: number, top: number, right: number, bottom: number }

type Managed = {
	basePosition: UDim2, -- the designed Position, after AnchorPoint snapping
	uiScale: UIScale,
	ownsScale: boolean,
	movable: boolean, -- false when a UIListLayout etc. positions the element
	ancestryConnection: RBXScriptConnection,
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
local platform: string = InputManager.getPlatform()

local insets: Insets = { left = 0, top = 0, right = 0, bottom = 0 }
local currentScale = 1
local managed: { [GuiObject]: Managed } = {}

--------------------------------------------------------------------------------
-- Safe-area measurement
--------------------------------------------------------------------------------

--[[
	GuiService:GetGuiInset() reports Roblox's top bar, but it knows nothing
	about notches. ScreenGui.ScreenInsets does: the engine shrinks a ScreenGui
	set to CoreUISafeInsets so it avoids device cutouts AND the top bar. So we
	put zero-size markers in the corners of a full-screen ScreenGui and of a
	safe one, and compare where they land. Zero-size markers draw nothing and
	can't catch clicks.
]]
type Probe = { topLeft: Frame, bottomRight: Frame }

local function makeProbe(name: string, ignoreGuiInset: boolean, screenInsets: Enum.ScreenInsets): Probe
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = ignoreGuiInset
	gui.ScreenInsets = screenInsets

	local function marker(markerName: string, position: UDim2): Frame
		local frame = Instance.new("Frame")
		frame.Name = markerName
		frame.Position = position
		frame.Size = UDim2.fromOffset(0, 0)
		frame.BackgroundTransparency = 1
		frame.Parent = gui
		return frame
	end

	local probe = {
		topLeft = marker("TopLeft", UDim2.fromScale(0, 0)),
		bottomRight = marker("BottomRight", UDim2.fromScale(1, 1)),
	}
	gui.Parent = playerGui
	return probe
end

local fullProbe = makeProbe("SafeAreaProbe_Full", true, Enum.ScreenInsets.None)
local safeProbe = makeProbe("SafeAreaProbe_Safe", false, Enum.ScreenInsets.CoreUISafeInsets)

-- Updates `insets` (pixels to keep clear on each edge) and returns the full screen size.
local function measure(): Vector2
	local screenTopLeft = fullProbe.topLeft.AbsolutePosition
	local screenBottomRight = fullProbe.bottomRight.AbsolutePosition
	local safeTopLeft = safeProbe.topLeft.AbsolutePosition
	local safeBottomRight = safeProbe.bottomRight.AbsolutePosition
	local screenSize = screenBottomRight - screenTopLeft

	-- The probe already includes the top bar; GetGuiInset() is a floor in case
	-- the engine reports it differently on some device.
	local topBarInset, bottomInset = GuiService:GetGuiInset()
	local left = math.max(safeTopLeft.X - screenTopLeft.X, topBarInset.X)
	local top = math.max(safeTopLeft.Y - screenTopLeft.Y, topBarInset.Y)
	local right = math.max(screenBottomRight.X - safeBottomRight.X, bottomInset.X)
	local bottom = math.max(screenBottomRight.Y - safeBottomRight.Y, bottomInset.Y)

	if platform == "Console" then
		local marginX, marginY = screenSize.X * TV_SAFE_MARGIN, screenSize.Y * TV_SAFE_MARGIN
		left, right = math.max(left, marginX), math.max(right, marginX)
		top, bottom = math.max(top, marginY), math.max(bottom, marginY)
	end

	insets = {
		left = math.max(0, left),
		top = math.max(0, top),
		right = math.max(0, right),
		bottom = math.max(0, bottom),
	}
	return screenSize
end

local function computeScale(screenSize: Vector2): number
	local rules = PLATFORM_RULES[platform] or PLATFORM_RULES.Desktop
	local safeWidth = screenSize.X - insets.left - insets.right
	local safeHeight = screenSize.Y - insets.top - insets.bottom
	-- Fit the reference layout into the safe area. Taking the smaller ratio is
	-- what makes this aspect-ratio aware: an ultrawide monitor is limited by
	-- its height, a narrow screen by its width, so the HUD fits both ways.
	local fit = math.min(safeWidth / REFERENCE_RESOLUTION.X, safeHeight / REFERENCE_RESOLUTION.Y)
	local scale = math.clamp(fit * rules.multiplier, rules.min, rules.max)
	return math.round(scale * 100) / 100 -- ignore sub-pixel changes
end

--------------------------------------------------------------------------------
-- Anchoring
--------------------------------------------------------------------------------

-- 0 = left/top edge, 1 = right/bottom edge, 0.5 = middle.
local function edgeAnchor(positionScale: number): number
	if positionScale <= 1 / 3 then
		return 0
	elseif positionScale >= 2 / 3 then
		return 1
	end
	return 0.5
end

-- Constraints and AutomaticSize make the drawn size differ from Size, which
-- the compensation below relies on.
local function hasSizeOverride(element: GuiObject): boolean
	return element.AutomaticSize ~= Enum.AutomaticSize.None
		or element:FindFirstChildWhichIsA("UIAspectRatioConstraint") ~= nil
		or element:FindFirstChildWhichIsA("UISizeConstraint") ~= nil
end

--[[
	UIScale grows an element around its AnchorPoint. A button on the right edge
	anchored at X = 0 therefore grows off-screen, while one anchored at X = 1
	grows inward. This re-anchors each element to the edge it sits on WITHOUT
	moving it on screen:

	    top-left corner = Position - AnchorPoint * Size    (UDim2 maths)

	Changing AnchorPoint by d and Position by d * Size keeps that corner fixed
	at every screen size, because Position and Size scale with the same parent.
]]
local function snapAnchorToEdge(element: GuiObject)
	local position = element.Position
	local anchor = element.AnchorPoint
	local target = Vector2.new(edgeAnchor(position.X.Scale), edgeAnchor(position.Y.Scale))
	if target == anchor then
		return
	end
	if hasSizeOverride(element) then
		if RunService:IsStudio() then
			warn(
				`[UIScaleController] {element:GetFullName()} sits near an edge but isn't anchored to it, and a `
					.. `constraint or AutomaticSize sets its size, so it wasn't re-anchored. Set its AnchorPoint to `
					.. `({target}) so scaling keeps it on-screen.`
			)
		end
		return
	end
	local delta = target - anchor
	local size = element.Size
	element.AnchorPoint = target
	element.Position = position
		+ UDim2.new(delta.X * size.X.Scale, delta.X * size.X.Offset, delta.Y * size.Y.Scale, delta.Y * size.Y.Offset)
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

--[[
	Places an element in the safe area and applies the shared scale.

	On each axis, the Scale part of Position is measured against the safe area
	instead of the full screen:

	    x = insetLeft + Position.X.Scale * safeWidth + Position.X.Offset * scale

	As a change to the designed Position, that is:

	    shift = insetLeft - Position.X.Scale * (insetLeft + insetRight)

	  Scale 0   (left edge)   ->  pushed right by the left inset (notch)
	  Scale 1   (right edge)  ->  pushed left by the right inset
	  Scale 0.5 (centre)      ->  centred in the safe area

	Offsets are multiplied by the scale too, so margins and the gaps between
	neighbouring elements grow with the elements and they never overlap.
]]
local function applyLayout(element: GuiObject, entry: Managed)
	if entry.movable then
		local base = entry.basePosition
		local shiftX = insets.left - base.X.Scale * (insets.left + insets.right)
		local shiftY = insets.top - base.Y.Scale * (insets.top + insets.bottom)
		element.Position = UDim2.new(
			base.X.Scale,
			math.round(base.X.Offset * currentScale + shiftX),
			base.Y.Scale,
			math.round(base.Y.Offset * currentScale + shiftY)
		)
	end
	entry.uiScale:SetAttribute(BASE_SCALE_ATTRIBUTE, currentScale)
	if entry.ownsScale then
		entry.uiScale.Scale = currentScale
	end
end

local function unmanage(element: GuiObject)
	local entry = managed[element]
	if entry then
		entry.ancestryConnection:Disconnect()
		managed[element] = nil
	end
end

local function manage(element: GuiObject, positionedByLayout: boolean)
	if managed[element] or element:GetAttribute(OPT_OUT_ATTRIBUTE) == false then
		return
	end
	if not positionedByLayout then
		snapAnchorToEdge(element)
	end

	local existingScale = element:FindFirstChildOfClass("UIScale")
	local uiScale: UIScale
	if existingScale then
		uiScale = existingScale
	else
		uiScale = Instance.new("UIScale")
		uiScale.Name = "AutoScale"
		uiScale.Parent = element
	end

	local entry: Managed = {
		basePosition = element.Position,
		uiScale = uiScale,
		ownsScale = existingScale == nil,
		movable = not positionedByLayout,
		ancestryConnection = element.AncestryChanged:Connect(function()
			if not element:IsDescendantOf(playerGui) then
				unmanage(element)
			end
		end),
	}
	managed[element] = entry
	applyLayout(element, entry)
end

local function manageScreenGui(gui: ScreenGui)
	-- Take over inset handling, so every managed ScreenGui shares one
	-- coordinate space (the whole screen) and applyLayout adds the insets.
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None

	local positionedByLayout = gui:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	local function onChild(child: Instance)
		if child:IsA("GuiObject") then
			manage(child, positionedByLayout)
		end
	end
	gui.ChildAdded:Connect(onChild)
	for _, child in gui:GetChildren() do
		onChild(child)
	end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function refresh()
	local screenSize = measure()
	if screenSize.X <= 0 or screenSize.Y <= 0 then
		return -- not laid out yet; the probes' change signals will call back
	end
	currentScale = computeScale(screenSize)
	for element, entry in managed do
		applyLayout(element, entry)
	end
	-- Handy when testing with Studio's device emulator: watch these on the script.
	script:SetAttribute("Platform", platform)
	script:SetAttribute("Scale", currentScale)
	script:SetAttribute("AspectRatio", math.round(screenSize.X / screenSize.Y * 100) / 100)
	script:SetAttribute("Insets", `L{insets.left} T{insets.top} R{insets.right} B{insets.bottom}`)
end

-- Rotation or a resize moves several markers at once; refresh once per frame.
local refreshQueued = false
local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		refresh()
	end)
end

for _, probe in { fullProbe, safeProbe } do
	probe.topLeft:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueRefresh)
	probe.bottomRight:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueRefresh)
end

-- The top bar can change height at runtime; older clients lack this property.
pcall(function()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(queueRefresh)
end)

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

refresh()

local managedNames: { [string]: boolean } = {}
for _, name in MANAGED_SCREEN_GUIS do
	managedNames[name] = true
end

-- ScreenGuis with ResetOnSpawn = true are re-cloned on every respawn.
local function onPlayerGuiChild(child: Instance)
	if managedNames[child.Name] and child:IsA("ScreenGui") then
		manageScreenGui(child)
	end
end

playerGui.ChildAdded:Connect(onPlayerGuiChild)
for _, child in playerGui:GetChildren() do
	onPlayerGuiChild(child)
end
