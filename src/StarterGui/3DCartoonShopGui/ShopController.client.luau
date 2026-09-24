--!strict
--[[
	ShopController (LocalScript)
	Location: StarterGui > 3DCartoonShopGui > ShopController
	Built into the GUI by tools/Build3DCartoonShop.luau, which embeds a copy
	of this file. Edit here, then re-run the builder (or paste this into the
	LocalScript by hand).

	  - Every 3D button (attribute Button3D) grows slightly on hover and
	    physically presses in: its face slides down onto its base while held.
	  - Item cards (attribute Card3D) lift on hover and spin their dice.
	  - SHOP toggles the window with a Back-eased pop; X, the dark backdrop
	    and ButtonB close it.
	  - While the shop is open, the featured dice spins and its light rays turn.

	Hooking up your game, from any LocalScript:

		local shopGui = Players.LocalPlayer.PlayerGui:WaitForChild("3DCartoonShopGui")

		-- action is "Buy" or "Equip"
		shopGui.ShopAction.Event:Connect(function(itemId, action)
			diceShopRemote:FireServer(itemId, action)
		end)

		-- Show what the player owns: "Buy" (shows the Price attribute),
		-- "Equip" or "Equipped". Only one card can be Equipped at a time.
		shopGui:FindFirstChild("Card_Silver", true):SetAttribute("State", "Equipped")

		shopGui:SetAttribute("Open", true) -- open or close from code
		shopGui.HomePressed.Event:Connect(teleportHome)
]]

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local gui = script.Parent :: ScreenGui
local window = gui:WaitForChild("ShopWindow") :: Frame
local windowScale = window:WaitForChild("UIScale") :: UIScale
local dim = gui:WaitForChild("Dim") :: GuiButton
local shopAction = gui:WaitForChild("ShopAction") :: BindableEvent
local homePressed = gui:WaitForChild("HomePressed") :: BindableEvent

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local HOVER_SCALE = 1.03
local SPIN_SPEED = 0.9 -- radians per second
local RAY_SPEED = 12 -- degrees per second
local DIM_TRANSPARENCY = 0.45

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local FADE_TWEEN = TweenInfo.new(0.2)

