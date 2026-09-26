--!strict
--[[
	AntiCheat Api (ModuleScript)
	Location: ServerScriptService > AntiCheat > Api

	The one module the rest of the game's SERVER code requires. It wires the
	modules together and is started by the AntiCheat Script next to it.

		local AntiCheat = require(game.ServerScriptService.AntiCheat.Api)

	Remotes
	  bindRemote(name, handler, options?)   bind a gameplay remote behind its
	                                         contract (RemoteContracts)
	  validate(specs, args, count)          the same argument checks, for code
	                                         that validates by hand

	Movement the server causes (so the anti-cheat never fights the game)
	  teleport(player, cframe, reason)       move a player; exempted + re-baselined
	  exempt(player, reason, seconds)        ignore movement for a moment
	                                         (knockback, launch pads, cutscenes)
	  setMovementModifier(player, key, modifier, seconds?)
	  clearMovementModifier(player, key)     rides, speed buffs, gliders

	Evidence
	  flag(player, kind, details?, severity?) report e.g. "EconomyTamper"
	  getScore / getEvidence / getSummary, onEvidence(callback)

	Staff
	  getRole(player), isStaff(player)
	  moderatorBan(moderator, userId, seconds, reason)   the only ban path

	Economy helpers: AntiCheat.Economy (see EconomyValidator).
]]

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local RemoteContracts = require(script.Parent.RemoteContracts)

local Modules = script.Parent.Modules
local Enforcement = require(Modules.Enforcement)
local EconomyValidator = require(Modules.EconomyValidator)
local EvidenceLogger = require(Modules.EvidenceLogger)
local ExemptionManager = require(Modules.ExemptionManager)
local MovementValidator = require(Modules.MovementValidator)
local RateLimiter = require(Modules.RateLimiter)
local RemoteValidator = require(Modules.RemoteValidator)
local ViolationTracker = require(Modules.ViolationTracker)

export type Modifier = ExemptionManager.Modifier
export type Evidence = EvidenceLogger.Evidence
export type Handler = RemoteValidator.Handler

export type BindOptions = {
	-- The real cooldown (seconds), or a function of the player for upgradable ones.
	cooldown: (number | (player: Player) -> number)?,
	rate: RemoteValidator.RateRule?,
	shop: string?, -- ShopId the player must stand near
	-- Extra server-side checks per argument index, e.g. catalog lookups.
	checks: { [number]: (value: any) -> boolean }?,
	-- A full contract, for a remote that isn't in RemoteContracts.
	contract: RemoteValidator.Contract?,
}

local clock = os.clock

local MOVEMENT_KINDS = {
	Speed = true,
	Fly = true,
	Teleport = true,
	Noclip = true,
	ImpossiblePhysics = true,
	SetbackLoop = true,
}

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local exemptions = ExemptionManager.new(clock)
local tracker = ViolationTracker.new(Config.Violations, Config.Enforcement.Levels, clock)
local logger = EvidenceLogger.new(Config.Logging, Config.DEBUG)
local limiter = RateLimiter.new(clock)

local function isBypassed(player: Player): boolean
	if Config.TEST_MODE or not Config.Permissions.BypassStaff then
		return false
	end
	return exemptions.getRole(player) ~= "Player"
end

local function persistKickReport(player: Player)
	if not Config.Logging.PersistKickReports then
		return
	end
	local recent = {}
	for _, entry in logger.getRecent(player, 10) do
		table.insert(recent, {
			t = entry.time,
			d = entry.detection,
			a = entry.action,
			s = math.round(entry.score * 10) / 10,
			x = entry.details,
		})
	end
	local report = {
		time = os.time(),
		placeId = game.PlaceId,
		jobId = game.JobId,
		score = math.round(tracker.getScore(player) * 10) / 10,
		summary = logger.summary(player),
		recent = recent,
	}
	local userId = player.UserId
	task.spawn(function()
		local ok, err = pcall(function()
			local store = DataStoreService:GetDataStore(Config.Logging.ReportStoreName)
			store:UpdateAsync(`user_{userId}`, function(old: any)
				local list = if type(old) == "table" then old else {}
				table.insert(list, report)
				while #list > Config.Logging.ReportsPerUser do
					table.remove(list, 1)
				end
				return list
			end)
		end)
		if not ok then
			warn(`[AntiCheat] couldn't save the kick report for {userId}: {err}`)
		end
	end)
