--[[
	BuildBackgroundMountains (Studio Command Bar script)

	Paste into View > Command Bar in Roblox Studio, in Edit mode (not while
	play-testing), and press Enter.

	Builds a sunset-pink world of sharp, jagged peaks around the island, under
	Workspace.Environment.BackgroundMountains:

	  Near, Mid, Far   rings of faceted low-poly mountains: steep karst spires
	                   and broad pointed peaks, with jagged spurs and smaller
	                   peaks fused to their flanks
	  Horizon          long, saw-toothed ranges fading into the haze
	  CloudSea         a peach-pink cloud floor that swallows every base and
	                   runs to the horizon, plus drifting puffs around the
	                   island and the nearer peaks

	Every mountain face is a flat triangle, built from two thin WedgeParts, so
	ridges and summits are crisp. The colours are painted onto the faces,
	so the pink look doesn't depend on the game's lighting:
	  - faces turned toward your sun are peach-coral, faces turned away are
	    mauve
	  - high, upward-facing faces glow pale pink, and low slopes sink into plum
	  - further rings blend toward the pink haze
	Nothing in Lighting (time of day, sun, sky, brightness) is changed. The
	only exception is the Atmosphere haze colour, and only while
	CHANGE_ATMOSPHERE is true.

	Faces the island can never see (the far sides of mountains, below the
	clouds) aren't built at all, which roughly halves the part count.

	It finds the island by itself: the centre is the median of the map's parts,
	the ground height comes from SpawnLocations, and the radius is the reach of
	95% of the parts. Override with ISLAND_CENTER / ISLAND_RADIUS /
	CLOUD_LEVEL below. DISTANCE_SCALE pushes everything further out.

	Scenery only:
	  - Every part is Anchored, CanCollide/CanTouch/CanQuery off, CastShadow off
	    and Locked. It can't be walked on, clicked, raycast or selected by
	    accident.
	  - Re-running replaces only the BackgroundMountains folder. Ctrl+Z undoes
	    the whole build.
	  - Every group is a Persistent-streaming Model, so it all still shows on
	    clients when StreamingEnabled is on.
	  - A tiny client-only Script, CloudSea.CloudPrewarm, fills the cloud sea
	    the moment a player joins.

	Replacing later: every mountain is a Model tagged "BackgroundPeak". Its
	pivot is where it meets the cloud floor, and it has PlaceholderHeight /
	PlaceholderWidth attributes, so a proper mountain mesh can be scaled to
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

-- true: tint the Atmosphere's distance haze warm pink to match the mountains.
-- false: leave Lighting exactly as the game had it (this also undoes the
-- haze from an earlier run of this script).
local CHANGE_ATMOSPHERE = true

local ADD_CLOUD_FLOOR = true
local ADD_CLOUD_PUFFS = true
local PREWARM_CLOUDS = true
-- Multiplies every cloud emitter's rate. About 1,600 soft particles at 1;
-- try 0.6 if low-end phones struggle. (Performance Mode already cuts it to a quarter.)
local CLOUD_DENSITY = 1
-- Roblox's built-in soft smoke puff. Swap in a Creator Store cloud texture for fluffier clouds.
local CLOUD_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local PEAK_TAG = "BackgroundPeak"
local GENERATED_NAME = "BackgroundMountains"

-- gap: studs beyond the island edge. height: summit height above the cloud sea.
-- spire: chance of a steep karst spire rather than a broad pointed peak.
-- detail: 3 = most facets and side peaks ... 0 = horizon ranges.
-- haze: how far colours are pre-blended toward the haze, for aerial perspective.
local LAYERS = {
	{ name = "Near", count = 9, gap = { 950, 1400 }, height = { 450, 850 }, spire = 0.55, detail = 3, haze = 0 },
	{ name = "Mid", count = 14, gap = { 1750, 2500 }, height = { 520, 980 }, spire = 0.45, detail = 2, haze = 0.28 },
	{ name = "Far", count = 20, gap = { 2900, 3900 }, height = { 600, 1150 }, spire = 0.35, detail = 1, haze = 0.52 },
	{ name = "Horizon", count = 11, gap = { 4400, 5300 }, height = { 500, 1000 }, spire = 0, detail = 0, haze = 0.74 },
}

-- Rings of cloud puffs across the open sea, as studs beyond the island edge.
local CLOUD_RINGS = { { gap = 450, count = 12 }, { gap = 1500, count = 16 }, { gap = 2700, count = 18 } }
local CLOUD_FLOOR_REACH = 6200 -- how far the cloud floor runs beyond the island edge

-- The painted light. Real lighting shades on top of these.
local ROCK_LIT = Color3.fromRGB(238, 164, 138) -- faces toward the sun: peach-coral
local ROCK_SHADOW = Color3.fromRGB(150, 96, 128) -- faces away: magenta-mauve
local ROCK_GLOW = Color3.fromRGB(252, 214, 200) -- high, upward-facing ridges
local ROCK_DEEP = Color3.fromRGB(104, 64, 98) -- low slopes near the clouds
local HAZE_TINT = Color3.fromRGB(236, 172, 170) -- dusty pink distance
local CLOUD_COLOR = Color3.fromRGB(252, 226, 222)
local CLOUD_FLOOR_COLOR = Color3.fromRGB(230, 184, 188)

local ATMOSPHERE = {
	Density = 0.33, -- low enough that the island (a few hundred studs) stays crisp
	Offset = 0.35, -- pushes the haze toward the horizon
	Color = Color3.fromRGB(245, 178, 160), -- peach-pink horizon glow
	Decay = Color3.fromRGB(170, 96, 120), -- rose-mauve away from the sun
	Glare = 0.5,
	Haze = 2.4,
}

local FACE_THICKNESS = 1.5 -- studs; each face is a thin slab
-- Faces pointing further than this from the island (as a dot product) are never
-- seen, so they're skipped. -0.2 leaves margin for players at the island edge.
local CULL_THRESHOLD = -0.2

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

type PeakInfo = { position: Vector3, topY: number, radius: number }
type CloudSpot = { position: Vector3, radius: number }
type Shading = { haze: number, baseY: number, height: number }

local rng = Random.new(SEED)
local center = Vector3.zero -- X/Z = island centre, Y = island ground height
local islandRadius = 300
local cloudY = -CLOUD_DEPTH
local viewPoint = Vector3.zero -- where players look from, for culling hidden faces
local keyLight = Vector3.new(0.8, 0.45, 0.4).Unit -- set from the real sun in build()
local partCount = 0
local faceCount = 0
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

local function makePart(
	parent: Instance,
	className: string,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3
): BasePart
	local part = Instance.new(className) :: BasePart
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
-- Faceted faces
--------------------------------------------------------------------------------

--[[
	Draws triangle abc as two thin WedgeParts (the standard Roblox technique).
	A WedgePart is a right triangle, so the triangle is split along the
	altitude dropped onto its longest side, and each half becomes one wedge.
]]
local function triangle(parent: Instance, a: Vector3, b: Vector3, c: Vector3, color: Color3)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- Relabel so that bc is the longest side and a is the vertex opposite it.
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b

	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-3 or bc.Magnitude < 1e-3 then
		return -- degenerate sliver
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))

	makePart(
		parent,
		"WedgePart",
		"Face",
		Vector3.new(FACE_THICKNESS, height, math.abs(ab:Dot(back))),
		CFrame.fromMatrix((a + b) / 2, right, up, back),
		color
	)
	makePart(
		parent,
		"WedgePart",
		"Face",
		Vector3.new(FACE_THICKNESS, height, math.abs(ac:Dot(back))),
		CFrame.fromMatrix((a + c) / 2, -right, up, -back),
		color
	)
