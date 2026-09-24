--[[
	BuildBackgroundMountains (Studio Command Bar script)

	Paste into View > Command Bar in Roblox Studio, in Edit mode (not while
	play-testing), and press Enter.

	What it builds, under Workspace.Environment.BackgroundMountains:
	  Midground     cliff pillars with moss caps, tree tufts, a few waterfalls
	                and low foothills in the valley below the island
	  Distant       larger, bluer pillars
	  VeryDistant   huge, faded silhouettes near the horizon
	  SkyRibbons    a few glowing ribbon arcs between the distant peaks
	It also tunes Lighting's Atmosphere for a blue-green distance haze that
	leaves the island itself clear.

	It finds the island by itself: the centre is the median of the map's parts,
	the ground height comes from SpawnLocations, and the radius is the reach of
	95% of the parts (so a stray part or a big baseplate doesn't count). Set
	ISLAND_CENTER / ISLAND_RADIUS below to override.

	Scenery only:
	  - Every part is Anchored, CanCollide/CanTouch/CanQuery off, CastShadow off
	    and Locked. It can't be walked on, clicked, raycast or selected by
	    accident.
	  - It touches nothing outside its own folder and the Atmosphere. The
	    Atmosphere's previous values are saved as attributes on it.
	  - Re-running replaces only the BackgroundMountains folder. Ctrl+Z undoes
	    the whole build.
	  - Each layer is a Persistent-streaming Model, so the mountains still show
	    on clients when StreamingEnabled is on.

	Replacing placeholders later: every peak is a Model tagged "BackgroundPeak".
	Its pivot is the base centre, and it has PlaceholderHeight /
	PlaceholderWidth attributes, so a proper cliff MeshPart can be scaled to
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

-- nil = auto-detect. Otherwise ISLAND_CENTER.Y is the island's ground height.
local ISLAND_CENTER: Vector3? = nil
local ISLAND_RADIUS: number? = nil

local BELOW_GROUND = 350 -- peaks reach this far below the island, so their bases sink into the haze
local ADD_SKY_RIBBONS = true
local PEAK_TAG = "BackgroundPeak"
local GENERATED_NAME = "BackgroundMountains"

-- gap: studs beyond the island edge. height: peak height above the island's
-- ground. shrink: each tier's width relative to the tier below.
local LAYERS = {
	{
		name = "Midground",
		short = "Mid",
		count = 16,
		gap = { 200, 420 },
		height = { 170, 360 },
		width = { 55, 115 },
		tiers = { 2, 3 },
		shrink = { 0.7, 0.86 },
		facetChance = 0.3,
		companionChance = 0.3,
		rockLight = Color3.fromRGB(206, 190, 196),
		rockShade = Color3.fromRGB(148, 138, 164),
		cap = Color3.fromRGB(124, 170, 72),
		tuft = Color3.fromRGB(78, 136, 62),
		tufts = 2,
		waterfalls = 3,
		foothills = 5,
	},
	{
		name = "Distant",
		short = "Far",
		count = 14,
		gap = { 750, 1150 },
		height = { 380, 720 },
		width = { 140, 300 },
		tiers = { 2, 3 },
		shrink = { 0.72, 0.88 },
		facetChance = 0.45,
		companionChance = 0.25,
		rockLight = Color3.fromRGB(164, 174, 202),
		rockShade = Color3.fromRGB(118, 132, 170),
		cap = Color3.fromRGB(88, 146, 122),
		tufts = 0,
		waterfalls = 0,
		foothills = 0,
	},
	{
		name = "VeryDistant",
		short = "Horizon",
		count = 14,
		gap = { 1700, 2400 },
		height = { 650, 1150 },
		width = { 300, 600 },
		tiers = { 1, 2 },
		shrink = { 0.75, 0.9 },
		facetChance = 0.55,
		companionChance = 0.2,
		rockLight = Color3.fromRGB(132, 160, 198),
		rockShade = Color3.fromRGB(106, 136, 178),
		tufts = 0,
		waterfalls = 0,
		foothills = 0,
	},
}

local FOOTHILL_COLOR = Color3.fromRGB(84, 130, 96)
local WATERFALL_COLOR = Color3.fromRGB(186, 236, 250)

local ATMOSPHERE = {
	Density = 0.3, -- low enough that the island (a few hundred studs) stays crisp
	Offset = 0.25, -- pushes the haze toward the horizon
	Color = Color3.fromRGB(166, 206, 220),
	Decay = Color3.fromRGB(78, 128, 150),
	Glare = 0.1,
	Haze = 1.3,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

type PeakInfo = { position: Vector3, topY: number, radius: number }

local rng = Random.new(SEED)
local center = Vector3.zero -- X/Z = island centre, Y = island ground height
local islandRadius = 300
local baseY = -BELOW_GROUND
local partCount = 0

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

local function makePart(
	parent: Instance,
	name: string,
	shape: Enum.PartType,
	size: Vector3,
	cframe: CFrame,
	color: Color3
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
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

-- Blend between two colours, plus a little random brightness so no two rocks match.
local function shade(from: Color3, to: Color3, t: number): Color3
	local color = from:Lerp(to, math.clamp(t, 0, 1))
	local jitter = rng:NextNumber(-0.035, 0.035)
	return Color3.new(
		math.clamp(color.R + jitter, 0, 1),
		math.clamp(color.G + jitter, 0, 1),
		math.clamp(color.B + jitter, 0, 1)
	)
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function direction(angle: number): Vector3
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

local function makeLayerModel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	-- With StreamingEnabled, parts this far away would never stream in.
	-- Persistent models are always sent to every client.
	pcall(function()
		(model :: any).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	return model
end

--------------------------------------------------------------------------------
-- Peaks
--------------------------------------------------------------------------------

-- A stack of 1-3 rock tiers, each narrower and leaning a little, with an
-- optional moss cap, tree tufts and a waterfall facing the island.
local function buildPeak(
	parent: Instance,
	layer: any,
	name: string,
	basePosition: Vector3,
	scale: number,
	decorate: boolean,
	waterfall: boolean
): PeakInfo
	local model = Instance.new("Model")
	model.Name = name

	local height = rng:NextNumber(layer.height[1], layer.height[2]) * scale
	local width = rng:NextNumber(layer.width[1], layer.width[2]) * scale
	local tiers = rng:NextInteger(layer.tiers[1], layer.tiers[2])
	local topY = center.Y + height
	local span = topY - baseY

	-- Split the height into tiers, lower ones a bit taller.
	local weights, totalWeight = {}, 0
	for tier = 1, tiers do
		weights[tier] = rng:NextNumber(0.8, 1.3) * (1 + (tiers - tier) * 0.15)
		totalWeight += weights[tier]
	end

	local lean = flat(Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)))
	lean = if lean.Magnitude > 1e-3 then lean.Unit else Vector3.xAxis

	local tierCenter = flat(basePosition)
	local diameter = width
	local y = baseY
	local topCenter, topDiameter, topTierHeight = tierCenter, diameter, 0

	for tier = 1, tiers do
		local tierHeight = span * weights[tier] / totalWeight
		local partHeight = tierHeight + (if tier < tiers then tierHeight * 0.08 else 0) -- overlap the next tier
		local tilt = CFrame.Angles(
			math.rad(rng:NextNumber(-3, 3)),
			rng:NextNumber(0, math.pi * 2),
			math.rad(rng:NextNumber(-3, 3))
		)
		local cframe = CFrame.new(tierCenter.X, y + partHeight / 2, tierCenter.Z) * tilt
		-- Higher tiers catch more light; the base fades into shade.
		local color = shade(layer.rockShade, layer.rockLight, (tier - 1) / math.max(tiers - 1, 1))
		-- A waterfall needs a round top tier to sit flush against.
		local faceted = not (waterfall and tier == tiers) and rng:NextNumber() < layer.facetChance

		if faceted then
			local size = Vector3.new(diameter, partHeight, diameter * rng:NextNumber(0.7, 0.95))
			makePart(model, `Rock{tier}`, Enum.PartType.Block, size, cframe, color)
		else
			local size = Vector3.new(partHeight, diameter, diameter) -- a cylinder's length runs along X
			makePart(
				model,
				`Rock{tier}`,
				Enum.PartType.Cylinder,
				size,
				cframe * CFrame.Angles(0, 0, math.pi / 2),
				color
			)
		end

		topCenter, topDiameter, topTierHeight = tierCenter, diameter, tierHeight
		y += tierHeight
		diameter *= rng:NextNumber(layer.shrink[1], layer.shrink[2])
		tierCenter += lean * diameter * rng:NextNumber(0.05, 0.14)
	end

	if layer.cap then
		local capHeight = math.clamp(span * 0.04, 8, 40)
		local capDiameter = topDiameter * rng:NextNumber(1.02, 1.12)
		makePart(
			model,
			"Moss",
			Enum.PartType.Cylinder,
			Vector3.new(capHeight, capDiameter, capDiameter),
			CFrame.new(topCenter.X, topY + capHeight * 0.3, topCenter.Z) * CFrame.Angles(0, 0, math.pi / 2),
			shade(layer.cap, layer.cap, 0)
		)

		if decorate and layer.tuft then
			for _ = 1, rng:NextInteger(0, layer.tufts) do
				local size = topDiameter * rng:NextNumber(0.22, 0.4)
				local offset = direction(rng:NextNumber(0, math.pi * 2)) * topDiameter * rng:NextNumber(0.1, 0.35)
				makePart(
					model,
					"Tuft",
					Enum.PartType.Ball,
					Vector3.one * size,
					CFrame.new(topCenter + offset + Vector3.new(0, topY + size * 0.25, 0)),
					shade(layer.tuft, layer.cap, rng:NextNumber())
				)
			end
		end
	end

	if waterfall then
		local toIsland = flat(center - topCenter).Unit
		local fallWidth = math.clamp(topDiameter * 0.14, 6, 18)
		local fallHeight = topTierHeight * 0.85
		local fallCenter = topCenter + toIsland * (topDiameter / 2 + 0.6) + Vector3.new(0, topY - fallHeight / 2, 0)
		local fall = makePart(
			model,
			"Waterfall",
			Enum.PartType.Block,
			Vector3.new(fallWidth, fallHeight, 1.2),
			CFrame.lookAt(fallCenter, fallCenter + toIsland),
			WATERFALL_COLOR
		)
		fall.Transparency = 0.2
	end

	-- Pivot at the base centre + size attributes: everything a replacement mesh needs.
	model.WorldPivot = CFrame.new(basePosition.X, baseY, basePosition.Z)
	model:SetAttribute("Layer", layer.name)
	model:SetAttribute("PlaceholderHeight", math.round(span))
	model:SetAttribute("PlaceholderWidth", math.round(width))
	CollectionService:AddTag(model, PEAK_TAG)
	model.Parent = parent

	return { position = Vector3.new(topCenter.X, topY, topCenter.Z), topY = topY, radius = width * 0.4 }
end

local function buildFoothills(parent: Instance, layer: any)
	for index = 1, layer.foothills do
		local distance = islandRadius + rng:NextNumber(layer.gap[1] * 0.7, layer.gap[2])
		local position = center + direction(rng:NextNumber(0, math.pi * 2)) * distance
		local diameter = rng:NextNumber(180, 320)
		-- Tops stay below the island's ground so they read as a valley, not a new area.
		local top = center.Y - rng:NextNumber(15, 60)
		makePart(
			parent,
			`Foothill{index}`,
			Enum.PartType.Ball,
			Vector3.one * diameter,
			CFrame.new(position.X, top - diameter / 2, position.Z),
			shade(FOOTHILL_COLOR, layer.cap, rng:NextNumber(0, 0.4))
		)
	end
end

local function buildLayer(root: Instance, layerIndex: number, layer: any): { PeakInfo }
	local model = makeLayerModel(layer.name)
	local peaks: { PeakInfo } = {}
	local sector = math.pi * 2 / layer.count
	local phase = rng:NextNumber(0, sector) -- layers don't line up with each other
	local waterfallsLeft = layer.waterfalls
	local gapMin, gapMax = layer.gap[1], layer.gap[2]

	for index = 1, layer.count do
		-- One peak per sector, at a random spot inside it: even coverage all the
		-- way round without a visible pattern.
		local angle = phase + (index - 1 + rng:NextNumber(0.15, 0.85)) * sector
		-- Low-frequency noise pushes the ring in and out so it doesn't read as a circle.
		local wobble = math.noise(math.cos(angle) * 1.5, math.sin(angle) * 1.5, SEED % 997 + layerIndex * 17.3)
		local t = math.clamp(0.2 + rng:NextNumber() * 0.6 + wobble, 0, 1)
		local distance = islandRadius + gapMin + (gapMax - gapMin) * t
		local position = center + direction(angle) * distance

		local waterfall = waterfallsLeft > 0 and (rng:NextNumber() < 0.3 or layer.count - index < waterfallsLeft)
		if waterfall then
			waterfallsLeft -= 1
		end
		table.insert(peaks, buildPeak(model, layer, `{layer.short}_{index}`, position, 1, true, waterfall))

		-- Sometimes a smaller companion beside it breaks up the rhythm.
		if rng:NextNumber() < layer.companionChance then
			local side = if rng:NextNumber() < 0.5 then -1 else 1
			local companionAngle = angle + side * sector * rng:NextNumber(0.18, 0.3)
			local companionDistance = distance + (gapMax - gapMin) * rng:NextNumber(-0.15, 0.25)
			local companionPosition = center + direction(companionAngle) * companionDistance
			local companionScale = rng:NextNumber(0.55, 0.75)
			local companion =
				buildPeak(model, layer, `{layer.short}_{index}b`, companionPosition, companionScale, false, false)
			table.insert(peaks, companion)
		end
	end

	buildFoothills(model, layer)
	model.Parent = root
	return peaks
end

--------------------------------------------------------------------------------
-- Sky ribbons
--------------------------------------------------------------------------------

-- Glowing curved Beams strung between neighbouring distant peaks.
-- PerformanceController turns Beams off in Performance Mode.
local function buildRibbons(root: Instance, peaks: { PeakInfo })
	if #peaks < 2 then
		return
	end
	table.sort(peaks, function(a, b)
		return math.atan2(a.position.Z - center.Z, a.position.X - center.X)
			< math.atan2(b.position.Z - center.Z, b.position.X - center.X)
	end)

	local model = makeLayerModel("SkyRibbons")
	local holder = makePart(model, "RibbonAnchor", Enum.PartType.Block, Vector3.one, CFrame.new(center), Color3.new())
	holder.Transparency = 1

	local function anchor(peak: PeakInfo): Attachment
		local height = center.Y + (peak.topY - center.Y) * rng:NextNumber(0.4, 0.7)
		-- Start just in front of the rock (island side) so the ribbon isn't hidden inside it.
		local toIsland = flat(center - peak.position).Unit
		local position = Vector3.new(peak.position.X, height, peak.position.Z) + toIsland * peak.radius * 1.6
		local attachment = Instance.new("Attachment")
		-- Beams curve along the attachment's X axis; point it up.
		attachment.WorldCFrame = CFrame.fromMatrix(position, Vector3.yAxis, toIsland)
		attachment.Parent = holder
		return attachment
	end

	for ribbon = 1, 3 do
		local first = math.floor((ribbon - 1) * #peaks / 3) + 1
		local beam = Instance.new("Beam")
		beam.Name = `Ribbon{ribbon}`
		beam.Attachment0 = anchor(peaks[first])
		beam.Attachment1 = anchor(peaks[first % #peaks + 1])
		beam.Texture = "" -- solid ribbon, no asset needed
		beam.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 230, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 150, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 110, 255)),
		})
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0.35),
			NumberSequenceKeypoint.new(0.85, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.Width0 = rng:NextNumber(60, 90)
		beam.Width1 = rng:NextNumber(30, 50)
		beam.CurveSize0 = rng:NextNumber(250, 450)
		beam.CurveSize1 = -rng:NextNumber(150, 350)
		beam.Segments = 40
		beam.FaceCamera = true
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Parent = holder
	end
	model.Parent = root
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
-- horizon and find the tallest peak in that direction. Reports the widest
-- stretch of empty sky, so gaps show up without having to look.
local function reportSightlines(peaks: { PeakInfo })
	local eye = center + Vector3.new(0, 6, 0)
	local elevations = {}
	for step = 0, 71 do
		local azimuth = step * 5
		local best = -90
		for _, peak in peaks do
			local offset = flat(peak.position - eye)
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
	baseY = center.Y - BELOW_GROUND

	local root = Instance.new("Folder")
	root.Name = GENERATED_NAME
	root:SetAttribute("Seed", SEED)

	local allPeaks: { PeakInfo } = {}
	local distantPeaks: { PeakInfo } = {}
	for layerIndex, layer in LAYERS do
		local peaks = buildLayer(root, layerIndex, layer)
		for _, peak in peaks do
			table.insert(allPeaks, peak)
		end
		if layer.name == "Distant" then
			distantPeaks = peaks
		end
	end
	if ADD_SKY_RIBBONS then
		buildRibbons(root, table.clone(distantPeaks))
	end
	root.Parent = environment
	applyAtmosphere()

	print(
		`[BuildBackgroundMountains] Island centre ({math.round(center.X)}, {math.round(center.Z)}), `
			.. `ground Y {math.round(center.Y)}, radius {math.round(islandRadius)} studs.`
	)
	print(
		`[BuildBackgroundMountains] Built {#allPeaks} peaks from {partCount} parts in Workspace.Environment.{GENERATED_NAME}.`
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
