--!strict
--[[
	InputManager (ModuleScript)
	Location: ReplicatedStorage > Source > InputManager
	Client only: require it from LocalScripts.

	One place that knows how the player is playing right now.

	  Input mode     "KeyboardMouse" | "Gamepad" | "Touch"   (switches live)
	  Gamepad style  "Xbox" | "PlayStation"                  (A vs X in hints)
	  Platform       "Desktop" | "Mobile" | "Console"        (device class)

	Actions have one name on every device:

	  RollDice   Space  |  Roll button click / tap (bindButton)  |  ButtonA or ButtonR2
	  ShiftLock  LeftShift  |  on-screen toggle (touch only)     |  ButtonL3 (left stick click)

	Shift Lock is implemented here so it also works on console and mobile. Turn
	off StarterPlayer.EnableMouseLockOption so Roblox's built-in Shift Lock
	doesn't also react to Shift.

	Example (HUD LocalScript):

		local InputManager = require(ReplicatedStorage.Source.InputManager)

		InputManager.bindButton("RollDice", hud.RollButton)
		InputManager.onAction("RollDice", function()
			rollRemote:FireServer()
		end)

		local function refreshHint()
			hud.RollButton.Hint.Text = InputManager.getHint("RollDice")
		end
		InputManager.InputDeviceChanged:Connect(refreshHint)
		refreshHint()
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

assert(RunService:IsClient(), "InputManager is client-only; require it from a LocalScript.")

export type InputMode = "KeyboardMouse" | "Gamepad" | "Touch"
export type GamepadStyle = "Xbox" | "PlayStation"
export type Platform = "Desktop" | "Mobile" | "Console"

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

-- Space and ButtonA are also Roblox's jump keys.
-- true: they roll instead of jumping. false: they roll AND jump.
local ROLL_KEYS_REPLACE_JUMP = true

-- Ignore a nudged mouse or a drifting thumbstick, so a gamepad player's hints
-- don't flicker to keyboard (and vice versa).
local MOUSE_SWITCH_PIXELS = 4
local ANALOG_SWITCH_THRESHOLD = 0.35

local SHIFT_LOCK_CAMERA_OFFSET = Vector3.new(1.75, 0, 0) -- over-the-shoulder, like Roblox's
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value -- above Roblox's movement/jump binds
local ACTION_PREFIX = "CartoonDice_"

local ACTION_KEYS: { [string]: { Enum.KeyCode } } = {
	RollDice = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonR2 },
	ShiftLock = { Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3 },
}

-- Hint text per action, keyed by input mode (or gamepad style in Gamepad mode).
local HINTS: { [string]: { [string]: string } } = {
	RollDice = { KeyboardMouse = "Space", Xbox = "A", PlayStation = "X", Touch = "Tap" },
	ShiftLock = { KeyboardMouse = "Shift", Xbox = "LS", PlayStation = "L3", Touch = "Tap" },
}

-- The gamepad button each hint refers to, for controller glyph images.
local HINT_GAMEPAD_KEY: { [string]: Enum.KeyCode } = {
	RollDice = Enum.KeyCode.ButtonA,
	ShiftLock = Enum.KeyCode.ButtonL3,
}

local LOCK_ON_COLOR = Color3.fromRGB(255, 196, 64)
local LOCK_OFF_COLOR = Color3.fromRGB(32, 34, 48)
local JUMP_BUTTON_GAP = 12

--------------------------------------------------------------------------------
-- Device detection
--------------------------------------------------------------------------------

local function isGamepadType(inputType: Enum.UserInputType): boolean
	return string.sub(inputType.Name, 1, 7) == "Gamepad" -- Gamepad1 ... Gamepad8
end

local function detectGamepadStyle(): GamepadStyle
	-- Roblox names PlayStation face buttons by their symbol, so ButtonA
	-- reports as "ButtonCross" when a PlayStation controller is in use.
	local ok, name = pcall(function()
		return UserInputService:GetStringForKeyCode(Enum.KeyCode.ButtonA)
	end)
	return if ok and name == "ButtonCross" then "PlayStation" else "Xbox"
end

local function detectInitialMode(): InputMode
	local lastType = UserInputService:GetLastInputType()
	if lastType == Enum.UserInputType.Touch then
		return "Touch"
	elseif isGamepadType(lastType) or GuiService:IsTenFootInterface() then
		return "Gamepad"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	end
	return "KeyboardMouse"
end

--------------------------------------------------------------------------------
-- State and events
--------------------------------------------------------------------------------

local player = Players.LocalPlayer

local InputManager = {}

-- The BindableEvents live under this ModuleScript, so other scripts can also
-- find them in the Explorer at ReplicatedStorage.Source.InputManager.
local deviceChanged = Instance.new("BindableEvent")
deviceChanged.Name = "InputDeviceChanged"
deviceChanged.Parent = script

local actionTriggered = Instance.new("BindableEvent")
actionTriggered.Name = "ActionTriggered"
actionTriggered.Parent = script

-- Fires (inputMode: InputMode, gamepadStyle: GamepadStyle) when the player switches device.
InputManager.InputDeviceChanged = deviceChanged.Event
-- Fires (action: string, inputMode: InputMode) every time an action triggers.
InputManager.ActionTriggered = actionTriggered.Event

local inputMode: InputMode = detectInitialMode()
local gamepadStyle: GamepadStyle = detectGamepadStyle()
local shiftLockEnabled = false

local mobileGui: ScreenGui? = nil
local shiftLockButton: TextButton? = nil

--------------------------------------------------------------------------------
-- Shift Lock
--------------------------------------------------------------------------------

local SHIFT_LOCK_STEP = ACTION_PREFIX .. "ShiftLock"

local function getHumanoid(): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

-- Runs every frame, right after the camera updates, while Shift Lock is on.
local function shiftLockStep()
	local humanoid = getHumanoid()
	local root = if humanoid then humanoid.RootPart else nil
	local camera = workspace.CurrentCamera
	if not humanoid or not root or not camera or humanoid.Sit or humanoid.Health <= 0 then
		return
	end

	humanoid.AutoRotate = false
	humanoid.CameraOffset = SHIFT_LOCK_CAMERA_OFFSET

	-- Only a mouse needs pinning to the centre; gamepad and touch cameras turn
	-- freely anyway. A visible GuiButton with Modal = true (the Settings menu's
	-- close button) still frees the cursor while menus are open.
	if inputMode == "KeyboardMouse" and not GuiService.MenuIsOpen then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	-- Face where the camera looks, flattened so the character stays upright.
	local look = camera.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude > 1e-3 then
		local position = root.Position
		root.CFrame = CFrame.lookAt(position, position + flatLook)
	end
end

local function releaseCharacter()
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.AutoRotate = true
		humanoid.CameraOffset = Vector3.zero
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

local function refreshShiftLockButton()
	local button = shiftLockButton
	if button then
		button.BackgroundColor3 = if shiftLockEnabled then LOCK_ON_COLOR else LOCK_OFF_COLOR
		button.TextColor3 = if shiftLockEnabled then LOCK_OFF_COLOR else LOCK_ON_COLOR
	end
end

local function setShiftLockEnabled(enabled: boolean)
	if enabled == shiftLockEnabled then
		return
	end
	shiftLockEnabled = enabled
	if enabled then
		RunService:BindToRenderStep(SHIFT_LOCK_STEP, Enum.RenderPriority.Camera.Value + 1, shiftLockStep)
	else
		RunService:UnbindFromRenderStep(SHIFT_LOCK_STEP)
		releaseCharacter()
	end
	refreshShiftLockButton()
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function fireAction(action: string)
	if action == "ShiftLock" then
		setShiftLockEnabled(not shiftLockEnabled)
	end
	actionTriggered:Fire(action, inputMode)
end

local function bindButton(action: string, button: GuiButton): RBXScriptConnection
	assert(ACTION_KEYS[action] ~= nil, `InputManager: unknown action "{action}"`)
	-- Activated covers a mouse click, a tap, and ButtonA on a selected button.
	return button.Activated:Connect(function()
		fireAction(action)
	end)
end

-- While the player is typing or moving through menus with a gamepad, keys
-- belong to the UI: Space types a space, ButtonA presses the selected button.
local function uiHasFocus(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil or GuiService.SelectedObject ~= nil or GuiService.MenuIsOpen
end

for action, keys in ACTION_KEYS do
	local sinkInput = action ~= "RollDice" or ROLL_KEYS_REPLACE_JUMP
	ContextActionService:BindActionAtPriority(ACTION_PREFIX .. action, function(_, state: Enum.UserInputState)
		if uiHasFocus() then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			fireAction(action)
		end
		return if sinkInput then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end, false, ACTION_PRIORITY, table.unpack(keys))
end

--------------------------------------------------------------------------------
-- Mobile controls (Shift Lock toggle)
--------------------------------------------------------------------------------

-- Sits the Shift Lock button just above Roblox's jump button, whatever size
-- Roblox picked for this screen.
local function placeAboveJumpButton(jumpButton: GuiObject)
	local gui, button = mobileGui, shiftLockButton
	if not gui or not button then
		return
	end
	local jumpPosition, jumpSize = jumpButton.AbsolutePosition, jumpButton.AbsoluteSize
	local size = math.max(44, math.floor(jumpSize.X * 0.6)) -- 44 px: minimum comfortable touch target
	-- Absolute positions share one screen space; subtract our ScreenGui's origin
	-- to turn the jump button's position into an offset inside our ScreenGui.
	local origin = gui.AbsolutePosition
	button.Size = UDim2.fromOffset(size, size)
	button.Position =
		UDim2.fromOffset(jumpPosition.X + jumpSize.X / 2 - origin.X, jumpPosition.Y - JUMP_BUTTON_GAP - origin.Y)
end

-- Roblox creates PlayerGui.TouchGui (with a JumpButton inside) on touch
-- devices, sometimes after this module loads, so watch for it.
local function watchForJumpButton(playerGui: Instance)
	local function tryAttach(instance: Instance)
		if instance.Name ~= "JumpButton" or not instance:IsA("GuiObject") then
			return
		end
		local jumpButton = instance :: GuiObject
		local function place()
			placeAboveJumpButton(jumpButton)
		end
		jumpButton:GetPropertyChangedSignal("AbsolutePosition"):Connect(place)
		jumpButton:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
		place()
	end

	local function watchTouchGui(touchGui: Instance)
		touchGui.DescendantAdded:Connect(tryAttach)
		for _, descendant in touchGui:GetDescendants() do
			tryAttach(descendant)
		end
	end

	playerGui.ChildAdded:Connect(function(child: Instance)
		if child.Name == "TouchGui" then
			watchTouchGui(child)
		end
	end)
	local touchGui = playerGui:FindFirstChild("TouchGui")
	if touchGui then
		watchTouchGui(touchGui)
	end
end

local function refreshMobileControls()
	if mobileGui then
		mobileGui.Enabled = inputMode == "Touch"
	end
end

local function createMobileControls()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "MobileControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	local button = Instance.new("TextButton")
	button.Name = "ShiftLockButton"
	button.AnchorPoint = Vector2.new(0.5, 1) -- bottom-centre sits on the spot above the jump button
	button.Position = UDim2.new(1, -60, 1, -110) -- until Roblox's jump button is found
	button.Size = UDim2.fromOffset(48, 48)
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.Font = Enum.Font.FredokaOne
	button.Text = "LOCK"
	button.TextScaled = true

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.25, 0)
	padding.PaddingBottom = UDim.new(0.25, 0)
	padding.PaddingLeft = UDim.new(0.15, 0)
	padding.PaddingRight = UDim.new(0.15, 0)
	padding.Parent = button

	button.Parent = gui
	mobileGui = gui
	shiftLockButton = button

	bindButton("ShiftLock", button)
	refreshShiftLockButton()
	refreshMobileControls()
	gui.Parent = playerGui
	watchForJumpButton(playerGui)
end

--------------------------------------------------------------------------------
-- Input mode tracking
--------------------------------------------------------------------------------

local function setInputMode(mode: InputMode)
	-- Re-read the controller type each time a gamepad is used: the player may
	-- have swapped an Xbox pad for a PlayStation one.
	local style = if mode == "Gamepad" then detectGamepadStyle() else gamepadStyle
	if mode == inputMode and style == gamepadStyle then
		return
	end
	inputMode = mode
	gamepadStyle = style
	if shiftLockEnabled and mode ~= "KeyboardMouse" then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	refreshMobileControls()
	deviceChanged:Fire(inputMode, gamepadStyle)
end

-- Presses always count: any key, mouse button, gamepad button or touch.
-- gameProcessedEvent is ignored on purpose; clicking a GUI still means "mouse".
UserInputService.InputBegan:Connect(function(input: InputObject)
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.Touch then
		setInputMode("Touch")
	elseif inputType == Enum.UserInputType.Keyboard or string.sub(inputType.Name, 1, 5) == "Mouse" then
		setInputMode("KeyboardMouse")
	elseif isGamepadType(inputType) then
		setInputMode("Gamepad")
	end
end)

-- Continuous input only counts when it's deliberate.
UserInputService.InputChanged:Connect(function(input: InputObject)
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseMovement then
		if input.Delta.Magnitude >= MOUSE_SWITCH_PIXELS then
			setInputMode("KeyboardMouse")
		end
	elseif isGamepadType(inputType) then
		-- Thumbsticks and triggers: Position holds the deflection.
		if input.Position.Magnitude >= ANALOG_SWITCH_THRESHOLD then
			setInputMode("Gamepad")
		end
	end
end)

UserInputService.GamepadConnected:Connect(function()
	if inputMode == "Gamepad" then
		setInputMode("Gamepad") -- picks up a changed controller style
	end
end)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function InputManager.getInputMode(): InputMode
	return inputMode
end

function InputManager.getGamepadStyle(): GamepadStyle
	return gamepadStyle
end

function InputManager.getPlatform(): Platform
	if GuiService:IsTenFootInterface() then
		return "Console"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Mobile"
	end
	return "Desktop"
end

-- Short label for the button that triggers `action` on the current device,
-- e.g. "Space", "A" (Xbox), "X" (PlayStation) or "Tap".
function InputManager.getHint(action: string): string
	local hints = HINTS[action]
	if not hints then
		return ""
	end
	local key = if inputMode == "Gamepad" then gamepadStyle else inputMode
	return hints[key] or ""
end

-- Roblox's own controller glyph for `action` in Gamepad mode (matches the
-- connected controller), or nil when there isn't one. Pair with getHint().
function InputManager.getHintImage(action: string): string?
	local keyCode = HINT_GAMEPAD_KEY[action]
	if inputMode ~= "Gamepad" or not keyCode then
		return nil
	end
	local ok, image = pcall(function()
		return (UserInputService :: any):GetImageForKeyCode(keyCode)
	end)
	return if ok and typeof(image) == "string" and image ~= "" then image else nil
end

-- Makes `button` trigger `action` when clicked, tapped or pressed with ButtonA.
InputManager.bindButton = bindButton

-- Calls `callback(inputMode)` every time `action` triggers on any device.
function InputManager.onAction(action: string, callback: (InputMode) -> ()): RBXScriptConnection
	return actionTriggered.Event:Connect(function(firedAction: string, mode: InputMode)
		if firedAction == action then
			callback(mode)
		end
	end)
end

function InputManager.isShiftLockEnabled(): boolean
	return shiftLockEnabled
end

InputManager.setShiftLockEnabled = setShiftLockEnabled

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

task.spawn(createMobileControls)

if player.DevEnableMouseLock then
	warn(
		"[InputManager] StarterPlayer.EnableMouseLockOption is on, so Roblox's built-in Shift Lock also reacts to Shift. "
			.. "Turn it off so InputManager's cross-platform Shift Lock is the only one."
	)
end

return InputManager
