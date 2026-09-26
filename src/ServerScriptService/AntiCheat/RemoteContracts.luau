--!strict
--[[
	RemoteContracts (ModuleScript)
	Location: ServerScriptService > AntiCheat > RemoteContracts

	One contract per gameplay remote: what the client may send, how often, and
	what the server must decide on its own. Api.bindRemote refuses to bind a
	remote without a contract, so no remote can go live unvalidated.

	The rule behind every contract: the client only ASKS. It never sends an
	amount, a price, a rarity, a roll result, a reward or proof of ownership.
	If a remote below seems to need one of those, the server should work it
	out from its own data instead.

	Rename or remove entries to match the game; unused contracts cost nothing.
	Per-game details (the real roll cooldown, catalog checks, shop ids) are
	passed to Api.bindRemote as options, e.g.

		AntiCheat.bindRemote("RollDice", onRoll, {
			cooldown = function(player) return RollService.getCooldown(player) end,
		})
		AntiCheat.bindRemote("DiceShop", onDiceShop, {
			checks = { [1] = function(id) return DiceCatalog[id] ~= nil end },
		})

	Fields: see RemoteValidator.Contract. `rate` is a token bucket
	(rate = requests per second, burst = how many may arrive at once).
]]

type ArgSpec = { [string]: any }
type Contract = {
	kind: "RemoteEvent" | "RemoteFunction",
	description: string,
	args: { ArgSpec },
	rate: { rate: number, burst: number, tolerance: number? }?,
	cooldown: number?,
	restrictable: boolean?,
	exclusive: boolean?,
	shop: string?,
}

-- Catalog-style ids ("Golden", "Speed_2") and per-character unique ids (GUIDs).
local ITEM_ID = { type = "string", maxLength = 32, pattern = "[%w_]+" }
local UNIQUE_ID = { type = "string", maxLength = 64, pattern = "[%w_%-{}]+" }
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }

