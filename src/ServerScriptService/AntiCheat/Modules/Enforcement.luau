--!strict
--[[
	Enforcement (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > Enforcement

	Turns a player's violation level into an action. Detectors never act on
	their own; they report here through the tracker.

	  Level 0-1   nothing (silent observation)
	  Level 2     logged
	  Level 3     movement detections: set back to the last trusted position
	  Level 4     movement: set back, then the server takes the character's
	              physics for a few seconds; remote/economy: those remotes are
	              refused for a few seconds. At most once per RestrictCooldown.
	  Level 5     kick, only with KickMinEvents separate violations in the
	              recent window. In TEST_MODE this is logged as "WouldKick".

	A detection that added no points (capped kind, or contact with another
	player) never escalates past logging. Staff with bypass are only logged.

	Bans are never automatic. moderatorBan is the one controlled path: server
	code (an admin panel or command) calls it for a moderator who has read
	the evidence, and it refuses anyone without the Moderator/Developer role.
]]

export type Category = "Movement" | "Remote"

export type Decision = {
	action: string, -- None, Observed, Logged, Setback, Restrict, Kick, WouldKick, Bypass
	level: number,
}

export type EnforcementDeps = {
	config: any, -- the whole Config module
	clock: () -> number,
	isBypassed: (player: Player) -> boolean,
	getRole: (player: Player) -> string,
	setback: (player: Player, reason: string) -> boolean,
	restrictMovement: (player: Player, seconds: number) -> boolean,
	kick: (player: Player, message: string) -> (),
	ban: (userId: number, seconds: number, displayReason: string, privateReason: string) -> (boolean, string?),
	onKick: (player: Player) -> (),
}

export type Enforcement = {
	decide: (player: Player, kind: string, category: Category, added: number, level: number, events: number) -> Decision,
	isRemoteRestricted: (player: Player) -> boolean,
	moderatorBan: (moderator: Player, userId: number, seconds: number, reason: string) -> (boolean, string?),
	removePlayer: (player: Player) -> (),
}

local Enforcement = {}

function Enforcement.new(deps: EnforcementDeps): Enforcement
	local config = deps.config
	local rules = config.Enforcement
	local remoteRestrictedUntil: { [Player]: number } = {}
	local restrictCooldownUntil: { [Player]: number } = {}
	local kicked: { [Player]: boolean } = {}

	local function decide(player: Player, kind: string, category: Category, added: number, level: number, events: number): Decision
		if deps.isBypassed(player) then
			return { action = "Bypass", level = level }
		end
		-- Nothing new was added (capped, or caused by someone else): the
		-- level may be high from earlier, but this event alone proves nothing.
		if added <= 0 then
			return { action = if level >= 2 then "Logged" else "Observed", level = level }
		end

		local t = deps.clock()

		if level >= 5 and rules.AllowKick and events >= rules.KickMinEvents and not kicked[player] then
			if config.TEST_MODE then
				-- Fall through so the lower actions still happen while testing.
				if category == "Movement" and rules.AllowSetback then
					deps.setback(player, kind)
				end
				return { action = "WouldKick", level = level }
			end
			kicked[player] = true
			deps.onKick(player)
			deps.kick(player, rules.KickMessage)
			return { action = "Kick", level = level }
		end

		if level >= 4 and rules.AllowRestrict and t >= (restrictCooldownUntil[player] or 0) then
			local restricted, corrected = false, false
			if category == "Movement" then
				-- Undo the gain first, then freeze, so it isn't kept.
				corrected = rules.AllowSetback and deps.setback(player, kind)
				restricted = deps.restrictMovement(player, rules.RestrictSeconds)
			else
				remoteRestrictedUntil[player] = t + rules.RestrictSeconds
				restricted = true
			end
			if restricted then
				restrictCooldownUntil[player] = t + rules.RestrictCooldown
				return { action = if corrected then "Setback+Restrict" else "Restrict", level = level }
			elseif corrected then
				return { action = "Setback", level = level }
			end
		end

		if level >= 3 and rules.AllowSetback and category == "Movement" then
			if deps.setback(player, kind) then
				return { action = "Setback", level = level }
			end
			return { action = "SetbackSkipped", level = level }
		end

		if level >= 2 then
			return { action = "Logged", level = level }
		elseif level >= 1 then
			return { action = "Observed", level = level }
		end
		return { action = "None", level = level }
	end

	local function isRemoteRestricted(player: Player): boolean
		local untilTime = remoteRestrictedUntil[player]
		if untilTime and deps.clock() < untilTime then
			return true
		end
		remoteRestrictedUntil[player] = nil
		return false
	end

	-- `seconds` <= 0 or -1 means permanent (Roblox's BanAsync convention).
	local function moderatorBan(moderator: Player, userId: number, seconds: number, reason: string): (boolean, string?)
		local role = deps.getRole(moderator)
		if role ~= "Moderator" and role ~= "Developer" then
			warn(`[AntiCheat] {moderator.Name} tried to ban {userId} without the Moderator role`)
			return false, "NotAllowed"
		end
		if type(userId) ~= "number" or not math.isfinite(userId) or userId ~= math.floor(userId) or userId <= 0 then
			return false, "InvalidUserId"
		end
		if type(seconds) ~= "number" or not math.isfinite(seconds) then
			return false, "InvalidDuration"
		end
		if type(reason) ~= "string" or #reason == 0 or #reason > 400 then
			return false, "InvalidReason"
		end
		local duration = if seconds <= 0 then -1 else math.floor(seconds)
		local privateReason = `AntiCheat review by {moderator.Name} ({moderator.UserId}): {reason}`
		if config.TEST_MODE then
			warn(`[AntiCheat] TEST_MODE: would ban {userId} for {duration}s. {privateReason}`)
			return true, "TestMode"
		end
		warn(`[AntiCheat] banning {userId} for {duration}s. {privateReason}`)
		return deps.ban(userId, duration, "You have been banned for cheating.", privateReason)
	end

	local function removePlayer(player: Player)
		remoteRestrictedUntil[player] = nil
		restrictCooldownUntil[player] = nil
		kicked[player] = nil
	end

	return {
		decide = decide,
		isRemoteRestricted = isRemoteRestricted,
		moderatorBan = moderatorBan,
		removePlayer = removePlayer,
	}
end

return Enforcement
