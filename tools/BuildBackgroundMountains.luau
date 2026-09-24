--[[
	BuildBackgroundMountains (Studio Command Bar script)

	Paste into View > Command Bar in Roblox Studio, in Edit mode (not while
	play-testing), and press Enter.

	Builds a painterly karst world around the island, under
	Workspace.Environment.BackgroundMountains:

	  Near, Mid, Far   rings of rounded karst peaks, each sculpted from
	                   overlapping smooth ellipsoids: a broad base, a tall
	                   rounded spire, side lumps, vertical rock ridges and
	                   green moss crowns. Further rings are bigger, simpler
	                   and paler.
	  Horizon          long, pale mountain ranges fading into the haze.
	  CloudSea         a cloud floor that swallows every mountain's base and
	                   runs out to the horizon, plus drifting cloud puffs
	                   around the island and around the nearer peaks.

	It also tunes Lighting's Atmosphere for a yellow-green distance haze that
	leaves the island itself clear.

	It finds the island by itself: the centre is the median of the map's parts,
	the ground height comes from SpawnLocations, and the radius is the reach of
	95% of the parts. Override with ISLAND_CENTER / ISLAND_RADIUS /
	CLOUD_LEVEL below. DISTANCE_SCALE pushes everything further out.

	Scenery only:
	  - Every part is Anchored, CanCollide/CanTouch/CanQuery off, CastShadow off
	    and Locked. It can't be walked on, clicked, raycast or selected by
	    accident.
	  - It touches nothing outside its own folder and the Atmosphere. The
	    Atmosphere's previous values are saved as attributes on it.
	  - Re-running replaces only the BackgroundMountains folder. Ctrl+Z undoes
	    the whole build.
	  - Every group is a Persistent-streaming Model, so it all still shows on
	    clients when StreamingEnabled is on.
	  - A tiny client-only Script, CloudSea.CloudPrewarm, fills the cloud sea
	    the moment a player joins. Without it the emitters take about 40
	    seconds to fill up.

	Replacing later: every peak is a Model tagged "BackgroundPeak". Its pivot
	is where it meets the cloud floor, and it has PlaceholderHeight /
	PlaceholderWidth attributes, so a proper karst MeshPart can be scaled to
	those and dropped in at the same pivot.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local SEED = 7310 -- same seed = same layout; change it to reroll

-- nil = auto-detect. ISLAND_CENTER.Y is the island's ground height.
local ISLAND_CENTER: Vector3? = nil
local ISLAND_RADIUS: number? = nil
local CLOUD_LEVEL: number? = nil -- world Y of the cloud sea; nil = CLOUD_DEPTH below the ground
local CLOUD_DEPTH = 120

local DISTANCE_SCALE = 1 -- 1.5 = everything half as far again

local ADD_CLOUD_FLOOR = true
local ADD_CLOUD_PUFFS = true
local PREWARM_CLOUDS = true
-- Multiplies every cloud emitter's rate. About 1,500 soft particles at 1;
-- try 0.6 if low-end phones struggle. (Performance Mode already cuts it to a quarter.)
local CLOUD_DENSITY = 1
-- Roblox's built-in soft smoke puff. Swap in a Creator Store cloud texture for fluffier clouds.
local CLOUD_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local PEAK_TAG = "BackgroundPeak"
local GENERATED_NAME = "BackgroundMountains"

-- gap: studs beyond the island edge. visible: peak height above the cloud sea.
-- detail: 3 = full sculpt ... 0 = mountain-range silhouettes.
-- haze: how far colours are pre-blended toward the haze, for aerial perspective.
local LAYERS = {
	{ name = "Near", count = 9, gap = { 950, 1400 }, visible = { 420, 820 }, spire = 0.6, detail = 3, haze = 0 },
	{ name = "Mid", count = 15, gap = { 1750, 2500 }, visible = { 500, 950 }, spire = 0.55, detail = 2, haze = 0.25 },
	{ name = "Far", count = 22, gap = { 2900, 3900 }, visible = { 560, 1100 }, spire = 0.5, detail = 1, haze = 0.48 },
	{ name = "Horizon", count = 12, gap = { 4400, 5300 }, visible = { 450, 950 }, spire = 0, detail = 0, haze = 0.7 },
}

-- Rings of cloud puffs across the open sea, as studs beyond the island edge.
local CLOUD_RINGS = { { gap = 450, count = 12 }, { gap = 1500, count = 16 }, { gap = 2700, count = 18 } }
local CLOUD_FLOOR_REACH = 6200 -- how far the cloud floor runs beyond the island edge

local ROCK = Color3.fromRGB(128, 138, 122)
local ROCK_LIGHT = Color3.fromRGB(152, 158, 140) -- sunlit ridges
local ROCK_DARK = Color3.fromRGB(106, 116, 104) -- shaded ridges
local ROCK_BASE = Color3.fromRGB(102, 116, 106) -- low rock in the clouds' shade
local MOSS = { Color3.fromRGB(78, 128, 56), Color3.fromRGB(100, 146, 60), Color3.fromRGB(64, 110, 60) }
local HAZE_TINT = Color3.fromRGB(188, 214, 198)
local CLOUD_COLOR = Color3.fromRGB(240, 247, 242)
local CLOUD_FLOOR_COLOR = Color3.fromRGB(206, 225, 215)

local ATMOSPHERE = {
	Density = 0.33, -- low enough that the island (a few hundred studs) stays crisp
	Offset = 0.3, -- pushes the haze toward the horizon
	Color = Color3.fromRGB(199, 225, 176), -- yellow-green horizon glow
	Decay = Color3.fromRGB(104, 150, 128), -- teal-green away from the sun
	Glare = 0.35,
	Haze = 2.4,
}

local PREWARM_SOURCE = [[
-- Generated by BuildBackgroundMountains (client only). Fills the cloud sea as
-- soon as a player joins; the emitters would otherwise take ~40 s to fill up.
for _, emitter in script.Parent:GetDescendants() do
	if emitter:IsA("ParticleEmitter") then
		local lifetime = (emitter.Lifetime.Min + emitter.Lifetime.Max) / 2
		emitter:Emit(math.max(1, math.round(emitter.Rate * lifetime * 0.8)))
	end
end
]]

--------------------------------------------------------------------------------
-- State and basic helpers
--------------------------------------------------------------------------------

-- A peak's ellipsoid in the peak's local space (Y up from the cloud sea).
type Lobe = { center: Vector3, size: Vector3, yaw: number }
type PeakInfo = { position: Vector3, topY: number, radius: number }
type CloudSpot = { position: Vector3, radius: number }

local rng = Random.new(SEED)
local center = Vector3.zero -- X/Z = island centre, Y = island ground height
local islandRadius = 300
local cloudY = -CLOUD_DEPTH
local partCount = 0
local emitterCount = 0
local particleEstimate = 0

local function percentile(values: { number }, p: number): number
	table.sort(values)
	return values[math.clamp(math.round(p * #values), 1, #values)]
end

local function detectIsland(): (Vector3, number)
	local parts: { BasePart } = {}
	local xs, ys, zs = {}, {}, {}
	local camera = workspace.CurrentCamera
	for _, descendant in workspace:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and not descendant:IsA("Terrain")
			and not (camera and descendant:IsDescendantOf(camera))
		then
			table.insert(parts, descendant)
			table.insert(xs, descendant.Position.X)
			table.insert(ys, descendant.Position.Y)
			table.insert(zs, descendant.Position.Z)
		end
	end
	if #parts == 0 then
		warn("[BuildBackgroundMountains] No parts found; assuming a 300-stud island at the origin.")
		return Vector3.zero, 300
	end

	local centerX, centerZ = percentile(xs, 0.5), percentile(zs, 0.5)
	local reaches, spawnTops = {}, {}
	for _, part in parts do
		local offset = Vector3.new(part.Position.X - centerX, 0, part.Position.Z - centerZ)
		table.insert(reaches, offset.Magnitude + math.max(part.Size.X, part.Size.Z) / 2)
		if part:IsA("SpawnLocation") then
			table.insert(spawnTops, part.Position.Y + part.Size.Y / 2)
		end
	end

	-- 95th percentile: one huge baseplate or a stray far-away part doesn't inflate it.
	local radius = if #reaches >= 20 then percentile(reaches, 0.95) else percentile(reaches, 1)
	local ground = if #spawnTops > 0 then percentile(spawnTops, 0.5) else percentile(ys, 0.5)
	return Vector3.new(centerX, ground, centerZ), math.clamp(radius, 120, 2000)
end

local function makePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	-- Scenery only: never physical, never hit by clicks or raycasts, never selected by accident.
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false -- also keeps giant shadows off the plots
	part.Locked = true
	part.Parent = parent
	partCount += 1
	return part
end

-- A smooth-shaded ellipsoid of any proportions: a Part with a Sphere SpecialMesh
-- stretches to the Part's Size on every axis.
local function makeEllipsoid(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local limit = 2040 -- Parts max out at 2048 studs per axis
	local clamped = Vector3.new(math.min(size.X, limit), math.min(size.Y, limit), math.min(size.Z, limit))
	local part = makePart(parent, name, clamped, cframe, color)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

-- Blend toward the haze colour for depth, plus a little random brightness so
-- no two rocks match.
local function shade(color: Color3, haze: number): Color3
	local tinted = color:Lerp(HAZE_TINT, haze)
	local jitter = rng:NextNumber(-0.03, 0.03)
	return Color3.new(
		math.clamp(tinted.R + jitter, 0, 1),
		math.clamp(tinted.G + jitter, 0, 1),
		math.clamp(tinted.B + jitter, 0, 1)
	)
end

local function range(bounds: { number }): number
	return rng:NextNumber(bounds[1], bounds[2])
end

local function direction(angle: number): Vector3
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

local function makeGroup(parent: Instance, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	-- With StreamingEnabled, parts this far away would never stream in.
	-- Persistent models are always sent to every client.
	pcall(function()
		(model :: any).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	model.Parent = parent
	return model
end

--------------------------------------------------------------------------------
-- Karst peaks
--------------------------------------------------------------------------------

-- Half-width of a lobe at local height y; uses its narrower side so anything
-- placed on the surface stays attached. 0 above or below the lobe.
local function halfWidthAt(lobe: Lobe, y: number): number
	local d = (y - lobe.center.Y) / (lobe.size.Y / 2)
	if math.abs(d) >= 1 then
		return 0
	end
	return math.min(lobe.size.X, lobe.size.Z) / 2 * math.sqrt(1 - d * d)
end

local function topOf(lobe: Lobe): number
	return lobe.center.Y + lobe.size.Y / 2
end

type Sculptor = {
	add: (name: string, center: Vector3, size: Vector3, color: Color3) -> Lobe,
	crown: (lobe: Lobe, thickness: number, lip: number, color: Color3) -> (),
}

-- Adds ellipsoids to `model` in the local space of `frame` (the peak's base on
-- the cloud sea, including its lean).
local function newSculptor(model: Model, frame: CFrame): Sculptor
	local function add(name: string, lobeCenter: Vector3, size: Vector3, color: Color3): Lobe
		local lobe = { center = lobeCenter, size = size, yaw = rng:NextNumber(0, math.pi * 2) }
		makeEllipsoid(model, name, size, frame * CFrame.new(lobeCenter) * CFrame.Angles(0, lobe.yaw, 0), color)
		return lobe
	end

	-- A green cap hugging the top of `lobe`. `lip` (e.g. 1.05) makes it overhang
	-- slightly, like vegetation spilling over the edge.
	local function crown(lobe: Lobe, thickness: number, lip: number, color: Color3)
		local depth = lobe.size.Y / 2 * thickness
		local rimY = topOf(lobe) - depth
		local d = (rimY - lobe.center.Y) / (lobe.size.Y / 2)
		local widthFraction = math.sqrt(math.max(1 - d * d, 0))
		local size = Vector3.new(lobe.size.X * widthFraction * lip, depth * 2.3, lobe.size.Z * widthFraction * lip)
		local capCenter = Vector3.new(lobe.center.X, rimY + depth * 0.3, lobe.center.Z)
		makeEllipsoid(model, "Moss", size, frame * CFrame.new(capCenter) * CFrame.Angles(0, lobe.yaw, 0), color)
	end

	return { add = add, crown = crown }
end

local function moss(haze: number): Color3
	return shade(MOSS[rng:NextInteger(1, #MOSS)], haze)
end

--[[
	A tapering stack of lobes: the basic karst tower.

	Each lobe is narrower than the one below, and its widest point sits about
	three-quarters of the way up that lower lobe. The silhouette therefore
	steps inward in rounded bulges, like the towers in the reference art,
	instead of pinching into "snowman" necks. The stack is laid out with a
	unit-height bottom lobe, then scaled so its summit lands exactly on `top`.
]]
local function buildStack(
	sculpt: Sculptor,
	prefix: string,
	origin: Vector3, -- local X/Z of the stack's axis
	lobeCount: number,
	baseRadius: number,
	top: number,
	bottomCenterY: number,
	taper: { number },
	lean: Vector3,
	haze: number
): { Lobe }
	local layout = {}
	local centerY, halfHeight, halfWidth, drift = 0, 1, baseRadius, Vector3.zero
	for index = 1, lobeCount do
		layout[index] = { centerY = centerY, halfHeight = halfHeight, halfWidth = halfWidth, drift = drift }
		centerY += halfHeight * rng:NextNumber(0.65, 0.8)
		halfHeight *= rng:NextNumber(0.7, 0.92)
		halfWidth *= rng:NextNumber(taper[1], taper[2])
		drift += lean * halfWidth * rng:NextNumber(0, 0.3) -- towers drift a little as they rise
	end

	local last = layout[lobeCount]
	local scale = (top - bottomCenterY) / (last.centerY + last.halfHeight)
	local lobes = {}
	for index, lobe in layout do
		local size = Vector3.new(
			lobe.halfWidth * 2 * rng:NextNumber(0.92, 1.05),
			lobe.halfHeight * 2 * scale,
			lobe.halfWidth * 2 * rng:NextNumber(0.8, 1)
		)
		local lobeCenter = origin + lobe.drift + Vector3.new(0, bottomCenterY + lobe.centerY * scale, 0)
		-- Low lobes sit in the clouds' shade; higher ones catch the light.
		local tone = ROCK_BASE:Lerp(ROCK, (index - 1) / math.max(lobeCount - 1, 1))
		lobes[index] = sculpt.add(`{prefix}{index}`, lobeCenter, size, shade(tone, haze))
	end
	return lobes
end

--[[
	One karst peak, in local space with Y = 0 on the cloud sea:

	  Rock1..4    the main tower: a tapering stack (spires are tall and narrow,
	              domes broad and conical)
	  Buttress    smaller towers fused to its base, for the clustered look
	  Ridge       thin, tall ellipsoids set into the surface, a shade lighter
	              or darker, for the vertical streaks of eroded limestone
	  Moss        a thick crown on every summit, a ring on every ledge where
	              the stack steps in, and clumps on the upper slopes
]]
local function buildPeak(parent: Instance, layer: any, name: string, base: Vector3): PeakInfo
	local model = Instance.new("Model")
	model.Name = name

	local detail = layer.detail
	local haze = layer.haze
	local spire = rng:NextNumber() < layer.spire
	local visible = range(layer.visible)
	local radius = visible / (if spire then rng:NextNumber(3.2, 4.6) else rng:NextNumber(1.9, 2.7))
	local tilt = math.rad(rng:NextNumber(0, if spire then 5 else 2.5))
	local frame = CFrame.new(base) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0) * CFrame.Angles(tilt, 0, 0)
	local sculpt = newSculptor(model, frame)
	local lean = direction(rng:NextNumber(0, math.pi * 2))

	local main = buildStack(
		sculpt,
		"Rock",
		Vector3.zero,
		if spire then rng:NextInteger(3, 4) else rng:NextInteger(2, 3),
		radius,
		visible,
		visible * rng:NextNumber(-0.12, 0.05), -- the widest lobe meets the clouds
		if spire then { 0.66, 0.8 } else { 0.55, 0.72 },
		lean,
		haze
	)
	local summit = main[#main]

	if detail >= 1 then
		sculpt.crown(summit, rng:NextNumber(0.25, 0.38), 1.06, moss(haze))
	end
	if detail >= 2 then
		-- The next lobe up covers the middle of each lower crown, leaving a
		-- green band along the ledge.
		for index = 1, #main - 1 do
			sculpt.crown(main[index], rng:NextNumber(0.2, 0.28), 1.03, moss(haze))
		end
		-- Lumps of vegetation round the summit break up its smooth dome.
		local axis = Vector3.new(summit.center.X, 0, summit.center.Z)
		for _ = 1, rng:NextInteger(2, 4) do
			local y = topOf(summit) - summit.size.Y / 2 * rng:NextNumber(0.15, 0.45)
			local rim = halfWidthAt(summit, y)
			local size = rim * rng:NextNumber(0.35, 0.6)
			local offset = axis + direction(rng:NextNumber(0, math.pi * 2)) * rim * rng:NextNumber(0.7, 0.95)
			sculpt.add("Moss", offset + Vector3.new(0, y, 0), Vector3.new(size * 2, size * 1.3, size * 2), moss(haze))
		end
	end

	local buttressCount = if detail >= 3
		then rng:NextInteger(2, 3)
		elseif detail == 2 then rng:NextInteger(1, 2)
		else rng:NextInteger(0, 1)
	for index = 1, buttressCount do
		local height = visible * rng:NextNumber(0.3, 0.62)
		local offset = direction(rng:NextNumber(0, math.pi * 2)) * radius * rng:NextNumber(0.7, 1.05)
		local buttress = buildStack(
			sculpt,
			`Buttress{index}_`,
			offset,
			rng:NextInteger(2, 3),
			radius * rng:NextNumber(0.45, 0.7),
			height,
			height * rng:NextNumber(-0.2, 0),
			{ 0.6, 0.78 },
			lean,
			haze
		)
		if detail >= 2 then
			sculpt.crown(buttress[#buttress], rng:NextNumber(0.3, 0.45), 1.05, moss(haze))
		end
	end

	local ridgeCount = if detail >= 3 then rng:NextInteger(5, 8) elseif detail == 2 then rng:NextInteger(2, 4) else 0
	for index = 1, ridgeCount do
		-- Kept within the lobe's widest band, so a ridge never sticks out of the
		-- silhouette as a needle.
		local lobe = main[rng:NextInteger(1, math.max(#main - 1, 1))]
		local height = lobe.size.Y * rng:NextNumber(0.35, 0.6)
		local centerY = lobe.center.Y + lobe.size.Y * 0.3 - height / 2
		local axis = Vector3.new(lobe.center.X, 0, lobe.center.Z)
		local offset = axis
			+ direction(rng:NextNumber(0, math.pi * 2)) * halfWidthAt(lobe, centerY) * rng:NextNumber(0.86, 0.94)
		local width = radius * rng:NextNumber(0.12, 0.22)
		sculpt.add(
			`Ridge{index}`,
			offset + Vector3.new(0, centerY, 0),
			Vector3.new(width, height, width),
			shade(if index % 2 == 0 then ROCK_DARK else ROCK_LIGHT, haze)
		)
	end

	if detail >= 3 then
		for _ = 1, rng:NextInteger(3, 6) do
			local lobe = main[rng:NextInteger(math.max(#main - 1, 1), #main)]
			local y = lobe.center.Y + lobe.size.Y / 2 * rng:NextNumber(-0.2, 0.6)
			local size = radius * rng:NextNumber(0.14, 0.26)
			local axis = Vector3.new(lobe.center.X, 0, lobe.center.Z)
			local offset = axis + direction(rng:NextNumber(0, math.pi * 2)) * halfWidthAt(lobe, y) * 0.95
			sculpt.add("Moss", offset + Vector3.new(0, y, 0), Vector3.new(size * 2, size * 1.2, size * 2), moss(haze))
		end
	end

	-- Pivot on the cloud sea + size attributes: everything a replacement mesh needs.
	model.WorldPivot = CFrame.new(base)
	model:SetAttribute("Layer", layer.name)
	model:SetAttribute("PlaceholderHeight", math.round(visible))
	model:SetAttribute("PlaceholderWidth", math.round(radius * 2))
	CollectionService:AddTag(model, PEAK_TAG)
	model.Parent = parent

	local summitPosition = frame * Vector3.new(summit.center.X, topOf(summit), summit.center.Z)
	return { position = summitPosition, topY = summitPosition.Y, radius = radius * 0.7 }
end

-- A pale mountain range for the horizon: 3-6 overlapping domes along the
-- horizon line, the tallest somewhere in the middle.
local function buildRange(parent: Instance, layer: any, name: string, base: Vector3, tangent: Vector3): { PeakInfo }
	local model = Instance.new("Model")
	model.Name = name
	local tallest = range(layer.visible)
	local domes = rng:NextInteger(3, 6)
	local length = tallest * rng:NextNumber(1.2, 2.2)
	local summitIndex = rng:NextInteger(2, domes - 1)
	local peaks: { PeakInfo } = {}

	for index = 1, domes do
		local along = ((index - 1) / (domes - 1) - 0.5 + rng:NextNumber(-0.08, 0.08)) * length
		local height = tallest * (if index == summitIndex then 1 else rng:NextNumber(0.45, 0.85))
		local width = height * rng:NextNumber(0.55, 0.9)
		local position = base + tangent * along + Vector3.new(0, -height * 0.05, 0)
		makeEllipsoid(
			model,
			`Dome{index}`,
			Vector3.new(width, height * 1.9, width * rng:NextNumber(0.7, 1)),
			CFrame.new(position) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
			shade(if index == summitIndex then ROCK else ROCK_BASE, layer.haze)
		)
		table.insert(peaks, { position = position, topY = position.Y + height * 0.95, radius = width * 0.4 })
	end

	model.WorldPivot = CFrame.new(base)
	model:SetAttribute("Layer", layer.name)
	model:SetAttribute("PlaceholderHeight", math.round(tallest))
	model:SetAttribute("PlaceholderWidth", math.round(length))
	CollectionService:AddTag(model, PEAK_TAG)
	model.Parent = parent
	return peaks
end

-- One peak per sector, at a random spot inside it: even coverage all the way
-- round without a visible pattern. Low-frequency noise pushes the ring in and
-- out so it never reads as a circle.
local function buildLayer(root: Instance, layerIndex: number, layer: any, cloudSpots: { CloudSpot }): { PeakInfo }
	local group = makeGroup(root, layer.name)
	local peaks: { PeakInfo } = {}
	local sector = math.pi * 2 / layer.count
	local phase = rng:NextNumber(0, sector) -- layers don't line up with each other
	local gapMin, gapMax = layer.gap[1] * DISTANCE_SCALE, layer.gap[2] * DISTANCE_SCALE

	for index = 1, layer.count do
		local angle = phase + (index - 1 + rng:NextNumber(0.15, 0.85)) * sector
		local wobble = math.noise(math.cos(angle) * 1.5, math.sin(angle) * 1.5, SEED % 997 + layerIndex * 17.3)
		local t = math.clamp(0.2 + rng:NextNumber() * 0.6 + wobble, 0, 1)
		local distance = islandRadius + gapMin + (gapMax - gapMin) * t
		local flat = center + direction(angle) * distance
		local base = Vector3.new(flat.X, cloudY, flat.Z)
		local name = `{layer.name}_{index}`

		if layer.detail == 0 then
			local tangent = direction(angle + math.pi / 2)
			for _, peak in buildRange(group, layer, name, base, tangent) do
				table.insert(peaks, peak)
			end
		else
			local peak = buildPeak(group, layer, name, base)
			table.insert(peaks, peak)
			if layer.detail >= 2 then
				table.insert(cloudSpots, { position = base, radius = peak.radius / 0.7 })
			end
		end
	end
	return peaks
end

--------------------------------------------------------------------------------
-- Cloud sea
--------------------------------------------------------------------------------

-- An invisible box that breathes slow, soft cloud puffs.
local function cloudEmitter(parent: Instance, name: string, position: Vector3, width: number, rate: number)
	local part = makePart(parent, name, Vector3.new(width, 40, width), CFrame.new(position), CLOUD_COLOR)
	part.Transparency = 1

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = CLOUD_TEXTURE
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rate = rate * CLOUD_DENSITY
	emitter.Lifetime = NumberRange.new(30, 45)
	emitter.Speed = NumberRange.new(0.3, 1.2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-2, 2)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 60, 15),
		NumberSequenceKeypoint.new(1, 100), -- 100 studs is the particle size limit
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.35),
		NumberSequenceKeypoint.new(0.75, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(CLOUD_COLOR)
	emitter.LightEmission = 0.1
	emitter.LightInfluence = 0.7
	emitter.Parent = part

	emitterCount += 1
	particleEstimate += rate * CLOUD_DENSITY * 37.5 -- rate x average lifetime
end

local function buildCloudSea(root: Instance, cloudSpots: { CloudSpot })
	local group = makeGroup(root, "CloudSea")

	if ADD_CLOUD_FLOOR then
		-- A solid cloud floor, tiled because parts max out at 2048 studs. It hides
		-- every mountain's base and fades into the haze at the horizon.
		local reach = islandRadius + CLOUD_FLOOR_REACH * DISTANCE_SCALE
		local tile = 2048
		local tiles = math.ceil(reach * 2 / tile)
		local first = -(tiles - 1) * tile / 2
		for ix = 0, tiles - 1 do
			for iz = 0, tiles - 1 do
				local offset = Vector3.new(first + ix * tile, 0, first + iz * tile)
				-- Skip corner tiles that lie entirely outside the circle.
				local nearest = Vector3.new(
					math.max(math.abs(offset.X) - tile / 2, 0),
					0,
					math.max(math.abs(offset.Z) - tile / 2, 0)
				)
				if nearest.Magnitude <= reach then
					local position = Vector3.new(center.X + offset.X, cloudY - 1, center.Z + offset.Z)
					makePart(
						group,
						`Floor{ix}_{iz}`,
						Vector3.new(tile, 2, tile),
						CFrame.new(position),
						CLOUD_FLOOR_COLOR
					)
				end
			end
		end
	end

	if ADD_CLOUD_PUFFS then
		local puffY = cloudY + 15

		-- Two rows of clouds hugging the island's edge.
		for row, skirt in { { gap = 120, rate = 0.45 }, { gap = 320, rate = 0.3 } } do
			local skirtRadius = islandRadius + skirt.gap
			local count = math.clamp(math.round(math.pi * 2 * skirtRadius / 170), 10, 28)
			for index = 1, count do
				local angle = (index - 1 + rng:NextNumber(-0.3, 0.3)) / count * math.pi * 2
				local flat = center + direction(angle) * (skirtRadius + rng:NextNumber(-60, 60))
				cloudEmitter(group, `Skirt{row}_{index}`, Vector3.new(flat.X, puffY, flat.Z), 280, skirt.rate)
			end
		end

		-- Clouds wrapped around the bases of the nearer peaks, so they rise out
		-- of the sea instead of sitting on it.
		for index, spot in cloudSpots do
			local position = Vector3.new(spot.position.X, puffY, spot.position.Z)
			local rate = math.clamp(spot.radius / 250, 0.35, 0.9)
			cloudEmitter(group, `PeakBase{index}`, position, math.min(spot.radius * 4.5, 1600), rate)
		end

		-- Loose rings across the open sea, so the floor has texture all the way out.
		for ringIndex, ring in CLOUD_RINGS do
			local distance = islandRadius + ring.gap * DISTANCE_SCALE
			local phase = rng:NextNumber(0, math.pi * 2)
			for index = 1, ring.count do
				local angle = phase + (index - 1 + rng:NextNumber(-0.3, 0.3)) / ring.count * math.pi * 2
				local flat = center + direction(angle) * (distance + rng:NextNumber(-150, 150))
				cloudEmitter(group, `Sea{ringIndex}_{index}`, Vector3.new(flat.X, puffY, flat.Z), 800, 0.3)
			end
		end

		if PREWARM_CLOUDS then
			local prewarm = Instance.new("Script")
			prewarm.Name = "CloudPrewarm"
			prewarm.RunContext = Enum.RunContext.Client
			prewarm.Source = PREWARM_SOURCE
			prewarm.Parent = group
		end
	end
end

--------------------------------------------------------------------------------
-- Atmosphere
--------------------------------------------------------------------------------

local function applyAtmosphere()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	for property, value in ATMOSPHERE do
		-- Keep the values from before the first run, so they can be put back by hand.
		local key = `Original{property}`
		if atmosphere:GetAttribute(key) == nil then
			atmosphere:SetAttribute(key, (atmosphere :: any)[property])
		end
		(atmosphere :: any)[property] = value
	end
end

--------------------------------------------------------------------------------
-- Player's-eye check
--------------------------------------------------------------------------------

-- From head height at the island centre, look every 5 degrees round the
-- horizon and find the tallest peak in that direction. Reports the average
-- rise and the widest stretch of open sky, so gaps show up without having to look.
local function reportSightlines(peaks: { PeakInfo })
	local eye = center + Vector3.new(0, 6, 0)
	local elevations = {}
	for step = 0, 71 do
		local azimuth = step * 5
		local best = -90
		for _, peak in peaks do
			local offset = Vector3.new(peak.position.X - eye.X, 0, peak.position.Z - eye.Z)
			local distance = offset.Magnitude
			local peakAzimuth = math.deg(math.atan2(offset.Z, offset.X))
			local difference = math.abs((azimuth - peakAzimuth + 540) % 360 - 180)
			if difference <= math.deg(math.atan(peak.radius / distance)) then
				best = math.max(best, math.deg(math.atan((peak.topY - eye.Y) / distance)))
			end
		end
		elevations[step + 1] = best
	end

	local run, widestGap, total = 0, 0, 0
	for index = 1, #elevations * 2 do -- twice round, so a gap across 0 degrees counts once
		if elevations[(index - 1) % #elevations + 1] < 4 then
			run += 1
			widestGap = math.max(widestGap, math.min(run, #elevations))
		else
			run = 0
		end
	end
	for _, elevation in elevations do
		total += math.max(elevation, 0)
	end
	print(
		`[BuildBackgroundMountains] From the island centre: peaks rise {math.round(total / #elevations)} degrees `
			.. `above the horizon on average; widest open sky is {widestGap * 5} degrees.`
	)
	if widestGap * 5 > 30 then
		warn("[BuildBackgroundMountains] That gap is wide; raise a layer's count or change SEED.")
	end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function build()
	local environment = workspace:FindFirstChild("Environment")
	if not environment then
		environment = Instance.new("Folder")
		environment.Name = "Environment"
		environment.Parent = workspace
	end
	local previous = environment:FindFirstChild(GENERATED_NAME)
	if previous then
		previous:Destroy() -- only our own folder; the rest of Environment is untouched
	end

	local detectedCenter, detectedRadius = detectIsland()
	center = ISLAND_CENTER or detectedCenter
	islandRadius = ISLAND_RADIUS or detectedRadius
	cloudY = CLOUD_LEVEL or center.Y - CLOUD_DEPTH

	local root = Instance.new("Folder")
	root.Name = GENERATED_NAME
	root:SetAttribute("Seed", SEED)

	local allPeaks: { PeakInfo } = {}
	local cloudSpots: { CloudSpot } = {}
	for layerIndex, layer in LAYERS do
		for _, peak in buildLayer(root, layerIndex, layer, cloudSpots) do
			table.insert(allPeaks, peak)
		end
	end
	buildCloudSea(root, cloudSpots)
	root.Parent = environment
	applyAtmosphere()

	print(
		`[BuildBackgroundMountains] Island centre ({math.round(center.X)}, {math.round(center.Z)}), `
			.. `ground Y {math.round(center.Y)}, radius {math.round(islandRadius)} studs; `
			.. `cloud sea at Y {math.round(cloudY)}.`
	)
	print(
		`[BuildBackgroundMountains] Built {#allPeaks} peaks and {emitterCount} cloud emitters from {partCount} parts `
			.. `(about {math.round(particleEstimate)} cloud particles at once).`
	)
	reportSightlines(allPeaks)
end

if RunService:IsRunning() then
	warn("[BuildBackgroundMountains] Stop the play test first; changes made while playing are thrown away.")
	return
end

local recording: string? = nil
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build background mountains")
end)

local ok, err = xpcall(build, debug.traceback)
if recording then
	-- On failure, Cancel rolls back everything this run changed.
	ChangeHistoryService:FinishRecording(
		recording,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
end
if not ok then
	warn(`[BuildBackgroundMountains] Failed; changes rolled back.\n{err}`)
end