end

-- The painted light for a face, from its outward normal and height.
local function faceColor(normal: Vector3, centroid: Vector3, shading: Shading): Color3
	local lit = math.clamp(normal:Dot(keyLight), 0, 1)
	local color = ROCK_SHADOW:Lerp(ROCK_LIT, lit ^ 0.8)
	local heightFraction = math.clamp((centroid.Y - shading.baseY) / shading.height, 0, 1)
	-- High faces catch a pale glow, strongest where they face up or into the
	-- sun, like sunlit snow on the ridges.
	local glow = math.max(math.clamp((normal.Y - 0.2) / 0.5, 0, 1), lit * 0.5) * heightFraction ^ 1.5
	color = color:Lerp(ROCK_GLOW, glow * 0.7)
	-- Low slopes sink into shadow toward the clouds.
	color = color:Lerp(ROCK_DEEP, (1 - heightFraction) ^ 2 * 0.45)
	-- Distance: blend toward the haze, plus a little per-face variation.
	color = color:Lerp(HAZE_TINT, shading.haze)
	local jitter = rng:NextNumber(-0.025, 0.025)
	return Color3.new(
		math.clamp(color.R + jitter, 0, 1),
		math.clamp(color.G + jitter, 0, 1),
		math.clamp(color.B + jitter, 0, 1)
	)