-- Item button colours per State. Keep in sync with STATE_STYLES in the builder.
type Style = { top: Color3, bottom: Color3, base: Color3 }
local STATE_STYLES: { [string]: Style } = {
	Buy = {
		top = Color3.fromRGB(46, 204, 113),
		bottom = Color3.fromRGB(35, 155, 86),
		base = Color3.fromRGB(22, 105, 58),
	},
	Equip = {
		top = Color3.fromRGB(64, 222, 212),
		bottom = Color3.fromRGB(22, 160, 172),
		base = Color3.fromRGB(10, 104, 116),
	},
	Equipped = {
		top = Color3.fromRGB(176, 186, 210),
		bottom = Color3.fromRGB(112, 122, 152),
		base = Color3.fromRGB(70, 78, 106),
	},
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function tween(instance: Instance, info: TweenInfo, goals: { [string]: any })
	TweenService:Create(instance, info, goals):Play()
end

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function isTouch(): boolean
	return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
end

local function isGamepad(): boolean
	return string.sub(UserInputService:GetLastInputType().Name, 1, 7) == "Gamepad"
end

-- A 3D button or card: Visual (outline + UIScale) holding Base and Face.
local function partsOf(target: Instance): (Frame?, Frame?, UIScale?)
	local visual = target:FindFirstChild("Visual")
	if not visual or not visual:IsA("Frame") then
		return nil, nil, nil
	end
	local face = visual:FindFirstChild("Face")
	return visual, if face and face:IsA("Frame") then face else nil, visual:FindFirstChildOfClass("UIScale")
end

--------------------------------------------------------------------------------
-- 3D press and hover
--------------------------------------------------------------------------------

--[[
	Pressed: the face slides down `shift` px toward the base. Visual, which
	carries the outline, shrinks from the top by the same amount, so the
	outline keeps hugging the button and only the base strip under the face
	gets thinner:

	    Visual  Position.Y = shift / 2, Size.Y = -shift   (top edge moves down)
	    Face    Size.Y = -(depth - shift)                  (face height unchanged)
]]
local function setPressed(button: GuiButton, pressed: boolean)
	local visual, face = partsOf(button)
	if not visual or not face then
		return
	end
	local depth = numberAttribute(button, "Depth", 7)
	local shift = if pressed then math.min(numberAttribute(button, "PressDepth", 4), depth - 1) else 0
	local info = if pressed then PRESS_TWEEN else RELEASE_TWEEN
	tween(visual, info, { Position = UDim2.new(0.5, 0, 0.5, shift / 2), Size = UDim2.new(1, 0, 1, -shift) })
	tween(face, info, { Size = UDim2.new(1, 0, 1, -(depth - shift)) })
end

local function setHovered(target: Instance, hovered: boolean)
	local _, _, scale = partsOf(target)
	if scale then
		tween(scale, HOVER_TWEEN, { Scale = if hovered then HOVER_SCALE else 1 })
	end
end

local held: { [GuiButton]: boolean } = {}

local function release(button: GuiButton)
	if held[button] then
		held[button] = nil
		setPressed(button, false)
	end
end

--------------------------------------------------------------------------------
-- Item cards and their states
--------------------------------------------------------------------------------

local cards: { Instance } = {}
local spinningOnHover: { [Model]: boolean } = {}
local angles: { [Model]: number } = {}
local featuredDie: Model? = nil

local function findCard(instance: Instance): Instance?
	local current: Instance? = instance
	while current and current ~= gui do
		if current:GetAttribute("Card3D") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function dieOf(card: Instance): Model?
	local die = card:FindFirstChild("Die", true)
	return if die and die:IsA("Model") then die else nil
end

local function setLabelText(label: Instance?, text: string)
	if label then
		for _, child in label:GetChildren() do
			if child:IsA("TextLabel") then
				child.Text = text
			end
		end
	end
end

-- Recolours and relabels a card's button for its State attribute.
local function applyState(card: Instance)
	local state = card:GetAttribute("State")
	local stateName = if typeof(state) == "string" and STATE_STYLES[state] then state else "Buy"
	local style = STATE_STYLES[stateName]
	local button = card:FindFirstChild("ActionButton", true)
	if not button then
		return
	end
	local visual, face = partsOf(button)
	if not visual or not face then
		return
	end

	local base = visual:FindFirstChild("Base")
	if base and base:IsA("Frame") then
		base.BackgroundColor3 = style.base
	end
	local gradient = face:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(style.top, style.bottom)
	end

	local buying = stateName == "Buy"
	local price = card:GetAttribute("Price")
	local text = if buying
		then (if typeof(price) == "string" and price ~= "" then price else "BUY")
		elseif stateName == "Equipped" then "EQUIPPED"
		else "EQUIP"
	local label = face:FindFirstChild("Label")
	setLabelText(label, text)
	-- The money icon only shows on prices; words take the full width.
	local icon = face:FindFirstChild("Icon")
	if icon and icon:IsA("GuiObject") then
		icon.Visible = buying
	end
	if label and label:IsA("GuiObject") then
		label.Position = if buying then UDim2.fromScale(0.58, 0.5) else UDim2.fromScale(0.5, 0.5)
		label.Size = if buying then UDim2.fromScale(0.66, 0.62) else UDim2.fromScale(0.86, 0.62)
	end
end

local function onStateChanged(card: Instance)
	-- Only one dice can be equipped: equipping one un-equips the rest.
	if card:GetAttribute("State") == "Equipped" then
		for _, other in cards do
			if other ~= card and other:GetAttribute("State") == "Equipped" then
				other:SetAttribute("State", "Equip")
			end
		end
	end
	applyState(card)
end

--------------------------------------------------------------------------------
-- Window open / close
--------------------------------------------------------------------------------

local isOpen = false

-- Scale that keeps the whole window (plus its header tab and base) on small
-- screens such as phones. Never enlarges past the designed size.
local function fitScale(): number
	local screen = gui.AbsoluteSize
	local width = window.Size.X.Scale * screen.X + window.Size.X.Offset
	local height = window.Size.Y.Scale * screen.Y + window.Size.Y.Offset
	local constraint = window:FindFirstChildOfClass("UISizeConstraint")
	if constraint then
		width = math.clamp(width, constraint.MinSize.X, constraint.MaxSize.X)
		height = math.clamp(height, constraint.MinSize.Y, constraint.MaxSize.Y)
	end
	local fit = math.min((screen.X - 24) / width, (screen.Y - 24) / (height + 50))
	-- Honour UIScaleController's device scale if it manages this GUI.
	return math.min(numberAttribute(windowScale, "BaseScale", 1), fit)
end

local function open()
	if isOpen then
		return
	end
	isOpen = true
	gui:SetAttribute("Open", true)
	if not window.Visible then
		windowScale.Scale = 0
		window.Visible = true
	end
	dim.Visible = true
	tween(windowScale, OPEN_TWEEN, { Scale = fitScale() })
	tween(dim, FADE_TWEEN, { BackgroundTransparency = DIM_TRANSPARENCY })

	-- A gamepad has no pointer: start on the featured buy button.
	if isGamepad() then
		local buy = window:FindFirstChild("ActionButton", true)
		if buy and buy:IsA("GuiObject") then
			GuiService.SelectedObject = buy
		end
	end
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	gui:SetAttribute("Open", false)
	for button in held do
		release(button)
	end
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(window) then
		GuiService.SelectedObject = nil
	end

	-- Reopening mid-close cancels these tweens; only hide after they finish.
	local shrink = TweenService:Create(windowScale, CLOSE_TWEEN, { Scale = 0 })
	shrink.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed and not isOpen then
			window.Visible = false
		end
	end)
	shrink:Play()
	local fade = TweenService:Create(dim, FADE_TWEEN, { BackgroundTransparency = 1 })
	fade.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed and not isOpen then
			dim.Visible = false
		end
	end)
	fade:Play()
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function onActivated(button: GuiButton)
	local action = button:GetAttribute("Action")
	if action == "ToggleShop" then
		if isOpen then
			close()
		else
			open()
		end
	elseif action == "Close" then
		close()
	elseif action == "Home" then
		homePressed:Fire()
	elseif action == "Item" then
		local card = findCard(button)
		local state = if card then card:GetAttribute("State") else nil
		if card and state ~= "Equipped" then
			shopAction:Fire(card:GetAttribute("ItemId"), if state == "Equip" then "Equip" else "Buy")
		end
	end
