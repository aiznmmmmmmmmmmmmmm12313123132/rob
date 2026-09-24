--!strict
--[[
	SettingsController (LocalScript)
	Location: StarterGui > SettingsGui > SettingsController

	Drives three things:
	  1. The top-right Settings button (hover scale-up, click to toggle the menu).
	  2. The centred Settings menu (Back-eased pop-in, shrink-out on close).
	  3. The Background Music (BGM) volume slider (0% - 100%).

	The slider only writes SoundService.BGMGroup.Volume. SFX and UI sounds live
	in other SoundGroups (or none), so they are never affected. A SoundGroup
	volume set from a LocalScript only changes what this player hears.

	Works with the cross-platform scripts in StarterPlayerScripts:
	  - UIScaleController keeps the button clear of the top bar and notches,
	    and publishes a "BaseScale" attribute on both UIScales here. The hover
	    and pop-in animations multiply by it (1 when that script isn't running).
	  - PerformanceController adds its Performance Mode row to this menu.
	Gamepad: the slider is selected when the menu opens, D-pad left/right
	changes the volume, and ButtonB closes the menu.

	The UI hierarchy this script expects is documented in docs/settings-menu.md.
]]

local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local BGM_GROUP_NAME = "BGMGroup"
local DEFAULT_VOLUME = 0.5 -- 0-1, used only until BGMGroup exists

local HOVER_SCALE = 1.1
local GAMEPAD_STEP = 0.1 -- volume change per D-pad press
local BASE_SCALE_ATTRIBUTE = "BaseScale"
local HOVER_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In)

--------------------------------------------------------------------------------
-- UI references
--------------------------------------------------------------------------------

local gui = script.Parent :: ScreenGui

local settingsButton = gui:WaitForChild("SettingsButton") :: GuiButton
local buttonScale = settingsButton:WaitForChild("UIScale") :: UIScale

local settingsMenu = gui:WaitForChild("SettingsMenu") :: Frame
local menuScale = settingsMenu:WaitForChild("UIScale") :: UIScale
local closeButton = settingsMenu:WaitForChild("CloseButton") :: GuiButton

local bgmRow = settingsMenu:WaitForChild("BGMRow") :: Frame
local valueLabel = bgmRow:WaitForChild("ValueLabel") :: TextLabel
local slider = bgmRow:WaitForChild("Slider") :: GuiButton
local track = slider:WaitForChild("Track") :: Frame
local fill = track:WaitForChild("Fill") :: Frame
local knob = slider:WaitForChild("Knob") :: Frame

-- The device-wide scale UIScaleController has chosen for this UIScale.
local function baseScaleOf(uiScale: UIScale): number
	local value = uiScale:GetAttribute(BASE_SCALE_ATTRIBUTE)
	return if typeof(value) == "number" then value else 1
end

--------------------------------------------------------------------------------
-- BGM volume
--------------------------------------------------------------------------------

-- Always a whole percent expressed as 0-1 (e.g. 0.75), so the audio matches
-- the number shown on screen.
local currentVolume = DEFAULT_VOLUME

local function getBGMGroup(): SoundGroup?
	local group = SoundService:FindFirstChild(BGM_GROUP_NAME)
	if group and group:IsA("SoundGroup") then
		return group
	end
	return nil
end

local function applyVolume()
	local group = getBGMGroup()
	if group then
		group.Volume = currentVolume
	end
end

--------------------------------------------------------------------------------
-- Slider visuals
--------------------------------------------------------------------------------