end

-- Adds face abc if the island can see it. `inside` is any point inside the
-- solid (or, for a one-sided range, behind it), used to orient the normal outward.
local function face(parent: Instance, a: Vector3, b: Vector3, c: Vector3, inside: Vector3, shading: Shading)
	local centroid = (a + b + c) / 3
	local normal = (b - a):Cross(c - a)
	if normal.Magnitude < 1e-3 then
		return
	end
	normal = normal.Unit
	local outward = Vector3.new(centroid.X - inside.X, 0, centroid.Z - inside.Z)
	if normal:Dot(outward) < 0 then
		normal = -normal
	end
	if normal:Dot((viewPoint - centroid).Unit) < CULL_THRESHOLD then
		return -- faces away from the island; nobody will ever see it
	end
	triangle(parent, a, b, c, faceColor(normal, centroid, shading))
	faceCount += 1
end

-- Quad abcd (in order round its edge) as two faces, split along a random
-- diagonal so the facets don't line up.
local function quad(parent: Instance, a: Vector3, b: Vector3, c: Vector3, d: Vector3, inside: Vector3, shading: Shading)
	if rng:NextNumber() < 0.5 then
		face(parent, a, b, c, inside, shading)
		face(parent, a, c, d, inside, shading)
	else
		face(parent, a, b, d, inside, shading)
		face(parent, b, c, d, inside, shading)
	end
end

--------------------------------------------------------------------------------
-- Mountains
--------------------------------------------------------------------------------

--[[
	One jagged peak as a faceted cone:

	  - rings of vertices from just below the clouds to near the top, each
	    ring narrower and twisted a little
	  - every side of the cone is a ridge or a gully all the way up (sides
	    alternate, and each keeps its own strength), so rock ribs run from
	    the summit down into the clouds like real mountain faces; a few
	    vertices jut further out as crags
	  - a single apex, offset sideways so the summit leans
	  - `power` shapes the profile: below 1, the walls stay steep and the top
	    pinches to a point (karst spire); around 1, it's a classic pointed
	    mountain

	Returns the apex, for the sightline check.
]]
local function buildCone(
	parent: Instance,
	base: Vector3,
	height: number,
	radius: number,
	sides: number,
	rings: number,
	power: number,
	lean: Vector3,
	shading: Shading
): Vector3
	local vertexRings: { { Vector3 } } = {}
	local ringTwist = rng:NextNumber(0, math.pi * 2)
	local bottomY = cloudY - 30 -- start just under the cloud floor, so no base shows

	-- Ridge (> 1) or gully (< 1) strength of each side, kept on every ring.
	local ridges = {}
	for side = 1, sides do
		ridges[side] = if side % 2 == 0 then rng:NextNumber(1.05, 1.35) else rng:NextNumber(0.7, 0.92)
	end

	for ring = 0, rings - 1 do
		local t = ring / rings
		local ringRadius = radius * (1 - t) ^ power
		if ring == rings - 1 then
			ringRadius *= 0.75 -- pinch the last ring so every summit ends in a sharp point
		end
		local ringCenter = base + lean * height * t
		local y = bottomY + (base.Y + height - bottomY) * t
		local vertices = {}
		for side = 1, sides do
			local angle = ringTwist + (side - 1 + rng:NextNumber(-0.12, 0.12)) / sides * math.pi * 2
			local reach = ringRadius * ridges[side] * rng:NextNumber(0.9, 1.1)
			if ring > 0 and rng:NextNumber() < 0.15 then
				reach *= 1.25 -- a crag jutting out of the slope
			end
			local jitterY = if ring > 0 then rng:NextNumber(-0.12, 0.12) * height / rings else 0
			vertices[side] = ringCenter + direction(angle) * reach + Vector3.new(0, y - ringCenter.Y + jitterY, 0)
		end
		vertexRings[ring + 1] = vertices
		ringTwist += rng:NextNumber(-0.15, 0.15)
	end

	local apex = base + lean * height + Vector3.new(0, height, 0)
	local axis = base + lean * height * 0.5 -- a point inside the solid

	for ring = 1, rings - 1 do
		local lower, upper = vertexRings[ring], vertexRings[ring + 1]
		for side = 1, sides do
			local nextSide = side % sides + 1
			quad(parent, lower[side], lower[nextSide], upper[nextSide], upper[side], axis, shading)
		end
	end
	local top = vertexRings[rings]
	for side = 1, sides do
		face(parent, top[side], top[side % sides + 1], apex, axis, shading)
	end
	return apex
