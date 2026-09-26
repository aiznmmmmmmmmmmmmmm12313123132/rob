--!strict
--[[
	RemoteValidator (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > RemoteValidator

	Two jobs:

	1. validate(specs, args, count): checks remote arguments against a schema
	   and returns clean copies. Every value is type-checked; numbers must be
	   finite and in range; strings must be valid UTF-8, short and free of
	   control characters; arrays must be real arrays (no extra keys, no holes,
	   limited length) and are rebuilt, so a client table can never smuggle
	   extra keys into game or saved data. Extra arguments are refused.

	2. createGateway(deps): binds a handler to a RemoteEvent/RemoteFunction
	   behind, in order:

	     rate limit        dropped silently; flooding far beyond it is evidence
	     restriction       economy remotes refused while Enforcement restricts
	     schema            malformed arguments are refused and are evidence
	     exclusive         one call per player at a time for yielding handlers
	     shop proximity    for contracts with a `shop`
	     handler           in a protected call; errors never reach the client

	   The handler only ever sees validated arguments. It still has to decide
	   the outcome itself (roll result, price, ownership): the client only
	   asks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RateLimiter = require(script.Parent.RateLimiter)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type ArgSpec = {
	type: "string" | "number" | "integer" | "boolean" | "enum" | "array",
	optional: boolean?,
	-- number / integer
	min: number?,
	max: number?,
	-- string / array
	minLength: number?,
	maxLength: number?,
	pattern: string?, -- Lua pattern the whole string must match
	-- enum
	values: { string }?,
	-- array
	of: ArgSpec?,
	unique: boolean?,
	-- any type: extra server-side check, e.g. "is this a real item id?"
	check: ((value: any) -> boolean)?,
}

export type RateRule = RateLimiter.Rule

export type Contract = {
	kind: "RemoteEvent" | "RemoteFunction",
	description: string,
	args: { ArgSpec },
	rate: RateRule?,
	-- Real cooldown in seconds (or per player, for upgradable cooldowns).
	-- Enforced exactly over time, but a request may arrive 0.3 s early.
	cooldown: (number | (player: Player) -> number)?,
	restrictable: boolean?, -- refused while the player is restricted
	exclusive: boolean?, -- refused while the previous call is still running
	shop: string?, -- ShopId the player must be standing near
}

export type Handler = (player: Player, ...any) -> ...any

export type GatewayDeps = {
	config: any, -- Config.Remotes
	consume: (player: Player, action: string, rule: RateRule) -> (boolean, number),
	isRestricted: (player: Player) -> boolean,
	isNearShop: (player: Player, shopId: string) -> (boolean, string?, boolean),
	report: (player: Player, kind: string, severity: number, details: string) -> (),
	clock: () -> number,
	container: Instance?, -- defaults to ReplicatedStorage.<FolderName>
}

export type Gateway = {
	bind: (name: string, contract: Contract, handler: Handler, isDemo: boolean?) -> RemoteEvent | RemoteFunction,
	isBound: (name: string) -> boolean,
	isDemo: (name: string) -> boolean,
	boundRemotes: () -> { [Instance]: string },
	removePlayer: (player: Player) -> (),
}

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

local RemoteValidator = {}

local DEFAULT_MAX_STRING = 64
local DEFAULT_MAX_ARRAY = 100

-- "^pattern$" built once per pattern, not once per value checked.
local anchoredPatterns: { [string]: string } = {}

function RemoteValidator.isFiniteNumber(value: any): boolean
	return type(value) == "number" and math.isfinite(value)
end

local validateValue: (spec: ArgSpec, value: any) -> (boolean, any)

local function validateString(spec: ArgSpec, value: any): (boolean, any)
	if type(value) ~= "string" then
		return false, `expected string, got {typeof(value)}`
	end
	if #value > (spec.maxLength or DEFAULT_MAX_STRING) then
		return false, `string too long ({#value} bytes)`
	end
	if #value < (spec.minLength or 0) then
		return false, "string too short"
	end
	if utf8.len(value) == nil then
		return false, "string is not valid UTF-8"
	end
	if string.find(value, "%c") then
		return false, "string has control characters"
	end
	local pattern = spec.pattern
	if pattern then
		local anchored = anchoredPatterns[pattern]
		if not anchored then
			anchored = "^" .. pattern .. "$"
			anchoredPatterns[pattern] = anchored
		end
		if not string.find(value, anchored) then
			return false, "string has unexpected characters"
		end
	end
	return true, value
end

local function validateNumber(spec: ArgSpec, value: any): (boolean, any)
	if type(value) ~= "number" then
		return false, `expected number, got {typeof(value)}`
	end
	if not math.isfinite(value) then
		return false, "number is NaN or infinite"
	end
	if spec.type == "integer" and value ~= math.floor(value) then
		return false, "expected a whole number"
	end
	if spec.min and value < spec.min then
		return false, `number below {spec.min}`
	end
	if spec.max and value > spec.max then
		return false, `number above {spec.max}`
	end
	return true, value
end

local function validateArray(spec: ArgSpec, value: any): (boolean, any)
	if type(value) ~= "table" then
		return false, `expected array, got {typeof(value)}`
	end
	if getmetatable(value) ~= nil then
		return false, "array has a metatable"
	end
	local maxLength = spec.maxLength or DEFAULT_MAX_ARRAY
	local count = 0
	for key in value do
		count += 1
		if count > maxLength then
			return false, `array longer than {maxLength}`
		end
		if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
			return false, "array has non-index keys"
		end
	end
	if count ~= #value or (count > 0 and value[count] == nil) then
		return false, "array has holes"
	end
	if count < (spec.minLength or 0) then
		return false, "array too short"
	end

	local elementSpec = spec.of
	if not elementSpec then
		return false, "array spec has no element type"
	end
	local clean = table.create(count)
	local seen: { [any]: boolean } = {}
	for index = 1, count do
		local ok, result = validateValue(elementSpec, value[index])
		if not ok then
			return false, `element {index}: {result}`
		end
		if spec.unique then
			if seen[result] then
				return false, "array has duplicates"
			end
			seen[result] = true
		end
		clean[index] = result
	end
	return true, clean
end

validateValue = function(spec: ArgSpec, value: any): (boolean, any)
	local ok, result
	local kind = spec.type
	if kind == "string" then
		ok, result = validateString(spec, value)
	elseif kind == "number" or kind == "integer" then
		ok, result = validateNumber(spec, value)
	elseif kind == "boolean" then
		ok, result = type(value) == "boolean", value
		if not ok then
			result = `expected boolean, got {typeof(value)}`
		end
	elseif kind == "enum" then
		ok, result = type(value) == "string" and spec.values ~= nil and table.find(spec.values, value) ~= nil, value
		if not ok then
			result = "value is not one of the allowed options"
		end
	elseif kind == "array" then
		ok, result = validateArray(spec, value)
	else
		ok, result = false, `unknown spec type {tostring(kind)}`
	end
	if ok and spec.check then
		local checked, passed = pcall(spec.check, result)
		if not checked or passed ~= true then
			return false, "value failed the server-side check"
		end
	end
	return ok, result
end

-- Returns (true, cleanArgs) or (false, reason).
function RemoteValidator.validate(specs: { ArgSpec }, args: { any }, count: number): (boolean, any)
	if count > #specs then
		for index = #specs + 1, count do
			if args[index] ~= nil then
				return false, `too many arguments ({count}, expected {#specs})`
			end
		end
	end
	local clean = table.create(#specs)
	for index, spec in specs do
		local value = args[index]
		if value == nil then
			if not spec.optional then
				return false, `argument {index} is missing`
			end
		else
			local ok, result = validateValue(spec, value)
			if not ok then
				return false, `argument {index}: {result}`
			end
			clean[index] = result
		end
	end
	return true, clean
end

--------------------------------------------------------------------------------
-- Gateway
--------------------------------------------------------------------------------

local function ruleFor(contract: Contract, player: Player): RateRule
	local cooldown = contract.cooldown
	if cooldown ~= nil then
		local seconds = if type(cooldown) == "function" then cooldown(player) else cooldown
		if type(seconds) ~= "number" or not math.isfinite(seconds) or seconds <= 0 then
			seconds = 1
		end
		return RateLimiter.fromCooldown(seconds)
	end
	return contract.rate or { rate = 2, burst = 3 }
end

function RemoteValidator.createGateway(deps: GatewayDeps): Gateway
	local config = deps.config
	local bound: { [string]: { remote: Instance, connection: RBXScriptConnection?, demo: boolean } } = {}
	local inFlight: { [Player]: { [string]: boolean } } = {}
	local lastFloodFlag: { [Player]: { [string]: number } } = {}

	local function getContainer(): Instance
		if deps.container then
			return deps.container
		end
		local folder = ReplicatedStorage:FindFirstChild(config.FolderName)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = config.FolderName
			folder.Parent = ReplicatedStorage
		end
		return folder :: Instance
	end

	local function markFlood(player: Player, name: string, denied: number)
		local byName = lastFloodFlag[player]
		if not byName then
			byName = {}
			lastFloodFlag[player] = byName
		end
		local t = deps.clock()
		if t - (byName[name] or -math.huge) >= config.FloodFlagInterval then
			byName[name] = t
			deps.report(player, "RemoteFlood", 1, `{name}: {denied} requests refused in the last second`)
		end
	end

	-- Runs every check, then the handler. Returns (accepted, ...results).
	local function process(name: string, contract: Contract, handler: Handler, player: Player, ...: any): ...any
		local count = select("#", ...)
		local args = { ... }

		local allowed, denied = deps.consume(player, name, ruleFor(contract, player))
		if not allowed then
			if denied >= config.FloodThreshold then
				markFlood(player, name, denied)
			end
			return nil, "RateLimited"
		end

		if contract.restrictable and deps.isRestricted(player) then
			return nil, "Restricted"
		end

		local valid, result = RemoteValidator.validate(contract.args, args, count)
		if not valid then
			deps.report(player, "InvalidRemote", 1, `{name}: {result}`)
			return nil, "InvalidArguments"
		end

		if contract.shop then
			local near, reason, suspicious = deps.isNearShop(player, contract.shop)
			if not near then
				if suspicious then
					deps.report(player, "EconomyTamper", 1, `{name}: used shop {contract.shop} from far away`)
				end
				return nil, reason or "TooFar"
			end
		end

		local running = inFlight[player]
		if contract.exclusive then
			if running and running[name] then
				return nil, "Busy"
			end
			if not running then
				running = {}
				inFlight[player] = running
			end
			(running :: { [string]: boolean })[name] = true
		end

		local results = table.pack(xpcall(handler, debug.traceback, player, table.unpack(result, 1, #contract.args)))

		if contract.exclusive and inFlight[player] then
			inFlight[player][name] = nil
		end
		if not results[1] then
			warn(`[AntiCheat] {name} handler error: {results[2]}`)
			return nil, "Error"
		end
		return table.unpack(results, 2, results.n)
	end

	local function bind(name: string, contract: Contract, handler: Handler, isDemo: boolean?): RemoteEvent | RemoteFunction
		local existing = bound[name]
		if existing and not existing.demo then
			error(`[AntiCheat] {name} is already bound; bind each remote once`, 2)
		end

		local container = getContainer()
		local remote: Instance? = container:FindFirstChild(name)
		if remote == nil then
			local created = Instance.new(contract.kind :: any)
			created.Name = name
			created.Parent = container
			remote = created
		elseif not remote:IsA(contract.kind) then
			error(`[AntiCheat] {remote:GetFullName()} is a {remote.ClassName}, but its contract says {contract.kind}`, 2)
		end
		assert(remote, "remote exists by now")

		if existing and existing.connection then
			existing.connection:Disconnect()
		end

		local entry = { remote = remote, connection = nil :: RBXScriptConnection?, demo = isDemo == true }
		if contract.kind == "RemoteFunction" then
			(remote :: RemoteFunction).OnServerInvoke = function(player: Player, ...: any)
				return process(name, contract, handler, player, ...)
			end
		else
			entry.connection = (remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, ...: any)
				process(name, contract, handler, player, ...)
			end)
		end
		bound[name] = entry
		return remote :: any
	end

	local function boundRemotes(): { [Instance]: string }
		local result = {}
		for name, entry in bound do
			result[entry.remote] = name
		end
		return result
	end

	local function removePlayer(player: Player)
		inFlight[player] = nil
		lastFloodFlag[player] = nil
	end

	return {
		bind = bind,
		isBound = function(name: string): boolean
			return bound[name] ~= nil
		end,
		isDemo = function(name: string): boolean
			local entry = bound[name]
			return entry ~= nil and entry.demo
		end,
		boundRemotes = boundRemotes,
		removePlayer = removePlayer,
	}
end

return RemoteValidator