-- `fraction` runs from 0 (far left, 0%) to 1 (far right, 100%).
local function setSliderFraction(fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	local percent = math.round(fraction * 100)

	-- Scale-based X puts the knob at exactly `fraction` of the track's width,
	-- and its AnchorPoint of (0.5, 0.5) centres it on that point. The knob
	-- follows the raw fraction so dragging stays smooth rather than stepping.
	knob.Position = UDim2.fromScale(fraction, 0.5)
	fill.Size = UDim2.fromScale(fraction, 1)
	valueLabel.Text = `{percent}%`

	currentVolume = percent / 100
	applyVolume()
end

--[[
	Converts the pointer's horizontal screen position into a 0-1 fraction of
	the track. Track.AbsolutePosition / AbsoluteSize share the same horizontal
	pixel space as InputObject.Position, so no unit conversion is needed:

	    trackLeft                                 trackLeft + trackWidth
	    |<------------------- trackWidth ------------------->|
	    0%                                                 100%

	    fraction = (pointerX - trackLeft) / trackWidth

	  pointer on the left edge     ->  0 / trackWidth          =  0   (0%)
	  pointer on the right edge    ->  trackWidth / trackWidth =  1   (100%)
	  pointer dragged past left    ->  negative                ->  clamped to 0
	  pointer dragged past right   ->  greater than 1          ->  clamped to 1

	math.clamp(x, 0, 1) is what pins the knob to the ends of the track no
	matter how far the pointer travels. Only X is used, so the vertical top bar
	inset never affects the result.
]]
local function fractionFromScreenX(pointerX: number): number
	local trackLeft = track.AbsolutePosition.X
	local trackWidth = track.AbsoluteSize.X
	if trackWidth <= 0 then
		return currentVolume -- not laid out yet; keep the current value
	end
	return math.clamp((pointerX - trackLeft) / trackWidth, 0, 1)
end

--------------------------------------------------------------------------------
-- Slider dragging
--------------------------------------------------------------------------------

-- The InputObject that started the current drag, or nil when idle. For touch
-- we remember the exact finger, so a second finger (e.g. on the movement
-- thumbstick) can neither move nor end the drag.
local dragInput: InputObject? = nil

-- Whether the menu is open (or opening). Declared here so dragging can check it.
local isOpen = false

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- True if `input` belongs to the active drag: the same finger for touch, or
-- any input of `mouseType` when the drag was started with the mouse.
local function isDragInput(input: InputObject, mouseType: Enum.UserInputType): boolean
	local active = dragInput
	if active == nil then
		return false
	end
	if active.UserInputType == Enum.UserInputType.Touch then
		return input == active
	end
	return input.UserInputType == mouseType
end

local function beginDrag(input: InputObject)
	-- Ignore presses while the menu is shrinking closed.
	if not isOpen or dragInput ~= nil or not isPress(input) then
		return
	end
	dragInput = input
	-- Jump straight to the press point, so clicking the track works too.
	setSliderFraction(fractionFromScreenX(input.Position.X))
end

local function endDrag()
	dragInput = nil
end

-- A press on the hit area, or on the knob sitting on top of it, starts a drag.
-- If both fire for the same press, beginDrag ignores the second one.
slider.InputBegan:Connect(beginDrag)
knob.InputBegan:Connect(beginDrag)

-- Follow the pointer anywhere on screen while dragging, even off the track.
-- gameProcessedEvent is deliberately ignored: the pointer is over GUI.
UserInputService.InputChanged:Connect(function(input: InputObject)
	if isDragInput(input, Enum.UserInputType.MouseMovement) then
		setSliderFraction(fractionFromScreenX(input.Position.X))
	end
end)

-- Releasing anywhere on screen ends the drag. InputEnded covers both the mouse
-- button coming up (MouseButton1Up) and the finger lifting (TouchEnded), and
-- it fires even when the release lands on some other GUI element.
UserInputService.InputEnded:Connect(function(input: InputObject)
	if isDragInput(input, Enum.UserInputType.MouseButton1) then
		endDrag()
	end
end)

-- If the window loses focus mid-drag (e.g. alt-tab), the release never arrives.
UserInputService.WindowFocusReleased:Connect(endDrag)

--------------------------------------------------------------------------------
-- Settings button hover
--------------------------------------------------------------------------------

local isHovered = false

local function refreshButtonScale()
	local scale = baseScaleOf(buttonScale) * (if isHovered then HOVER_SCALE else 1)
	TweenService:Create(buttonScale, HOVER_TWEEN, { Scale = scale }):Play()
end

settingsButton.MouseEnter:Connect(function()
	-- A tap can fire MouseEnter with no matching MouseLeave, which would leave
	-- the button stuck enlarged on touch screens. Hover is a mouse-only effect.
	if UserInputService:GetLastInputType() ~= Enum.UserInputType.Touch then
		isHovered = true
		refreshButtonScale()
	end
end)

settingsButton.MouseLeave:Connect(function()
	isHovered = false
	refreshButtonScale()
end)

buttonScale:GetAttributeChangedSignal(BASE_SCALE_ATTRIBUTE):Connect(refreshButtonScale)

--------------------------------------------------------------------------------
-- Menu open / close
--------------------------------------------------------------------------------

local menuTween: Tween? = nil

local function playMenuTween(info: TweenInfo, scale: number): Tween
	if menuTween then
		menuTween:Cancel()
	end
	local tween = TweenService:Create(menuScale, info, { Scale = scale })
	menuTween = tween
	tween:Play()
	return tween
end

local function openMenu()
	if isOpen then
		return
	end
	isOpen = true

	-- Pop in from nothing, unless a close is still shrinking the menu; then
	-- grow back from its current size instead of snapping to 0.
	if not settingsMenu.Visible then
		menuScale.Scale = 0
		settingsMenu.Visible = true
	end
	-- Back + Out overshoots slightly past full size, then settles: the "pop".
	playMenuTween(OPEN_TWEEN, baseScaleOf(menuScale))

	-- A gamepad has no pointer; start on the slider so the D-pad works straight away.
	if string.sub(UserInputService:GetLastInputType().Name, 1, 7) == "Gamepad" then
		GuiService.SelectedObject = slider
	end
end

local function closeMenu()
	if not isOpen then
		return
	end
	isOpen = false
	endDrag()

	-- Hand the gamepad back to gameplay instead of leaving it inside a closed menu.
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(settingsMenu) then
		GuiService.SelectedObject = nil
	end

	local tween = playMenuTween(CLOSE_TWEEN, 0)
	tween.Completed:Once(function(playbackState: Enum.PlaybackState)
		-- Reopening mid-close cancels this tween; only hide after a full shrink.
		if playbackState == Enum.PlaybackState.Completed and not isOpen then
			settingsMenu.Visible = false
		end
	end)
end

settingsButton.Activated:Connect(function()
	if isOpen then
		closeMenu()
	else
		openMenu()
	end
end)

closeButton.Activated:Connect(closeMenu)

-- The device scale can change while the menu is open (rotation, resize).
menuScale:GetAttributeChangedSignal(BASE_SCALE_ATTRIBUTE):Connect(function()
	if isOpen then
		playMenuTween(HOVER_TWEEN, baseScaleOf(menuScale))
	end
end)

--------------------------------------------------------------------------------
-- Gamepad
--------------------------------------------------------------------------------

-- Keep D-pad left/right on the slider so it changes the volume instead of
-- moving the selection to another button.
slider.NextSelectionLeft = slider
slider.NextSelectionRight = slider

UserInputService.InputBegan:Connect(function(input: InputObject)
	if not isOpen then
		return
	end
	if input.KeyCode == Enum.KeyCode.ButtonB then
		closeMenu()
	elseif GuiService.SelectedObject == slider then
		if input.KeyCode == Enum.KeyCode.DPadLeft then
			setSliderFraction(currentVolume - GAMEPAD_STEP)
		elseif input.KeyCode == Enum.KeyCode.DPadRight then
			setSliderFraction(currentVolume + GAMEPAD_STEP)
		end
	end
end)

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

settingsMenu.Visible = false
menuScale.Scale = 0
buttonScale.Scale = baseScaleOf(buttonScale)

-- A visible Modal button frees the mouse cursor, so the menu stays clickable
-- while Shift Lock (or first person) would otherwise pin it to the centre.
closeButton.Modal = true

local bgmGroup = getBGMGroup()
if bgmGroup then
	-- Start the slider at whatever volume BGMGroup was authored with.
	setSliderFraction(bgmGroup.Volume)
else
	warn(`[SettingsController] SoundService.{BGM_GROUP_NAME} (SoundGroup) not found; volume will apply once it exists.`)
	setSliderFraction(DEFAULT_VOLUME)
end

-- If BGMGroup shows up later (e.g. created by a script), give it the chosen volume.
SoundService.ChildAdded:Connect(function(child: Instance)
	if child.Name == BGM_GROUP_NAME and child:IsA("SoundGroup") then
		child.Volume = currentVolume
	end
end)