end

-- A mountain: a main peak plus smaller peaks fused to its flanks.
local function buildPeak(parent: Instance, layer: any, name: string, base: Vector3): (PeakInfo, number)
	local model = Instance.new("Model")
	model.Name = name

	local detail = layer.detail
	local spire = rng:NextNumber() < layer.spire
	local height = range(layer.height)
	local radius = height / (if spire then rng:NextNumber(2.6, 4.2) else rng:NextNumber(1.3, 2.2))
	local shading = { haze = layer.haze, baseY = cloudY, height = height }
	local lean = direction(rng:NextNumber(0, math.pi * 2)) * rng:NextNumber(0, if spire then 0.12 else 0.2)

	local apex = buildCone(
		model,
		base,
		height,
		radius,
		if detail >= 3 then 8 elseif detail == 2 then 7 else 6,
		if detail >= 3 then 4 else 3,
		if spire then rng:NextNumber(0.45, 0.7) else rng:NextNumber(0.9, 1.4),
		lean,
		shading
	)

	local sidePeaks = if detail >= 3
		then rng:NextInteger(2, 3)
		elseif detail == 2 then rng:NextInteger(1, 2)
		else rng:NextInteger(0, 1)
	for _ = 1, sidePeaks do
		local offset = direction(rng:NextNumber(0, math.pi * 2)) * radius * rng:NextNumber(0.45, 0.9)
		local sideHeight = height * rng:NextNumber(0.3, 0.65)
		buildCone(
			model,
			base + offset,
			sideHeight,
			radius * rng:NextNumber(0.45, 0.7),
			if detail >= 3 then 6 else 5,
			if detail >= 3 then 3 else 2,
			if spire then rng:NextNumber(0.5, 0.8) else rng:NextNumber(0.9, 1.3),
			lean + direction(rng:NextNumber(0, math.pi * 2)) * 0.08,
			shading
		)
	end

	-- Pivot on the cloud sea + size attributes: everything a replacement mesh needs.
	model.WorldPivot = CFrame.new(base)
	model:SetAttribute("Layer", layer.name)
	model:SetAttribute("PlaceholderHeight", math.round(height))
	model:SetAttribute("PlaceholderWidth", math.round(radius * 2))
	CollectionService:AddTag(model, PEAK_TAG)
	model.Parent = parent

	return { position = apex, topY = apex.Y, radius = radius * 0.6 }, radius
end

--[[
	A saw-toothed horizon range, built one-sided because it's only ever seen
	from the island: three rows of vertices (base, mid-slope, ridge) along an
	arc, the ridge alternating peaks and saddles and tapering at both ends.
	The lower rows lean toward the island, so the slopes are faceted and lit.
]]
local function buildRange(parent: Instance, layer: any, name: string, angle: number, distance: number): { PeakInfo }
	local model = Instance.new("Model")
	model.Name = name
	local height = range(layer.height)
	local arc = height * rng:NextNumber(1.8, 3)
	local segments = rng:NextInteger(6, 9)
	local depth = height * 0.9
	local outward, tangent = direction(angle), direction(angle + math.pi / 2)
	local shading = { haze = layer.haze, baseY = cloudY, height = height }
	local middle = center + outward * distance
	local behind = middle + outward * 5000 -- orients every face toward the island

	local bottoms, mids, tops = {}, {}, {}
	local peaks: { PeakInfo } = {}
	for index = 0, segments do
		local s = index / segments
		local along = middle + tangent * (s - 0.5) * arc
		local taper = math.sin(s * math.pi) ^ 0.6 -- ends drop away to the clouds
		local ridge = if index % 2 == 0 then rng:NextNumber(0.7, 1) else rng:NextNumber(0.35, 0.62)
		local ridgeHeight = height * math.max(ridge * taper, 0.12)
		local sway = tangent * rng:NextNumber(-0.3, 0.3) * arc / segments
		local top = along + outward * rng:NextNumber(0, 60) + sway
		tops[index] = Vector3.new(top.X, cloudY + ridgeHeight, top.Z)
		local mid = along - outward * depth * 0.45 + sway * 0.5
		mids[index] = Vector3.new(mid.X, cloudY + ridgeHeight * rng:NextNumber(0.4, 0.55), mid.Z)
		local bottom = along - outward * depth
		bottoms[index] = Vector3.new(bottom.X, cloudY - 30, bottom.Z)
		if ridge >= 0.7 then
			table.insert(peaks, { position = tops[index], topY = tops[index].Y, radius = arc / segments * 0.5 })
		end
	end

	for index = 0, segments - 1 do
		quad(model, bottoms[index], bottoms[index + 1], mids[index + 1], mids[index], behind, shading)
		quad(model, mids[index], mids[index + 1], tops[index + 1], tops[index], behind, shading)
	end

	model.WorldPivot = CFrame.new(middle.X, cloudY, middle.Z)
	model:SetAttribute("Layer", layer.name)
	model:SetAttribute("PlaceholderHeight", math.round(height))
	model:SetAttribute("PlaceholderWidth", math.round(arc))
	CollectionService:AddTag(model, PEAK_TAG)
	model.Parent = parent
	return peaks
