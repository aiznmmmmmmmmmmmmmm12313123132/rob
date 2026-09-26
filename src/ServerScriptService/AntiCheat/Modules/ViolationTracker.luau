--!strict
--[[
	ViolationTracker (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > ViolationTracker

	One suspicion score per player. Detectors never kick anyone themselves;
	they add weighted points here and Enforcement acts on the resulting level.

	  - Each detection kind has a weight (Config.Violations.Weights), multiplied
	    by the severity the detector reports (1-3).
	  - Low-confidence kinds have a cap: once the total score has reached it,
	    they're still logged but add nothing.
	  - After DecayDelay seconds of clean play the score falls by
	    DecayPerSecond, so an accidental flag fades out on its own.
	  - Recent events are counted too: a kick needs a high score AND several
	    separate violations, never one big spike.

	Decay is applied lazily when the score is read, so there is no loop.
]]

export type ViolationsConfig = {
	Weights: { [string]: number },
	ScoreCaps: { [string]: number },
	DecayDelay: number,
	DecayPerSecond: number,
	MaxScore: number,
	EventWindow: number,
}

export type Levels = {
	Observe: number,
	Log: number,
	Setback: number,
	Restrict: number,
	Kick: number,
}

export type AddResult = {
	kind: string,
	added: number,
	score: number,
	level: number,
	events: number,
}

export type ViolationTracker = {
	add: (player: any, kind: string, severity: number?) -> AddResult,
	getScore: (player: any) -> number,
	getLevel: (score: number) -> number,
	getEvents: (player: any) -> number,
	remove: (player: any) -> (),
}

type Entry = {
	score: number,
	updated: number,
	lastViolation: number,
	events: { number },
}

local MAX_EVENTS_KEPT = 200

local ViolationTracker = {}

ViolationTracker.LEVEL_NAMES = { [0] = "Normal", "Observe", "Log", "Setback", "Restrict", "Kick" }

function ViolationTracker.new(config: ViolationsConfig, levels: Levels, clock: (() -> number)?): ViolationTracker
	local now = clock or os.clock
	local entries: { [any]: Entry } = {}

	local function applyDecay(entry: Entry, t: number)
		if t - entry.lastViolation > config.DecayDelay then
			local decayStart = math.max(entry.updated, entry.lastViolation + config.DecayDelay)
			entry.score = math.max(0, entry.score - (t - decayStart) * config.DecayPerSecond)
		end
		entry.updated = t
	end

	local function pruneEvents(entry: Entry, t: number)
		local events = entry.events
		local cutoff = t - config.EventWindow
		local firstKept = 1
		while firstKept <= #events and events[firstKept] < cutoff do
			firstKept += 1
		end
		if firstKept > 1 then
			table.move(events, firstKept, #events, 1)
			for i = #events - firstKept + 2, #events do
				events[i] = nil
			end
		end
	end

	local function getEntry(player: any, t: number): Entry
		local entry = entries[player]
		if not entry then
			entry = { score = 0, updated = t, lastViolation = -math.huge, events = {} }
			entries[player] = entry
		end
		return entry
	end

	local function getLevel(score: number): number
		if score >= levels.Kick then
			return 5
		elseif score >= levels.Restrict then
			return 4
		elseif score >= levels.Setback then
			return 3
		elseif score >= levels.Log then
			return 2
		elseif score >= levels.Observe then
			return 1
		end
		return 0
	end

	local function add(player: any, kind: string, severity: number?): AddResult
		local t = now()
		local entry = getEntry(player, t)
		applyDecay(entry, t)
		pruneEvents(entry, t)

		local weight = (config.Weights[kind] or 1) * math.clamp(severity or 1, 0, 3)
		local cap = config.ScoreCaps[kind]
		local added = weight
		if cap then
			added = math.clamp(cap - entry.score, 0, weight)
		end
		added = math.clamp(added, 0, config.MaxScore - entry.score)

		if added > 0 then
			entry.score += added
			entry.lastViolation = t
			if #entry.events < MAX_EVENTS_KEPT then
				table.insert(entry.events, t)
			end
		end

		return {
			kind = kind,
			added = added,
			score = entry.score,
			level = getLevel(entry.score),
			events = #entry.events,
		}
	end

	local function getScore(player: any): number
		local entry = entries[player]
		if not entry then
			return 0
		end
		applyDecay(entry, now())
		return entry.score
	end

	local function getEvents(player: any): number
		local entry = entries[player]
		if not entry then
			return 0
		end
		pruneEvents(entry, now())
		return #entry.events
	end

	local function remove(player: any)
		entries[player] = nil
	end

	return {
		add = add,
		getScore = getScore,
		getLevel = getLevel,
		getEvents = getEvents,
		remove = remove,
	}
end

return ViolationTracker