end

local movement: MovementValidator.MovementValidator

local enforcement = Enforcement.new({
	config = Config,
	clock = clock,
	isBypassed = isBypassed,
	getRole = exemptions.getRole,
	setback = function(player: Player, reason: string): boolean
		return movement.setback(player, reason)
	end,
	restrictMovement = function(player: Player, seconds: number): boolean
		return movement.restrict(player, seconds)
	end,
	kick = function(player: Player, message: string)
		player:Kick(message)
	end,
	ban = function(userId: number, seconds: number, displayReason: string, privateReason: string): (boolean, string?)
		local ok, err = pcall(function()
			Players:BanAsync({
				UserIds = { userId },
				ApplyToUniverse = true,
				Duration = seconds,
				DisplayReason = displayReason,
				PrivateReason = privateReason,
				ExcludeAltAccounts = false,
			})
		end)
		return ok, if ok then nil else tostring(err)
	end,
	onKick = persistKickReport,
})

type ViolationInfo = {
	position: Vector3?,
	velocity: Vector3?,
	expectedSpeed: number?,
	actualSpeed: number?,
	humanoidState: string?,
	ping: number?,
	details: string?,
}

-- Every detection ends up here: score it, act on the level, keep the evidence.
local function handleViolation(player: Player, kind: string, severity: number, info: ViolationInfo)
	local result = tracker.add(player, kind, severity)
	local category: Enforcement.Category = if MOVEMENT_KINDS[kind] then "Movement" else "Remote"
	local decision = enforcement.decide(player, kind, category, result.added, result.level, result.events)
	logger.record(player, {
		detection = kind,
		severity = severity,
		added = result.added,
		score = result.score,
		level = result.level,
		action = decision.action,
		position = info.position,
		velocity = info.velocity,
		expectedSpeed = info.expectedSpeed,
		actualSpeed = info.actualSpeed,
		humanoidState = info.humanoidState,
		ping = info.ping or movement.getPing(player),
		details = info.details,
	})
end

movement = MovementValidator.new({
	config = Config.Movement,
	world = MovementValidator.robloxWorld(Config.Movement),
	clock = clock,
	isExempt = function(player: Player): boolean
		return (exemptions.isExempt(player))
	end,
	getProfile = exemptions.getProfile,
	isBypassed = isBypassed,
	report = function(player: Player, entry: MovementValidator.Report)
		handleViolation(player, entry.kind, entry.severity, entry)
	end,
})

local economy = EconomyValidator.new({
	config = Config.Economy,
	getRootPosition = movement.getRootPosition,
	getWalkSpeed = movement.getWalkSpeed,
	getPing = movement.getPing,
	getShops = function(shopId: string): { Instance }
		local shops = {}
		for _, instance in CollectionService:GetTagged(Config.Economy.ShopTag) do
			if instance:GetAttribute("ShopId") == shopId and instance:IsDescendantOf(workspace) then
				table.insert(shops, instance)
			end
		end
		return shops
	end,
})

local gateway = RemoteValidator.createGateway({
	config = Config.Remotes,
	consume = limiter.consume,
	isRestricted = enforcement.isRemoteRestricted,
	isNearShop = economy.isNearShop,
	report = function(player: Player, kind: string, severity: number, details: string)
		handleViolation(player, kind, severity, { details = details })
	end,
	clock = clock,
})

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local AntiCheat = {}

AntiCheat.Config = Config
AntiCheat.Economy = economy
AntiCheat.validate = RemoteValidator.validate

local function deepClone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepClone(item)
	end
	return copy
end

