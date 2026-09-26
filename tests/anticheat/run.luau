--[[
	AntiCheat test suite. Run from the repository root:

		lune run tests/anticheat/run
		lune run tests/anticheat/run -- --verbose     (print evidence per test)
		lune run tests/anticheat/run -- Speed         (only tests whose name matches)

	Three groups:
	  unit        each module on its own
	  legit       normal play that must never earn points, corrections or kicks
	  hostile     exploit behaviour the server must detect and / or refuse
]]

local process = require("@lune/process")
local H = require("./harness")

local Vector3 = H.Vector3
local CFrame = H.CFrame

local VERBOSE = table.find(process.args, "--verbose") ~= nil
local FILTER: string? = nil
for _, arg in process.args do
	if string.sub(arg, 1, 2) ~= "--" then
		FILTER = arg
	end
end

math.randomseed(1)

--------------------------------------------------------------------------------
-- Tiny test runner
--------------------------------------------------------------------------------

local results = { passed = 0, failed = 0, failures = {} }
local currentNotes: { string } = {}

local function note(text: string)
	table.insert(currentNotes, text)
end

local function check(condition: any, message: string)
	if not condition then
		error(message, 2)
	end
end

local function test(group: string, name: string, fn: () -> ())
	local fullName = `{group}: {name}`
	if FILTER and not string.find(fullName, FILTER, 1, true) then
		return
	end
	currentNotes = {}
	table.clear(H.worlds)
	local ok, err = pcall(fn)
	if ok then
		-- Anti-cheat code that threw inside its own pcall still fails the test.
		for _, world in H.worlds do
			local errors = world.internalErrors()
			if #errors > 0 then
				ok, err = false, "anti-cheat code errored: " .. errors[1]
				break
			end
		end
	end
	if ok then
		results.passed += 1
		print(`  PASS  {fullName}`)
	else
		results.failed += 1
		table.insert(results.failures, fullName)
		print(`  FAIL  {fullName}\n        {err}`)
	end
	if VERBOSE or not ok then
		for _, line in currentNotes do
			print(`        {line}`)
		end
	end
end

--------------------------------------------------------------------------------
-- Movement helpers (client-side behaviour)
--------------------------------------------------------------------------------

local DIRECTIONS = {
	Vector3.new(1, 0, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 0, -1),
}

-- Walks a square, turning every `leg` seconds; optionally jumps every `jumpEvery`.
local function walkSquare(record, leg: number, jumpEvery: number?)
	local started = nil
	local lastJump = -math.huge
	return function(t: number)
		started = started or t
		local index = math.floor((t - started) / leg) % 4 + 1
		record.client.move = DIRECTIONS[index]
		if jumpEvery and t - lastJump >= jumpEvery and record.client.grounded then
			record.client.jump = true
			lastJump = t
		end
	end
end

local function newLegitWorld(options: any?)
	local sim = H.newWorld(options)
	return sim
end

