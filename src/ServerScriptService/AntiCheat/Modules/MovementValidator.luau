--!strict
--[[
	MovementValidator (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > MovementValidator

	Server-side movement checks. Nothing is asked of the client: every check
	reads the character as the server sees it. One central loop (step) samples
	each character every SampleInterval seconds, staggered across players.

	Per sample, in order:

	  1. Impossible physics   NaN / infinite / absurd position or velocity.
	                          Always corrected straight away.
	  2. Skips                dead, anchored (server-held), exempt, restricted,
	                          spawn / teleport / setback grace, bypassed staff.
	  3. Teleport             one sample to the next moved further than the
	                          allowed speed could cover. The allowance counts
	                          the time the server saw no movement, so a laggy
	                          client catching up in one burst isn't flagged.
	  4. Speed                net horizontal distance over a rolling window
	                          (SpeedWindow), over the limit for at least
	                          SpeedSustainSeconds. A single spike never counts.
	  5. Fly                  airborne with nothing under or beside the
	                          character, and either not falling for FlyWindow
	                          or risen higher than any legal jump.
	  6. Noclip               the path since the last sample crossed a solid,
	                          anchored wall. Evidence only.

	The allowed speed comes from the server: max(Humanoid.WalkSpeed as the
	SERVER sees it, BaseWalkSpeed) x movement modifiers (rides, buffs), plus
	the speed of a moving platform the character stands on. Clients can't
	change any of these. Tolerances widen with the player's ping (latency
	profiles in Config).

	Detections are reported with a severity; the tracker and Enforcement decide
	what happens. A detection made while another character is touching this
	one (collisions, flings by someone else) is recorded with no points.

	Server moves are never flagged. Api.teleport / Api.exempt are the proper
	way, but as a safety net any SERVER script that sets the root's CFrame
	(PivotTo, CFrame =) is noticed through GetPropertyChangedSignal("CFrame"),
	which replicated client physics doesn't fire, and gets the same grace. If
	that signal ever fires at physics rates (AutoExemptMaxEventsPerSecond),
	the safety net switches itself off for the server and warns, so it can
	never become a blind spot.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type LatencyProfile = {
	name: string,
	maxPing: number,
	speedTolerance: number,
	extraSlack: number,
	extraAirTime: number,
}

type MovementProfile = {
	speedMultiplier: number,
	maxSpeed: number,
	allowFlight: boolean,
	allowNoclip: boolean,
}

export type Report = {
	kind: string,
	severity: number,
	position: Vector3?,
	velocity: Vector3?,
	expectedSpeed: number?,
	actualSpeed: number?,
	humanoidState: string?,
	ping: number?,
	details: string?,
}

-- Everything the validator asks of the world, so tests can stand in for it.
export type World = {
	-- Is something solid under or right beside the character? Also returns
	-- the velocity of what it stands on (conveyors, moving platforms).
	isSupported: (root: BasePart, character: Model, humanoid: Humanoid) -> (boolean, Vector3?),
	-- Studs of solid, anchored wall between two points, or nil.
	wallPenetration: (from: Vector3, to: Vector3, root: BasePart) -> number?,
	otherCharacterNear: (player: Player, position: Vector3, radius: number) -> boolean,
	gravity: () -> number,
}

export type Dependencies = {
	config: any, -- Config.Movement
	world: World,
	clock: () -> number,
	isExempt: (player: Player) -> boolean,
	getProfile: (player: Player) -> MovementProfile,
	isBypassed: (player: Player) -> boolean,
	report: (player: Player, report: Report) -> (),
}

export type MovementValidator = {
	addCharacter: (player: Player, character: Model, humanoid: Humanoid, root: BasePart) -> (),
	removePlayer: (player: Player) -> (),
	step: (now: number) -> (),
	resetBaseline: (player: Player, graceSeconds: number?) -> (),
	setback: (player: Player, reason: string) -> boolean,
	restrict: (player: Player, seconds: number) -> boolean,
	teleport: (player: Player, target: CFrame, reason: string) -> boolean,
	getPing: (player: Player) -> number,
	getRootPosition: (player: Player) -> Vector3?,
	getWalkSpeed: (player: Player) -> number,
}

type State = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	nextSample: number,

	-- Ring buffer of recent samples.
	times: { number },
	positions: { Vector3 },
	head: number,
	count: number,

	lastPos: Vector3,
	lastTime: number,
	lastMovedTime: number,
	graceUntil: number,
	contactUntil: number,

	airborneSince: number?,
	groundY: number,
	overSince: number?,
	lastSpeedFlag: number,
	lastFlyFlag: number,
	platformSpeed: number,
	platformTime: number,
	noclipHits: { number },

	trustedCFrame: CFrame?,
	trustedTime: number,
	setbackTimes: { number },
	lastSetback: number,
	lastLoopFlag: number,
	lastPhysicsFlag: number,
	lastPhysicsFix: number,
	restrictedUntil: number,
	restrictToken: number,
	selfMoving: boolean,
	serverMovedAt: number,
	cframeEvents: number,
	cframeWindow: number,
	cframeConnection: RBXScriptConnection?,

	ping: number,
	latency: LatencyProfile,
	lastPingCheck: number,
	lastError: number,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function isFiniteVector(vector: Vector3): boolean
	return math.isfinite(vector.X) and math.isfinite(vector.Y) and math.isfinite(vector.Z)
end

local function horizontalDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function stateName(humanoid: Humanoid): string?
	local ok, state = pcall(function()
		return humanoid:GetState().Name
	end)
	return if ok then state else nil
end

-- The launch speed of this humanoid's jump, from the SERVER's jump settings.
local function jumpVelocityOf(humanoid: Humanoid, gravity: number): number
	local velocity
	if humanoid.UseJumpPower then
		velocity = humanoid.JumpPower
	else
		velocity = math.sqrt(2 * gravity * math.max(humanoid.JumpHeight, 0))
	end
	return if math.isfinite(velocity) and velocity >= 0 then velocity else 50
end

--------------------------------------------------------------------------------
-- The real world (Workspace queries)
--------------------------------------------------------------------------------

local MovementValidator = {}

function MovementValidator.robloxWorld(config: any): World
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.IgnoreWater = false -- standing on water counts as supported
	groundParams.RespectCanCollide = true

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.RespectCanCollide = true
	overlapParams.MaxParts = 1

	local wallParams = RaycastParams.new()
	wallParams.FilterType = Enum.RaycastFilterType.Exclude
	wallParams.IgnoreWater = true
	wallParams.RespectCanCollide = true

	local exitParams = RaycastParams.new()
	exitParams.FilterType = Enum.RaycastFilterType.Include

	local function isInWater(position: Vector3, below: number): boolean
		local region = Region3.new(position - Vector3.new(2, below, 2), position + Vector3.new(2, 2, 2)):ExpandToGrid(4)
		local ok, materials = pcall(function()
			return (Workspace.Terrain:ReadVoxels(region, 4))
		end)
		if not ok or type(materials) ~= "table" then
			return false
		end
		-- Index numerically: the arrays also carry a Size field.
		local voxels = materials :: { { { Enum.Material } } }
		for x = 1, #voxels do
			local plane = voxels[x]
			for y = 1, #plane do
				local row = plane[y]
				for z = 1, #row do
					if row[z] == Enum.Material.Water then
						return true
					end
				end
			end
		end
		return false
	end

	local function isSupported(root: BasePart, character: Model, humanoid: Humanoid): (boolean, Vector3?)
		local position = root.Position
		-- R6 rigs report HipHeight 0 but stand on 2-stud legs.
		local reach = math.max(humanoid.HipHeight, 2) + root.Size.Y / 2 + config.GroundProbeDepth

		groundParams.FilterDescendantsInstances = { character }
		groundParams.CollisionGroup = root.CollisionGroup
		local hit = Workspace:Raycast(position, Vector3.new(0, -reach, 0), groundParams)
		if hit then
			local part = hit.Instance
			return true, if part:IsA("BasePart") then part.AssemblyLinearVelocity else nil
		end

		-- Ledges, ladders, walls and ceilings: anything collidable touching a
		-- box a little bigger than the character.
		overlapParams.FilterDescendantsInstances = { character }
		overlapParams.CollisionGroup = root.CollisionGroup
		local top = position.Y + 3
		local bottom = position.Y - reach
		local center = Vector3.new(position.X, (top + bottom) / 2, position.Z)
		local touching = Workspace:GetPartBoundsInBox(CFrame.new(center), Vector3.new(5, top - bottom, 5), overlapParams)
		if #touching > 0 then
			return true, nil
		end

		return isInWater(position, reach), nil
	end

	-- Every character, refreshed at most once a second: walking through
	-- another player isn't noclip.
	local characters: { Instance } = {}
	local charactersAt = -math.huge
	local function allCharacters(): { Instance }
		local t = os.clock()
		if t - charactersAt >= 1 then
			charactersAt = t
			characters = {}
			for _, player in Players:GetPlayers() do
				if player.Character then
					table.insert(characters, player.Character)
				end
			end
		end
		return characters
	end

	local function wallPenetration(from: Vector3, to: Vector3, root: BasePart): number?
		wallParams.FilterDescendantsInstances = allCharacters()
		wallParams.CollisionGroup = root.CollisionGroup

		local direction = to - from
		local hit = Workspace:Raycast(from, direction, wallParams)
		local wall = if hit then hit.Instance else nil
		if not hit or not wall or not wall:IsA("BasePart") or not wall.Anchored then
			return nil
		end
		-- The same crossing at head height too, so ducking under a beam or
		-- stepping over a kerb isn't a wall.
		local up = Vector3.new(0, 1.5, 0)
		local headHit = Workspace:Raycast(from + up, direction, wallParams)
		local headWall = if headHit then headHit.Instance else nil
		if not headWall or not headWall:IsA("BasePart") or not headWall.Anchored then
			return nil
		end

		-- How much solid was crossed: cast back from the end against only this
		-- wall. No hit means the end point is inside it.
		exitParams.FilterDescendantsInstances = { wall }
		local back = Workspace:Raycast(to, -direction, exitParams)
		local exitPoint = if back then back.Position else to
		return (exitPoint - hit.Position).Magnitude
	end

	local function otherCharacterNear(player: Player, position: Vector3, radius: number): boolean
		for _, other in Players:GetPlayers() do
			local character = other.Character
			if other ~= player and character then
				local root = character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= radius then
					return true
				end
			end
		end
		return false
	end

	return {
		isSupported = isSupported,
		wallPenetration = wallPenetration,
		otherCharacterNear = otherCharacterNear,
		gravity = function()
			return Workspace.Gravity
		end,
	}
end

--------------------------------------------------------------------------------
-- Validator
--------------------------------------------------------------------------------

function MovementValidator.new(deps: Dependencies): MovementValidator
	local config = deps.config
	local world = deps.world
	local clock = deps.clock
	local report = deps.report

	local capacity = math.ceil(math.max(config.SpeedWindow, config.FlyWindow) / config.SampleInterval) + 4
	local states: { [Player]: State } = {}
	local autoExemptEnabled = config.AutoExemptServerMoves == true

	local function latencyFor(ping: number): LatencyProfile
		for _, profile in config.LatencyProfiles do
			if ping <= profile.maxPing then
				return profile
			end
		end
		return config.LatencyProfiles[#config.LatencyProfiles]
	end

	local function refreshPing(s: State, t: number)
		if t - s.lastPingCheck < config.PingRefreshInterval then
			return
		end
		s.lastPingCheck = t
		local ok, ping = pcall(function()
			return s.player:GetNetworkPing()
		end)
		if ok and type(ping) == "number" and math.isfinite(ping) then
			s.ping = math.clamp(ping, 0, 5)
			s.latency = latencyFor(s.ping)
		end
	end

	local function pushSample(s: State, t: number, position: Vector3)
		s.head = s.head % capacity + 1
		s.times[s.head] = t
		s.positions[s.head] = position
		s.count = math.min(s.count + 1, capacity)
	end

	-- The oldest kept sample no older than `age` seconds (nil if none is old
	-- enough to be useful). Walks at most `capacity` entries.
	local function sampleAtAge(s: State, t: number, age: number): (number?, Vector3?)
		local foundTime: number?, foundPosition: Vector3? = nil, nil
		local index = s.head
		for _ = 1, s.count do
			local sampleTime = s.times[index]
			if t - sampleTime > age then
				break
			end
			foundTime, foundPosition = sampleTime, s.positions[index]
			index = (index - 2) % capacity + 1
		end
		return foundTime, foundPosition
	end

	-- Start measuring again from where the character is now.
	local function rebaseline(s: State, t: number, position: Vector3)
		s.count = 0
		s.head = 0
		pushSample(s, t, position)
		s.lastPos = position
		s.lastTime = t
		s.lastMovedTime = t
		s.overSince = nil
		s.airborneSince = nil
		s.groundY = position.Y
		table.clear(s.noclipHits)
	end

	local function baseReport(s: State, kind: string, severity: number, details: string): Report
		return {
			kind = kind,
			severity = severity,
			position = s.root.Position,
			velocity = s.root.AssemblyLinearVelocity,
			humanoidState = stateName(s.humanoid),
			ping = s.ping,
			details = details,
		}
	end

	-- Contact with another character: collisions and flings move players in
	-- ways no WalkSpeed explains, so detections then carry no points.
	local function inContact(s: State, t: number, position: Vector3): boolean
		if t < s.contactUntil then
			return true
		end
		if world.otherCharacterNear(s.player, position, config.ContactRadius) then
			s.contactUntil = t + config.ContactGrace
			return true
		end
		return false
	end

	-- Reports a detection. Returns true if Enforcement corrected or froze the
	-- character in response, in which case the rest of the sample is stale.
	local function flag(s: State, t: number, entry: Report): boolean
		if inContact(s, t, s.lastPos) then
			entry.severity = 0
			entry.details = (entry.details or "") .. "; near another character, no points"
		end
		report(s.player, entry)
		return s.lastSetback == t or t < s.restrictedUntil
	end

	local function isSeated(s: State): boolean
		return s.humanoid.SeatPart ~= nil
	end

	-- The anti-cheat's own moves, which the CFrame safety net must ignore.
	local function moveTo(s: State, target: CFrame)
		s.selfMoving = true
		local ok, err = pcall(function()
			s.character:PivotTo(target)
		end)
		s.selfMoving = false
		s.root.AssemblyLinearVelocity = Vector3.zero
		s.root.AssemblyAngularVelocity = Vector3.zero
		if not ok then
			warn(`[AntiCheat] couldn't move {s.player.Name}: {err}`)
		end
	end

	local function trustedTarget(s: State, t: number): CFrame?
		local target = s.trustedCFrame
		if not target or t - s.trustedTime > config.Setback.TrustedMaxAge then
			return nil
		end
		local position = target.Position
		if not isFiniteVector(position) or position.Magnitude > config.MaxCoordinate then
			return nil
		end
		return target
	end

	-- Shared guard for every correction: rate-limited, and repeated
	-- corrections become evidence instead of an endless loop.
	local function correctionAllowed(s: State, t: number): boolean
		local setbackConfig = config.Setback
		if t - s.lastSetback < setbackConfig.MinInterval then
			return false
		end
		local times = s.setbackTimes
		while #times > 0 and t - times[1] > setbackConfig.Window do
			table.remove(times, 1)
		end
		if #times >= setbackConfig.MaxPerWindow then
			if t - s.lastLoopFlag >= setbackConfig.Window then
				s.lastLoopFlag = t
				report(
					s.player,
					baseReport(s, "SetbackLoop", 1, `{#times} corrections in {setbackConfig.Window}s; not correcting again`)
				)
			end
			return false
		end
		return true
	end

	local function applyCorrection(s: State, t: number, target: CFrame)
		moveTo(s, target)
		table.insert(s.setbackTimes, t)
		s.lastSetback = t
		rebaseline(s, t, target.Position)
		s.graceUntil = t + config.SetbackGrace + s.ping
	end

	local function physicsProblem(position: Vector3, velocity: Vector3, angular: Vector3): string?
		if not isFiniteVector(position) then
			return "position is NaN/infinite"
		elseif math.max(math.abs(position.X), math.abs(position.Y), math.abs(position.Z)) > config.MaxCoordinate then
			return "position outside the world"
		elseif not isFiniteVector(velocity) or velocity.Magnitude > config.MaxLinearVelocity then
			return "linear velocity impossible"
		elseif not isFiniteVector(angular) or angular.Magnitude > config.MaxAngularVelocity then
			return "angular velocity impossible (fling)"
		end
		return nil
	end

	local function sample(s: State, t: number)
		local player, root, humanoid, character = s.player, s.root, s.humanoid, s.character
		if root.Parent ~= character or character.Parent == nil or humanoid.Health <= 0 then
			return
		end
		if deps.isBypassed(player) then
			rebaseline(s, t, root.Position)
			return
		end
		refreshPing(s, t)

		-- 1. Impossible physics -------------------------------------------------
		local cframe = root.CFrame
		local position = cframe.Position
		local velocity = root.AssemblyLinearVelocity
		local problem = physicsProblem(position, velocity, root.AssemblyAngularVelocity)
		if problem then
			-- One report per interval: a broken state can last several samples
			-- until the client receives the fix, and that is still one incident.
			if t - s.lastPhysicsFlag >= config.PhysicsFlagInterval then
				s.lastPhysicsFlag = t
				local entry = baseReport(s, "ImpossiblePhysics", 1, problem)
				entry.position = if isFiniteVector(position) then position else nil
				entry.velocity = if isFiniteVector(velocity) then velocity else nil
				report(player, entry)
			end
			-- Corrupt state is always undone, whatever the score.
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			local target = trustedTarget(s, t)
			if target and t - s.lastPhysicsFix >= 0.5 then
				s.lastPhysicsFix = t
				moveTo(s, target)
				rebaseline(s, t, target.Position)
				s.graceUntil = t + config.SetbackGrace + s.ping
			else
				s.count = 0
			end
			return
		end

		-- 2. Skips ------------------------------------------------------------
		local serverMoved = t - s.serverMovedAt <= config.TeleportGrace + s.ping
		if t < s.restrictedUntil or t < s.graceUntil or serverMoved or root.Anchored or deps.isExempt(player) then
			rebaseline(s, t, position)
			return
		end
		if s.count == 0 or t - s.lastTime > config.MaxSampleGap then
			rebaseline(s, t, position)
			return
		end

		local profile = deps.getProfile(player)
		local latency = s.latency
		local seated = isSeated(s)
		local gravity = world.gravity()
		local jumpVelocity = jumpVelocityOf(humanoid, gravity)

		local walkSpeed = humanoid.WalkSpeed
		if not math.isfinite(walkSpeed) then
			walkSpeed = config.BaseWalkSpeed
		end
		local allowed = math.max(math.max(walkSpeed, config.BaseWalkSpeed) * profile.speedMultiplier, profile.maxSpeed)
		if seated then
			allowed = math.max(allowed, config.SeatedMaxSpeed)
		end

		local supported, platformVelocity = world.isSupported(root, character, humanoid)
		if platformVelocity then
			local platformSpeed = math.sqrt(platformVelocity.X ^ 2 + platformVelocity.Z ^ 2)
			if math.isfinite(platformSpeed) and platformSpeed > 1 then
				s.platformSpeed = math.min(platformSpeed, config.SeatedMaxSpeed)
				s.platformTime = t
			end
		end
		if t - s.platformTime <= config.SpeedWindow + 1 then
			allowed += s.platformSpeed
		end

		local delta = position - s.lastPos
		local horizontal = horizontalDistance(position, s.lastPos)
		local dt = t - s.lastTime
		local moved = delta.Magnitude > 0.05
		local flagged = false

		-- Clearly faster than walking: note whether someone is (or just was)
		-- touching us, because by the time the window-based checks fire they
		-- may have parted.
		if horizontal > allowed * dt * 1.25 + 1 or delta.Y > jumpVelocity * dt + 1 then
			local _ = inContact(s, t, s.lastPos) or inContact(s, t, position)
		end

		-- 3. Teleport ---------------------------------------------------------
		local credit = if moved then math.clamp(t - s.lastMovedTime, dt, config.StallCreditMax) else dt
		local allowedStep = allowed * latency.speedTolerance * credit + config.TeleportSlack + latency.extraSlack
		local allowedRise = (jumpVelocity + allowed) * credit + config.UpwardSlack + latency.extraSlack
		local teleportDetail: string? = nil
		if horizontal > allowedStep then
			teleportDetail = string.format("moved %.1f studs in %.2fs (allowed %.1f)", horizontal, credit, allowedStep)
		elseif delta.Y > allowedRise and not seated and not profile.allowFlight then
			teleportDetail = string.format("rose %.1f studs in %.2fs (allowed %.1f)", delta.Y, credit, allowedRise)
		end
		if teleportDetail then
			local ratio = math.max(horizontal / allowedStep, delta.Y / allowedRise)
			local entry = baseReport(s, "Teleport", if ratio > 3 then 2 else 1, teleportDetail)
			entry.expectedSpeed = allowed
			entry.actualSpeed = delta.Magnitude / math.max(dt, 1e-3)
			if not flag(s, t, entry) then
				-- Measure from the new spot so one jump isn't counted twice.
				rebaseline(s, t, position)
			end
			return
		end

		pushSample(s, t, position)
		if moved then
			s.lastMovedTime = t
		end

		-- 4. Speed ------------------------------------------------------------
		if not seated then
			local limit = allowed * latency.speedTolerance + config.SpeedFlatTolerance
			local oldTime, oldPosition = sampleAtAge(s, t, config.SpeedWindow)
			if oldTime and oldPosition and t - oldTime >= config.SpeedWindowMin then
				local speed = horizontalDistance(position, oldPosition) / (t - oldTime)
				if speed > limit then
					s.overSince = s.overSince or t
					local overFor = t - (s.overSince :: number)
					if overFor >= config.SpeedSustainSeconds and t - s.lastSpeedFlag >= config.SpeedFlagInterval then
						s.lastSpeedFlag = t
						flagged = true
						local ratio = speed / limit
						local severity = if ratio > 3 then 3 elseif ratio > 1.75 then 2 else 1
						local entry = baseReport(
							s,
							"Speed",
							severity,
							string.format("%.1fs window, over for %.1fs, %s latency", t - oldTime, overFor, latency.name)
						)
						entry.expectedSpeed = limit
						entry.actualSpeed = speed
						if flag(s, t, entry) then
							return
						end
					end
				else
					s.overSince = nil
				end
			end
		else
			s.overSince = nil
		end

		-- 5. Fly --------------------------------------------------------------
		if supported or seated or profile.allowFlight then
			s.airborneSince = nil
			s.groundY = position.Y
		else
			s.airborneSince = s.airborneSince or t
			local airTime = t - (s.airborneSince :: number)
			local jumpTime = if gravity > 0 then 2 * jumpVelocity / gravity else math.huge
			local legalAirTime = math.max(config.AirborneGrace, jumpTime + 0.5) + latency.extraAirTime
			local jumpHeight = if gravity > 0 then jumpVelocity ^ 2 / (2 * gravity) else math.huge
			local maxRise = jumpHeight + config.AscentSlack + latency.extraSlack
			local rise = position.Y - s.groundY

			local flyDetail: string? = nil
			local severity = 1
			if rise > maxRise then
				flyDetail = string.format("%.1f studs above the last ground (max jump %.1f)", rise, jumpHeight)
				severity = if rise > maxRise * 3 then 2 else 1
			elseif airTime >= legalAirTime then
				local pastTime, pastPosition = sampleAtAge(s, t, config.FlyWindow)
				if pastTime and pastPosition and pastTime >= (s.airborneSince :: number) then
					local descent = pastPosition.Y - position.Y
					if descent < config.HoverMaxDescent then
						flyDetail = string.format("airborne %.1fs, fell only %.1f studs in %.1fs", airTime, descent, t - pastTime)
					end
				end
			end
			if flyDetail and t - s.lastFlyFlag >= config.FlyFlagInterval then
				s.lastFlyFlag = t
				flagged = true
				if flag(s, t, baseReport(s, "Fly", severity, flyDetail)) then
					return
				end
			end
		end

		-- 6. Noclip -----------------------------------------------------------
		local noclip = config.Noclip
		if noclip.Enabled and not seated and not profile.allowNoclip and horizontal >= noclip.MinSegment then
			local penetration = world.wallPenetration(s.lastPos, position, root)
			if penetration and penetration >= noclip.MinPenetration then
				local hits = s.noclipHits
				table.insert(hits, t)
				while #hits > 0 and t - hits[1] > noclip.HitWindow do
					table.remove(hits, 1)
				end
				if #hits >= noclip.HitsToFlag then
					table.clear(hits)
					flagged = true
					local entry = baseReport(s, "Noclip", 1, string.format("crossed %.1f studs of solid wall", penetration))
					if flag(s, t, entry) then
						return
					end
				end
			end
		end

		-- A clean, grounded sample is a safe place to set the player back to.
		if supported and not flagged and not s.overSince and not seated and t >= s.contactUntil then
			s.trustedCFrame = cframe
			s.trustedTime = t
		end

		s.lastPos = position
		s.lastTime = t
	end

	--------------------------------------------------------------------------
	-- Public
	--------------------------------------------------------------------------

	local function addCharacter(player: Player, character: Model, humanoid: Humanoid, root: BasePart)
		local t = clock()
		local old = states[player]
		local s: State = {
			player = player,
			character = character,
			humanoid = humanoid,
			root = root,
			nextSample = t + math.random() * config.SampleInterval, -- stagger players
			times = {},
			positions = {},
			head = 0,
			count = 0,
			lastPos = root.Position,
			lastTime = t,
			lastMovedTime = t,
			graceUntil = t + config.SpawnGrace,
			contactUntil = 0,
			airborneSince = nil,
			groundY = root.Position.Y,
			overSince = nil,
			lastSpeedFlag = -math.huge,
			lastFlyFlag = -math.huge,
			platformSpeed = 0,
			platformTime = -math.huge,
			noclipHits = {},
			trustedCFrame = nil,
			trustedTime = -math.huge,
			-- Corrections are limited per player, not per life.
			setbackTimes = if old then old.setbackTimes else {},
			lastSetback = if old then old.lastSetback else -math.huge,
			lastLoopFlag = if old then old.lastLoopFlag else -math.huge,
			lastPhysicsFlag = if old then old.lastPhysicsFlag else -math.huge,
			lastPhysicsFix = -math.huge,
			restrictedUntil = 0,
			restrictToken = if old then old.restrictToken + 1 else 0,
			ping = if old then old.ping else 0,
			latency = if old then old.latency else config.LatencyProfiles[2],
			lastPingCheck = -math.huge,
			lastError = -math.huge,
			selfMoving = false,
			serverMovedAt = -math.huge,
			cframeEvents = 0,
			cframeWindow = t,
			cframeConnection = nil,
		}
		if old and old.cframeConnection then
			old.cframeConnection:Disconnect()
		end
		states[player] = s

		if autoExemptEnabled then
			s.cframeConnection = root:GetPropertyChangedSignal("CFrame"):Connect(function()
				if s.selfMoving or not autoExemptEnabled then
					return
				end
				local now = clock()
				if now - s.cframeWindow >= 1 then
					s.cframeWindow = now
					s.cframeEvents = 0
				end
				s.cframeEvents += 1
				if s.cframeEvents > config.AutoExemptMaxEventsPerSecond then
					-- Firing like physics replication: not trustworthy here.
					autoExemptEnabled = false
					for _, other in states do
						if other.cframeConnection then
							other.cframeConnection:Disconnect()
							other.cframeConnection = nil
						end
						other.serverMovedAt = -math.huge
					end
					warn(
						"[AntiCheat] the root CFrame signal fires too often to mean \"moved by a server script\"; "
							.. "automatic server-move exemptions are off. Use AntiCheat.teleport / AntiCheat.exempt."
					)
					return
				end
				s.serverMovedAt = now
			end)
		end
	end

	local function removePlayer(player: Player)
		local s = states[player]
		if s and s.cframeConnection then
			s.cframeConnection:Disconnect()
		end
		states[player] = nil
	end

	local function step(now: number)
		for _, s in states do
			if now >= s.nextSample then
				-- Keep each player's stagger; skip ahead after a long hitch.
				s.nextSample = math.max(s.nextSample + config.SampleInterval, now)
				local ok, err = pcall(function()
					sample(s, now)
				end)
				if not ok and now - s.lastError > 30 then
					s.lastError = now
					warn(`[AntiCheat] movement sample failed for {s.player.Name}: {err}`)
				end
			end
		end
	end

	local function resetBaseline(player: Player, graceSeconds: number?)
		local s = states[player]
		if s then
			local t = clock()
			rebaseline(s, t, s.root.Position)
			if graceSeconds then
				s.graceUntil = math.max(s.graceUntil, t + graceSeconds)
			end
		end
	end

	local function setback(player: Player, _reason: string): boolean
		local s = states[player]
		if not s or not s.root.Parent or s.humanoid.Health <= 0 then
			return false
		end
		local t = clock()
		-- Never fight a legitimate movement state.
		if deps.isExempt(player) or isSeated(s) or deps.getProfile(player).allowFlight or t < s.graceUntil then
			return false
		end
		local target = trustedTarget(s, t)
		if not target or not correctionAllowed(s, t) then
			return false
		end
		applyCorrection(s, t, target)
		return true
	end

	-- Takes physics ownership of the character on the server for `seconds`,
	-- which stops a client from moving it at all, then hands it back.
	local function restrict(player: Player, seconds: number): boolean
		local s = states[player]
		if not s or not s.root.Parent then
			return false
		end
		local root = s.root
		local canSet = false
		pcall(function()
			canSet = (root:CanSetNetworkOwnership())
		end)
		if not canSet then
			return false
		end
		if not pcall(function()
			root:SetNetworkOwner(nil)
		end) then
			return false
		end
		local t = clock()
		s.restrictedUntil = t + seconds
		s.restrictToken += 1
		local token = s.restrictToken
		task.delay(seconds, function()
			if states[player] == s and s.restrictToken == token and root.Parent then
				pcall(function()
					root:SetNetworkOwner(player)
				end)
				s.restrictedUntil = 0
				local now = clock()
				rebaseline(s, now, root.Position)
				s.graceUntil = now + config.SetbackGrace + s.ping
			end
		end)
		return true
	end

	-- A server-authorised move: exempted, performed and re-baselined in one go.
	local function teleport(player: Player, target: CFrame, reason: string): boolean
		local s = states[player]
		if typeof(target) ~= "CFrame" then
			return false
		end
		local position = target.Position
		if not isFiniteVector(position) or position.Magnitude > config.MaxCoordinate then
			warn(`[AntiCheat] refused teleport "{reason}" to an invalid position`)
			return false
		end
		if not s then
			local character = player.Character
			if character then
				character:PivotTo(target)
				return true
			end
			return false
		end
		local t = clock()
		moveTo(s, target)
		rebaseline(s, t, position)
		s.graceUntil = math.max(s.graceUntil, t + config.TeleportGrace + s.ping)
		s.trustedCFrame = target
		s.trustedTime = t
		return true
	end

	local function getPing(player: Player): number
		local s = states[player]
		return if s then s.ping else 0
	end

	local function getRootPosition(player: Player): Vector3?
		local s = states[player]
		if s and s.root.Parent and s.humanoid.Health > 0 then
			local position = s.root.Position
			return if isFiniteVector(position) then position else nil
		end
		return nil
	end

	local function getWalkSpeed(player: Player): number
		local s = states[player]
		local speed = if s then s.humanoid.WalkSpeed else config.BaseWalkSpeed
		return if math.isfinite(speed) then math.max(speed, config.BaseWalkSpeed) else config.BaseWalkSpeed
	end

	return {
		addCharacter = addCharacter,
		removePlayer = removePlayer,
		step = step,
		resetBaseline = resetBaseline,
		setback = setback,
		restrict = restrict,
		teleport = teleport,
		getPing = getPing,
		getRootPosition = getRootPosition,
		getWalkSpeed = getWalkSpeed,
	}
end

return MovementValidator