local RemoteContracts: { [string]: Contract } = {
	--------------------------------------------------------------------------
	-- Rolling
	--------------------------------------------------------------------------
	RollDice = {
		kind = "RemoteEvent",
		description = "Roll the equipped dice. Server checks the dice is owned and equipped, rolls "
			.. "rarity / character / mutation with its own RNG and luck from saved upgrades, and "
			.. "grants the result. Requests faster than the real cooldown are dropped, never queued.",
		args = {},
		cooldown = 1, -- replace with the game's real cooldown via bindRemote options
		restrictable = true,
		exclusive = true,
	},
	SetAutoRoll = {
		kind = "RemoteEvent",
		description = "Toggle Auto Roll. The server runs the auto-roll loop itself at the normal "
			.. "cooldown; the client never fires RollDice for it.",
		args = { { type = "boolean" } },
		rate = { rate = 2, burst = 4 },
	},

	--------------------------------------------------------------------------
	-- Shops and purchases (price, currency and ownership come from the server)
	--------------------------------------------------------------------------
	DiceShop = {
		kind = "RemoteEvent",
		description = "Buy or equip a dice (ShopController's ShopAction). Server looks the id up in "
			.. "its catalog, checks progression, price and balance for Buy, ownership for Equip.",
		args = { ITEM_ID, { type = "enum", values = { "Buy", "Equip" } } },
		rate = { rate = 3, burst = 4 },
		restrictable = true,
		exclusive = true,
	},
	BuyUpgrade = {
		kind = "RemoteEvent",
		description = "Buy the next level of an upgrade. Server reads the current level and price.",
		args = { ITEM_ID },
		rate = { rate = 3, burst = 4 },
		restrictable = true,
		exclusive = true,
	},
	UnlockSkill = {
		kind = "RemoteEvent",
		description = "Unlock a skill tree node. Server checks prerequisites, gem cost and that it isn't owned.",
		args = { ITEM_ID },
		rate = { rate = 3, burst = 4 },
		restrictable = true,
		exclusive = true,
	},
	BuyCosmetic = {
		kind = "RemoteEvent",
		description = "Buy a cosmetic with Dream Essence. Server checks catalog, price and ownership.",
		args = { ITEM_ID },
		rate = { rate = 2, burst = 3 },
		restrictable = true,
		exclusive = true,
	},
	BuyRide = {
		kind = "RemoteEvent",
		description = "Buy a ride / hoverboard with Dream Essence. Server checks catalog, price and ownership.",
		args = { ITEM_ID },
		rate = { rate = 2, burst = 3 },
		restrictable = true,
		exclusive = true,
	},
	EquipRide = {
		kind = "RemoteEvent",
		description = "Equip an owned ride (nil unequips). Server checks ownership, then sets the "
			.. "movement modifier with AntiCheat.setMovementModifier.",
		args = { { type = "string", maxLength = 32, pattern = "[%w_]+", optional = true } },
		rate = { rate = 2, burst = 4 },
	},

	--------------------------------------------------------------------------
	-- Inventory and placement (the server owns the inventory)
	--------------------------------------------------------------------------
	EquipCharacter = {
		kind = "RemoteEvent",
		description = "Equip a character by its unique id. Server checks it is in this player's "
			.. "inventory and a slot is free.",
		args = { UNIQUE_ID },
		rate = { rate = 8, burst = 10 },
	},
	UnequipCharacter = {
		kind = "RemoteEvent",
		description = "Unequip a character by its unique id. Server checks it is equipped.",
		args = { UNIQUE_ID },
		rate = { rate = 8, burst = 10 },
	},
	PlaceCharacter = {
		kind = "RemoteEvent",
		description = "Place an owned character on a plot slot. Server checks ownership, that the "
			.. "slot exists on this player's plot and is unlocked.",
		args = { UNIQUE_ID, { type = "integer", min = 1, max = 100 } },
		rate = { rate = 8, burst = 10 },
	},
	EquipBest = {
		kind = "RemoteEvent",
		description = "Equip the best owned characters. Server computes \"best\" from its own data.",
		args = {},
		rate = { rate = 1, burst = 2 },
	},
	SellCharacters = {
		kind = "RemoteEvent",
		description = "Sell owned characters by unique id. Server checks each is owned, not equipped "
			.. "or locked, and computes the sale value itself.",
		args = { { type = "array", of = UNIQUE_ID, maxLength = 200, unique = true } },
		rate = { rate = 2, burst = 3 },
		restrictable = true,
		exclusive = true,
	},
	SetAutoSell = {
		kind = "RemoteEvent",
		description = "Choose which rarities Auto Sell sells. The server does the selling.",
		args = { { type = "array", of = { type = "enum", values = RARITIES }, maxLength = #RARITIES, unique = true } },
		rate = { rate = 2, burst = 4 },
	},

	--------------------------------------------------------------------------
	-- Income and rewards (amounts and eligibility are server-calculated)
	--------------------------------------------------------------------------
	CollectCash = {
		kind = "RemoteEvent",
		description = "Collect stored plot income. Server computes the amount from placed characters "
			.. "and the time since the last collection.",
		args = {},
		rate = { rate = 2, burst = 3 },
		restrictable = true,
		exclusive = true,
	},
	ClaimIndexReward = {
		kind = "RemoteEvent",
		description = "Claim an Index reward. Server checks the entry is discovered and not already "
			.. "claimed in saved data (plus Economy.claimOnce for the save race).",
		args = { ITEM_ID },
		rate = { rate = 2, burst = 4 },
		restrictable = true,
		exclusive = true,
	},
	ClaimDailyReward = {
		kind = "RemoteEvent",
		description = "Claim the daily reward. Server checks the last claim time in saved data (os.time).",
		args = {},
		rate = { rate = 0.5, burst = 2 },
		restrictable = true,
		exclusive = true,
	},
	ClaimAfkReward = {
		kind = "RemoteEvent",
		description = "Claim AFK rewards. Server computes them from its own timestamps; the client "
			.. "never says how long it was AFK.",
		args = {},
		rate = { rate = 0.2, burst = 1 },
		restrictable = true,
		exclusive = true,
	},
	RedeemCode = {
		kind = "RemoteFunction",
		description = "Redeem a code. Server checks the code list, expiry and saved redemptions. "
			.. "Slow rate limit against guessing.",
		args = { { type = "string", maxLength = 32, pattern = "[%w_%-]+" } },
		rate = { rate = 0.5, burst = 3 },
		restrictable = true,
		exclusive = true,
	},
	Rebirth = {
		kind = "RemoteEvent",
		description = "Rebirth. Server checks the requirement from saved data, resets and rewards "
			.. "in one transaction, and moves the character with AntiCheat.teleport.",
		args = {},
		rate = { rate = 0.5, burst = 1 },
		restrictable = true,
		exclusive = true,
	},
}

return RemoteContracts