end

-- One mountain per sector, at a random spot inside it: even coverage all the
-- way round without a visible pattern. Low-frequency noise pushes the ring in
-- and out so it never reads as a circle.
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
		local name = `{layer.name}_{index}`

		if layer.detail == 0 then
			for _, peak in buildRange(group, layer, name, angle, distance) do
				table.insert(peaks, peak)
			end
		else
			local flat = center + direction(angle) * distance
			local base = Vector3.new(flat.X, cloudY, flat.Z)
			local peak, radius = buildPeak(group, layer, name, base)
			table.insert(peaks, peak)
			if layer.detail >= 2 then
				table.insert(cloudSpots, { position = base, radius = radius })
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
	local part = makePart(parent, "Part", name, Vector3.new(width, 40, width), CFrame.new(position), CLOUD_COLOR)
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
	emitter.LightEmission = 0.15
	emitter.LightInfluence = 0.5 -- keep their warm colour in any lighting
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
						"Part",
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

		-- Clouds wrapped around the bases of the nearer mountains, so they rise
		-- out of the sea instead of sitting on it.
		for index, spot in cloudSpots do
			local position = Vector3.new(spot.position.X, puffY, spot.position.Z)
			local rate = math.clamp(spot.radius / 250, 0.35, 0.9)
			cloudEmitter(group, `PeakBase{index}`, position, math.min(spot.radius * 3, 1600), rate)
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

local CREATED_ATTRIBUTE = "CreatedByBackgroundMountains"

local function applyAtmosphere()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

	if not CHANGE_ATMOSPHERE then
		-- Leave Lighting as the game had it: undo an earlier run's haze, if any.
		if atmosphere and atmosphere:GetAttribute(CREATED_ATTRIBUTE) then
			atmosphere:Destroy()
		elseif atmosphere then
			for property in ATMOSPHERE do
				local key = `Original{property}`
				local original = atmosphere:GetAttribute(key)
				if original ~= nil then
					(atmosphere :: any)[property] = original
					atmosphere:SetAttribute(key, nil)
				end
			end
		end
		return
	end

	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere:SetAttribute(CREATED_ATTRIBUTE, true)
		atmosphere.Parent = Lighting
	end
	for property, value in ATMOSPHERE do
		-- Keep the values from before the first run, so they can be restored.
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
	viewPoint = center + Vector3.new(0, 10, 0)

	-- Paint the faces lit from the real sun's side, low in the sky for long,
	-- dramatic light. The game's lighting itself isn't touched.
	local sun = Lighting:GetSunDirection()
	local sunSide = Vector3.new(sun.X, 0, sun.Z)
	sunSide = if sunSide.Magnitude > 0.1 then sunSide.Unit else Vector3.new(0.9, 0, 0.45).Unit
	keyLight = (sunSide * math.cos(math.rad(25)) + Vector3.yAxis * math.sin(math.rad(25))).Unit

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
	local mountainParts = partCount
	buildCloudSea(root, cloudSpots)
	root.Parent = environment
	applyAtmosphere()

	print(
		`[BuildBackgroundMountains] Island centre ({math.round(center.X)}, {math.round(center.Z)}), `
			.. `ground Y {math.round(center.Y)}, radius {math.round(islandRadius)} studs; `
			.. `cloud sea at Y {math.round(cloudY)}.`
	)
	print(
		`[BuildBackgroundMountains] Built {faceCount} mountain faces ({mountainParts} wedges) and `
			.. `{emitterCount} cloud emitters; {partCount} parts in total, `
			.. `about {math.round(particleEstimate)} cloud particles at once.`
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