end

local function wireButton(button: GuiButton)
	button.MouseEnter:Connect(function()
		-- A tap can fire MouseEnter without MouseLeave; hover is mouse-only.
		if not isTouch() then
			setHovered(button, true)
		end
	end)
	button.MouseLeave:Connect(function()
		setHovered(button, false)
		release(button) -- dragged off while held: pop back up
	end)
	button.SelectionGained:Connect(function()
		setHovered(button, true)
	end)
	button.SelectionLost:Connect(function()
		setHovered(button, false)
	end)
	button.MouseButton1Down:Connect(function()
		held[button] = true
		setPressed(button, true)
	end)
	button.MouseButton1Up:Connect(function()
		release(button)
	end)
	button.Activated:Connect(function(input: InputObject?)
		local inputType = if input then input.UserInputType else nil
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			-- Gamepad and keyboard presses have no down/up, so play a quick press.
			setPressed(button, true)
			task.delay(0.08, setPressed, button, false)
		end
		onActivated(button)
	end)
end

local function wireCard(card: Instance)
	table.insert(cards, card)
	card:GetAttributeChangedSignal("State"):Connect(function()
		onStateChanged(card)
	end)
	card:GetAttributeChangedSignal("Price"):Connect(function()
		applyState(card)
	end)
	applyState(card)

	local die = dieOf(card)
	if card:GetAttribute("Featured") then
		featuredDie = die -- always spins while open
		die = nil
	end
	if card:IsA("GuiObject") then
		card.MouseEnter:Connect(function()
			if not isTouch() then
				setHovered(card, true)
				if die then
					spinningOnHover[die] = true
				end
			end
		end)
		card.MouseLeave:Connect(function()
			setHovered(card, false)
			if die then
				spinningOnHover[die] = nil
			end
		end)
	end
end

for _, descendant in gui:GetDescendants() do
	if descendant:IsA("GuiButton") and descendant:GetAttribute("Button3D") then
		wireButton(descendant)
	elseif descendant:GetAttribute("Card3D") then
		wireCard(descendant)
	end
end

dim.Activated:Connect(close)

-- Releasing anywhere ends a press, even off the button (touch has no MouseLeave).
UserInputService.InputEnded:Connect(function(input: InputObject)
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
		for button in held do
			release(button)
		end
	end
end)

UserInputService.InputBegan:Connect(function(input: InputObject)
	if isOpen and input.KeyCode == Enum.KeyCode.ButtonB then
		close()
	end
end)

-- Other scripts can open or close the shop with gui:SetAttribute("Open", ...).
gui:GetAttributeChangedSignal("Open"):Connect(function()
	local wanted = gui:GetAttribute("Open") == true
	if wanted and not isOpen then
		open()
	elseif not wanted and isOpen then
		close()
	end
end)

gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if isOpen then
		tween(windowScale, HOVER_TWEEN, { Scale = fitScale() })
	end
end)

-- Spinning dice and turning light rays, only while the shop is open.
local rays = window:FindFirstChild("Rays", true)
RunService.RenderStepped:Connect(function(deltaTime: number)
	if not isOpen then
		return
	end
	local function spin(die: Model)
		local angle = (angles[die] or 0) + deltaTime * SPIN_SPEED
		angles[die] = angle
		die:PivotTo(CFrame.Angles(0, angle, 0))
	end
	if featuredDie then
		spin(featuredDie)
	end
	for die in spinningOnHover do
		spin(die)
	end
	if rays and rays:IsA("GuiObject") then
		rays.Rotation = (rays.Rotation + deltaTime * RAY_SPEED) % 360
	end
end)

--------------------------------------------------------------------------------
-- Startup: the window is visible in Studio for editing, but starts closed.
--------------------------------------------------------------------------------

window.Visible = false
windowScale.Scale = 0
dim.Visible = false
dim.BackgroundTransparency = 1
gui:SetAttribute("Open", false)
