--!strict
--[[
	ExemptionManager (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > ExemptionManager

	What the SERVER says a player is allowed to do right now. The anti-cheat
	checks movement against this, never against what the client claims.

	  Exemptions   "ignore this player's movement for N seconds", granted by
	               the server just before it moves them itself (spawn, rebirth
	               teleport, shop travel, knockback).
	  Modifiers    lasting changes to the movement profile, keyed by source:
	               a hoverboard, a speed potion, a glider. The allowed speed is
	               base WalkSpeed x every speedMultiplier, or the highest
	               maxSpeed, whichever is bigger.
	  Roles        "Player", "Developer" or "Moderator", resolved on the server
	               from Config.Permissions.

	None of this is reachable from the client: there are no remotes here, and
	nothing is stored in replicated attributes.
]]

export type Role = "Player" | "Developer" | "Moderator"

export type Modifier = {
	speedMultiplier: number?,
	maxSpeed: number?, -- studs/s, for rides that don't use WalkSpeed
	allowFlight: boolean?,
	allowNoclip: boolean?,
}

export type MovementProfile = {
	speedMultiplier: number,
	maxSpeed: number,
	allowFlight: boolean,
	allowNoclip: boolean,
	modifierCount: number,
}

export type ExemptionManager = {
	grant: (player: any, reason: string, seconds: number) -> (),
	revoke: (player: any, reason: string) -> (),
	isExempt: (player: any) -> (boolean, string?),
	setModifier: (player: any, key: string, modifier: Modifier, seconds: number?) -> (),
	clearModifier: (player: any, key: string) -> (),
	getProfile: (player: any) -> MovementProfile,
	setRole: (player: any, role: Role) -> (),
	getRole: (player: any) -> Role,
	remove: (player: any) -> (),
}

type ModifierEntry = { modifier: Modifier, expires: number }

type PlayerEntry = {
	exemptions: { [string]: number }, -- reason -> expiry
	modifiers: { [string]: ModifierEntry },
	role: Role,
}

-- What almost every player gets on almost every sample: shared, read-only,
-- so the movement loop doesn't allocate a profile per sample.
local DEFAULT_PROFILE: MovementProfile = table.freeze({
	speedMultiplier = 1,
	maxSpeed = 0,
	allowFlight = false,
	allowNoclip = false,
	modifierCount = 0,
})

local MAX_EXEMPTION_SECONDS = 120
local MAX_SPEED_MULTIPLIER = 20
local MAX_RIDE_SPEED = 1000

local function finiteIn(value: any, min: number, max: number): boolean
	return type(value) == "number" and math.isfinite(value) and value >= min and value <= max
end

local ExemptionManager = {}

function ExemptionManager.new(clock: (() -> number)?): ExemptionManager
	local now = clock or os.clock
	local players: { [any]: PlayerEntry } = {}

	local function entryOf(player: any): PlayerEntry
		local entry = players[player]
		if not entry then
			entry = { exemptions = {}, modifiers = {}, role = "Player" }
			players[player] = entry
		end
		return entry
	end

	local function grant(player: any, reason: string, seconds: number)
		assert(type(reason) == "string", "AntiCheat exemption needs a reason string")
		assert(finiteIn(seconds, 0, MAX_EXEMPTION_SECONDS), "AntiCheat exemption seconds must be 0-120")
		local exemptions = entryOf(player).exemptions
		local expires = now() + seconds
		-- Two systems may exempt the same player; keep the later expiry.
		exemptions[reason] = math.max(exemptions[reason] or 0, expires)
	end

	local function revoke(player: any, reason: string)
		local entry = players[player]
		if entry then
			entry.exemptions[reason] = nil
		end
	end

	local function isExempt(player: any): (boolean, string?)
		local entry = players[player]
		if not entry then
			return false, nil
		end
		local t = now()
		local activeReason: string? = nil
		for reason, expires in entry.exemptions do
			if expires <= t then
				entry.exemptions[reason] = nil
			else
				activeReason = reason
			end
		end
		return activeReason ~= nil, activeReason
	end

	local function setModifier(player: any, key: string, modifier: Modifier, seconds: number?)
		assert(type(key) == "string", "AntiCheat modifier needs a key string")
		local speedMultiplier = modifier.speedMultiplier
		local maxSpeed = modifier.maxSpeed
		assert(
			speedMultiplier == nil or finiteIn(speedMultiplier, 0, MAX_SPEED_MULTIPLIER),
			"speedMultiplier must be a finite number from 0 to 20"
		)
		assert(maxSpeed == nil or finiteIn(maxSpeed, 0, MAX_RIDE_SPEED), "maxSpeed must be a finite number from 0 to 1000")
		assert(seconds == nil or finiteIn(seconds, 0, math.huge), "modifier seconds must be a positive number")
		entryOf(player).modifiers[key] = {
			modifier = table.clone(modifier),
			expires = if seconds then now() + seconds else math.huge,
		}
	end

	local function clearModifier(player: any, key: string)
		local entry = players[player]
		if entry then
			entry.modifiers[key] = nil
		end
	end

	-- Read-only result: don't modify it.
	local function getProfile(player: any): MovementProfile
		local entry = players[player]
		if not entry or next(entry.modifiers) == nil then
			return DEFAULT_PROFILE
		end
		local profile: MovementProfile = table.clone(DEFAULT_PROFILE)
		local t = now()
		for key, modifierEntry in entry.modifiers do
			if modifierEntry.expires <= t then
				entry.modifiers[key] = nil
				continue
			end
			local modifier = modifierEntry.modifier
			profile.modifierCount += 1
			profile.speedMultiplier *= modifier.speedMultiplier or 1
			profile.maxSpeed = math.max(profile.maxSpeed, modifier.maxSpeed or 0)
			profile.allowFlight = profile.allowFlight or modifier.allowFlight == true
			profile.allowNoclip = profile.allowNoclip or modifier.allowNoclip == true
		end
		-- A slowing modifier (multiplier < 1) must not make the check stricter
		-- than normal walking: the player may still be decelerating.
		profile.speedMultiplier = math.max(profile.speedMultiplier, 1)
		return profile
	end

	local function setRole(player: any, role: Role)
		entryOf(player).role = role
	end

	local function getRole(player: any): Role
		local entry = players[player]
		return if entry then entry.role else "Player"
	end

	local function remove(player: any)
		players[player] = nil
	end

	return {
		grant = grant,
		revoke = revoke,
		isExempt = isExempt,
		setModifier = setModifier,
		clearModifier = clearModifier,
		getProfile = getProfile,
		setRole = setRole,
		getRole = getRole,
		remove = remove,
	}
end

return ExemptionManager
