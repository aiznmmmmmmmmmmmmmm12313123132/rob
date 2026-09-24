--!strict
--[[
	Build3DCartoonShop (Studio Command Bar script)

	Paste into View > Command Bar in Roblox Studio (Edit mode) and press Enter.
	Builds StarterGui["3DCartoonShopGui"]: a cartoon "3D" Dice Shop made only
	of Roblox UI instances, with no image assets to upload:

	  TopBar           HOME and SHOP buttons (SHOP opens the shop)
	  Dim              dark backdrop behind the window; clicking it closes the shop
	  ShopWindow       navy window standing on a raised base, with a gold
	                   "DICE SHOP" header tab and a round red close button
	    Featured card  the big gold card: SPECIAL OFFER badge, spinning dice
	                   with light rays, luck and odds, a large green price button
	    Grid           scrolling grid of smaller rarity-coloured dice cards
	  ShopController   LocalScript: hover/press animations, open/close, spinning dice
	  ShopAction       BindableEvent (itemId, "Buy" | "Equip") for your shop code
	  HomePressed      BindableEvent fired by HOME

	Every button is a 2-layer depth stack:

	  <Button>        TextButton hit area (attributes Button3D, Depth, Action)
	  └── Visual      the outline (UIStroke) and hover UIScale
	      ├── Base    darker colour: the 3D extrusion under the face
	      └── Face    vertical UIGradient, a glossy top half, a white rim
	                  light and the 3D label (text over a dark offset copy)

	Pressing slides Face down onto Base (see ShopController).

	The dice (names, luck, odds, prices, states) come from DICE below, and each
	dice is a small rounded 3D model with glowing pips in a ViewportFrame.

	Re-running replaces the whole 3DCartoonShopGui (Ctrl+Z undoes it). Your old
	shop UI isn't touched; delete it once you've switched over. The
	ShopController source near the bottom is a copy of
	src/StarterGui/3DCartoonShopGui/ShopController.client.luau.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local GUI_NAME = "3DCartoonShopGui"
local BUILD_TOP_BAR = true -- HOME / SHOP buttons; set false if you keep your own
local SHOW_WINDOW_IN_STUDIO = true -- visible for editing; ShopController hides it at runtime

local TITLE_FONT = Enum.Font.LuckiestGuy
local BODY_FONT = Enum.Font.FredokaOne

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local WHITE = rgb(255, 255, 255)
local OUTLINE = rgb(15, 18, 28) -- dark charcoal strokes

local WINDOW_TOP = rgb(30, 36, 58)
local WINDOW_BOTTOM = rgb(20, 24, 38)
local WINDOW_BASE = rgb(9, 11, 19)

type Palette = { top: Color3, bottom: Color3, base: Color3 }

local GOLD: Palette = { top = rgb(255, 210, 40), bottom = rgb(255, 150, 0), base = rgb(186, 92, 0) }
local GREEN: Palette = { top = rgb(46, 204, 113), bottom = rgb(35, 155, 86), base = rgb(22, 105, 58) }
local RED: Palette = { top = rgb(255, 92, 92), bottom = rgb(206, 34, 56), base = rgb(136, 14, 36) }
local PINK: Palette = { top = rgb(255, 96, 150), bottom = rgb(222, 34, 104), base = rgb(142, 12, 62) }

-- Item button colours per State. Keep in sync with STATE_STYLES in ShopController.
local STATE_STYLES: { [string]: Palette } = {
	Buy = GREEN,
	Equip = { top = rgb(64, 222, 212), bottom = rgb(22, 160, 172), base = rgb(10, 104, 116) },
	Equipped = { top = rgb(176, 186, 210), bottom = rgb(112, 122, 152), base = rgb(70, 78, 106) },
}

local RARITIES: { [string]: Palette } = {
	Common = { top = rgb(214, 220, 230), bottom = rgb(140, 148, 162), base = rgb(88, 94, 108) },
	Uncommon = { top = rgb(122, 232, 110), bottom = rgb(44, 166, 74), base = rgb(24, 108, 46) },
	Rare = { top = rgb(96, 196, 255), bottom = rgb(34, 112, 232), base = rgb(18, 68, 160) },
	Epic = { top = rgb(206, 124, 255), bottom = rgb(132, 52, 222), base = rgb(84, 24, 150) },
	Legendary = { top = rgb(255, 184, 64), bottom = rgb(238, 108, 10), base = rgb(156, 64, 0) },
	Mythic = { top = rgb(255, 112, 172), bottom = rgb(222, 40, 112), base = rgb(146, 14, 66) },
}

-- Your dice. State: "Buy" (shows Price), "Equip" or "Equipped". The featured
-- one gets the big gold card; the rest fill the grid in this order.
type Dice = {
	id: string,
	rarity: string,
	luck: string,
	odds: string,
	state: string,
	price: string,
	body: Color3,
	pips: Color3,
	material: Enum.Material,
	featured: boolean?,
}

local DICE: { Dice } = {
	{
		id = "Wooden",
		rarity = "Common",
		luck = "1.0x",
		odds = "Common 90% • Uncommon 10%",
		state = "Equip",
		price = "",
		body = rgb(176, 116, 64),
		pips = rgb(255, 168, 64),
		material = Enum.Material.Wood,
	},
	{
		id = "Bronze",
		rarity = "Uncommon",
		luck = "1.8x",
		odds = "Common 60% • Uncommon 37% • Rare 1/33",
		state = "Equip",
		price = "",
		body = rgb(200, 120, 62),
		pips = rgb(255, 150, 50),
		material = Enum.Material.Metal,
	},
	{
		id = "Silver",
		rarity = "Rare",
		luck = "5.6x",
		odds = "Uncommon 60% • Rare 39% • Epic 1/67",
		state = "Equip",
		price = "",
		body = rgb(210, 214, 226),
		pips = rgb(100, 215, 255),
		material = Enum.Material.Metal,
	},
	{
		id = "Golden",
		rarity = "Epic",
		luck = "19x",
		odds = "Rare 62% • Epic 38% • Legendary 1/200",
		state = "Equip",
		price = "",
		body = rgb(255, 198, 64),
		pips = rgb(255, 140, 30),
		material = Enum.Material.Metal,
	},
	{
		id = "Diamond",
		rarity = "Legendary",
		luck = "71x",
		odds = "Epic 75% • Legendary 25%",
		state = "Equipped",
		price = "",
		body = rgb(205, 240, 255),
		pips = rgb(70, 140, 255),
		material = Enum.Material.SmoothPlastic,
	},
	{
		id = "Celestial",
		rarity = "Mythic",
		luck = "136x",
		odds = "Epic 30% • Legendary 70%",
		state = "Buy",
		price = "$350M",
		body = rgb(118, 78, 214),
		pips = rgb(255, 120, 225),
		material = Enum.Material.SmoothPlastic,
		featured = true,
	},
}

local CARD_SIZE = Vector2.new(160, 236)

--------------------------------------------------------------------------------
-- Instance helpers
--------------------------------------------------------------------------------

local function create(className: string, props: { [string]: any }, children: { Instance }?): Instance
	local instance = Instance.new(className)
	if instance:IsA("GuiObject") then
		instance.BorderSizePixel = 0
	end
	for key, value in props do
		(instance :: any)[key] = value
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	return instance
end

local function corner(radius: UDim): Instance
	return create("UICorner", { CornerRadius = radius })
end

local function outline(thickness: number): Instance
	return create("UIStroke", {
		Color = OUTLINE,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

-- Vertical gradient: bright at the top, darker at the bottom.
local function gradient(top: Color3, bottom: Color3): Instance
	return create("UIGradient", { Rotation = 90, Color = ColorSequence.new(top, bottom) })
end

type TextSpec = {
	name: string?,
	text: string,
	position: UDim2,
	size: UDim2,
	anchor: Vector2?,
	color: Color3?,
	font: Enum.Font?,
	maxTextSize: number?,
	stroke: number?, -- outline thickness
	depth: number?, -- how far the dark copy sits below the text
	wrapped: boolean?,
}

--[[
	Cartoon text with depth, the same trick as the buttons: a dark copy of the
	text sits a few px lower, and both have a thick dark outline.

	  <name>      Frame
	  ├── Shadow  TextLabel (dark, offset down)
	  └── Text    TextLabel
]]
local function text3D(parent: Instance, spec: TextSpec): Frame
	local holder = create("Frame", {
		Name = spec.name or "Label",
		AnchorPoint = spec.anchor or Vector2.new(0.5, 0.5),
		Position = spec.position,
		Size = spec.size,
		BackgroundTransparency = 1,
	}) :: Frame

	local function layer(name: string, color: Color3, offset: number, zIndex: number)
		create("TextLabel", {
			Name = name,
			Position = UDim2.fromOffset(0, offset),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = spec.font or BODY_FONT,
			Text = spec.text,
			TextColor3 = color,
			TextScaled = true,
			TextWrapped = spec.wrapped == true,
			ZIndex = zIndex,
		}, {
			create("UIStroke", {
				Color = OUTLINE,
				Thickness = spec.stroke or 3,
				LineJoinMode = Enum.LineJoinMode.Round,
			}),
			create("UITextSizeConstraint", { MaxTextSize = spec.maxTextSize or 40 }),
		}).Parent =
			holder
	end
	layer("Shadow", OUTLINE, spec.depth or 3, 1)
	layer("Text", spec.color or WHITE, 0, 2)

	holder.Parent = parent
	return holder
end

type BlockSpec = {
	name: string,
	size: UDim2,
	palette: Palette,
	position: UDim2?,
	anchor: Vector2?,
	depth: number?, -- height of the 3D base under the face, in px
	radius: UDim?,
	stroke: number?,
	rotation: number?,
	zIndex: number?,
	interactive: boolean?, -- a TextButton with the Button3D press animation
	action: string?, -- what ShopController does on click
	gloss: number?, -- transparency at the top of the gloss (1 = none); big cards use less
}

--[[
	The 2-layer depth stack every button, card, tab and badge is built from.
	Returns the outer object and the Face (where content goes).
]]
local function block3D(parent: Instance, spec: BlockSpec): (GuiObject, Frame)
	local depth = spec.depth or 7
	local radius = spec.radius or UDim.new(0, 12)

	local outer: GuiObject
	if spec.interactive then
		outer = create("TextButton", { Text = "", AutoButtonColor = false }) :: GuiObject
		outer:SetAttribute("Button3D", true)
		outer:SetAttribute("Depth", depth)
		outer:SetAttribute("PressDepth", math.max(depth - 3, 2))
		if spec.action then
			outer:SetAttribute("Action", spec.action)
		end
	else
		outer = create("Frame", {}) :: GuiObject
	end
	outer.Name = spec.name
	outer.AnchorPoint = spec.anchor or Vector2.zero
	outer.Position = spec.position or UDim2.new()
	outer.Size = spec.size
	outer.BackgroundTransparency = 1
	outer.Rotation = spec.rotation or 0
	outer.ZIndex = spec.zIndex or 1

	-- The outline sits on Visual, which covers face + base, so it wraps the
	-- whole 3D shape like one flattened object.
	local visual = create("Frame", {
		Name = "Visual",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, { corner(radius), outline(spec.stroke or 3), create("UIScale", {}) })

	create("Frame", {
		Name = "Base",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = spec.palette.base,
		ZIndex = 1,
	}, { corner(radius) }).Parent =
		visual

	local face = create("Frame", {
		Name = "Face",
		Size = UDim2.new(1, 0, 1, -depth),
		BackgroundColor3 = WHITE, -- the gradient supplies the colour
		ZIndex = 2,
	}, { corner(radius), gradient(spec.palette.top, spec.palette.bottom) }) :: Frame

	-- Glossy top half: white fading to clear.
	local gloss = spec.gloss or 0.6
	if gloss < 1 then
		create("Frame", {
			Name = "Gloss",
			Position = UDim2.fromOffset(3, 3),
			Size = UDim2.new(1, -6, 0.5, -3),
			BackgroundColor3 = WHITE,
		}, {
			corner(radius),
			create("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, gloss),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		}).Parent =
			face
	end

	-- Rim light: a thin white line just inside the top edge.
	local rimSize = if radius.Scale > 0
		then UDim2.new(0.5, 0, 0, 3)
		else UDim2.new(1, -2 * math.max(radius.Offset, 6), 0, 3)
	create("Frame", {
		Name = "Rim",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 3),
		Size = rimSize,
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.6,
	}, { corner(UDim.new(1, 0)) }).Parent =
		face

	face.Parent = visual
	visual.Parent = outer
	outer.Parent = parent
	return outer, face
end

-- Button text, optionally with an emoji icon on the left (e.g. a money icon
-- on prices). With `showIcon` false the icon is hidden and the text centred;
-- ShopController flips between the two when an item's State changes.
local function buttonLabel(face: Frame, text: string, icon: string?, maxTextSize: number, showIcon: boolean?)
	local iconShown = icon ~= nil and showIcon ~= false
	if icon then
		create("TextLabel", {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.15, 0.5),
			Size = UDim2.fromScale(0.2, 0.62),
			BackgroundTransparency = 1,
			Font = BODY_FONT,
			Text = icon,
			TextScaled = true,
			Visible = iconShown,
			ZIndex = 3,
		}).Parent =
			face
	end
	text3D(face, {
		text = text,
		position = if iconShown then UDim2.fromScale(0.58, 0.5) else UDim2.fromScale(0.5, 0.5),
		size = if iconShown then UDim2.fromScale(0.66, 0.62) else UDim2.fromScale(0.86, 0.62),
		maxTextSize = maxTextSize,
		stroke = if maxTextSize >= 24 then 3 else 2,
		depth = if maxTextSize >= 24 then 3 else 2,
	})
end

--------------------------------------------------------------------------------
-- Procedural 3D dice
--------------------------------------------------------------------------------

local DIE_SIZE = 4
local DIE_ROUNDING = 0.55

-- Pip positions on a 3x3 grid, for each face value.
local PIP_LAYOUTS: { { { number } } } = {
	{ { 0, 0 } },
	{ { -1, -1 }, { 1, 1 } },
	{ { -1, -1 }, { 0, 0 }, { 1, 1 } },
	{ { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } },
	{ { -1, -1 }, { -1, 1 }, { 0, 0 }, { 1, -1 }, { 1, 1 } },
	{ { -1, -1 }, { -1, 0 }, { -1, 1 }, { 1, -1 }, { 1, 0 }, { 1, 1 } },
}

-- Opposite faces add up to 7; the 6 is on top, where the camera always sees it.
local DIE_FACES = {
	{ value = 6, normal = Vector3.yAxis, u = Vector3.xAxis, v = Vector3.zAxis },
	{ value = 1, normal = -Vector3.yAxis, u = Vector3.xAxis, v = Vector3.zAxis },
	{ value = 3, normal = Vector3.xAxis, u = Vector3.zAxis, v = Vector3.yAxis },
	{ value = 4, normal = -Vector3.xAxis, u = Vector3.zAxis, v = Vector3.yAxis },
	{ value = 2, normal = Vector3.zAxis, u = Vector3.xAxis, v = Vector3.yAxis },
	{ value = 5, normal = -Vector3.zAxis, u = Vector3.xAxis, v = Vector3.yAxis },
}

--[[
	A rounded dice around the origin: three crossed slabs for the faces, 12
	cylinders for the rounded edges and 8 balls for the corners, plus Neon
	pips (bright in a ViewportFrame even without bloom).
]]
local function buildDie(dice: Dice): Model
	local model = Instance.new("Model")
	model.Name = "Die"

	local function piece(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material)
		local part = Instance.new("Part")
		part.Shape = shape
		part.Size = size
		part.CFrame = cframe
		part.Color = color
		part.Material = material
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
	end

	local s, r = DIE_SIZE, DIE_ROUNDING
	local inner = s - 2 * r
	local h = inner / 2
	local body, material = dice.body, dice.material

	piece(Enum.PartType.Block, Vector3.new(s, inner, inner), CFrame.new(), body, material)
	piece(Enum.PartType.Block, Vector3.new(inner, s, inner), CFrame.new(), body, material)
	piece(Enum.PartType.Block, Vector3.new(inner, inner, s), CFrame.new(), body, material)
	local edge = Vector3.new(inner, 2 * r, 2 * r) -- a cylinder's length runs along X
	for _, a in { -1, 1 } do
		for _, b in { -1, 1 } do
			piece(Enum.PartType.Cylinder, edge, CFrame.new(0, a * h, b * h), body, material)
			piece(
				Enum.PartType.Cylinder,
				edge,
				CFrame.new(a * h, 0, b * h) * CFrame.Angles(0, 0, math.pi / 2),
				body,
				material
			)
			piece(
				Enum.PartType.Cylinder,
				edge,
				CFrame.new(a * h, b * h, 0) * CFrame.Angles(0, math.pi / 2, 0),
				body,
				material
			)
			for _, c in { -1, 1 } do
				piece(Enum.PartType.Ball, Vector3.one * 2 * r, CFrame.new(a * h, b * h, c * h), body, material)
			end
		end
	end

	local spacing = s * 0.25
	local pipSize = s * 0.18
	for _, dieFace in DIE_FACES do
		for _, spot in PIP_LAYOUTS[dieFace.value] do
			-- Sunk almost flush, so each pip reads as a glowing dot.
			local position = dieFace.normal * (s / 2 - pipSize * 0.35)
				+ dieFace.u * spot[1] * spacing
				+ dieFace.v * spot[2] * spacing
			piece(Enum.PartType.Ball, Vector3.one * pipSize, CFrame.new(position), dice.pips, Enum.Material.Neon)
		end
	end

	model.WorldPivot = CFrame.new() -- ShopController spins it with PivotTo
	return model
end

local function diceViewport(parent: Instance, dice: Dice, position: UDim2, size: UDim2, anchor: Vector2)
	local viewport = create("ViewportFrame", {
		Name = "Viewport",
		AnchorPoint = anchor,
		Position = position,
		Size = size,
		BackgroundTransparency = 1,
		Ambient = rgb(170, 170, 185),
		LightColor = WHITE,
		LightDirection = Vector3.new(-0.6, -1, -0.4),
	}) :: ViewportFrame
	buildDie(dice).Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = 28
	-- Looking down on a corner, so three faces (always including the 6) show.
	camera.CFrame = CFrame.lookAt(Vector3.new(7, 6, 9).Unit * 15, Vector3.zero)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Parent = parent
end

--------------------------------------------------------------------------------
-- Cards
--------------------------------------------------------------------------------

local function tagCard(card: Instance, dice: Dice)
	card:SetAttribute("Card3D", true)
	card:SetAttribute("ItemId", dice.id)
	card:SetAttribute("State", dice.state)
	card:SetAttribute("Price", dice.price)
end

local function actionButtonText(dice: Dice): string
	if dice.state == "Buy" then
		return if dice.price ~= "" then dice.price else "BUY"
	end
	return if dice.state == "Equipped" then "EQUIPPED" else "EQUIP"
end

--[[
	A grid card (160 x 236):

	  Title / Rarity   name and rarity
	  Viewport         the dice
	  Luck / Odds      the numbers from your current shop
	  ActionButton     Buy (green, with price) / Equip / Equipped
]]
local function buildCard(parent: Instance, dice: Dice, order: number)
	local card, face = block3D(parent, {
		name = `Card_{dice.id}`,
		size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		palette = RARITIES[dice.rarity],
		depth = 6,
		radius = UDim.new(0, 14),
		gloss = 0.82,
	})
	card.LayoutOrder = order
	tagCard(card, dice)

	text3D(face, {
		name = "Title",
		text = dice.id,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 8),
		size = UDim2.new(1, -16, 0, 26),
		maxTextSize = 24,
		stroke = 2.5,
		depth = 2,
	})
	text3D(face, {
		name = "Rarity",
		text = string.upper(dice.rarity),
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 34),
		size = UDim2.new(1, -20, 0, 14),
		maxTextSize = 13,
		stroke = 1.5,
		depth = 1,
	})
	diceViewport(face, dice, UDim2.new(0.5, 0, 0, 50), UDim2.fromOffset(84, 84), Vector2.new(0.5, 0))
	text3D(face, {
		name = "Luck",
		text = `{dice.luck} Luck`,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 136),
		size = UDim2.new(1, -16, 0, 18),
		maxTextSize = 17,
		stroke = 2,
		depth = 2,
	})
	text3D(face, {
		name = "Odds",
		text = dice.odds,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 156),
		size = UDim2.new(1, -12, 0, 34), -- room for three lines, like "Rare / Epic / Legendary"
		maxTextSize = 12,
		stroke = 1.2,
		depth = 1,
		wrapped = true,
	})

	local _, buttonFace = block3D(face, {
		name = "ActionButton",
		interactive = true,
		action = "Item",
		anchor = Vector2.new(0.5, 1),
		position = UDim2.new(0.5, 0, 1, -6),
		size = UDim2.new(1, -20, 0, 34),
		palette = STATE_STYLES[dice.state] or GREEN,
		depth = 5,
		radius = UDim.new(0, 10),
	})
	buttonLabel(buttonFace, actionButtonText(dice), "💵", 18, dice.state == "Buy")
end

--[[
	The featured card fills the left 40% of the window. Its layout is in
	scale units, so it holds together at any window height:

	  Badge         SPECIAL OFFER, tilted, hanging off the top-right corner
	  Title         dice name          (7% - 16% down)
	  Subtitle      rarity             (16% - 21%)
	  Showcase      rays, glow, dice   (centred at 45%, 36% tall)
	  Luck / Odds                      (64% - 76%)
	  ActionButton  big price button   (bottom, 15% tall, 44-72 px)
]]
local function buildFeatured(parent: Instance, dice: Dice)
	local card, face = block3D(parent, {
		name = `Card_{dice.id}`,
		size = UDim2.fromScale(1, 1),
		palette = GOLD,
		depth = 8,
		radius = UDim.new(0, 18),
		stroke = 4,
		gloss = 0.8,
	})
	tagCard(card, dice)
	card:SetAttribute("Featured", true)

	local _, badgeFace = block3D(face, {
		name = "Badge",
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, 14, 0, 4), -- top-right, clear of the header tab
		size = UDim2.fromOffset(178, 42),
		palette = PINK,
		depth = 5,
		radius = UDim.new(0, 12),
		rotation = 6,
		zIndex = 5,
	})
	text3D(badgeFace, {
		text = "SPECIAL OFFER",
		position = UDim2.fromScale(0.5, 0.52),
		size = UDim2.fromScale(0.88, 0.7),
		font = TITLE_FONT,
		maxTextSize = 20,
		stroke = 2,
		depth = 2,
	})

	text3D(face, {
		name = "Title",
		text = string.upper(dice.id),
		anchor = Vector2.new(0.5, 0),
		position = UDim2.fromScale(0.5, 0.07),
		size = UDim2.fromScale(0.9, 0.09),
		font = TITLE_FONT,
		maxTextSize = 44,
		stroke = 3.5,
		depth = 4,
	})
	text3D(face, {
		name = "Subtitle",
		text = `{string.upper(dice.rarity)} DICE`,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.fromScale(0.5, 0.16),
		size = UDim2.fromScale(0.7, 0.05),
		color = RARITIES[dice.rarity].top,
		maxTextSize = 24,
		stroke = 2.5,
		depth = 2,
	})

	-- Showcase: slowly turning light rays behind a soft glow and the dice.
	local showcase = create("Frame", {
		Name = "Showcase",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromScale(0.75, 0.36),
		BackgroundTransparency = 1,
	}, { create("UIAspectRatioConstraint", { AspectRatio = 1 }) })
	local rays = create("Frame", {
		Name = "Rays",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.25, 1.25),
		BackgroundTransparency = 1,
	})
	for index = 0, 5 do
		create("Frame", {
			Name = `Ray{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.16, 1),
			Rotation = index * 30,
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.55,
		}, {
			create("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.3, 0.3),
					NumberSequenceKeypoint.new(0.7, 0.3),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		}).Parent =
			rays
	end
	rays.Parent = showcase
	create("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.8),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.55,
	}, { corner(UDim.new(1, 0)) }).Parent =
		showcase
	diceViewport(showcase, dice, UDim2.fromScale(0.5, 0.5), UDim2.fromScale(1, 1), Vector2.new(0.5, 0.5))
	showcase.Parent = face

	text3D(face, {
		name = "Luck",
		text = `{dice.luck} LUCK`,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.fromScale(0.5, 0.64),
		size = UDim2.fromScale(0.8, 0.07),
		font = TITLE_FONT,
		maxTextSize = 34,
		stroke = 3,
		depth = 3,
	})
	text3D(face, {
		name = "Odds",
		text = dice.odds,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.fromScale(0.5, 0.715),
		size = UDim2.fromScale(0.9, 0.045),
		maxTextSize = 18,
		stroke = 2,
		depth = 2,
	})

	local button, buttonFace = block3D(face, {
		name = "ActionButton",
		interactive = true,
		action = "Item",
		anchor = Vector2.new(0.5, 1),
		position = UDim2.fromScale(0.5, 0.97),
		size = UDim2.fromScale(0.86, 0.15),
		palette = STATE_STYLES[dice.state] or GREEN,
		depth = 8,
		radius = UDim.new(0, 14),
		stroke = 4,
	})
	create("UISizeConstraint", { MinSize = Vector2.new(0, 44), MaxSize = Vector2.new(math.huge, 72) }).Parent = button
	buttonLabel(buttonFace, actionButtonText(dice), "💵", 40, dice.state == "Buy")
end

--------------------------------------------------------------------------------
-- Window, top bar and GUI
--------------------------------------------------------------------------------

local function buildWindow(gui: Instance)
	local window = create("Frame", {
		Name = "ShopWindow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.55),
		Size = UDim2.fromScale(0.55, 0.7),
		BackgroundTransparency = 1,
		Visible = SHOW_WINDOW_IN_STUDIO,
		ZIndex = 2,
	}, {
		create("UIScale", {}), -- ShopController's pop-in / fit-to-screen scale
		-- 700 px wide fits the featured card plus two grid columns.
		create("UISizeConstraint", { MinSize = Vector2.new(700, 420), MaxSize = Vector2.new(1000, 640) }),
	})

	-- The window stands on its own darker base, like the buttons.
	create("Frame", {
		Name = "Base",
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WINDOW_BASE,
	}, { corner(UDim.new(0, 16)), outline(4) }).Parent =
		window
	local face = create("Frame", {
		Name = "Face",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.15,
	}, { corner(UDim.new(0, 16)), outline(4), gradient(WINDOW_TOP, WINDOW_BOTTOM) })

	local body = create("Frame", {
		Name = "Body",
		Position = UDim2.fromOffset(20, 58), -- clears the header tab
		Size = UDim2.new(1, -40, 1, -78),
		BackgroundTransparency = 1,
	})

	local featured = DICE[#DICE]
	for _, dice in DICE do
		if dice.featured then
			featured = dice
		end
	end
	local featuredHolder = create("Frame", {
		Name = "Featured",
		Size = UDim2.new(0.4, 0, 1, -8),
		BackgroundTransparency = 1,
	})
	buildFeatured(featuredHolder, featured)
	featuredHolder.Parent = body

	-- Padding keeps outlines and the hover lift from being clipped.
	local grid = create("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.new(0.4, 18, 0, 0),
		Size = UDim2.new(0.6, -18, 1, 0),
		BackgroundTransparency = 1,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = GOLD.top,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
	}, {
		create("UIPadding", {
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
		}),
		create("UIGridLayout", {
			CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
			CellPadding = UDim2.fromOffset(14, 16),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local order = 0
	for _, dice in DICE do
		if dice ~= featured then
			order += 1
			buildCard(grid, dice, order)
		end
	end
	grid.Parent = body
	body.Parent = face
	face.Parent = window

	-- Header tab, straddling the window's top edge.
	local _, headerFace = block3D(window, {
		name = "Header",
		anchor = Vector2.new(0, 0.5),
		position = UDim2.fromOffset(24, 0),
		size = UDim2.fromOffset(300, 66),
		palette = GOLD,
		depth = 7,
		radius = UDim.new(0, 14),
		stroke = 4,
		zIndex = 5,
	})
	text3D(headerFace, {
		name = "Title",
		text = "DICE SHOP",
		anchor = Vector2.new(0, 0.5),
		position = UDim2.fromScale(0.07, 0.52),
		size = UDim2.fromScale(0.68, 0.66),
		font = TITLE_FONT,
		maxTextSize = 40,
		stroke = 3.5,
		depth = 4,
	})
	create("TextLabel", {
		Name = "Icon",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.94, 0.5),
		Size = UDim2.fromScale(0.18, 0.7),
		BackgroundTransparency = 1,
		Font = BODY_FONT,
		Text = "🎲",
		TextScaled = true,
		ZIndex = 3,
	}).Parent =
		headerFace

	-- Round red close button on the top-right corner.
	local _, closeFace = block3D(window, {
		name = "CloseButton",
		interactive = true,
		action = "Close",
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.new(1, -16, 0, 8),
		size = UDim2.fromOffset(60, 67),
		palette = RED,
		depth = 7,
		radius = UDim.new(1, 0),
		stroke = 4,
		zIndex = 5,
	})
	text3D(closeFace, {
		text = "X",
		position = UDim2.fromScale(0.5, 0.52),
		size = UDim2.fromScale(0.6, 0.6),
		font = TITLE_FONT,
		maxTextSize = 34,
		stroke = 3,
		depth = 3,
	})

	window.Parent = gui
end

local function buildTopBar(gui: Instance)
	local topBar = create("Frame", {
		Name = "TopBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(340, 64),
		BackgroundTransparency = 1,
		ZIndex = 3,
	})
	local _, homeFace = block3D(topBar, {
		name = "HomeButton",
		interactive = true,
		action = "Home",
		size = UDim2.fromOffset(160, 62),
		palette = RED,
		depth = 7,
	})
	buttonLabel(homeFace, "HOME", "🏠", 30)
	local _, shopFace = block3D(topBar, {
		name = "ShopButton",
		interactive = true,
		action = "ToggleShop",
		anchor = Vector2.new(1, 0),
		position = UDim2.fromScale(1, 0),
		size = UDim2.fromOffset(160, 62),
		palette = GREEN,
		depth = 7,
	})
	buttonLabel(shopFace, "SHOP", "🛒", 30)
	topBar.Parent = gui
end

local CONTROLLER_SOURCE = [==[
--!strict
--[[
	ShopController (LocalScript)
	Location: StarterGui > 3DCartoonShopGui > ShopController
	Built into the GUI by tools/Build3DCartoonShop.luau, which embeds a copy
	of this file. Edit here, then re-run the builder (or paste this into the
	LocalScript by hand).

	  - Every 3D button (attribute Button3D) grows slightly on hover and
	    physically presses in: its face slides down onto its base while held.
	  - Item cards (attribute Card3D) lift on hover and spin their dice.
	  - SHOP toggles the window with a Back-eased pop; X, the dark backdrop
	    and ButtonB close it.
	  - While the shop is open, the featured dice spins and its light rays turn.

	Hooking up your game, from any LocalScript:

		local shopGui = Players.LocalPlayer.PlayerGui:WaitForChild("3DCartoonShopGui")

		-- action is "Buy" or "Equip"
		shopGui.ShopAction.Event:Connect(function(itemId, action)
			diceShopRemote:FireServer(itemId, action)
		end)

		-- Show what the player owns: "Buy" (shows the Price attribute),
		-- "Equip" or "Equipped". Only one card can be Equipped at a time.
		shopGui:FindFirstChild("Card_Silver", true):SetAttribute("State", "Equipped")

		shopGui:SetAttribute("Open", true) -- open or close from code
		shopGui.HomePressed.Event:Connect(teleportHome)
]]

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local gui = script.Parent :: ScreenGui
local window = gui:WaitForChild("ShopWindow") :: Frame
local windowScale = window:WaitForChild("UIScale") :: UIScale
local dim = gui:WaitForChild("Dim") :: GuiButton
local shopAction = gui:WaitForChild("ShopAction") :: BindableEvent
local homePressed = gui:WaitForChild("HomePressed") :: BindableEvent

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local HOVER_SCALE = 1.03
local SPIN_SPEED = 0.9 -- radians per second
local RAY_SPEED = 12 -- degrees per second
local DIM_TRANSPARENCY = 0.45

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local FADE_TWEEN = TweenInfo.new(0.2)

-- Item button colours per State. Keep in sync with STATE_STYLES in the builder.
type Style = { top: Color3, bottom: Color3, base: Color3 }
local STATE_STYLES: { [string]: Style } = {
	Buy = {
		top = Color3.fromRGB(46, 204, 113),
		bottom = Color3.fromRGB(35, 155, 86),
		base = Color3.fromRGB(22, 105, 58),
	},
	Equip = {
		top = Color3.fromRGB(64, 222, 212),
		bottom = Color3.fromRGB(22, 160, 172),
		base = Color3.fromRGB(10, 104, 116),
	},
	Equipped = {
		top = Color3.fromRGB(176, 186, 210),
		bottom = Color3.fromRGB(112, 122, 152),
		base = Color3.fromRGB(70, 78, 106),
	},
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function tween(instance: Instance, info: TweenInfo, goals: { [string]: any })
	TweenService:Create(instance, info, goals):Play()
end

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function isTouch(): boolean
	return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
end

local function isGamepad(): boolean
	return string.sub(UserInputService:GetLastInputType().Name, 1, 7) == "Gamepad"
end

-- A 3D button or card: Visual (outline + UIScale) holding Base and Face.
local function partsOf(target: Instance): (Frame?, Frame?, UIScale?)
	local visual = target:FindFirstChild("Visual")
	if not visual or not visual:IsA("Frame") then
		return nil, nil, nil
	end
	local face = visual:FindFirstChild("Face")
	return visual, if face and face:IsA("Frame") then face else nil, visual:FindFirstChildOfClass("UIScale")
end

--------------------------------------------------------------------------------
-- 3D press and hover
--------------------------------------------------------------------------------

--[[
	Pressed: the face slides down `shift` px toward the base. Visual, which
	carries the outline, shrinks from the top by the same amount, so the
	outline keeps hugging the button and only the base strip under the face
	gets thinner:

	    Visual  Position.Y = shift / 2, Size.Y = -shift   (top edge moves down)
	    Face    Size.Y = -(depth - shift)                  (face height unchanged)
]]
local function setPressed(button: GuiButton, pressed: boolean)
	local visual, face = partsOf(button)
	if not visual or not face then
		return
	end
	local depth = numberAttribute(button, "Depth", 7)
	local shift = if pressed then math.min(numberAttribute(button, "PressDepth", 4), depth - 1) else 0
	local info = if pressed then PRESS_TWEEN else RELEASE_TWEEN
	tween(visual, info, { Position = UDim2.new(0.5, 0, 0.5, shift / 2), Size = UDim2.new(1, 0, 1, -shift) })
	tween(face, info, { Size = UDim2.new(1, 0, 1, -(depth - shift)) })
end

local function setHovered(target: Instance, hovered: boolean)
	local _, _, scale = partsOf(target)
	if scale then
		tween(scale, HOVER_TWEEN, { Scale = if hovered then HOVER_SCALE else 1 })
	end
end

local held: { [GuiButton]: boolean } = {}

local function release(button: GuiButton)
	if held[button] then
		held[button] = nil
		setPressed(button, false)
	end
end

--------------------------------------------------------------------------------
-- Item cards and their states
--------------------------------------------------------------------------------

local cards: { Instance } = {}
local spinningOnHover: { [Model]: boolean } = {}
local angles: { [Model]: number } = {}
local featuredDie: Model? = nil

local function findCard(instance: Instance): Instance?
	local current: Instance? = instance
	while current and current ~= gui do
		if current:GetAttribute("Card3D") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function dieOf(card: Instance): Model?
	local die = card:FindFirstChild("Die", true)
	return if die and die:IsA("Model") then die else nil
end

local function setLabelText(label: Instance?, text: string)
	if label then
		for _, child in label:GetChildren() do
			if child:IsA("TextLabel") then
				child.Text = text
			end
		end
	end
end

-- Recolours and relabels a card's button for its State attribute.
local function applyState(card: Instance)
	local state = card:GetAttribute("State")
	local stateName = if typeof(state) == "string" and STATE_STYLES[state] then state else "Buy"
	local style = STATE_STYLES[stateName]
	local button = card:FindFirstChild("ActionButton", true)
	if not button then
		return
	end
	local visual, face = partsOf(button)
	if not visual or not face then
		return
	end

	local base = visual:FindFirstChild("Base")
	if base and base:IsA("Frame") then
		base.BackgroundColor3 = style.base
	end
	local gradient = face:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(style.top, style.bottom)
	end

	local buying = stateName == "Buy"
	local price = card:GetAttribute("Price")
	local text = if buying
		then (if typeof(price) == "string" and price ~= "" then price else "BUY")
		elseif stateName == "Equipped" then "EQUIPPED"
		else "EQUIP"
	local label = face:FindFirstChild("Label")
	setLabelText(label, text)
	-- The money icon only shows on prices; words take the full width.
	local icon = face:FindFirstChild("Icon")
	if icon and icon:IsA("GuiObject") then
		icon.Visible = buying
	end
	if label and label:IsA("GuiObject") then
		label.Position = if buying then UDim2.fromScale(0.58, 0.5) else UDim2.fromScale(0.5, 0.5)
		label.Size = if buying then UDim2.fromScale(0.66, 0.62) else UDim2.fromScale(0.86, 0.62)
	end
end

local function onStateChanged(card: Instance)
	-- Only one dice can be equipped: equipping one un-equips the rest.
	if card:GetAttribute("State") == "Equipped" then
		for _, other in cards do
			if other ~= card and other:GetAttribute("State") == "Equipped" then
				other:SetAttribute("State", "Equip")
			end
		end
	end
	applyState(card)
end

--------------------------------------------------------------------------------
-- Window open / close
--------------------------------------------------------------------------------

local isOpen = false

-- Scale that keeps the whole window (plus its header tab and base) on small
-- screens such as phones. Never enlarges past the designed size.
local function fitScale(): number
	local screen = gui.AbsoluteSize
	local width = window.Size.X.Scale * screen.X + window.Size.X.Offset
	local height = window.Size.Y.Scale * screen.Y + window.Size.Y.Offset
	local constraint = window:FindFirstChildOfClass("UISizeConstraint")
	if constraint then
		width = math.clamp(width, constraint.MinSize.X, constraint.MaxSize.X)
		height = math.clamp(height, constraint.MinSize.Y, constraint.MaxSize.Y)
	end
	local fit = math.min((screen.X - 24) / width, (screen.Y - 24) / (height + 50))
	-- Honour UIScaleController's device scale if it manages this GUI.
	return math.min(numberAttribute(windowScale, "BaseScale", 1), fit)
end

local function open()
	if isOpen then
		return
	end
	isOpen = true
	gui:SetAttribute("Open", true)
	if not window.Visible then
		windowScale.Scale = 0
		window.Visible = true
	end
	dim.Visible = true
	tween(windowScale, OPEN_TWEEN, { Scale = fitScale() })
	tween(dim, FADE_TWEEN, { BackgroundTransparency = DIM_TRANSPARENCY })

	-- A gamepad has no pointer: start on the featured buy button.
	if isGamepad() then
		local buy = window:FindFirstChild("ActionButton", true)
		if buy and buy:IsA("GuiObject") then
			GuiService.SelectedObject = buy
		end
	end
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	gui:SetAttribute("Open", false)
	for button in held do
		release(button)
	end
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(window) then
		GuiService.SelectedObject = nil
	end

	-- Reopening mid-close cancels these tweens; only hide after they finish.
	local shrink = TweenService:Create(windowScale, CLOSE_TWEEN, { Scale = 0 })
	shrink.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed and not isOpen then
			window.Visible = false
		end
	end)
	shrink:Play()
	local fade = TweenService:Create(dim, FADE_TWEEN, { BackgroundTransparency = 1 })
	fade.Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed and not isOpen then
			dim.Visible = false
		end
	end)
	fade:Play()
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function onActivated(button: GuiButton)
	local action = button:GetAttribute("Action")
	if action == "ToggleShop" then
		if isOpen then
			close()
		else
			open()
		end
	elseif action == "Close" then
		close()
	elseif action == "Home" then
		homePressed:Fire()
	elseif action == "Item" then
		local card = findCard(button)
		local state = if card then card:GetAttribute("State") else nil
		if card and state ~= "Equipped" then
			shopAction:Fire(card:GetAttribute("ItemId"), if state == "Equip" then "Equip" else "Buy")
		end
	end
end

local function wireButton(button: GuiButton)
	button.MouseEnter:Connect(function()
		-- A tap can fire MouseEnter without MouseLeave; hover is mouse-only.
		if not isTouch() then
			setHovered(button, true)
		end
	end)
	button.MouseLeave:Connect(function()
		setHovered(button, false)
		release(button) -- dragged off while held: pop back up
	end)
	button.SelectionGained:Connect(function()
		setHovered(button, true)
	end)
	button.SelectionLost:Connect(function()
		setHovered(button, false)
	end)
	button.MouseButton1Down:Connect(function()
		held[button] = true
		setPressed(button, true)
	end)
	button.MouseButton1Up:Connect(function()
		release(button)
	end)
	button.Activated:Connect(function(input: InputObject?)
		local inputType = if input then input.UserInputType else nil
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			-- Gamepad and keyboard presses have no down/up, so play a quick press.
			setPressed(button, true)
			task.delay(0.08, setPressed, button, false)
		end
		onActivated(button)
	end)
end

local function wireCard(card: Instance)
	table.insert(cards, card)
	card:GetAttributeChangedSignal("State"):Connect(function()
		onStateChanged(card)
	end)
	card:GetAttributeChangedSignal("Price"):Connect(function()
		applyState(card)
	end)
	applyState(card)

	local die = dieOf(card)
	if card:GetAttribute("Featured") then
		featuredDie = die -- always spins while open
		die = nil
	end
	if card:IsA("GuiObject") then
		card.MouseEnter:Connect(function()
			if not isTouch() then
				setHovered(card, true)
				if die then
					spinningOnHover[die] = true
				end
			end
		end)
		card.MouseLeave:Connect(function()
			setHovered(card, false)
			if die then
				spinningOnHover[die] = nil
			end
		end)
	end
end

for _, descendant in gui:GetDescendants() do
	if descendant:IsA("GuiButton") and descendant:GetAttribute("Button3D") then
		wireButton(descendant)
	elseif descendant:GetAttribute("Card3D") then
		wireCard(descendant)
	end
end

dim.Activated:Connect(close)

-- Releasing anywhere ends a press, even off the button (touch has no MouseLeave).
UserInputService.InputEnded:Connect(function(input: InputObject)
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
		for button in held do
			release(button)
		end
	end
end)

UserInputService.InputBegan:Connect(function(input: InputObject)
	if isOpen and input.KeyCode == Enum.KeyCode.ButtonB then
		close()
	end
end)

-- Other scripts can open or close the shop with gui:SetAttribute("Open", ...).
gui:GetAttributeChangedSignal("Open"):Connect(function()
	local wanted = gui:GetAttribute("Open") == true
	if wanted and not isOpen then
		open()
	elseif not wanted and isOpen then
		close()
	end
end)

gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if isOpen then
		tween(windowScale, HOVER_TWEEN, { Scale = fitScale() })
	end
end)

-- Spinning dice and turning light rays, only while the shop is open.
local rays = window:FindFirstChild("Rays", true)
RunService.RenderStepped:Connect(function(deltaTime: number)
	if not isOpen then
		return
	end
	local function spin(die: Model)
		local angle = (angles[die] or 0) + deltaTime * SPIN_SPEED
		angles[die] = angle
		die:PivotTo(CFrame.Angles(0, angle, 0))
	end
	if featuredDie then
		spin(featuredDie)
	end
	for die in spinningOnHover do
		spin(die)
	end
	if rays and rays:IsA("GuiObject") then
		rays.Rotation = (rays.Rotation + deltaTime * RAY_SPEED) % 360
	end
end)

--------------------------------------------------------------------------------
-- Startup: the window is visible in Studio for editing, but starts closed.
--------------------------------------------------------------------------------

window.Visible = false
windowScale.Scale = 0
dim.Visible = false
dim.BackgroundTransparency = 1
gui:SetAttribute("Open", false)
]==]

local function build()
	local existing = StarterGui:FindFirstChild(GUI_NAME)
	if existing then
		existing:Destroy()
	end

	local gui = create("ScreenGui", {
		Name = GUI_NAME,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 20,
	})

	create("TextButton", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = rgb(0, 0, 0),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Visible = false,
		ZIndex = 1,
	}).Parent =
		gui
	buildWindow(gui)
	if BUILD_TOP_BAR then
		buildTopBar(gui)
	end

	create("BindableEvent", { Name = "ShopAction" }).Parent = gui
	create("BindableEvent", { Name = "HomePressed" }).Parent = gui
	create("LocalScript", { Name = "ShopController", Source = CONTROLLER_SOURCE }).Parent = gui

	gui.Parent = StarterGui
	print(`[Build3DCartoonShop] Built StarterGui.{GUI_NAME}. Press Play and click SHOP.`)
end

if RunService:IsRunning() then
	warn("[Build3DCartoonShop] Stop the play test first; changes made while playing are thrown away.")
	return
end

local recording: string? = nil
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build 3D cartoon shop")
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
	warn(`[Build3DCartoonShop] Failed; changes rolled back.\n{err}`)
end
