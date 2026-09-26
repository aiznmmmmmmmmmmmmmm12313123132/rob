--!strict
--[[
	EvidenceLogger (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > EvidenceLogger

	Keeps the last few evidence entries per player (a small ring buffer) and
	prints the meaningful ones to the server output, which developers can read
	in Studio or in the live game's Developer Console (F9 > Server).

	  - Level 2+ entries (and everything, with DEBUG on) are printed.
	  - The same player + detection prints at most once per ThrottleSeconds;
	    the next line says how many were suppressed. Nothing prints per frame.
	  - Restrict and Kick always print.
	  - Nothing is ever sent to clients.

	Other server code can subscribe with onRecord, e.g. to feed analytics.
]]

export type Evidence = {
	detection: string,
	severity: number,
	added: number,
	score: number,
	level: number,
	action: string,
	time: number?, -- filled in: os.time()
	position: Vector3?,
	velocity: Vector3?,
	expectedSpeed: number?,
	actualSpeed: number?,
	humanoidState: string?,
	ping: number?,
	details: string?,
}

export type LoggingConfig = {
	EvidencePerPlayer: number,
	ThrottleSeconds: number,
}

export type EvidenceLogger = {
	record: (player: any, evidence: Evidence) -> (),
	getRecent: (player: any, count: number?) -> { Evidence },
	summary: (player: any) -> string,
	onRecord: (callback: (player: any, evidence: Evidence) -> ()) -> () -> (),
	remove: (player: any) -> (),
}

type Output = (level: "print" | "warn", message: string) -> ()

type PlayerLog = {
	entries: { Evidence },
	nextIndex: number,
	lastPrinted: { [string]: number },
	suppressed: { [string]: number },
}

local LEVEL_NAMES = { [0] = "Normal", "Observe", "Log", "Setback", "Restrict", "Kick" }
local ALWAYS_PRINT_ACTIONS = { Restrict = true, ["Setback+Restrict"] = true, Kick = true, WouldKick = true }

local function defaultOutput(level: "print" | "warn", message: string)
	if level == "warn" then
		warn(message)
	else
		print(message)
	end
end

local function round(value: number, places: number): number
	local factor = 10 ^ places
	return math.round(value * factor) / factor
end

local function formatVector(vector: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", vector.X, vector.Y, vector.Z)
end

local function describePlayer(player: any): string
	local ok, text = pcall(function()
		return `{player.Name} ({player.UserId})`
	end)
	return if ok then text else tostring(player)
end

local EvidenceLogger = {}

function EvidenceLogger.format(player: any, evidence: Evidence): string
	local parts = {
		`[AntiCheat] {describePlayer(player)} {evidence.detection}`,
		`sev {evidence.severity} +{round(evidence.added, 2)} -> score {round(evidence.score, 2)} L{evidence.level} {LEVEL_NAMES[evidence.level] or "?"}`,
		`action={evidence.action}`,
	}
	if evidence.actualSpeed and evidence.expectedSpeed then
		table.insert(parts, `speed {round(evidence.actualSpeed, 1)} vs allowed {round(evidence.expectedSpeed, 1)}`)
	end
	if evidence.position then
		table.insert(parts, `pos {formatVector(evidence.position)}`)
	end
	if evidence.velocity then
		table.insert(parts, `vel {formatVector(evidence.velocity)}`)
	end
	if evidence.humanoidState then
		table.insert(parts, `state {evidence.humanoidState}`)
	end
	if evidence.ping then
		table.insert(parts, `ping {math.round(evidence.ping * 1000)}ms`)
	end
	if evidence.details then
		table.insert(parts, evidence.details)
	end
	return table.concat(parts, " | ")
end

function EvidenceLogger.new(config: LoggingConfig, debugMode: boolean, output: Output?): EvidenceLogger
	local write: Output = output or defaultOutput
	local logs: { [any]: PlayerLog } = {}
	local listeners: { (player: any, evidence: Evidence) -> () } = {}

	local function logOf(player: any): PlayerLog
		local log = logs[player]
		if not log then
			log = { entries = {}, nextIndex = 1, lastPrinted = {}, suppressed = {} }
			logs[player] = log
		end
		return log
	end

	local function record(player: any, evidence: Evidence)
		evidence.time = evidence.time or os.time()
		local log = logOf(player)
		log.entries[log.nextIndex] = evidence
		log.nextIndex = log.nextIndex % config.EvidencePerPlayer + 1

		local important = ALWAYS_PRINT_ACTIONS[evidence.action] == true
		if important or evidence.level >= 2 or debugMode then
			local key = evidence.detection
			local t = os.clock()
			local last = log.lastPrinted[key]
			if important or last == nil or t - last >= config.ThrottleSeconds then
				local message = EvidenceLogger.format(player, evidence)
				local suppressed = log.suppressed[key]
				if suppressed and suppressed > 0 then
					message ..= ` | +{suppressed} similar suppressed`
				end
				log.lastPrinted[key] = t
				log.suppressed[key] = 0
				write(if evidence.level >= 2 or important then "warn" else "print", message)
			else
				log.suppressed[key] = (log.suppressed[key] or 0) + 1
			end
		end

		for _, listener in listeners do
			task.spawn(listener, player, evidence)
		end
	end

	-- Newest first.
	local function getRecent(player: any, count: number?): { Evidence }
		local log = logs[player]
		local result: { Evidence } = {}
		if not log then
			return result
		end
		local size = config.EvidencePerPlayer
		local limit = math.min(count or size, size)
		local index = log.nextIndex
		for _ = 1, size do
			index = (index - 2) % size + 1
			local entry = log.entries[index]
			if entry == nil or #result >= limit then
				break
			end
			table.insert(result, entry)
		end
		return result
	end

	local function summary(player: any): string
		local counts: { [string]: number } = {}
		local order: { string } = {}
		for _, entry in getRecent(player) do
			if not counts[entry.detection] then
				table.insert(order, entry.detection)
			end
			counts[entry.detection] = (counts[entry.detection] or 0) + 1
		end
		local parts = {}
		for _, detection in order do
			table.insert(parts, `{detection} x{counts[detection]}`)
		end
		return if #parts > 0 then table.concat(parts, ", ") else "no evidence"
	end

	local function onRecord(callback: (player: any, evidence: Evidence) -> ()): () -> ()
		table.insert(listeners, callback)
		return function()
			local index = table.find(listeners, callback)
			if index then
				table.remove(listeners, index)
			end
		end
	end

	local function remove(player: any)
		logs[player] = nil
	end

	return {
		record = record,
		getRecent = getRecent,
		summary = summary,
		onRecord = onRecord,
		remove = remove,
	}
end

return EvidenceLogger
