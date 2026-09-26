--!strict
--[[
	Config (ModuleScript)
	Location: ServerScriptService > AntiCheat > Config

	Every tunable number of the anti-cheat lives here. The defaults are chosen
	to avoid false positives first and to catch cheaters second: a single odd
	measurement never punishes anyone, and nothing here ever bans.

	Lives in ServerScriptService, so clients can't read or change it.
]]

local RunService = game:GetService("RunService")

local IS_STUDIO = RunService:IsStudio()

local Config = {}

--------------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------------

-- TEST_MODE: every detection still runs (for developers too), setbacks still
-- happen so you can see them, but kicks are only logged as "WOULD KICK".
-- It is on automatically in Studio, so a play-test can never kick you.
-- Set FORCE_TEST_MODE to test the same way on a live test server.
Config.FORCE_TEST_MODE = false
Config.TEST_MODE = IS_STUDIO or Config.FORCE_TEST_MODE

-- DEBUG: prints every evidence entry (throttled) instead of only level 2+.
Config.DEBUG = IS_STUDIO

--------------------------------------------------------------------------------
-- Permissions (server-side only; a client can't grant itself any of this)
--------------------------------------------------------------------------------

Config.Permissions = {
	-- Staff are never set back, restricted or kicked outside TEST_MODE.
	DeveloperUserIds = {} :: { number },
	ModeratorUserIds = {} :: { number },
	-- The place owner (or group owner, for group games) counts as a developer.
	GameOwnerIsDeveloper = true,
	-- Optional group ranks. 0 turns group lookups off.
	GroupId = 0,
	DeveloperMinRank = 255,
	ModeratorMinRank = 254,
	BypassStaff = true,
}

--------------------------------------------------------------------------------
-- Violations: score, weights and decay
--------------------------------------------------------------------------------

Config.Violations = {
	-- Points added per detection. Detectors pass a severity (1-3) that
	-- multiplies the weight, e.g. a 5x speed hack counts more than 1.6x.
	Weights = {
		Speed = 1,
		Fly = 2,
		Teleport = 2.5, -- one teleport, even a blatant one, is only logged
		Noclip = 0.5,
		ImpossiblePhysics = 4,
		SetbackLoop = 2,
		InvalidRemote = 2,
		RemoteFlood = 1,
		EconomyTamper = 3,
	} :: { [string]: number },

	-- A detection of this kind stops adding points once the total score has
	-- reached the cap. Low-confidence evidence (noclip, spam, malformed
	-- remotes, which a stale client after an update can also produce) can
	-- never push anyone into setbacks or kicks on its own.
	ScoreCaps = {
		Noclip = 4,
		RemoteFlood = 5,
		InvalidRemote = 8,
	} :: { [string]: number },

	-- After DecayDelay seconds without a new violation the score drops by
	-- DecayPerSecond, so one accidental flag is gone within a minute.
	DecayDelay = 10,
	DecayPerSecond = 0.1,
	MaxScore = 40,

	-- Events older than this don't count towards KickMinEvents.
	EventWindow = 300,
}

--------------------------------------------------------------------------------
-- Enforcement levels
--------------------------------------------------------------------------------

--[[
	Score  Level  Action
	  0      0    normal player
	 >=1     1    silent observation
	 >=3     2    evidence is logged to the output
	 >=6     3    movement is corrected (set back to the last trusted spot)
	 >=10    4    temporary restriction (movement frozen / economy remotes refused)
	 >=18    5    kick, and only with KickMinEvents violations in EventWindow

	There is no automatic ban. Bans go through Api.moderatorBan, which a
	moderator has to call after reading the evidence.
]]
Config.Enforcement = {
	Levels = {
		Observe = 1,
		Log = 3,
		Setback = 6,
		Restrict = 10,
		Kick = 18,
	},
	AllowSetback = true,
	AllowRestrict = true,
	AllowKick = true, -- only simulated in TEST_MODE
	KickMinEvents = 6,
	RestrictSeconds = 8,
	RestrictCooldown = 30,
	KickMessage = "Disconnected: unusual activity was detected. If this was a mistake, just rejoin.",
}

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

export type LatencyProfile = {
	name: string,
	maxPing: number, -- round trip, seconds
	speedTolerance: number, -- multiplier on the allowed speed
	extraSlack: number, -- extra studs for teleport / ascent checks
	extraAirTime: number, -- extra seconds before hovering counts
}

Config.Movement = {
	Enabled = true,

	-- One central loop samples every character this often (staggered).
	SampleInterval = 0.25,
	-- A gap between samples longer than this (server hitch) re-baselines.
	MaxSampleGap = 1.0,

	-- Used when the server-side Humanoid.WalkSpeed is lower. WalkSpeed is
	-- read from the SERVER's Humanoid, which clients can't change; buffs set
	-- it there, or use Api.setMovementModifier.
	BaseWalkSpeed = 16,
	-- Allowed speed while seated (vehicles). Speed and fly checks are skipped
	-- while seated; this only bounds the teleport check.
	SeatedMaxSpeed = 120,

	-- Speed: net horizontal distance over a rolling window, not per sample.
	SpeedWindow = 2.0,
	SpeedWindowMin = 1.0,
	SpeedSustainSeconds = 1.0, -- over the limit this long before it counts
	SpeedFlagInterval = 1.5, -- at most one speed violation per interval
	SpeedFlatTolerance = 3, -- studs/s on top of the multiplier

	-- Teleport: one sample to the next. The allowance grows with the time the
	-- server saw no movement (a lagging client catching up in one burst).
	TeleportSlack = 30,
	UpwardSlack = 25,
	StallCreditMax = 3,

	-- Fly: airborne with nothing supporting the character.
	GroundProbeDepth = 4, -- studs below the feet that still count as ground
	AirborneGrace = 2.5, -- seconds airborne before hovering can count
	FlyWindow = 1.5,
	HoverMaxDescent = 3, -- fell less than this over FlyWindow = hovering
	AscentSlack = 8, -- studs above the highest legal jump
	FlyFlagInterval = 1.5,

	-- Another character this close means the movement may have been caused
	-- by a collision or a fling, so it's recorded without points. The grace
	-- outlasts SpeedWindow so the fling can't be scored once they part.
	ContactRadius = 8,
	ContactGrace = 3,

	-- Impossible physics: always corrected, never legitimate. Reported at
	-- most once per PhysicsFlagInterval.
	MaxCoordinate = 100000,
	MaxLinearVelocity = 3000,
	MaxAngularVelocity = 400,
	PhysicsFlagInterval = 2,

	SpawnGrace = 3, -- after spawning / respawning
	TeleportGrace = 1.5, -- after Api.teleport (or any server-side move)

	-- Safety net for server scripts that move players without Api.teleport:
	-- a server-side CFrame write on the root gets TeleportGrace too. It turns
	-- itself off if the signal fires more often than this (physics rates).
	AutoExemptServerMoves = true,
	AutoExemptMaxEventsPerSecond = 20,
	SetbackGrace = 1.0, -- after a correction (plus the player's ping)

	Setback = {
		MinInterval = 2,
		MaxPerWindow = 4, -- more than this in Window = escalate instead of looping
		Window = 30,
		TrustedMaxAge = 20, -- never set back to a spot older than this
	},

	-- Noclip is evidence only: it can't reach the setback level by itself.
	Noclip = {
		Enabled = true,
		MinSegment = 2, -- only check samples that moved this far
		MinPenetration = 0.8, -- studs of solid wall crossed (corner cuts are shallower)
		HitsToFlag = 3,
		HitWindow = 10,
	},

	PingRefreshInterval = 2,
	LatencyProfiles = {
		{ name = "Good", maxPing = 0.12, speedTolerance = 1.25, extraSlack = 0, extraAirTime = 0 },
		{ name = "Normal", maxPing = 0.3, speedTolerance = 1.4, extraSlack = 10, extraAirTime = 0.5 },
		{ name = "HighLatency", maxPing = math.huge, speedTolerance = 1.7, extraSlack = 25, extraAirTime = 1.5 },
	} :: { LatencyProfile },
}

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

Config.Remotes = {
	-- Remotes bound with Api.bindRemote live in ReplicatedStorage.<FolderName>.
	FolderName = "Remotes",
	-- Denied requests per second (per remote) before it counts as flooding.
	-- Well above what anyone can click, so auto-clickers aren't flagged.
	FloodThreshold = 30,
	FloodFlagInterval = 5,
	DefaultMaxStringLength = 64,
	DefaultMaxArrayLength = 100,
	-- Studio / DEBUG: warn about remotes that bypass the gateway.
	AuditOnStart = true,
	AuditDelay = 5,
}

--------------------------------------------------------------------------------
-- Economy
--------------------------------------------------------------------------------

export type ReasonRule = {
	sign: "+" | "-" | "any",
	currencies: { string }?,
}

Config.Economy = {
	Currencies = { "Cash", "Gems", "DreamEssence" },
	-- Balances above this, or any NaN / infinite value, are refused.
	MaxBalance = 1e30,
	-- Every balance change needs one of these reasons. A reason that should
	-- only add (or only remove) currency is refused if it goes the other way.
	Reasons = {
		CharacterIncome = { sign = "+" },
		CashCollect = { sign = "+" },
		Sell = { sign = "+" },
		IndexReward = { sign = "+" },
		DailyReward = { sign = "+" },
		AfkReward = { sign = "+" },
		CodeReward = { sign = "+" },
		RebirthReward = { sign = "+" },
		CosmeticReward = { sign = "+", currencies = { "DreamEssence" } },
		DevProduct = { sign = "+" },
		DicePurchase = { sign = "-" },
		UpgradePurchase = { sign = "-" },
		SkillPurchase = { sign = "-" },
		CosmeticPurchase = { sign = "-" },
		RidePurchase = { sign = "-" },
		RebirthCost = { sign = "-" },
		AdminAdjust = { sign = "any" },
	} :: { [string]: ReasonRule },
	LedgerSize = 50, -- recent transactions kept per player

	-- World shops are parts or models tagged ShopTag with a ShopId attribute
	-- (and optionally Radius / Active attributes).
	ShopTag = "Shop",
	DefaultShopRadius = 20,
	ShopSlack = 6, -- studs, plus ping x walk speed
}

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

Config.Logging = {
	EvidencePerPlayer = 50, -- ring buffer of recent evidence
	ThrottleSeconds = 5, -- same player + detection prints at most this often
	-- On a kick, save a short evidence summary to this DataStore for
	-- moderators (pcall-guarded; skipped when DataStores are unavailable).
	PersistKickReports = true,
	ReportStoreName = "AntiCheatReports_v1",
	ReportsPerUser = 10,
}

--------------------------------------------------------------------------------
-- Testing
--------------------------------------------------------------------------------

Config.Testing = {
	-- In TEST_MODE, contract remotes nobody has bound yet get a stand-in
	-- handler that only prints "accepted", so the Studio tester has
	-- something to hit. A real Api.bindRemote replaces it.
	DemoHandlers = Config.TEST_MODE,
}

return Config