-- Binds `handler` to ReplicatedStorage.Remotes[name] behind its contract.
-- The handler receives (player, ...validated arguments). For RemoteFunctions,
-- a refused call returns nil, reason ("RateLimited", "InvalidArguments", ...).
function AntiCheat.bindRemote(name: string, handler: Handler, options: BindOptions?): RemoteEvent | RemoteFunction
	local base = if options and options.contract then options.contract else RemoteContracts[name]
	if not base then
		error(`[AntiCheat] no contract for remote "{name}". Add it to RemoteContracts or pass options.contract.`, 2)
	end
	local contract = deepClone(base) :: RemoteValidator.Contract
	if options then
		if options.cooldown ~= nil then
			contract.cooldown = options.cooldown
		end
		if options.rate then
			contract.rate = options.rate
			contract.cooldown = nil
		end
		if options.shop then
			contract.shop = options.shop
		end
		local checks = options.checks
		if checks then
			for index, check in checks do
				local spec = contract.args[index]
				assert(spec, `[AntiCheat] {name} has no argument {index} to check`)
				local existing = spec.check
				spec.check = if existing
					then function(value: any): boolean
						return existing(value) and check(value)
					end
					else check
			end
		end
	end
	return gateway.bind(name, contract, handler)
end

-- Report something the game itself caught, e.g. a purchase of an item id the
-- catalog doesn't have ("EconomyTamper"). Kinds are the keys of
-- Config.Violations.Weights.
function AntiCheat.flag(player: Player, kind: string, details: string?, severity: number?)
	if Config.Violations.Weights[kind] == nil then
		error(`[AntiCheat] unknown violation kind "{kind}"`, 2)
	end
	handleViolation(player, kind, math.clamp(severity or 1, 0, 3), { details = details })
end

function AntiCheat.exempt(player: Player, reason: string, seconds: number)
	exemptions.grant(player, reason, seconds)
end

function AntiCheat.teleport(player: Player, target: CFrame, reason: string): boolean
	return movement.teleport(player, target, reason)
end

function AntiCheat.setMovementModifier(player: Player, key: string, modifier: Modifier, seconds: number?)
	exemptions.setModifier(player, key, modifier, seconds)
end

function AntiCheat.clearMovementModifier(player: Player, key: string)
	exemptions.clearModifier(player, key)
	-- The player is still going fast for a moment after getting off a ride.
	exemptions.grant(player, `ModifierEnded:{key}`, Config.Movement.SpeedWindow + 0.5)
end

function AntiCheat.getRole(player: Player): ExemptionManager.Role
	return exemptions.getRole(player)
end

function AntiCheat.isStaff(player: Player): boolean
	return exemptions.getRole(player) ~= "Player"
end

function AntiCheat.getScore(player: Player): number
	return tracker.getScore(player)
end

function AntiCheat.getEvidence(player: Player, count: number?): { Evidence }
	return logger.getRecent(player, count)
end

function AntiCheat.getSummary(player: Player): string
	return logger.summary(player)
end

function AntiCheat.onEvidence(callback: (player: Player, evidence: Evidence) -> ()): () -> ()
	return logger.onRecord(callback)
end

function AntiCheat.moderatorBan(moderator: Player, userId: number, seconds: number, reason: string): (boolean, string?)
	return enforcement.moderatorBan(moderator, userId, seconds, reason)
end

-- Lists remotes in ReplicatedStorage that don't go through bindRemote.
function AntiCheat.auditRemotes(): { string }
	local bound = gateway.boundRemotes()
	local unprotected = {}
	for _, instance in ReplicatedStorage:GetDescendants() do
		if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") or instance:IsA("UnreliableRemoteEvent") then
			local name = bound[instance]
			if not name or gateway.isDemo(name) then
				table.insert(unprotected, instance:GetFullName())
			end
		end
	end
	return unprotected
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function resolveRole(player: Player): ExemptionManager.Role
	local permissions = Config.Permissions
	if table.find(permissions.DeveloperUserIds, player.UserId) then
		return "Developer"
	elseif table.find(permissions.ModeratorUserIds, player.UserId) then
		return "Moderator"
	elseif
		permissions.GameOwnerIsDeveloper
		and game.CreatorType == Enum.CreatorType.User
		and player.UserId == game.CreatorId
	then
		return "Developer"
	end
	return "Player"
end