local function expectClean(sim, player, label: string)
	local points = sim.pointsFor(player)
	local actions = sim.actionsFor(player)
	note(`evidence: {sim.describe(player)}`)
	check(points == 0, `{label}: earned {points} points\n      {sim.describe(player)}`)
	check(
		not actions.Setback and not actions["Setback+Restrict"] and not actions.Restrict and not actions.Kick and not actions.WouldKick,
		`{label}: was corrected or kicked`
	)
	check(#sim.kicks == 0, `{label}: was kicked`)
end

--------------------------------------------------------------------------------
-- Unit: RateLimiter
--------------------------------------------------------------------------------

test("unit", "RateLimiter: cooldown bucket allows one per cooldown, absorbs jitter", function()
	local sim = H.newWorld()
	local RateLimiter = sim.require("Modules/RateLimiter")
	local now = 0
	local limiter = RateLimiter.new(function()
		return now
	end)
	local rule = RateLimiter.fromCooldown(1)
	local allowed = 0
	for _ = 1, 100 do
		if limiter.consume("p", "Roll", rule) then
			allowed += 1
		end
	end
	check(allowed == 1, `100 requests in one frame: {allowed} allowed, expected 1`)
	local _, denied = limiter.consume("p", "Roll", rule)
	check(denied >= 30, "denied count feeds flood detection")

	-- A client firing exactly on its own 1 s cooldown, with +-0.15 s of network
	-- jitter per request: every roll must be accepted.
	limiter.reset("p")
	allowed = 0
	local random = 0
	for i = 0, 99 do
		random = (random * 1103515245 + 12345) % 2147483648
		now = 10 + i * 1.0 + (random / 2147483648 * 2 - 1) * 0.15
		if limiter.consume("p", "Roll", rule) then
			allowed += 1
		end
	end
	check(allowed == 100, `on-time rolls with jitter: {allowed}/100 accepted`)

	-- Faster than the cooldown (every 0.4 s for 60 s): still one per second.
	limiter.reset("p")
	allowed = 0
	for i = 0, 150 do
		now = 200 + i * 0.4
		if limiter.consume("p", "Roll", rule) then
			allowed += 1
		end
	end
	check(allowed <= 62, `spamming can't beat the cooldown: {allowed} in 60 s`)
end)

--------------------------------------------------------------------------------
-- Unit: ViolationTracker
--------------------------------------------------------------------------------

test("unit", "ViolationTracker: weights, caps, decay and levels", function()
	local sim = H.newWorld()
	local Config = sim.Config
	local ViolationTracker = sim.require("Modules/ViolationTracker")
	local now = 0
	local tracker = ViolationTracker.new(Config.Violations, Config.Enforcement.Levels, function()
		return now
	end)

	local result = tracker.add("p", "Teleport", 1)
	check(result.added == 2.5 and result.level == 1, "one teleport = 2.5 points, observed only")
	result = tracker.add("t", "Teleport", 2)
	check(result.added == 5 and result.level == 2, "even a blatant teleport is only logged")

	for _ = 1, 20 do
		tracker.add("p", "Noclip", 1)
	end
	check(tracker.getScore("p") <= 4 + 2.5, "noclip is capped")

	local flood = tracker.add("q", "RemoteFlood", 1)
	for _ = 1, 50 do
		flood = tracker.add("q", "RemoteFlood", 1)
	end
	check(flood.score <= 5 and flood.level < 3, `flood alone never reaches setback (score {flood.score})`)

	local invalid
	for _ = 1, 50 do
		invalid = tracker.add("r", "InvalidRemote", 1)
	end
	check(invalid.level < 4, "malformed remotes alone never reach restrict")

	-- Decay: nothing new for DecayDelay, then DecayPerSecond.
	now = 5
	check(tracker.getScore("p") == 4, "no decay during DecayDelay")
	now = 1000
	check(tracker.getScore("p") == 0, "score decays to zero after clean play")

	local zero = tracker.add("s", "Speed", 0)
	check(zero.added == 0 and zero.events == 0, "severity 0 adds nothing and isn't an event")
end)

--------------------------------------------------------------------------------
-- Unit: RemoteValidator
--------------------------------------------------------------------------------

test("unit", "RemoteValidator: rejects malformed arguments, returns clean copies", function()
	local sim = H.newWorld()
	local RemoteValidator = sim.require("Modules/RemoteValidator")
	local validate = RemoteValidator.validate
	local ID = { type = "string", maxLength = 32, pattern = "[%w_]+" }
	local nan = 0 / 0

	local function rejects(specs, ...)
		local ok = validate(specs, { ... }, select("#", ...))
		return not ok
	end

	check(rejects({}, "Legendary"), "extra argument (client-chosen rarity)")
	check(not rejects({}, nil), "trailing nil is fine")
	check(rejects({ ID }, nil), "missing argument")
	check(rejects({ ID }, 5), "wrong type")
	check(rejects({ ID }, string.rep("A", 5000)), "huge string")
	check(rejects({ ID }, "Wooden\0"), "control character")
	check(rejects({ ID }, "\xff\xfe"), "invalid UTF-8")
	check(rejects({ ID }, "Wood en"), "pattern")
	check(rejects({ ID }, { "Wooden" }), "table where a string belongs")
	check(rejects({ { type = "number" } }, nan), "NaN")
	check(rejects({ { type = "number" } }, math.huge), "infinity")
	check(rejects({ { type = "number" } }, -math.huge), "-infinity")
	check(rejects({ { type = "integer", min = 1, max = 100 } }, 1.5), "fraction")
	check(rejects({ { type = "integer", min = 1, max = 100 } }, -1), "below range")
	check(rejects({ { type = "integer", min = 1, max = 100 } }, 1e308), "above range")
	check(rejects({ { type = "enum", values = { "Buy", "Equip" } } }, "Steal"), "enum")
	check(rejects({ { type = "boolean" } }, "true"), "boolean as string")

	local ARRAY = { type = "array", of = ID, maxLength = 3, unique = true }
	check(rejects({ ARRAY }, { "a", "a" }), "duplicates")
	check(rejects({ ARRAY }, { [1] = "a", [3] = "b" }), "holes")
	check(rejects({ ARRAY }, { a = "b" }), "dictionary keys")
	check(rejects({ ARRAY }, { "a", "b", "c", "d" }), "too long")
	check(rejects({ ARRAY }, setmetatable({}, {})), "metatable")
	check(rejects({ ARRAY }, { "a", nan }), "bad element")

	local input = { "a", "b" }
	local ok, clean = validate({ ARRAY }, { input }, 1)
	check(ok and clean[1] ~= input and clean[1][2] == "b", "arrays are rebuilt, not passed through")

	local checked = { type = "string", check = function(value)
		return value == "Golden"
	end }
	check(rejects({ checked }, "FreeCelestial"), "server-side catalog check")
	check(not rejects({ checked }, "Golden"), "catalog check passes real ids")
	local throws = { type = "string", check = function()
		error("boom")
	end }
	check(rejects({ throws }, "x"), "a check that errors counts as a failure")
end)

--------------------------------------------------------------------------------
-- Unit: EconomyValidator
--------------------------------------------------------------------------------

test("unit", "EconomyValidator: impossible transactions are refused, the rest are explained", function()
	local sim = H.newWorld()
	local economy = sim.api.Economy
	local player = sim.addPlayer({ name = "Buyer" })
	local nan = 0 / 0

	local ok, value = economy.applyChange(player, "Cash", 1000, -1500, "DicePurchase")
	check(not ok and value == "InsufficientFunds", "can't go negative")
	ok, value = economy.applyChange(player, "Cash", 1000, 500, "DicePurchase")
	check(not ok and value == "WrongDirection", "a purchase can't add cash")
	ok, value = economy.applyChange(player, "Cash", 1000, nan, "CharacterIncome")
	check(not ok, "NaN delta")
	ok, value = economy.applyChange(player, "Cash", 1000, math.huge, "CharacterIncome")
	check(not ok, "infinite delta")
	ok, value = economy.applyChange(player, "Cash", nan, 5, "CharacterIncome")
	check(not ok and value == "CorruptBalance", "corrupt balance is not built on")
	ok, value = economy.applyChange(player, "Cash", 1e30, 1e30, "CharacterIncome")
	check(not ok and value == "AboveMaxBalance", "max balance")
	ok, value = economy.applyChange(player, "Cash", 10, 5, "FreeMoney")
	check(not ok and value == "UnknownReason", "every change needs a known reason")
	ok, value = economy.applyChange(player, "Cash", 10, 5, "CosmeticReward")
	check(not ok and value == "CurrencyNotAllowed", "reason limited to its currency")
	ok, value = economy.applyChange(player, "Cash", 1000, -400, "DicePurchase")
	check(ok and value == 600, "valid purchase")
	local ledger = economy.getLedger(player)
	check(#ledger == 1 and ledger[1].reason == "DicePurchase" and ledger[1].delta == -400, "ledger explains the change")

	local catalog = { Golden = { price = 1 } }
	check(economy.lookup(catalog, "Golden") ~= nil, "lookup real id")
	check(economy.lookup(catalog, "__index") == nil, "lookup odd key")
	check(economy.lookup(catalog, 5) == nil, "lookup non-string")
	check(economy.lookup(setmetatable({}, { __index = catalog }), "Golden") == nil, "lookup ignores inherited keys")

	local release = economy.beginTransaction(player)
	check(release ~= nil, "first transaction starts")
	check(economy.beginTransaction(player) == nil, "second concurrent transaction refused")
	check(economy.transaction(player, function() end) == false, "transaction refused while locked")
	release()
	check(not pcall(economy.transaction, player, function()
		error("handler bug")
	end), "errors are re-raised")
	local ran = false
	check(economy.transaction(player, function()
		ran = true
	end) and ran, "the lock was released after the error")
	local stale = economy.beginTransaction(player)
	check(stale ~= nil, "lock taken")
	sim.advance(31)
	check(economy.beginTransaction(player) ~= nil, "a stale lock expires")

	check(economy.claimOnce(player, "Index:Wooden"), "first claim")
	check(not economy.claimOnce(player, "Index:Wooden"), "duplicate claim")

	check(not economy.isValidQuantity(0, 10) and not economy.isValidQuantity(2.5, 10) and economy.isValidQuantity(3, 10), "quantities")
	check(not economy.canAfford(100, nan) and not economy.canAfford(100, -5) and economy.canAfford(100, 100), "canAfford")
end)

--------------------------------------------------------------------------------
-- Unit: ExemptionManager
--------------------------------------------------------------------------------

test("unit", "ExemptionManager: modifiers are validated and expire", function()
	local sim = H.newWorld()
	local ExemptionManager = sim.require("Modules/ExemptionManager")
	local now = 0
	local exemptions = ExemptionManager.new(function()
		return now
	end)
	check(not pcall(exemptions.setModifier, "p", "Bad", { speedMultiplier = 0 / 0 }), "NaN multiplier refused")
	check(not pcall(exemptions.setModifier, "p", "Bad", { maxSpeed = math.huge }), "infinite speed refused")
	check(not pcall(exemptions.grant, "p", "Bad", 1e9), "absurd exemption refused")
	exemptions.setModifier("p", "Potion", { speedMultiplier = 2 }, 10)
	exemptions.setModifier("p", "Hoverboard", { maxSpeed = 60, allowFlight = true })
	local profile = exemptions.getProfile("p")
	check(profile.speedMultiplier == 2 and profile.maxSpeed == 60 and profile.allowFlight, "profile combines modifiers")
	now = 11
	check(exemptions.getProfile("p").speedMultiplier == 1, "timed modifier expires")
	exemptions.grant("p", "Rebirth", 2)
	check(exemptions.isExempt("p"), "exempt")
	now = 14
	check(not exemptions.isExempt("p"), "exemption expires")
end)

test("unit", "Studio start: audit warns, demo handlers never replace the game's remotes", function()
	local sim = H.newWorld({ isStudio = true })
	check(sim.Config.TEST_MODE, "Studio is TEST_MODE automatically")
	local folder = H.newInstance("Folder", "Remotes")
	folder.Parent = sim.replicatedStorage
	local gameRemote = H.newInstance("RemoteFunction", "RedeemCode")
	gameRemote.Parent = folder
	local function gameHandler()
		return "game"
	end
	gameRemote.OnServerInvoke = gameHandler
	local legacy = H.newInstance("RemoteEvent", "AntiCheatEvent")
	legacy.Parent = sim.replicatedStorage
	sim.advance(6)
	check(gameRemote.OnServerInvoke == gameHandler, "the game's own handler was left alone")
	check(sim.remote("RollDice") ~= nil, "a demo stand-in exists for unbound contracts")
	local audit, legacyWarning = false, false
	for _, line in sim.output do
		if string.find(line.text, "Remotes.RedeemCode", 1, true) then
			audit = true
		end
		if string.find(line.text, "AntiCheatEvent belongs to the old free-model", 1, true) then
			legacyWarning = true
		end
	end
	check(audit, "audit lists the unprotected game remote")
	check(legacyWarning, "audit flags the old template's AntiCheatEvent")
end)

--------------------------------------------------------------------------------
-- Legit play: must never earn points
--------------------------------------------------------------------------------

test("legit", "normal walking for 2 minutes", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Walker" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(120, walkSquare(record, 6))
	expectClean(sim, player, "walking")
end)

test("legit", "one unexplained teleport is logged, never corrected", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "OneOff" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(6, walkSquare(record, 3))
	record.client.position += Vector3.new(200, 0, 0)
	sim.advance(6, walkSquare(record, 3))
	check(#sim.evidenceFor(player, "Teleport") == 1, "recorded")
	local actions = sim.actionsFor(player)
	check(not actions.Setback and not actions["Setback+Restrict"] and not actions.Restrict, "not corrected")
	sim.advance(60)
	check(sim.api.getScore(player) == 0, "forgotten after a minute")
end)

test("legit", "walking and jumping constantly", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Jumper" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(90, walkSquare(record, 5, 0.1))
	expectClean(sim, player, "jumping")
end)

test("legit", "falling off a 150-stud tower", function()
	local sim = newLegitWorld()
	sim.addPart({ position = Vector3.new(0, 75, 0), size = Vector3.new(10, 150, 10) })
	local player, record = sim.addPlayer({ name = "Faller" })
	sim.spawn(player, Vector3.new(0, 150, 0))
	sim.advance(5)
	sim.advance(8, function()
		record.client.move = Vector3.new(1, 0, 0)
	end)
	check(record.client.position.Y < 10, "reached the ground")
	sim.advance(5, function()
		record.client.move = Vector3.zero
	end)
	expectClean(sim, player, "falling")
end)

test("legit", "respawn far away and character reset", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Respawner" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(10, walkSquare(record, 3))
	for round = 1, 3 do
		record.humanoid.Health = 0
		sim.advance(2)
		sim.spawn(player, Vector3.new(800 * round, 0, -600))
		sim.advance(10, walkSquare(record, 3))
	end
	expectClean(sim, player, "respawn")
end)

test("legit", "high ping (400 ms, +-150 ms jitter)", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Laggy", ping = 0.4, jitter = 0.15 })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(120, walkSquare(record, 4, 1.3))
	expectClean(sim, player, "high ping")
end)

test("legit", "lag spikes: packets held then delivered in one burst", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Spiky", ping = 0.15, jitter = 0.05 })
	sim.spawn(player, Vector3.new(0, 0, 0))
	local walk = walkSquare(record, 7, 2)
	for spike = 1, 6 do
		sim.advance(8, walk)
		sim.lagSpike(player, if spike == 6 then 3 else 1.5)
	end
	sim.advance(10, walk)
	expectClean(sim, player, "lag spikes")
end)

test("legit", "server teleports through Api.teleport (shop, rebirth)", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Traveller", ping = 0.25 })
	sim.spawn(player, Vector3.new(0, 0, 0))
	local walk = walkSquare(record, 3)
	for index = 1, 5 do
		sim.advance(6, walk) -- keeps walking: stale packets arrive after the teleport
		check(sim.api.teleport(player, CFrame.new(Vector3.new(index * 500, 3, 0)), "Rebirth"), "teleport accepted")
	end
	sim.advance(6, walk)
	expectClean(sim, player, "server teleports")
end)

test("legit", "a teleport made by code that only calls Api.exempt first", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Exempted" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(8, walkSquare(record, 3))
	sim.api.exempt(player, "ShopTravel", 2)
	record.character:PivotTo(CFrame.new(Vector3.new(0, 3, 900)))
	sim.advance(10, walkSquare(record, 3))
	expectClean(sim, player, "exempted teleport")
end)

test("legit", "server teleports by game code that never calls the Api", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "PadUser", ping = 0.2 })
	sim.spawn(player, Vector3.new(0, 0, 0))
	local walk = walkSquare(record, 3)
	for index = 1, 6 do
		sim.advance(4, walk)
		-- e.g. an old teleport pad script: a plain PivotTo on the server.
		record.character:PivotTo(CFrame.new(Vector3.new(index * 400, 3, 200)))
	end
	sim.advance(6, walk)
	expectClean(sim, player, "unintegrated server teleports")
end)

test("legit", "walking up a long staircase", function()
	local sim = newLegitWorld()
	-- 60 steps, each half a stud high and 1.5 deep: 30 studs of climb.
	for step = 1, 60 do
		sim.addPart({ name = "Step", position = Vector3.new(step * 1.5, step / 4, 0), size = Vector3.new(1.5, step / 2, 10) })
	end
	local player, record = sim.addPlayer({ name = "StairClimber" })
	sim.spawn(player, Vector3.new(-5, 0, 0))
	sim.advance(3)
	sim.advance(5.5, function()
		record.client.move = Vector3.new(1, 0, 0)
	end)
	check(record.client.position.Y > 25, `climbed the stairs ({record.client.position.Y})`)
	sim.advance(3, function()
		record.client.move = Vector3.zero
	end)
	expectClean(sim, player, "stairs")
end)

test("legit", "hoverboard ride (maxSpeed 60), then getting off at speed", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Rider" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(5, walkSquare(record, 3))
	sim.api.setMovementModifier(player, "Hoverboard", { maxSpeed = 60 })
	record.client.walkSpeed = 60
	sim.advance(30, walkSquare(record, 6))
	sim.api.clearMovementModifier(player, "Hoverboard")
	record.client.walkSpeed = 16
	sim.advance(15, walkSquare(record, 6))
	expectClean(sim, player, "hoverboard")
end)

test("legit", "server-side speed buff (Humanoid.WalkSpeed 32)", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Buffed" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	record.humanoid.__props.WalkSpeed = 32
	record.client.walkSpeed = 32
	sim.advance(40, walkSquare(record, 5, 1))
	expectClean(sim, player, "speed buff")
end)

test("legit", "seated in a vehicle at 80 studs/s", function()
	local sim = newLegitWorld()
	local seat = sim.addPart({ name = "VehicleSeat", position = Vector3.new(0, -50, 0), size = Vector3.new(1, 1, 1), anchored = false })
	local player, record = sim.addPlayer({ name = "Driver" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(4)
	record.humanoid.__props.SeatPart = seat
	record.client.override = function(dt, client)
		client.position += Vector3.new(80 * dt, 0, 0)
		client.velocity = Vector3.new(80, 0, 0)
	end
	sim.advance(20)
	record.humanoid.__props.SeatPart = nil
	record.client.override = nil
	sim.api.exempt(player, "VehicleExit", 1)
	sim.advance(8, walkSquare(record, 3))
	expectClean(sim, player, "vehicle")
end)

test("legit", "climbing a 100-stud truss", function()
	local sim = newLegitWorld()
	sim.addPart({ name = "Truss", position = Vector3.new(1.6, 50, 0), size = Vector3.new(1.2, 100, 2) })
	local player, record = sim.addPlayer({ name = "Climber" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(4)
	record.client.override = function(dt, client)
		if client.position.Y < 100 then
			client.position += Vector3.new(0, 10 * dt, 0)
			client.velocity = Vector3.new(0, 10, 0)
		else
			client.velocity = Vector3.zero -- holding on at the top
		end
	end
	sim.advance(14)
	expectClean(sim, player, "climbing")
end)

test("legit", "swimming and treading water", function()
	local sim = newLegitWorld()
	sim.addWater(Vector3.new(50, 0, -50), Vector3.new(250, 40, 150))
	local player, record = sim.addPlayer({ name = "Swimmer" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(3)
	record.client.override = function(dt, client)
		if client.position.X < 100 then
			client.position += Vector3.new(16 * dt, 0, 0)
		else
			-- Treading water mid-pool, drifting up and down.
			local y = 20 + math.sin(sim.now) * 5
			client.position = Vector3.new(client.position.X + 4 * dt, y, client.position.Z)
		end
		client.velocity = Vector3.new(16, 0, 0)
	end
	sim.advance(3)
	record.client.override = function(dt, client)
		local y = 20 + math.sin(sim.now) * 5
		client.position = Vector3.new(client.position.X + 4 * dt, y, client.position.Z)
		client.velocity = Vector3.new(4, 5 * math.cos(sim.now), 0)
	end
	sim.advance(30)
	expectClean(sim, player, "swimming")
end)

test("legit", "riding a 30 studs/s conveyor while walking along it", function()
	local sim = newLegitWorld()
	sim.addPart({ name = "Conveyor", position = Vector3.new(0, 0.5, 200), size = Vector3.new(20, 1, 420), velocity = Vector3.new(0, 0, 30) })
	local player, record = sim.addPlayer({ name = "Conveyed" })
	sim.spawn(player, Vector3.new(0, 1, 0))
	sim.advance(3)
	sim.advance(8, function()
		record.client.move = Vector3.new(0, 0, 1)
	end)
	expectClean(sim, player, "conveyor")
end)

test("legit", "flung by another player (collision with a stranger)", function()
	local sim = newLegitWorld()
	local victim, record = sim.addPlayer({ name = "Victim" })
	local other, otherRecord = sim.addPlayer({ name = "Stranger" })
	sim.spawn(victim, Vector3.new(0, 0, 0))
	sim.spawn(other, Vector3.new(3, 0, 0))
	sim.advance(6, walkSquare(record, 2))
	for _ = 1, 3 do
		otherRecord.client.override = function(_, client)
			client.position = record.client.position + Vector3.new(2, 0, 0)
		end
		sim.advance(0.3)
		local started = sim.now
		record.client.override = function(dt, client)
			client.position += Vector3.new(-150 * dt, 40 * dt, 0)
			client.velocity = Vector3.new(-150, 40, 0)
			if sim.now - started > 0.35 then
				record.client.override = nil
			end
		end
		sim.advance(0.4)
		otherRecord.client.override = nil
		sim.advance(8, walkSquare(record, 2))
	end
	expectClean(sim, victim, "flung victim")
end)

test("legit", "a short physics bump (no exemption)", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Bumped" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(6, walkSquare(record, 3))
	local started = sim.now
	record.client.override = function(dt, client)
		client.position += Vector3.new(40 * dt, 0, 0)
		if sim.now - started > 0.2 then
			record.client.override = nil
		end
	end
	sim.advance(6, walkSquare(record, 3))
	expectClean(sim, player, "bump")
end)

test("legit", "walking tight around a building corner", function()
	local sim = newLegitWorld()
	sim.addPart({ name = "Building", position = Vector3.new(0, 10, 0), size = Vector3.new(20, 20, 20) })
	local player, record = sim.addPlayer({ name = "CornerCutter" })
	sim.spawn(player, Vector3.new(-20, 0, -11.2))
	sim.advance(3)
	-- Laps around the building, 1.2 studs from its walls.
	local lap = { Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(0, 0, -1) }
	local corners = { Vector3.new(11.2, 0, -11.2), Vector3.new(11.2, 0, 11.2), Vector3.new(-11.2, 0, 11.2), Vector3.new(-11.2, 0, -11.2) }
	local leg = 1
	sim.advance(90, function()
		local position = record.client.position
		local target = corners[leg]
		if (Vector3.new(position.X, 0, position.Z) - target).Magnitude < 0.5 then
			leg = leg % 4 + 1
		end
		local toTarget = corners[leg] - Vector3.new(position.X, 0, position.Z)
		record.client.move = if toTarget.Magnitude > 0.01 then toTarget.Unit else lap[leg]
	end)
	expectClean(sim, player, "corner")
end)

test("legit", "launch pad with Api.exempt (100 studs up)", function()
	local sim = newLegitWorld()
	local player, record = sim.addPlayer({ name = "Launched" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(4, walkSquare(record, 2))
	sim.api.exempt(player, "LaunchPad", 5)
	record.client.velocity = Vector3.new(0, 200, 0)
	record.client.grounded = false
	record.client.jumpVelocity = 200
	record.client.jump = true
	sim.advance(8)
	record.client.jumpVelocity = 50
	sim.advance(5, walkSquare(record, 2))
	expectClean(sim, player, "launch pad")
end)

test("legit", "AFK for 20 minutes", function()
	local sim = newLegitWorld()
	local player = sim.addPlayer({ name = "Afk" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(1200)
	expectClean(sim, player, "AFK")
end)

test("legit", "roll button mashed at 15 clicks/s for 30 s", function()
	local sim = newLegitWorld()
	local player = sim.addPlayer({ name = "Masher" })
	local rolls = 0
	sim.api.bindRemote("RollDice", function()
		rolls += 1
	end, { cooldown = 1 })
	local nextClick = sim.now
	sim.advance(30, function(t)
		if t >= nextClick then
			nextClick = t + 1 / 15
			sim.fire(player, "RollDice")
		end
	end)
	note(`{rolls} rolls accepted`)
	check(rolls >= 29 and rolls <= 32, `about one roll per second, got {rolls}`)
	expectClean(sim, player, "roll mashing")
end)

test("legit", "opening menus and equipping rapidly", function()
	local sim = newLegitWorld()
	local player = sim.addPlayer({ name = "MenuFlipper" })
	local equips = 0
	sim.api.bindRemote("EquipCharacter", function()
		equips += 1
	end)
	sim.api.bindRemote("UnequipCharacter", function() end)
	sim.api.bindRemote("SetAutoRoll", function() end)
	local nextClick = sim.now
	local toggle = false
	sim.advance(20, function(t)
		if t >= nextClick then
			nextClick = t + 0.12
			toggle = not toggle
			sim.fire(player, if toggle then "EquipCharacter" else "UnequipCharacter", "{3F2504E0-4F89-11D3-9A0C-0305E82C3301}")
			sim.fire(player, "SetAutoRoll", toggle)
		end
	end)
	check(equips > 60, `equips went through ({equips})`)
	expectClean(sim, player, "menus")
end)

--------------------------------------------------------------------------------
-- Hostile play
--------------------------------------------------------------------------------

test("hostile", "client-side WalkSpeed 48 is detected, corrected, then kicked", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "SpeedHacker" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(5, walkSquare(record, 30))
	record.client.walkSpeed = 48 -- the server's Humanoid still says 16
	local firstFlag
	sim.advance(120, function(t)
		walkSquare(record, 30)(t)
		if not firstFlag and #sim.evidenceFor(player, "Speed") > 0 then
			firstFlag = t
		end
	end)
	local actions = sim.actionsFor(player)
	note(sim.describe(player))
	check(#sim.evidenceFor(player, "Speed") > 0, "speed detected")
	check((actions.Setback or 0) + (actions["Setback+Restrict"] or 0) > 0, "corrected")
	check(#sim.kicks == 1, "kicked after sustained abuse")
	check(sim.kicks[1].time - 1005 > 10, "not kicked within the first 10 seconds")
	check(#sim.bans == 0, "never auto-banned")
	local report = sim.dataStore["AntiCheatReports_v1/user_" .. player.UserId]
	check(report and #report == 1 and string.find(report[1].summary, "Speed"), "kick report saved for moderators")
end)

test("hostile", "same speed hack in TEST_MODE is only a simulated kick", function()
	local sim = H.newWorld({ testMode = true })
	local player, record = sim.addPlayer({ name = "Tester" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(5)
	record.client.walkSpeed = 48
	sim.advance(90, walkSquare(record, 30))
	local actions = sim.actionsFor(player)
	check(#sim.kicks == 0, "no kick in TEST_MODE")
	check(actions.WouldKick and actions.WouldKick > 0, "logged as WouldKick")
end)

test("hostile", "CFrame speed hack (60 studs/s)", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "CFrameSpeed" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(5)
	record.client.override = function(dt, client)
		client.position += Vector3.new(60 * dt, 0, 0)
		client.velocity = Vector3.zero
	end
	sim.advance(8)
	note(sim.describe(player))
	check(sim.pointsFor(player, "Speed") > 0, "speed detected")
	local actions = sim.actionsFor(player)
	check(actions.Setback or actions["Setback+Restrict"], "set back")
end)

test("hostile", "hovering 25 studs up", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "Hoverer" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(5)
	local hold = record.client.position + Vector3.new(0, 25, 0)
	record.client.override = function(_, client)
		client.position = hold
		client.velocity = Vector3.zero
	end
	sim.advance(12)
	note(sim.describe(player))
	check(sim.pointsFor(player, "Fly") > 0, "fly detected")
end)

test("hostile", "flying upward", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "Riser" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(5)
	record.client.override = function(dt, client)
		client.position += Vector3.new(10 * dt, 20 * dt, 0)
		client.velocity = Vector3.new(10, 20, 0)
	end
	sim.advance(6)
	note(sim.describe(player))
	check(sim.pointsFor(player, "Fly") > 0, "ascent detected")
end)

test("hostile", "super jump (client JumpPower 150)", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "SuperJumper" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(5)
	record.client.jumpVelocity = 150
	sim.advance(10, walkSquare(record, 5, 1.8))
	note(sim.describe(player))
	check(sim.pointsFor(player, "Fly") + sim.pointsFor(player, "Teleport") > 0, "super jump detected")
end)

test("hostile", "repeated 150-stud teleports", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "Teleporter" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(6, walkSquare(record, 3))
	for _ = 1, 3 do
		record.client.position += Vector3.new(150, 0, 0)
		sim.advance(1.2)
	end
	note(sim.describe(player))
	check(#sim.evidenceFor(player, "Teleport") >= 2, "teleports detected")
	local actions = sim.actionsFor(player)
	check(actions.Setback or actions["Setback+Restrict"], "corrected from the second teleport")
	check(record.root.Position.X < 200, "ended up back near the start")
end)

test("hostile", "teleport loop escalates instead of correcting forever", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "Looper" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(6, walkSquare(record, 3))
	for _ = 1, 20 do
		record.client.position += Vector3.new(120, 0, 0)
		sim.advance(2.1)
	end
	local actions = sim.actionsFor(player)
	local setbacks = (actions.Setback or 0) + (actions["Setback+Restrict"] or 0)
	note(sim.describe(player))
	check(#sim.evidenceFor(player, "SetbackLoop") > 0 or #sim.kicks > 0, "loop became evidence")
	check(setbacks <= 4 * 2, `corrections are rate limited ({setbacks})`)
end)

test("hostile", "the server-move safety net turns itself off if the signal is noisy", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "Noisy" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(6, walkSquare(record, 3))
	for _ = 1, 30 do
		record.cframeChanged:Fire() -- as if replication fired it
	end
	local warned = false
	for _, line in sim.output do
		if string.find(line.text, "automatic server-move exemptions are off", 1, true) then
			warned = true
		end
	end
	check(warned, "warned that the safety net is off")
	sim.advance(3, walkSquare(record, 3))
	record.client.position += Vector3.new(150, 0, 0) -- a real teleport hack
	sim.advance(1)
	check(#sim.evidenceFor(player, "Teleport") == 1, "teleports are still detected afterwards")
end)

test("hostile", "noclip through a row of thick walls", function()
	local sim = H.newWorld()
	for index = 1, 6 do
		sim.addPart({ name = "Wall", position = Vector3.new(index * 12, 10, 0), size = Vector3.new(4, 20, 40) })
	end
	local player, record = sim.addPlayer({ name = "Noclipper" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(4)
	record.client.noclip = true
	sim.advance(7, function()
		record.client.move = Vector3.new(1, 0, 0)
		record.client.walkSpeed = 14
	end)
	note(sim.describe(player))
	check(#sim.evidenceFor(player, "Noclip") > 0, "noclip recorded as evidence")
	check(sim.pointsFor(player, "Noclip") <= 4, "noclip alone stays under the setback level")
end)

test("hostile", "NaN position and fling spin are corrected", function()
	local sim = H.newWorld()
	local player, record = sim.addPlayer({ name = "Physics" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(6, walkSquare(record, 3))
	local nan = 0 / 0
	record.client.override = function(_, client)
		client.position = Vector3.new(nan, nan, nan)
	end
	sim.advance(0.3)
	record.client.override = nil
	sim.advance(3)
	check(#sim.evidenceFor(player, "ImpossiblePhysics") > 0, "NaN detected")
	local position = record.root.Position
	check(position.X == position.X, "server position is valid again")
	record.client.angular = Vector3.new(0, 1000, 0)
	sim.advance(1)
	record.client.angular = Vector3.zero
	sim.advance(2)
	note(sim.describe(player))
	check(#sim.evidenceFor(player, "ImpossiblePhysics") >= 2, "fling spin detected")
end)

test("hostile", "developer bypass in live servers, but tested in TEST_MODE", function()
	local live = H.newWorld()
	live.Config.Permissions.DeveloperUserIds = { 4242 }
	local dev, record = live.addPlayer({ name = "Dev", userId = 4242 })
	check(live.api.getRole(dev) == "Developer", "role from config")
	live.spawn(dev, Vector3.new(0, 0, 0))
	live.advance(4)
	record.client.walkSpeed = 60
	live.advance(60, walkSquare(record, 20))
	local devActions = live.actionsFor(dev)
	check(#live.kicks == 0 and not devActions.Setback and not devActions.Restrict, "developer untouched in live servers")
	check(#live.evidenceFor(dev, "Speed") == 0, "staff movement isn't checked in live servers")
	live.api.flag(dev, "EconomyTamper", "test")
	check(live.actionsFor(dev).Bypass == 1, "staff remote / economy detections are logged as Bypass")
	check(live.api.getRole(dev) == "Developer" and live.api.isStaff(dev), "isStaff")

	local test = H.newWorld({ testMode = true })
	test.Config.Permissions.DeveloperUserIds = { 4242 }
	local dev2, record2 = test.addPlayer({ name = "Dev", userId = 4242 })
	test.spawn(dev2, Vector3.new(0, 0, 0))
	test.advance(4)
	record2.client.walkSpeed = 60
	test.advance(20, walkSquare(record2, 20))
	check(test.pointsFor(dev2, "Speed") > 0, "developer is tested in TEST_MODE")

	local owner = H.newWorld()
	local creator = owner.addPlayer({ name = "Owner", userId = 1 })
	check(owner.api.getRole(creator) == "Developer", "place owner is a developer")
end)

--------------------------------------------------------------------------------
-- Hostile remotes
--------------------------------------------------------------------------------

local function remoteWorld()
	local sim = H.newWorld()
	local player = sim.addPlayer({ name = "RemoteAbuser" })
	sim.spawn(player, Vector3.new(0, 0, 0))
	sim.advance(1)
	return sim, player
end

test("hostile", "malformed remote arguments never reach handlers", function()
	local sim, player = remoteWorld()
	local calls = {}
	local function counter(name)
		return function()
			calls[name] = (calls[name] or 0) + 1
		end
	end
	for _, name in { "RollDice", "DiceShop", "PlaceCharacter", "SellCharacters", "CollectCash", "ClaimAfkReward" } do
		sim.api.bindRemote(name, counter(name))
	end
	local nan = 0 / 0
	local attempts = {
		{ "RollDice", "Legendary" },
		{ "RollDice", { character = "Mythic" } },
		{ "DiceShop", nil, "Buy" },
		{ "DiceShop", "Celestial", "Steal" },
		{ "DiceShop", string.rep("A", 5000), "Buy" },
		{ "DiceShop", nan, "Buy" },
		{ "DiceShop", "Celestial", "Buy", 0 },
		{ "PlaceCharacter", "abc", -1 },
		{ "PlaceCharacter", "abc", math.huge },
		{ "SellCharacters", { "a", "a" } },
		{ "SellCharacters", { a = "b" } },
		{ "CollectCash", 1e12 },
		{ "ClaimAfkReward", 86400 },
	}
	for index, attempt in attempts do
		sim.advance(1.1) -- stay inside every rate limit: only validation is tested here
		sim.fire(player, table.unpack(attempt, 1, 4))
		check(next(calls) == nil, `attempt {index} ({attempt[1]}) reached the handler`)
	end
	local invalid = sim.evidenceFor(player, "InvalidRemote")
	note(sim.describe(player))
	check(#invalid == #attempts, `all {#attempts} logged, got {#invalid}`)
	check(sim.api.getScore(player) <= 8, "malformed remotes alone stay under the restrict level")
end)

test("hostile", "roll spam: 100 in one frame, then 20/s", function()
	local sim, player = remoteWorld()
	local rolls = 0
	sim.api.bindRemote("RollDice", function()
		rolls += 1
	end, { cooldown = 1.5 })
	for _ = 1, 100 do
		sim.fire(player, "RollDice")
	end
	check(rolls == 1, `one roll from a 100-request burst, got {rolls}`)
	local nextFire = sim.now
	sim.advance(3, function(t)
		if t >= nextFire then
			nextFire = t + 0.05
			sim.fire(player, "RollDice")
		end
	end)
	note(sim.describe(player))
	check(rolls <= 4, `the real cooldown holds under spam ({rolls} rolls in ~3s at a 1.5s cooldown)`)
	check(#sim.evidenceFor(player, "RemoteFlood") >= 1, "flood recorded")
	check(sim.api.getScore(player) <= 5, "flood alone can't reach setbacks")
end)

test("hostile", "fake purchases: unknown id, price, duplicates, insufficient funds", function()
	local sim, player = remoteWorld()
	local economy = sim.api.Economy
	local catalog = { Wooden = { price = 0 }, Golden = { price = 500 }, Celestial = { price = 350e6 } }
	local cash = 1000
	local owned = {}
	local reentered = false
	sim.api.bindRemote("DiceShop", function(buyer, itemId, action)
		local item = economy.lookup(catalog, itemId)
		if action ~= "Buy" or owned[itemId] then
			return
		end
		economy.transaction(buyer, function()
			if not reentered then
				-- A second request arrives while this one is still running.
				reentered = true
				sim.fire(buyer, "DiceShop", itemId, "Buy")
			end
			local ok, newCash = economy.applyChange(buyer, "Cash", cash, -item.price, "DicePurchase")
			if ok then
				cash = newCash
				owned[itemId] = true
			end
		end)
	end, { checks = { [1] = function(id)
		return catalog[id] ~= nil
	end } })

	sim.fire(player, "DiceShop", "Golden", "Buy")
	check(cash == 500, `Golden bought once despite a concurrent duplicate (cash {cash})`)
	sim.advance(1)
	sim.fire(player, "DiceShop", "Golden", "Buy")
	check(cash == 500, "owned dice isn't charged again")
	sim.advance(1)
	sim.fire(player, "DiceShop", "Celestial", "Buy")
	check(cash == 500 and not owned.Celestial, "insufficient funds refused")
	sim.advance(1)
	sim.fire(player, "DiceShop", "FreeCelestial", "Buy")
	sim.advance(1)
	sim.fire(player, "DiceShop", "Celestial", "Buy", 0)
	check(cash == 500 and not owned.Celestial and not owned.FreeCelestial, "fake ids and prices refused")
	check(#sim.evidenceFor(player, "InvalidRemote") == 2, "fakes logged as evidence")
	local ledger = economy.getLedger(player)
	check(#ledger == 1 and ledger[1].reason == "DicePurchase", "the one real purchase is explained in the ledger")
end)

test("hostile", "duplicate reward claims pay out once", function()
	local sim, player = remoteWorld()
	local economy = sim.api.Economy
	local claimedInSave = {}
	local gems = 0
	sim.api.bindRemote("ClaimIndexReward", function(claimer, entryId)
		if claimedInSave[entryId] or not economy.claimOnce(claimer, "Index:" .. entryId) then
			return
		end
		local ok, newGems = economy.applyChange(claimer, "Gems", gems, 25, "IndexReward")
		if ok then
			gems = newGems
			claimedInSave[entryId] = true
		end
	end)
	local afkPaid = 0
	local lastAfkClaim = sim.now
	sim.api.bindRemote("ClaimAfkReward", function()
		-- The server works out the reward from its own clock.
		local minutes = math.floor((sim.now - lastAfkClaim) / 60)
		lastAfkClaim = sim.now
		afkPaid += minutes
	end)
	for _ = 1, 10 do
		sim.fire(player, "ClaimIndexReward", "Wooden")
		sim.fire(player, "ClaimAfkReward")
		sim.fire(player, "ClaimAfkReward", 86400)
	end
	check(gems == 25, `index reward paid once, got {gems}`)
	check(afkPaid == 0, "no AFK reward without AFK time, whatever the client says")
	sim.advance(301)
	sim.fire(player, "ClaimAfkReward")
	check(afkPaid == 5, `AFK reward from the server clock ({afkPaid})`)
end)

test("hostile", "shop proximity is checked on the server", function()
	local sim, player = remoteWorld()
	sim.addPart({
		name = "RideShop",
		position = Vector3.new(0, 2, 10),
		size = Vector3.new(4, 4, 4),
		tag = "Shop",
		attributes = { ShopId = "RideShop", Radius = 15 },
	})
	local bought = 0
	sim.api.bindRemote("BuyRide", function()
		bought += 1
	end, { shop = "RideShop" })
	sim.fire(player, "BuyRide", "Hoverboard")
	check(bought == 1, "near the shop: allowed")
	sim.advance(1)
	sim.api.teleport(player, CFrame.new(Vector3.new(0, 3, 900)), "Test")
	sim.advance(1)
	sim.fire(player, "BuyRide", "Hoverboard")
	check(bought == 1, "far from the shop: refused")
	check(#sim.evidenceFor(player, "EconomyTamper") == 1, "an absurd distance is evidence")
end)

test("hostile", "RemoteFunction: refusals return a reason, codes are rate limited", function()
	local sim, player = remoteWorld()
	sim.api.bindRemote("RedeemCode", function(_, code)
		return code == "LAUNCH", "ok"
	end)
	local a, b = sim.invoke(player, "RedeemCode", string.rep("x", 100))
	check(a == nil and b == "InvalidArguments", "long code refused")
	local ok = sim.invoke(player, "RedeemCode", "LAUNCH")
	check(ok == true, "real code accepted")
	local limited = 0
	for _ = 1, 10 do
		local result, reason = sim.invoke(player, "RedeemCode", "GUESS")
		if result == nil and reason == "RateLimited" then
			limited += 1
		end
	end
	check(limited >= 8, `guessing is rate limited ({limited}/10)`)
end)

test("hostile", "repeated tampering restricts economy remotes for a while", function()
	local sim, player = remoteWorld()
	local bought = 0
	sim.api.bindRemote("BuyUpgrade", function()
		bought += 1
	end)
	for _ = 1, 4 do
		sim.api.flag(player, "EconomyTamper", "test")
	end
	sim.fire(player, "BuyUpgrade", "Luck_1")
	check(bought == 0, "restricted")
	check(sim.actionsFor(player).Restrict, "restriction logged")
	sim.advance(9)
	sim.fire(player, "BuyUpgrade", "Luck_1")
	check(bought == 1, "restriction lifts after RestrictSeconds")
end)

test("hostile", "remotes without a contract can't be bound", function()
	local sim = H.newWorld()
	check(not pcall(sim.api.bindRemote, "GiveCharacter", function() end), "no contract, no remote")
	check(sim.remote("GiveCharacter") == nil, "nothing was created")
end)

test("hostile", "bans only through a moderator", function()
	local sim = H.newWorld()
	sim.Config.Permissions.ModeratorUserIds = { 777 }
	local normal = sim.addPlayer({ name = "Normal" })
	local moderator = sim.addPlayer({ name = "Mod", userId = 777 })
	local ok, reason = sim.api.moderatorBan(normal, 1001, 86400, "trust me")
	check(not ok and reason == "NotAllowed", "players can't ban")
	check(not sim.api.moderatorBan(moderator, 0 / 0, 60, "x"), "bad user id refused")
	check(sim.api.moderatorBan(moderator, 1001, 86400, "speed evidence reviewed"), "moderator ban")
	check(#sim.bans == 1 and sim.bans[1].UserIds[1] == 1001, "BanAsync called once")
	sim.Config.TEST_MODE = true
	sim.api.moderatorBan(moderator, 1002, 86400, "test")
	check(#sim.bans == 1, "TEST_MODE never bans")
end)

--------------------------------------------------------------------------------

print(`\n{results.passed} passed, {results.failed} failed`)
if results.failed > 0 then
	print("Failed:\n  " .. table.concat(results.failures, "\n  "))
	process.exit(1)
end
