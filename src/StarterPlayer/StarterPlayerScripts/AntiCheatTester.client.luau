--!strict
--[[
	AntiCheatTester (LocalScript)
	Location: StarterPlayer > StarterPlayerScripts > AntiCheatTester

	Studio-only buttons that do what an exploiter's client would do, so the
	server-side anti-cheat can be tested for real: client-side WalkSpeed,
	CFrame speed, hovering, teleporting, noclip, flinging, malformed remote
	arguments, roll spam and replayed reward claims.

	It does nothing outside Studio, and nothing unless the server's
	AntiCheat is in TEST_MODE (ReplicatedStorage attribute AntiCheatTestMode).
	In TEST_MODE the server never kicks, so it's safe to press everything.
	Watch the server output for the [AntiCheat] lines.

	Nothing here is security: it's a test tool. Exploiters can already do all
	of it, which is exactly why the checks live on the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

if not RunService:IsStudio() then
	return
end

local TEST_MODE_ATTRIBUTE = "AntiCheatTestMode"
if ReplicatedStorage:GetAttribute(TEST_MODE_ATTRIBUTE) == nil then
	local deadline = os.clock() + 15
	while ReplicatedStorage:GetAttribute(TEST_MODE_ATTRIBUTE) == nil and os.clock() < deadline do
		task.wait(0.5)
	end
end
if ReplicatedStorage:GetAttribute(TEST_MODE_ATTRIBUTE) ~= true then
	return
end

local player = Players.LocalPlayer
local busy = false

local function log(message: string)
	print(`[AntiCheatTester] {message}`)
end

local function getCharacter(): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
		return character, humanoid, root
	end
	return nil, nil, nil
end

local function flatLook(): Vector3
	local camera = Workspace.CurrentCamera
	local look = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)
	local flat = Vector3.new(look.X, 0, look.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
end

-- Runs `callback(dt)` every frame for `seconds`.
local function everyFrame(seconds: number, callback: (dt: number) -> ())
	local finished = os.clock() + seconds
	local connection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		if os.clock() >= finished then
			connection:Disconnect()
			return
		end
		callback(dt)
	end)
	task.wait(seconds + 0.05)
end

local function getRemote(name: string): Instance?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = if folder then folder:FindFirstChild(name) else nil
	if not remote then
		log(`{name}: no such remote in ReplicatedStorage.Remotes (skipped)`)
	end
	return remote
end

local function fire(name: string, ...: any)
	local remote = getRemote(name)
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer(...)
	elseif remote and remote:IsA("RemoteFunction") then
		local args = table.pack(...)
		task.spawn(function()
			local ok, result, reason = pcall(function()
				return remote:InvokeServer(table.unpack(args, 1, args.n))
			end)
			log(`{name} returned {tostring(ok)} {tostring(result)} {tostring(reason)}`)
		end)
	end
end

--------------------------------------------------------------------------------
-- Hostile movement
--------------------------------------------------------------------------------

local function walkSpeedHack()
	local _, humanoid = getCharacter()
	if not humanoid then
		return
	end
	log("WalkSpeed 80 on the client for 6s. Hold W and run in a straight line.")
	local original = humanoid.WalkSpeed
	humanoid.WalkSpeed = 80 -- a client-side change: the server still sees its own value
	task.wait(6)
	humanoid.WalkSpeed = original
	log("WalkSpeed restored.")
end

local function cframeSpeedHack()
	local _, _, root = getCharacter()
	if not root then
		return
	end
	log("CFrame speed: 60 studs/s forward for 5s.")
	local direction = flatLook()
	everyFrame(5, function(dt)
		root.CFrame += direction * 60 * dt
	end)
end

local function hover()
	local _, _, root = getCharacter()
	if not root then
		return
	end
	log("Hover 25 studs up for 7s.")
	local hold = root.CFrame + Vector3.new(0, 25, 0)
	everyFrame(7, function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = hold
	end)
end

local function teleports()
	local character, _, root = getCharacter()
	if not character or not root then
		return
	end
	for index = 1, 3 do
		log(`Teleport {index}/3: 150 studs forward.`)
		character:PivotTo(root.CFrame + flatLook() * 150)
		task.wait(1)
	end
end

local function noclip()
	local character, _, root = getCharacter()
	if not character or not root then
		return
	end
	log("Noclip for 6s at walking speed. Face a thick wall first.")
	local direction = flatLook()
	everyFrame(6, function(dt)
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
		root.CFrame += direction * 14 * dt
	end)
end

local function fling()
	local _, _, root = getCharacter()
	if not root then
		return
	end
	log("Spinning at 1000 rad/s for 1s (fling exploit).")
	everyFrame(1, function()
		root.AssemblyAngularVelocity = Vector3.new(0, 1000, 0)
	end)
	root.AssemblyAngularVelocity = Vector3.zero
end

--------------------------------------------------------------------------------
-- Hostile remotes
--------------------------------------------------------------------------------

local function invalidRemotes()
	log("Sending malformed arguments. Each should be refused (InvalidRemote) on the server.")
	local nan = 0 / 0
	fire("RollDice", "Legendary") -- "I rolled this rarity"
	fire("RollDice", { character = "Mythic", mutation = "Rainbow" })
	fire("DiceShop", nil, "Buy")
	fire("DiceShop", "Celestial", "Steal")
	fire("DiceShop", string.rep("A", 5000), "Buy")
	fire("DiceShop", { "Celestial" }, "Buy")
	fire("DiceShop", nan, "Buy")
	fire("DiceShop", "Wooden\0", "Buy")
	fire("DiceShop", "Celestial", "Buy", 0) -- "I paid 0"
	fire("PlaceCharacter", "abc", -1)
	fire("PlaceCharacter", "abc", 1.5)
	fire("PlaceCharacter", "abc", math.huge)
	fire("SellCharacters", { "a", "a" })
	fire("SellCharacters", { [1] = "a", [3] = "b" })
	fire("SellCharacters", { a = "b" })
	fire("CollectCash", 1e12) -- "give me this amount of cash"
	fire("ClaimAfkReward", 86400) -- "I was AFK for a day"
	fire("RedeemCode", string.rep("x", 100))
end

local function rollSpam()
	log("RollDice x100 in one frame, then 20/s for 3s. The server should accept about one per cooldown.")
	for _ = 1, 100 do
		fire("RollDice")
	end
	for _ = 1, 60 do
		fire("RollDice")
		task.wait(0.05)
	end
end

local function replayClaims()
	log("Claiming the same rewards 10 times at once (duplicate claims).")
	for _ = 1, 10 do
		fire("ClaimIndexReward", "Wooden")
		fire("ClaimDailyReward")
		fire("ClaimAfkReward")
		fire("DiceShop", "Celestial", "Buy")
	end
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	for _, name in { "GiveCharacter", "GiveCash", "AddGems", "SetRarity" } do
		if folder and folder:FindFirstChild(name) then
			log(`WARNING: a remote named {name} exists. Remotes must never grant rewards directly.`)
		else
			log(`{name}: doesn't exist, good (no remote grants rewards directly).`)
		end
	end
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local TESTS: { { name: string, run: () -> () } } = {
	{ name = "WalkSpeed hack (hold W)", run = walkSpeedHack },
	{ name = "CFrame speed hack", run = cframeSpeedHack },
	{ name = "Hover / fly", run = hover },
	{ name = "Teleport x3", run = teleports },
	{ name = "Noclip (face a wall)", run = noclip },
	{ name = "Fling spin", run = fling },
	{ name = "Invalid remote args", run = invalidRemotes },
	{ name = "Roll spam", run = rollSpam },
	{ name = "Replay reward claims", run = replayClaims },
}

local gui = Instance.new("ScreenGui")
gui.Name = "AntiCheatTester"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0, 0.5)
panel.Position = UDim2.new(0, 12, 0.5, 0)
panel.Size = UDim2.fromOffset(200, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
panel.BackgroundTransparency = 0.2
panel.BorderSizePixel = 0
panel.Parent = gui

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 8)
padding.PaddingBottom = UDim.new(0, 8)
padding.PaddingLeft = UDim.new(0, 8)
padding.PaddingRight = UDim.new(0, 8)
padding.Parent = panel

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 4)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 20)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(255, 200, 60)
title.Text = "AntiCheat TEST_MODE"
title.Parent = panel

for index, test in TESTS do
	local button = Instance.new("TextButton")
	button.LayoutOrder = index
	button.Size = UDim2.new(1, 0, 0, 26)
	button.BackgroundColor3 = Color3.fromRGB(50, 56, 80)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.Gotham
	button.TextSize = 13
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Text = test.name
	button.Parent = panel
	button.Activated:Connect(function()
		if busy then
			log("Another test is still running.")
			return
		end
		busy = true
		local ok, err = pcall(function()
			test.run()
		end)
		if not ok then
			log(`{test.name} failed: {err}`)
		end
		busy = false
	end)
end

gui.Parent = player:WaitForChild("PlayerGui")
log("Ready. Server output shows what the anti-cheat did with each test.")
