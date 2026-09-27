--[[
	Test harness for ServerScriptService/AntiCheat, run with Lune
	(https://lune-org.github.io/docs):

		lune run tests/anticheat/run

	It loads the real anti-cheat modules unchanged and gives them a small
	stand-in for the Roblox engine:

	  - Players / RunService / ReplicatedStorage / CollectionService /
	    DataStoreService / Workspace services with just the members the
	    anti-cheat uses.
	  - A world of axis-aligned boxes (ground, walls, trusses, water, moving
	    platforms) that Workspace:Raycast, GetPartBoundsInBox and
	    Terrain:ReadVoxels answer from.
	  - Simulated clients: each character moves on its own "client" (walking,
	    gravity, jumping, landing, wall collisions), and its position reaches
	    the server through a replication queue with ping, jitter and lag
	    spikes, exactly as Roblox's client-owned physics would. Server moves
	    (teleports, setbacks) reach the client after half the ping, so stale
	    packets still arrive in between.
	  - A fake clock and task scheduler, so minutes of play run in
	    milliseconds and every run is identical.

	It is not Roblox physics, so it can't prove the absence of every false
	positive; it does exercise every code path with realistic timing.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local Enum = roblox.Enum
local Region3 = roblox.Region3

local H = {}

H.Vector3 = Vector3
H.CFrame = CFrame
H.Enum = Enum

-- The repository layout, or the downloadable package's (Source/...).
local SOURCE_DIR = if fs.isDir("src/ServerScriptService/AntiCheat")
	then "src/ServerScriptService/AntiCheat"
	else "Source/ServerScriptService/AntiCheat"
local FRAME = 1 / 60
local REPLICATION_INTERVAL = 1 / 20
local CHARACTER_ROOT_HEIGHT = 3 -- root centre above the feet (HipHeight 2 + half root)
local GRAVITY = 196.2

--------------------------------------------------------------------------------
-- Deterministic random numbers
--------------------------------------------------------------------------------

local function newRandom(seed: number)
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

--------------------------------------------------------------------------------
-- Signals and instances
--------------------------------------------------------------------------------

local function newSignal()
	local signal = { handlers = {} }
	function signal:Connect(fn)
		local entry = { fn = fn, connected = true }
		table.insert(self.handlers, entry)
		return {
			Disconnect = function()
				entry.connected = false
			end,
		}
	end
	function signal:Once(fn)
		local connection
		connection = self:Connect(function(...)
			connection.Disconnect()
			fn(...)
		end)
		return connection
	end
	function signal:Fire(...)
		for _, entry in table.clone(self.handlers) do
			if entry.connected then
				entry.fn(...)
			end
		end
	end
	return signal
end
H.newSignal = newSignal

local ANCESTRY = {
	Part = { "BasePart", "PVInstance" },
	Model = { "PVInstance" },
	ModuleScript = { "LuaSourceContainer" },
	Script = { "LuaSourceContainer" },
}

local function newInstance(className: string, name: string?)
	local props = {
		ClassName = className,
		Name = name or className,
		Parent = nil,
	}
	local children = {}
	local attributes = {}
	local methods = {}
	local instance = setmetatable({}, {
		__index = function(self, key)
			local value = props[key]
			if value ~= nil then
				return value
			end
			local method = methods[key]
			if method then
				return method
			end
			for _, child in children do
				if child.Name == key then
					return child
				end
			end
			return nil
		end,
		__newindex = function(self, key, value)
			if key == "Parent" then
				local old = props.Parent
				if old then
					local list = old.__childrenList
					local index = table.find(list, self)
					if index then
						table.remove(list, index)
					end
				end
				props.Parent = value
				if value then
					table.insert(value.__childrenList, self)
				end
			else
				props[key] = value
			end
		end,
		__tostring = function()
			return props.Name
		end,
	})
	props.__childrenList = children
	props.__props = props

	function methods:IsA(class)
		if class == props.ClassName or class == "Instance" then
			return true
		end
		return table.find(ANCESTRY[props.ClassName] or {}, class) ~= nil
	end
	function methods:FindFirstChild(childName)
		for _, child in children do
			if child.Name == childName then
				return child
			end
		end
		return nil
	end
	function methods:WaitForChild(childName)
		return self:FindFirstChild(childName)
	end
	function methods:FindFirstChildOfClass(class)
		for _, child in children do
			if child.ClassName == class then
				return child
			end
		end
		return nil
	end
	function methods:GetChildren()
		return table.clone(children)
	end
	function methods:GetDescendants()
		local result = {}
		for _, child in children do
			table.insert(result, child)
			for _, descendant in child:GetDescendants() do
				table.insert(result, descendant)
			end
		end
		return result
	end
	function methods:IsDescendantOf(ancestor)
		local current = props.Parent
		while current do
			if current == ancestor then
				return true
			end
			current = current.Parent
		end
		return false
	end
	function methods:GetFullName()
		local parts = { props.Name }
		local current = props.Parent
		while current and current.ClassName ~= "DataModel" do
			table.insert(parts, 1, current.Name)
			current = current.Parent
		end
		return table.concat(parts, ".")
	end
	function methods:GetAttribute(attribute)
		return attributes[attribute]
	end
	function methods:SetAttribute(attribute, value)
		attributes[attribute] = value
	end
	function methods:Destroy()
		self.Parent = nil
	end

	if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
		props.OnServerEvent = newSignal()
	end
	return instance, methods, props
end
H.newInstance = newInstance

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- Entry fraction t in [0, 1] of the segment origin -> origin + direction into
-- the box, or nil. Like Roblox, a ray that starts inside a part doesn't hit it.
local function rayEntry(origin, direction, min, max): number?
	local o = { origin.X, origin.Y, origin.Z }
	local d = { direction.X, direction.Y, direction.Z }
	local lo = { min.X, min.Y, min.Z }
	local hi = { max.X, max.Y, max.Z }
	local inside = true
	for axis = 1, 3 do
		if o[axis] <= lo[axis] or o[axis] >= hi[axis] then
			inside = false
		end
	end
	if inside then
		return nil
	end
	local tMin, tMax = 0, 1
	for axis = 1, 3 do
		if math.abs(d[axis]) < 1e-9 then
			if o[axis] < lo[axis] or o[axis] > hi[axis] then
				return nil
			end
		else
			local t1 = (lo[axis] - o[axis]) / d[axis]
			local t2 = (hi[axis] - o[axis]) / d[axis]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tMin = math.max(tMin, t1)
			tMax = math.min(tMax, t2)
			if tMin > tMax then
				return nil
			end
		end
	end
	return tMin
end

local function boxesOverlap(aMin, aMax, bMin, bMax): boolean
	return aMin.X < bMax.X and aMax.X > bMin.X and aMin.Y < bMax.Y and aMax.Y > bMin.Y and aMin.Z < bMax.Z and aMax.Z > bMin.Z
end

local function pointInBox(point, min, max): boolean
	return point.X > min.X and point.X < max.X and point.Y > min.Y and point.Y < max.Y and point.Z > min.Z and point.Z < max.Z
end

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

export type Options = {
	isStudio: boolean?,
	testMode: boolean?,
	seed: number?,
	echo: boolean?, -- print the anti-cheat's output while running
}

-- Every world created, so the runner can fail a test whose anti-cheat code
-- threw (errors inside the movement loop are caught and only warned).
H.worlds = {}

function H.newWorld(options: Options?)
	local opts = options or {}
	local sim = {
		now = 1000,
		output = {},
		evidence = {},
		kicks = {},
		bans = {},
		dataStore = {},
		players = {},
		parts = {},
		water = {},
		tagged = {},
		queue = {}, -- fake task scheduler
		-- Cost counters for bench.luau: engine queries made by the anti-cheat
		-- and the real time spent in its Heartbeat handler / in the stand-in
		-- queries (which are slow Luau here, native code in Roblox).
		stats = { raycasts = 0, overlaps = 0, voxelReads = 0, heartbeatTime = 0, queryTime = 0, frames = 0 },
		random = newRandom(opts.seed or 7),
	}

	------------------------------------------------------------------------
	-- Services
	------------------------------------------------------------------------

	local dataModel = newInstance("DataModel", "Game")
	local workspace, workspaceMethods, workspaceProps = newInstance("Workspace", "Workspace")
	workspace.Parent = dataModel
	workspaceProps.Gravity = GRAVITY
	local replicatedStorage = newInstance("ReplicatedStorage", "ReplicatedStorage")
	replicatedStorage.Parent = dataModel
	local serverScriptService = newInstance("ServerScriptService", "ServerScriptService")
	serverScriptService.Parent = dataModel
	local players, playersMethods, playersProps = newInstance("Players", "Players")
	players.Parent = dataModel
	playersProps.PlayerAdded = newSignal()
	playersProps.PlayerRemoving = newSignal()
	function playersMethods:GetPlayers()
		local list = {}
		for _, record in sim.players do
			if record.player.Parent == players then
				table.insert(list, record.player)
			end
		end
		return list
	end
	function playersMethods:BanAsync(config)
		table.insert(sim.bans, config)
	end

	local heartbeat = newSignal()
	local runService = {
		Heartbeat = heartbeat,
		IsStudio = function()
			return opts.isStudio == true
		end,
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
	}
	local collectionService = {
		GetTagged = function(_, tag)
			return table.clone(sim.tagged[tag] or {})
		end,
	}
	local dataStoreService = {
		GetDataStore = function(_, storeName)
			return {
				UpdateAsync = function(_, key, transform)
					local fullKey = storeName .. "/" .. key
					sim.dataStore[fullKey] = transform(sim.dataStore[fullKey])
				end,
			}
		end,
	}

	local terrain, terrainMethods = newInstance("Terrain", "Terrain")
	terrain.Parent = workspace
	workspaceProps.Terrain = terrain

	local function isExcluded(part, params): boolean
		local list = params.FilterDescendantsInstances or {}
		local listed = false
		for _, instance in list do
			if part == instance or part:IsDescendantOf(instance) then
				listed = true
				break
			end
		end
		if params.FilterType == Enum.RaycastFilterType.Include then
			return not listed
		end
		return listed
	end

	function workspaceMethods:Raycast(origin, direction, params)
		local bestT, bestPart, isWater = math.huge, nil, false
		for _, part in sim.parts do
			if part.Parent and not isExcluded(part, params) and (not params.RespectCanCollide or part.CanCollide) then
				local half = part.Size / 2
				local t = rayEntry(origin, direction, part.Position - half, part.Position + half)
				if t and t < bestT then
					bestT, bestPart, isWater = t, part, false
				end
			end
		end
		if not params.IgnoreWater and params.FilterType ~= Enum.RaycastFilterType.Include then
			for _, box in sim.water do
				local t = rayEntry(origin, direction, box.min, box.max)
				if t and t < bestT then
					bestT, bestPart, isWater = t, terrain, true
				end
			end
		end
		if not bestPart then
			return nil
		end
		return {
			Instance = bestPart,
			Position = origin + direction * bestT,
			Material = if isWater then Enum.Material.Water else Enum.Material.Plastic,
		}
	end

	function workspaceMethods:GetPartBoundsInBox(cframe, size, params)
		local result = {}
		local min, max = cframe.Position - size / 2, cframe.Position + size / 2
		for _, part in sim.parts do
			if part.Parent and not isExcluded(part, params) and (not params.RespectCanCollide or part.CanCollide) then
				local half = part.Size / 2
				if boxesOverlap(min, max, part.Position - half, part.Position + half) then
					table.insert(result, part)
					if params.MaxParts and params.MaxParts > 0 and #result >= params.MaxParts then
						break
					end
				end
			end
		end
		return result
	end

	-- Terrain:ReadVoxels(region, resolution): water boxes only.
	function terrainMethods:ReadVoxels(region, _resolution)
		local center = region.CFrame.Position
		local half = region.Size / 2
		-- Like Roblox, both arrays also carry a Size field.
		local function voxels(value)
			local array = { { { value } } }
			array.Size = Vector3.new(1, 1, 1)
			return array
		end
		for _, box in sim.water do
			if boxesOverlap(center - half, center + half, box.min, box.max) then
				return voxels(Enum.Material.Water), voxels(1)
			end
		end
		return voxels(Enum.Material.Air), voxels(0)
	end

	-- Count and time every query.
	for _, entry in {
		{ methods = workspaceMethods, name = "Raycast", counter = "raycasts" },
		{ methods = workspaceMethods, name = "GetPartBoundsInBox", counter = "overlaps" },
		{ methods = terrainMethods, name = "ReadVoxels", counter = "voxelReads" },
	} do
		local original = entry.methods[entry.name]
		entry.methods[entry.name] = function(...)
			sim.stats[entry.counter] += 1
			local started = os.clock()
			local a, b = original(...)
			sim.stats.queryTime += os.clock() - started
			return a, b
		end
	end

	local services = {
		Players = players,
		ReplicatedStorage = replicatedStorage,
		ServerScriptService = serverScriptService,
		RunService = runService,
		CollectionService = collectionService,
		DataStoreService = dataStoreService,
		Workspace = workspace,
	}

	local game = {
		PlaceId = 123,
		JobId = "test-job",
		CreatorType = Enum.CreatorType.User,
		CreatorId = 1,
		GetService = function(_, name)
			return services[name] or error("harness has no service " .. name)
		end,
	}

	------------------------------------------------------------------------
	-- Fake clock and task scheduler
	------------------------------------------------------------------------

	local function schedule(seconds, fn, ...)
		table.insert(sim.queue, { at = sim.now + math.max(seconds or 0, 0), fn = fn, args = table.pack(...) })
	end

	local fakeTask = {
		spawn = function(fn, ...)
			local co = if type(fn) == "thread" then fn else coroutine.create(fn)
			local ok, err = coroutine.resume(co, ...)
			if not ok then
				error(err, 0)
			end
			return co
		end,
		delay = function(seconds, fn, ...)
			schedule(seconds, fn, ...)
		end,
		defer = function(fn, ...)
			schedule(0, fn, ...)
		end,
		wait = function()
			error("task.wait isn't available in the harness")
		end,
	}

	local function runDueTasks()
		local ran = true
		while ran do
			ran = false
			for index, job in sim.queue do
				if job.at <= sim.now then
					table.remove(sim.queue, index)
					job.fn(table.unpack(job.args, 1, job.args.n))
					ran = true
					break
				end
			end
		end
	end

	local function capture(kind)
		return function(...)
			local parts = {}
			for index = 1, select("#", ...) do
				table.insert(parts, tostring((select(index, ...))))
			end
			local line = table.concat(parts, " ")
			table.insert(sim.output, { kind = kind, text = line })
			if opts.echo then
				print(`  [{kind}] {line}`)
			end
		end
	end

	local mathWithIsFinite = table.clone(math)
	mathWithIsFinite.isfinite = function(x)
		return x == x and x ~= math.huge and x ~= -math.huge
	end

	------------------------------------------------------------------------
	-- Module loader
	------------------------------------------------------------------------

	local cache = {}
	local function buildTree(dir, name, parent)
		local node = newInstance("Folder", name)
		node.Parent = parent
		for _, entry in fs.readDir(dir) do
			local path = dir .. "/" .. entry
			if fs.isDir(path) then
				buildTree(path, entry, node)
			elseif string.match(entry, "%.luau$") then
				local base = string.gsub(entry, "%.luau$", "")
				local class = "ModuleScript"
				if string.match(base, "%.server$") then
					class = "Script"
					base = string.gsub(base, "%.server$", "")
				end
				local child, _, props = newInstance(class, base)
				props.__file = path
				child.Parent = node
			end
		end
		return node
	end
	local root = buildTree(SOURCE_DIR, "AntiCheat", serverScriptService)

	local requireModule
	local function load(node)
		local path = node.__file
		local env = {
			script = node,
			require = requireModule,
			game = game,
			workspace = workspace,
			Instance = {
				new = function(className)
					return (newInstance(className))
				end,
			},
			Vector3 = Vector3,
			CFrame = CFrame,
			Region3 = Region3,
			Enum = Enum,
			RaycastParams = {
				new = function()
					return { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude }
				end,
			},
			OverlapParams = {
				new = function()
					return { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude }
				end,
			},
			os = {
				clock = function()
					return sim.now
				end,
				time = os.time,
				date = os.date,
			},
			task = fakeTask,
			math = mathWithIsFinite,
			warn = capture("warn"),
			print = capture("print"),
		}
		local chunk = luau.load(fs.readFile(path), { debugName = path, environment = env })
		return chunk()
	end
	requireModule = function(node)
		if type(node) ~= "table" or not node.__file then
			error("harness require: not a module " .. tostring(node), 2)
		end
		if cache[node] == nil then
			cache[node] = load(node)
		end
		return cache[node]
	end

	sim.root = root
	sim.require = function(path: string)
		local node = root
		for segment in string.gmatch(path, "[^/]+") do
			node = node:FindFirstChild(segment) or error("no module " .. path)
		end
		return requireModule(node)
	end

	-- Loading Api builds every module, exactly as the Script does.
	sim.Config = sim.require("Config")
	if opts.testMode ~= nil then
		sim.Config.TEST_MODE = opts.testMode
	end
	sim.api = sim.require("Api")
	sim.api.onEvidence(function(player, evidence)
		table.insert(sim.evidence, { player = player, evidence = evidence })
	end)
	sim.api.start()

	------------------------------------------------------------------------
	-- World building
	------------------------------------------------------------------------

	function sim.addPart(spec)
		local part, _, props = newInstance("Part", spec.name or "Part")
		props.Position = spec.position
		props.Size = spec.size
		props.Anchored = spec.anchored ~= false
		props.CanCollide = spec.canCollide ~= false
		props.AssemblyLinearVelocity = spec.velocity or Vector3.zero
		part.Parent = workspace
		table.insert(sim.parts, part)
		if spec.tag then
			sim.tagged[spec.tag] = sim.tagged[spec.tag] or {}
			table.insert(sim.tagged[spec.tag], part)
			for key, value in spec.attributes or {} do
				part:SetAttribute(key, value)
			end
		end
		return part
	end

	function sim.addWater(min, max)
		table.insert(sim.water, { min = min, max = max })
	end

	-- A 2000x2000 floor whose top is at y = 0.
	sim.addPart({ name = "Baseplate", position = Vector3.new(0, -2, 0), size = Vector3.new(2000, 4, 2000) })

	-- Highest solid top at or below `feetY + stepUp` under (x, z).
	local function groundTopAt(position, feetY, stepUp)
		local best = -math.huge
		local velocity = Vector3.zero
		for _, part in sim.parts do
			if part.Parent and part.CanCollide then
				local half = part.Size / 2
				local min, max = part.Position - half, part.Position + half
				local top = max.Y
				if position.X > min.X and position.X < max.X and position.Z > min.Z and position.Z < max.Z and top <= feetY + stepUp and top > best then
					best = top
					velocity = part.AssemblyLinearVelocity
				end
			end
		end
		return best, velocity
	end

	local function inWater(position)
		for _, box in sim.water do
			if pointInBox(position, box.min, box.max) then
				return true
			end
		end
		return false
	end

	local function blockedAt(position)
		-- Body box: 2 wide, from the feet + 0.6 (so kerbs are stepped over) to the head.
		local min = position - Vector3.new(1, CHARACTER_ROOT_HEIGHT - 0.6, 0.5)
		local max = position + Vector3.new(1, 2, 0.5)
		for _, part in sim.parts do
			if part.Parent and part.CanCollide then
				local half = part.Size / 2
				if boxesOverlap(min, max, part.Position - half, part.Position + half) then
					return true
				end
			end
		end
		return false
	end

	------------------------------------------------------------------------
	-- Players, characters, replication
	------------------------------------------------------------------------

	function sim.addPlayer(spec)
		local player, methods, props = newInstance("Player", spec.name or "Player")
		props.UserId = spec.userId or (1000 + #sim.players)
		props.CharacterAdded = newSignal()
		props.Character = nil
		local record = {
			player = player,
			ping = spec.ping or 0.08,
			jitter = spec.jitter or 0.01,
			inFlight = {}, -- packets travelling to the server
			lastApplied = -math.huge,
			nextSend = sim.now,
			lagUntil = -math.huge,
			pendingAdopt = nil, -- server move the client hasn't received yet
			client = nil,
		}
		function methods:GetNetworkPing()
			return record.ping
		end
		function methods:Kick(message)
			table.insert(sim.kicks, { player = player, message = message, time = sim.now })
			players.PlayerRemoving:Fire(player)
			player.Parent = nil
		end
		function methods:GetRankInGroupAsync()
			return 0
		end
		player.Parent = players
		table.insert(sim.players, record)
		record.player = player
		players.PlayerAdded:Fire(player)
		runDueTasks()
		return player, record
	end

	local function recordOf(player)
		for _, record in sim.players do
			if record.player == player then
				return record
			end
		end
		error("unknown player")
	end
	sim.recordOf = recordOf

	-- Spawns a character with its feet at `feetPosition`.
	function sim.spawn(player, feetPosition)
		local record = recordOf(player)
		local character, characterMethods = newInstance("Model", player.Name)
		local rootPart, _, rootProps = newInstance("Part", "HumanoidRootPart")
		local start = feetPosition + Vector3.new(0, CHARACTER_ROOT_HEIGHT, 0)
		rootProps.CFrame = CFrame.new(start)
		rootProps.Size = Vector3.new(2, 2, 1)
		rootProps.AssemblyLinearVelocity = Vector3.zero
		rootProps.AssemblyAngularVelocity = Vector3.zero
		rootProps.Anchored = false
		rootProps.CanCollide = true
		rootProps.CollisionGroup = "Default"
		rootProps.NetworkOwner = player
		-- Position always follows CFrame. Only server-side writes fire the
		-- CFrame changed signal; replicated client physics doesn't (as in Roblox).
		local cframeChanged = newSignal()
		record.cframeChanged = cframeChanged
		local rootMeta = getmetatable(rootPart)
		local baseIndex, baseNewIndex = rootMeta.__index, rootMeta.__newindex
		rootMeta.__index = function(self, key)
			if key == "GetPropertyChangedSignal" then
				return function(_, property)
					assert(property == "CFrame", "harness only models CFrame changes")
					return cframeChanged
				end
			elseif key == "Position" then
				return rootProps.CFrame.Position
			elseif key == "CanSetNetworkOwnership" then
				return function()
					return true, nil
				end
			elseif key == "SetNetworkOwner" then
				return function(_, owner)
					rootProps.NetworkOwner = owner
				end
			end
			return baseIndex(self, key)
		end
		rootMeta.__newindex = function(self, key, value)
			if key == "Position" then
				rootProps.CFrame = CFrame.new(value)
			else
				baseNewIndex(self, key, value)
			end
		end

		local humanoid, humanoidMethods, humanoidProps = newInstance("Humanoid", "Humanoid")
		humanoidProps.Health = 100
		humanoidProps.WalkSpeed = 16
		humanoidProps.JumpPower = 50
		humanoidProps.UseJumpPower = true
		humanoidProps.JumpHeight = 7.2
		humanoidProps.HipHeight = 2
		humanoidProps.SeatPart = nil
		local client
		function humanoidMethods:GetState()
			return { Name = if client and not client.grounded then "Freefall" else "Running" }
		end

		-- A server-side move reaches the client half a ping later.
		function characterMethods:PivotTo(target)
			rootProps.CFrame = target
			record.pendingAdopt = { at = sim.now + record.ping / 2, cframe = target }
			cframeChanged:Fire()
		end

		rootPart.Parent = character
		humanoid.Parent = character
		character.Parent = workspace

		client = {
			position = start,
			velocity = Vector3.zero,
			angular = Vector3.zero,
			grounded = true,
			walkSpeed = 16, -- the CLIENT's WalkSpeed (exploits change only this)
			jumpVelocity = 50,
			move = Vector3.zero, -- desired horizontal direction (unit or zero)
			jump = false,
			noclip = false,
			override = nil, -- function(dt, client) for hacks that set CFrame directly
			platformVelocity = Vector3.zero,
		}
		record.client = client
		record.character = character
		record.root = rootPart
		record.humanoid = humanoid
		record.inFlight = {}
		record.lastApplied = -math.huge
		record.pendingAdopt = nil

		player.__props.Character = character
		player.CharacterAdded:Fire(character)
		runDueTasks()
		return character, record
	end

	local function stepClient(record, dt)
		local client = record.client
		if not client then
			return
		end
		if record.pendingAdopt and sim.now >= record.pendingAdopt.at then
			client.position = record.pendingAdopt.cframe.Position
			client.velocity = Vector3.zero
			record.pendingAdopt = nil
		end
		if client.override then
			client.override(dt, client)
			return
		end

		local feetY = client.position.Y - CHARACTER_ROOT_HEIGHT
		local swimming = inWater(client.position)

		-- Horizontal: walk intent plus the platform the character stands on.
		local horizontal = client.move * client.walkSpeed
		if client.grounded then
			horizontal += Vector3.new(client.platformVelocity.X, 0, client.platformVelocity.Z)
		end
		local vy = client.velocity.Y
		if client.jump and (client.grounded or swimming) then
			vy = client.jumpVelocity
			client.grounded = false
		end
		client.jump = false
		if swimming then
			vy *= 0.9 -- buoyancy: treading water
		else
			vy -= GRAVITY * dt
		end

		local nextPosition = client.position + Vector3.new(horizontal.X * dt, 0, horizontal.Z * dt)
		if not client.noclip and blockedAt(nextPosition) then
			nextPosition = client.position -- walked into a wall
		end
		nextPosition += Vector3.new(0, vy * dt, 0)

		local top, platformVelocity = groundTopAt(nextPosition, feetY, 1.2)
		local nextFeet = nextPosition.Y - CHARACTER_ROOT_HEIGHT
		if top > -math.huge and nextFeet <= top and vy <= 0 then
			nextPosition = Vector3.new(nextPosition.X, top + CHARACTER_ROOT_HEIGHT, nextPosition.Z)
			vy = 0
			client.grounded = true
			client.platformVelocity = platformVelocity
		else
			client.grounded = false
		end
		client.velocity = Vector3.new(horizontal.X, vy, horizontal.Z)
		client.position = nextPosition
	end

	local function replicate(record)
		local client = record.client
		if not client or not record.root then
			return
		end
		-- Client -> server packets.
		if sim.now >= record.nextSend then
			record.nextSend = sim.now + REPLICATION_INTERVAL
			local jitter = (sim.random() * 2 - 1) * record.jitter
			local arrive = sim.now + record.ping / 2 + jitter
			if sim.now < record.lagUntil then
				arrive = record.lagUntil + record.ping / 2 + sim.random() * 0.05
			end
			table.insert(record.inFlight, {
				sent = sim.now,
				arrive = arrive,
				position = client.position,
				velocity = client.velocity,
				angular = client.angular,
			})
		end
		-- Arrivals: the newest packet wins, older ones are dropped.
		local keep = {}
		for _, packet in record.inFlight do
			if packet.arrive <= sim.now then
				if packet.sent > record.lastApplied then
					record.lastApplied = packet.sent
					local rootProps = record.root.__props
					if record.root.__props.NetworkOwner == record.player then
						rootProps.CFrame = CFrame.new(packet.position)
						rootProps.AssemblyLinearVelocity = packet.velocity
						rootProps.AssemblyAngularVelocity = packet.angular
					end
				end
			else
				table.insert(keep, packet)
			end
		end
		record.inFlight = keep
	end

	-- Runs the game for `seconds`: clients move, packets travel, the server's
	-- Heartbeat runs the anti-cheat, delayed tasks fire.
	function sim.advance(seconds: number, perFrame: ((t: number) -> ())?)
		local frames = math.max(1, math.round(seconds / FRAME))
		for _ = 1, frames do
			sim.now += FRAME
			if perFrame then
				perFrame(sim.now)
			end
			for _, record in sim.players do
				if record.player.Parent then
					stepClient(record, FRAME)
					replicate(record)
				end
			end
			runDueTasks()
			local started = os.clock()
			heartbeat:Fire(FRAME)
			sim.stats.heartbeatTime += os.clock() - started
			sim.stats.frames += 1
		end
	end

	-- Packets sent from now until `seconds` later all arrive in one burst.
	function sim.lagSpike(player, seconds: number)
		recordOf(player).lagUntil = sim.now + seconds
	end

	function sim.removePlayer(player)
		players.PlayerRemoving:Fire(player)
		player.Parent = nil
	end

	------------------------------------------------------------------------
	-- Remotes
	------------------------------------------------------------------------

	function sim.remote(name)
		local folder = replicatedStorage:FindFirstChild("Remotes")
		return folder and folder:FindFirstChild(name)
	end

	function sim.fire(player, name, ...)
		local remote = sim.remote(name) or error("no remote " .. name)
		remote.OnServerEvent:Fire(player, ...)
		runDueTasks()
	end

	function sim.invoke(player, name, ...)
		local remote = sim.remote(name) or error("no remote " .. name)
		local results = table.pack(remote.OnServerInvoke(player, ...))
		runDueTasks()
		return table.unpack(results, 1, results.n)
	end

	------------------------------------------------------------------------
	-- Results
	------------------------------------------------------------------------

	function sim.evidenceFor(player, kind: string?)
		local list = {}
		for _, item in sim.evidence do
			if item.player == player and (kind == nil or item.evidence.detection == kind) then
				table.insert(list, item.evidence)
			end
		end
		return list
	end

	function sim.pointsFor(player, kind: string?)
		local total = 0
		for _, evidence in sim.evidenceFor(player, kind) do
			total += evidence.added
		end
		return total
	end

	function sim.actionsFor(player)
		local actions = {}
		for _, evidence in sim.evidenceFor(player) do
			actions[evidence.action] = (actions[evidence.action] or 0) + 1
		end
		return actions
	end

	function sim.describe(player)
		local lines = {}
		for _, evidence in sim.evidenceFor(player) do
			table.insert(
				lines,
				string.format(
					"%s sev%s +%.2f score %.2f L%d %s %s",
					evidence.detection,
					tostring(evidence.severity),
					evidence.added,
					evidence.score,
					evidence.level,
					evidence.action,
					evidence.details or ""
				)
			)
		end
		return if #lines > 0 then table.concat(lines, "\n      ") else "(no evidence)"
	end

	function sim.internalErrors()
		local errors = {}
		for _, line in sim.output do
			if string.find(line.text, "sample failed", 1, true) or string.find(line.text, "handler error", 1, true) then
				table.insert(errors, line.text)
			end
		end
		return errors
	end

	sim.workspace = workspace
	sim.replicatedStorage = replicatedStorage
	sim.runDueTasks = runDueTasks
	table.insert(H.worlds, sim)
	return sim
end

return H
