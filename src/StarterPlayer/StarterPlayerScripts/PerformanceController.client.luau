--!strict
--[[
	PerformanceController (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > PerformanceController

	Adds a "Performance Mode" On/Off switch to SettingsGui > SettingsMenu
	(under the Music row) and, while it's on:

	  - ParticleEmitters in Workspace run at PARTICLE_RATE_MULTIPLIER of their
	    Rate, and Beams, Trails, Fire, Smoke and Sparkles are switched off.
	  - Bloom, Blur, DepthOfField and SunRays post effects are switched off.
	  - Parts under anything tagged "DiceRoll" (local roll animations) or
	    "PlotUnit" (units on plots) stop casting shadows.

	Effects that appear later (every dice roll spawns some) get the same
	treatment. Switching it off restores every value it changed, unless another
	script has changed that value in the meantime.

	Safety net: if the frame rate stays under LOW_FPS_THRESHOLD for
	LOW_FPS_SECONDS in a row, this either asks the player or turns Performance
	Mode on by itself (LOW_FPS_ACTION). It does this at most once per session.

	Other LocalScripts can react through the LocalPlayer attribute
	"PerformanceMode" (boolean), for example to Emit() fewer particles in the
	dice roll animation. Rate scaling can't reduce scripted Emit() bursts.

	Keep a specific effect at full quality by giving it (or an ancestor) the
	attribute KeepInPerformanceMode = true.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local PARTICLE_RATE_MULTIPLIER = 0.25 -- 0 turns ParticleEmitters off entirely
local DISABLE_BEAMS = true
local DISABLE_TRAILS = true
-- Lighting.GlobalShadows off is the biggest single win on weak phones, but it
-- flattens the whole look, so it's opt-in.
local DISABLE_GLOBAL_SHADOWS = false

local SHADOW_TAGS = { "DiceRoll", "PlotUnit" }
local DISABLED_POST_EFFECTS = { "BloomEffect", "BlurEffect", "DepthOfFieldEffect", "SunRaysEffect" }
local EXEMPT_ATTRIBUTE = "KeepInPerformanceMode"
local STATE_ATTRIBUTE = "PerformanceMode"

local LOW_FPS_THRESHOLD = 30
local LOW_FPS_SECONDS = 3
local LOW_FPS_ACTION: "Prompt" | "AutoEnable" = "Prompt"
local FPS_WARMUP_SECONDS = 15 -- ignore loading hitches right after joining

-- How many instances to process per frame when applying to a big Workspace.
local SCAN_BATCH_SIZE = 1500

-- Settings menu row
local ROW_NAME = "PerformanceRow"
local ROW_SPACING = 56
local TOGGLE_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local KNOB_OFF = UDim2.new(0, 16, 0.5, 0)
local KNOB_ON = UDim2.new(1, -16, 0.5, 0)
local DEFAULT_ON_COLOR = Color3.fromRGB(255, 196, 64)
local DEFAULT_OFF_COLOR = Color3.fromRGB(64, 68, 90)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

--------------------------------------------------------------------------------
-- Remember and restore
--------------------------------------------------------------------------------

type Override = { original: any, applied: any }

-- Weak keys: an effect destroyed while Performance Mode is on (each dice roll
-- spawns some) drops out of this table instead of leaking during a long AFK
-- session.
local overrides: { [Instance]: { [string]: Override } } = setmetatable({}, { __mode = "k" }) :: any

-- Sets instance[property] = compute(currentValue) and remembers the original.
local function override(instance: Instance, property: string, compute: (any) -> any)
	local saved = overrides[instance] or {}
	if saved[property] ~= nil then
		return -- already changed; doing it twice would e.g. quarter a Rate twice
	end
	local target = instance :: any
	local original = target[property]
	target[property] = compute(original)
	-- Store the value read back rather than the one written: the engine rounds
	-- floats, and restoreAll compares against exactly what it holds.
	saved[property] = { original = original, applied = target[property] }
	overrides[instance] = saved
end

local function restoreAll()
	for instance, saved in overrides do
		local target = instance :: any
		for property, entry in saved do
			-- If another script changed it since, its value wins.
			if target[property] == entry.applied then
				target[property] = entry.original
			end
		end
	end
	table.clear(overrides)
end

local function off(_: any): any
	return false
end

local function reduceRate(rate: any): any
	return rate * PARTICLE_RATE_MULTIPLIER
end

--------------------------------------------------------------------------------
-- Effects and shadows
--------------------------------------------------------------------------------

local POST_EFFECT_CLASSES: { [string]: boolean } = {}
for _, className in DISABLED_POST_EFFECTS do
	POST_EFFECT_CLASSES[className] = true
end

local function isEffect(instance: Instance): boolean
	return instance:IsA("ParticleEmitter")
		or (DISABLE_BEAMS and instance:IsA("Beam"))
		or (DISABLE_TRAILS and instance:IsA("Trail"))
		or instance:IsA("Fire")
		or instance:IsA("Smoke")
		or instance:IsA("Sparkles")
		or POST_EFFECT_CLASSES[instance.ClassName] == true
end

local function isExempt(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= game do
		if current:GetAttribute(EXEMPT_ATTRIBUTE) == true then
			return true
		end
		current = current.Parent
	end
	return false
end

local function applyToEffect(instance: Instance)
	if not isEffect(instance) or isExempt(instance) then
		return
	end
	if instance:IsA("ParticleEmitter") and PARTICLE_RATE_MULTIPLIER > 0 then
		override(instance, "Rate", reduceRate)
	else
		override(instance, "Enabled", off)
	end
end

local function disableShadow(instance: Instance)
	if instance:IsA("BasePart") then
		override(instance, "CastShadow", off)
	end
end

local function isShadowRoot(instance: Instance): boolean
	for _, tag in SHADOW_TAGS do
		if CollectionService:HasTag(instance, tag) then
			return true
		end
	end
	return false
end

local shadowRoots: { [Instance]: RBXScriptConnection } = {}

local function watchShadowRoot(root: Instance)
	-- Tagged templates in ReplicatedStorage must keep their shadows, or clones
	-- spawned from them would inherit CastShadow = false for good.
	if shadowRoots[root] or not root:IsDescendantOf(workspace) then
		return
	end
	-- Units stream in and animations add parts over time, so keep watching.
	shadowRoots[root] = root.DescendantAdded:Connect(disableShadow)
	disableShadow(root)
	for _, descendant in root:GetDescendants() do
		disableShadow(descendant)
	end
end

local function unwatchShadowRoot(root: Instance)
	local connection = shadowRoots[root]
	if connection then
		connection:Disconnect()
		shadowRoots[root] = nil
	end
end

--------------------------------------------------------------------------------
-- Performance Mode on / off
--------------------------------------------------------------------------------

local enabled = false
local generation = 0 -- bumped on every toggle so an unfinished scan knows to stop
local sessionConnections: { RBXScriptConnection } = {}

local function scanAsync(root: Instance, scanGeneration: number)
	for index, descendant in root:GetDescendants() do
		if scanGeneration ~= generation then
			return
		end
		applyToEffect(descendant)
		if index % SCAN_BATCH_SIZE == 0 then
			task.wait()
		end
	end
end

local function onDescendantAdded(instance: Instance)
	if isShadowRoot(instance) then
		watchShadowRoot(instance)
	end
	if isEffect(instance) then
		-- Let whatever spawned it finish setting Rate/Enabled first.
		task.defer(function()
			if enabled and instance.Parent then
				applyToEffect(instance)
			end
		end)
	end
end

local function enable()
	generation += 1
	local scanGeneration = generation

	if DISABLE_GLOBAL_SHADOWS then
		override(Lighting, "GlobalShadows", off)
	end

	table.insert(sessionConnections, workspace.DescendantAdded:Connect(onDescendantAdded))
	table.insert(sessionConnections, Lighting.DescendantAdded:Connect(onDescendantAdded))

	for _, tag in SHADOW_TAGS do
		table.insert(sessionConnections, CollectionService:GetInstanceAddedSignal(tag):Connect(watchShadowRoot))
		table.insert(sessionConnections, CollectionService:GetInstanceRemovedSignal(tag):Connect(unwatchShadowRoot))
		for _, root in CollectionService:GetTagged(tag) do
			watchShadowRoot(root)
		end
	end

	-- Spread over several frames so a big map doesn't freeze the game.
	task.spawn(function()
		scanAsync(Lighting, scanGeneration)
		scanAsync(workspace, scanGeneration)
	end)
end

local function disable()
	generation += 1
	for _, connection in sessionConnections do
		connection:Disconnect()
	end
	table.clear(sessionConnections)
	for _, connection in shadowRoots do
		connection:Disconnect()
	end
	table.clear(shadowRoots)
	restoreAll()
end

--------------------------------------------------------------------------------
-- Settings menu switch
--------------------------------------------------------------------------------

type ToggleView = {
	track: GuiObject,
	knob: GuiObject,
	stateLabel: TextLabel?,
	onColor: Color3,
	offColor: Color3,
}

local toggleView: ToggleView? = nil
local playerChoseManually = false

local function refreshToggle(animate: boolean)
	local view = toggleView
	if not view then
		return
	end
	local knobPosition = if enabled then KNOB_ON else KNOB_OFF
	local trackColor = if enabled then view.onColor else view.offColor
	if animate then
		TweenService:Create(view.knob, TOGGLE_TWEEN, { Position = knobPosition }):Play()
		TweenService:Create(view.track, TOGGLE_TWEEN, { BackgroundColor3 = trackColor }):Play()
	else
		view.knob.Position = knobPosition
		view.track.BackgroundColor3 = trackColor
	end
	local label = view.stateLabel
	if label then
		label.Text = if enabled then "ON" else "OFF"
	end
end

local function setPerformanceMode(on: boolean)
	if on == enabled then
		return
	end
	enabled = on
	if on then
		enable()
	else
		disable()
	end
	player:SetAttribute(STATE_ATTRIBUTE, on)
	refreshToggle(true)
end

local function findGuiObject(parent: Instance?, name: string): GuiObject?
	local found = if parent then parent:FindFirstChild(name, true) else nil
	return if found and found:IsA("GuiObject") then found else nil
end

-- The switch uses the BGM slider's fill colour for On and track colour for
-- Off, so it matches whatever theme the menu has.
local function themeColors(menu: Instance): (Color3, Color3)
	local fill = findGuiObject(menu, "Fill")
	local track = findGuiObject(menu, "Track")
	return if fill then fill.BackgroundColor3 else DEFAULT_ON_COLOR,
		if track then track.BackgroundColor3 else DEFAULT_OFF_COLOR
end

-- Copies a BGM row label so fonts and colours match, or makes a plain one.
local function labelFrom(template: GuiObject?, name: string): TextLabel
	local label: TextLabel
	if template and template:IsA("TextLabel") then
		label = template:Clone() :: TextLabel
	else
		label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextSize = 22
	end
	label.Name = name
	return label
end

local function addCorner(parent: Instance)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = parent
end

--[[
	Builds this row under BGMRow and grows the menu to fit:

	PerformanceRow        Frame
	├── NameLabel         TextLabel   "Performance Mode"
	├── StateLabel        TextLabel   "OFF" / "ON"
	└── Toggle            TextButton  (the switch track)
	    └── Knob          Frame
]]
local function createRow(menu: GuiObject, offColor: Color3): Instance
	local bgmRow = menu:FindFirstChild("BGMRow")

	local row = Instance.new("Frame")
	row.Name = ROW_NAME
	row.BackgroundTransparency = 1
	if bgmRow and bgmRow:IsA("GuiObject") then
		row.Position = bgmRow.Position + UDim2.fromOffset(0, ROW_SPACING)
		row.Size = bgmRow.Size
	else
		row.AnchorPoint = Vector2.new(0, 1)
		row.Position = UDim2.new(0, 24, 1, -16)
		row.Size = UDim2.new(1, -48, 0, 40)
	end

	local nameLabel = labelFrom(findGuiObject(bgmRow, "NameLabel"), "NameLabel")
	nameLabel.AnchorPoint = Vector2.zero
	nameLabel.Position = UDim2.fromScale(0, 0)
	nameLabel.Size = UDim2.new(1, -150, 1, 0)
	nameLabel.Text = "Performance Mode"
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = row

	local stateLabel = labelFrom(findGuiObject(bgmRow, "ValueLabel"), "StateLabel")
	stateLabel.AnchorPoint = Vector2.new(1, 0.5)
	stateLabel.Position = UDim2.new(1, -76, 0.5, 0)
	stateLabel.Size = UDim2.new(0, 56, 1, 0)
	stateLabel.Text = "OFF"
	stateLabel.TextXAlignment = Enum.TextXAlignment.Right
	stateLabel.Parent = row

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.AnchorPoint = Vector2.new(1, 0.5)
	toggle.Position = UDim2.fromScale(1, 0.5)
	toggle.Size = UDim2.fromOffset(64, 32)
	toggle.AutoButtonColor = false
	toggle.BackgroundColor3 = offColor
	toggle.BorderSizePixel = 0
	toggle.Text = ""
	addCorner(toggle)
	toggle.Parent = row

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = KNOB_OFF
	knob.Size = UDim2.fromOffset(26, 26)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BorderSizePixel = 0
	addCorner(knob)
	knob.Parent = toggle

	-- Make room for the new row.
	menu.Size += UDim2.fromOffset(0, ROW_SPACING)
	local sizeConstraint = menu:FindFirstChildOfClass("UISizeConstraint")
	if sizeConstraint then
		sizeConstraint.MaxSize += Vector2.new(0, ROW_SPACING)
	end

	row.Parent = menu
	return row
end

local function attachToSettingsGui(settingsGui: Instance)
	local menu = settingsGui:WaitForChild("SettingsMenu", 10)
	if not menu or not menu:IsA("GuiObject") then
		warn("[PerformanceController] SettingsGui.SettingsMenu not found; the Performance Mode switch wasn't added.")
		return
	end
	local menuObject = menu :: GuiObject

	-- Use a row built in Studio if there is one, otherwise build it.
	local onColor, offColor = themeColors(menuObject)
	local row = menuObject:FindFirstChild(ROW_NAME) or createRow(menuObject, offColor)

	local toggle = row:FindFirstChild("Toggle")
	local knob = if toggle then toggle:FindFirstChild("Knob") else nil
	if not toggle or not toggle:IsA("GuiButton") or not knob or not knob:IsA("GuiObject") then
		warn(`[PerformanceController] {row:GetFullName()} needs a Toggle button with a Knob frame inside.`)
		return
	end
	local toggleButton = toggle :: GuiButton
	local stateLabel = row:FindFirstChild("StateLabel")

	toggleView = {
		track = toggleButton,
		knob = knob :: GuiObject,
		stateLabel = if stateLabel and stateLabel:IsA("TextLabel") then stateLabel else nil,
		onColor = onColor,
		offColor = offColor,
	}
	toggleButton.Activated:Connect(function()
		playerChoseManually = true
		setPerformanceMode(not enabled)
	end)
	refreshToggle(false)
end

--------------------------------------------------------------------------------
-- Low frame rate safety net
--------------------------------------------------------------------------------

local function notify(payload: { [string]: any })
	task.spawn(function()
		-- SetCore errors until Roblox's CoreScripts have registered it; retry briefly.
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCore("SendNotification", payload)
			end)
			if ok then
				return
			end
			task.wait(1)
		end
	end)
end

local function onSustainedLowFps()
	if LOW_FPS_ACTION == "AutoEnable" then
		setPerformanceMode(true)
		notify({
			Title = "Performance Mode on",
			Text = "Switched on to keep things smooth. You can turn it off in Settings.",
			Duration = 8,
		})
		return
	end

	local answer = Instance.new("BindableFunction")
	answer.OnInvoke = function(choice: string)
		if choice == "Turn on" then
			setPerformanceMode(true)
		end
	end
	notify({
		Title = "Low frame rate",
		Text = "Turn on Performance Mode for smoother play?",
		Duration = 15,
		Button1 = "Turn on",
		Button2 = "No thanks",
		Callback = answer,
	})
end

local function watchFrameRate()
	local frames, elapsed, slowSeconds = 0, 0, 0
	local startedAt = os.clock()
	local windowFocused = true
	local connections: { RBXScriptConnection } = {}

	local function stop()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end

	table.insert(
		connections,
		UserInputService.WindowFocused:Connect(function()
			windowFocused = true
		end)
	)
	table.insert(
		connections,
		UserInputService.WindowFocusReleased:Connect(function()
			windowFocused = false
			slowSeconds = 0
		end)
	)

	-- Count frames in one-second windows; three slow windows in a row trigger it.
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(deltaTime: number)
			frames += 1
			elapsed += deltaTime
			if elapsed < 1 then
				return
			end
			local fps = frames / elapsed
			frames, elapsed = 0, 0

			if playerChoseManually then
				stop() -- they know where the switch is; never second-guess them
				return
			end
			-- Loading, a backgrounded window and an already-on mode don't count.
			if enabled or not windowFocused or os.clock() - startedAt < FPS_WARMUP_SECONDS then
				slowSeconds = 0
				return
			end

			slowSeconds = if fps < LOW_FPS_THRESHOLD then slowSeconds + 1 else 0
			if slowSeconds >= LOW_FPS_SECONDS then
				stop() -- once per session, so it never nags
				onSustainedLowFps()
			end
		end)
	)
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

player:SetAttribute(STATE_ATTRIBUTE, false)

-- SettingsGui is cloned from StarterGui into PlayerGui, and cloned again on
-- respawn if its ResetOnSpawn is true, so attach to every copy.
playerGui.ChildAdded:Connect(function(child: Instance)
	if child.Name == "SettingsGui" then
		task.spawn(attachToSettingsGui, child)
	end
end)
local existingSettingsGui = playerGui:FindFirstChild("SettingsGui")
if existingSettingsGui then
	task.spawn(attachToSettingsGui, existingSettingsGui)
end

watchFrameRate()