-- Group ranks need a web call, so they're looked up in the background.
local function resolveGroupRole(player: Player)
	local permissions = Config.Permissions
	local function rankIn(groupId: number): number
		local ok, rank = pcall(function()
			return player:GetRankInGroupAsync(groupId)
		end)
		return if ok and type(rank) == "number" then rank else 0
	end
	local role: ExemptionManager.Role? = nil
	if permissions.GameOwnerIsDeveloper and game.CreatorType == Enum.CreatorType.Group and rankIn(game.CreatorId) >= 255 then
		role = "Developer"
	elseif permissions.GroupId > 0 then
		local rank = rankIn(permissions.GroupId)
		if rank >= permissions.DeveloperMinRank then
			role = "Developer"
		elseif rank >= permissions.ModeratorMinRank then
			role = "Moderator"
		end
	end
	if role and player.Parent == Players and exemptions.getRole(player) == "Player" then
		exemptions.setRole(player, role)
	end
end

local function watchCharacter(player: Player, character: Model)
	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if
			humanoid
			and root
			and humanoid:IsA("Humanoid")
			and root:IsA("BasePart")
			and player.Character == character
		then
			movement.addCharacter(player, character, humanoid, root)
		end
	end)
end

local function onPlayerAdded(player: Player)
	exemptions.setRole(player, resolveRole(player))
	if Config.Permissions.GroupId > 0 or game.CreatorType == Enum.CreatorType.Group then
		task.spawn(resolveGroupRole, player)
	end
	player.CharacterAdded:Connect(function(character)
		watchCharacter(player, character)
	end)
	if player.Character then
		watchCharacter(player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	movement.removePlayer(player)
	tracker.remove(player)
	limiter.remove(player)
	exemptions.remove(player)
	logger.remove(player)
	economy.removePlayer(player)
	enforcement.removePlayer(player)
	gateway.removePlayer(player)
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

local started = false

-- Only for remotes that don't exist yet: a game remote with its own handler
-- is never touched (the audit lists it instead).
local function bindDemoHandlers()
	local folder = ReplicatedStorage:FindFirstChild(Config.Remotes.FolderName)
	for name, contract in RemoteContracts do
		if not gateway.isBound(name) and not (folder and folder:FindFirstChild(name)) then
			gateway.bind(name, contract, function(player: Player, ...: any)
				print(`[AntiCheat demo] {name} accepted from {player.Name}:`, ...)
				return true
			end, true)
		end
	end
end

local function auditOnStart()
	local unprotected = AntiCheat.auditRemotes()
	if #unprotected > 0 then
		warn(
			`[AntiCheat] {#unprotected} remote(s) don't go through AntiCheat.bindRemote (no rate limit or `
				.. `argument checks):\n  `
				.. table.concat(unprotected, "\n  ")
		)
	end
	if ReplicatedStorage:FindFirstChild("AntiCheatEvent") then
		warn(
			"[AntiCheat] ReplicatedStorage.AntiCheatEvent belongs to the old free-model anti-cheat, "
				.. "which trusted client-reported speed. Delete it and both of its scripts."
		)
	end
end

function AntiCheat.start()
	if started then
		return
	end
	started = true

	-- Lets the Studio tester know it may run. Harmless to expose.
	ReplicatedStorage:SetAttribute("AntiCheatTestMode", Config.TEST_MODE)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- The single loop: every character is sampled from here.
	if Config.Movement.Enabled then
		RunService.Heartbeat:Connect(function()
			movement.step(clock())
		end)
	end

	-- After the game's own scripts have had time to bind their remotes.
	task.delay(Config.Remotes.AuditDelay, function()
		if Config.Remotes.AuditOnStart and (RunService:IsStudio() or Config.DEBUG) then
			auditOnStart()
		end
		if Config.Testing.DemoHandlers then
			bindDemoHandlers()
		end
	end)

	print(
		`[AntiCheat] started ({if Config.TEST_MODE then "TEST_MODE: kicks are simulated" else "live enforcement"}, `
			.. `DEBUG {if Config.DEBUG then "on" else "off"})`
	)
end

return AntiCheat
