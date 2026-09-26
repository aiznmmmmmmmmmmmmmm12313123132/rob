--!strict
--[[
	EconomyValidator (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > EconomyValidator

	Helpers for the game's own economy code. The balances stay wherever the
	game keeps them; this module makes every change explainable and refuses
	the impossible ones.

	  applyChange       every balance change goes through here with a reason
	                    from Config.Economy.Reasons. NaN, infinity, negative
	                    results, balances over MaxBalance and a reason used in
	                    the wrong direction (a "Purchase" that adds money) are
	                    refused. Accepted changes go into a per-player ledger,
	                    so the server can answer "why does this player have
	                    this?".
	  lookup            safe catalog lookup for a client-supplied id.
	  transaction       per-player lock: while a purchase / claim is running
	                    (and yielding), a second one is refused, so double
	                    clicks and replayed requests can't pay out twice. The
	                    lock is released even if the function errors, and a
	                    lock older than LOCK_TIMEOUT counts as stale.
	  claimOnce         session-level "already claimed" guard for one-time
	                    rewards. Persist the claim in the player's saved data
	                    as well; this only closes the race before the save.
	  isNearShop        server-side distance check against a tagged shop.

		local Economy = AntiCheat.Economy
		Economy.transaction(player, function()
			local ok, newCash = Economy.applyChange(player, "Cash", data.Cash, -price, "DicePurchase")
			if ok then
				data.Cash = newCash
				data.OwnedDice[diceId] = true
			end
		end) -- returns false (and runs nothing) while another one is running
]]

local LOCK_TIMEOUT = 30

export type LedgerEntry = {
	time: number,
	currency: string,
	delta: number,
	reason: string,
	balance: number,
}

export type EconomyDeps = {
	config: any, -- Config.Economy
	getRootPosition: (player: Player) -> Vector3?,
	getWalkSpeed: (player: Player) -> number,
	getPing: (player: Player) -> number,
	getShops: (shopId: string) -> { Instance },
}

export type EconomyValidator = {
	isValidAmount: (value: any, maxValue: number?) -> boolean,
	isValidQuantity: (value: any, maxQuantity: number) -> boolean,
	canAfford: (balance: any, price: any) -> boolean,
	applyChange: (player: Player, currency: string, balance: number, delta: number, reason: string) -> (boolean, any),
	getLedger: (player: Player, count: number?) -> { LedgerEntry },
	lookup: (catalog: { [string]: any }, id: any) -> any,
	beginTransaction: (player: Player) -> (() -> ())?,
	transaction: (player: Player, fn: () -> ()) -> boolean,
	claimOnce: (player: Player, claimKey: string) -> boolean,
	isNearShop: (player: Player, shopId: string) -> (boolean, string?, boolean),
	removePlayer: (player: Player) -> (),
}

local EconomyValidator = {}

local function isFinite(value: any): boolean
	return type(value) == "number" and math.isfinite(value)
end

function EconomyValidator.new(deps: EconomyDeps): EconomyValidator
	local config = deps.config
	local ledgers: { [Player]: { entries: { LedgerEntry }, nextIndex: number } } = {}
	local locks: { [Player]: number } = {} -- when the lock was taken
	local claims: { [Player]: { [string]: boolean } } = {}
	local warnedShops: { [string]: boolean } = {}

	local function isValidAmount(value: any, maxValue: number?): boolean
		return isFinite(value) and value >= 0 and value <= (maxValue or config.MaxBalance)
	end

	local function isValidQuantity(value: any, maxQuantity: number): boolean
		return isFinite(value) and value == math.floor(value) and value >= 1 and value <= maxQuantity
	end

	local function canAfford(balance: any, price: any): boolean
		return isValidAmount(balance) and isValidAmount(price) and balance >= price
	end

	-- Ring buffer; old entry tables are reused, so frequent income ticks
	-- don't create garbage.
	local function record(player: Player, currency: string, delta: number, reason: string, balance: number)
		local ledger = ledgers[player]
		if not ledger then
			ledger = { entries = {}, nextIndex = 1 }
			ledgers[player] = ledger
		end
		local entry = ledger.entries[ledger.nextIndex]
		if entry then
			entry.time = os.time()
			entry.currency = currency
			entry.delta = delta
			entry.reason = reason
			entry.balance = balance
		else
			ledger.entries[ledger.nextIndex] = {
				time = os.time(),
				currency = currency,
				delta = delta,
				reason = reason,
				balance = balance,
			}
		end
		ledger.nextIndex = ledger.nextIndex % config.LedgerSize + 1
	end

	-- Returns (true, newBalance) or (false, reason). The caller stores the new
	-- balance; nothing is changed on failure.
	local function applyChange(player: Player, currency: string, balance: number, delta: number, reason: string): (boolean, any)
		if not table.find(config.Currencies, currency) then
			warn(`[AntiCheat] economy change refused: unknown currency {tostring(currency)}`)
			return false, "UnknownCurrency"
		end
		local rule = config.Reasons[reason]
		if not rule then
			warn(`[AntiCheat] economy change refused: unknown reason {tostring(reason)}`)
			return false, "UnknownReason"
		end
		if rule.currencies and not table.find(rule.currencies, currency) then
			warn(`[AntiCheat] economy change refused: {reason} can't change {currency}`)
			return false, "CurrencyNotAllowed"
		end
		if not isValidAmount(balance) then
			warn(`[AntiCheat] economy change refused: {player.Name}'s {currency} balance is corrupt ({tostring(balance)})`)
			return false, "CorruptBalance"
		end
		if not isFinite(delta) then
			return false, "InvalidAmount"
		end
		if (rule.sign == "+" and delta < 0) or (rule.sign == "-" and delta > 0) then
			warn(`[AntiCheat] economy change refused: {reason} must be {rule.sign}, got {delta}`)
			return false, "WrongDirection"
		end
		local newBalance = balance + delta
		if newBalance < 0 then
			return false, "InsufficientFunds"
		end
		if newBalance > config.MaxBalance then
			return false, "AboveMaxBalance"
		end
		record(player, currency, delta, reason, newBalance)
		return true, newBalance
	end

	-- Newest first, as copies (the ring's tables get reused).
	local function getLedger(player: Player, count: number?): { LedgerEntry }
		local result: { LedgerEntry } = {}
		local ledger = ledgers[player]
		if not ledger then
			return result
		end
		local size = config.LedgerSize
		local index = ledger.nextIndex
		for _ = 1, math.min(count or size, size) do
			index = (index - 2) % size + 1
			local entry = ledger.entries[index]
			if not entry then
				break
			end
			table.insert(result, table.clone(entry))
		end
		return result
	end

	-- A client-supplied id: only plain strings, only the catalog's own keys.
	local function lookup(catalog: { [string]: any }, id: any): any
		if type(id) ~= "string" or #id == 0 or #id > 64 then
			return nil
		end
		return rawget(catalog, id)
	end

	local function beginTransaction(player: Player): (() -> ())?
		local now = os.clock()
		local taken = locks[player]
		if taken and now - taken < LOCK_TIMEOUT then
			return nil
		end
		locks[player] = now
		local released = false
		return function()
			if not released then
				released = true
				if locks[player] == now then
					locks[player] = nil
				end
			end
		end
	end

	-- Runs `fn` holding the player's lock. Returns false if another
	-- transaction is still running. Errors are re-raised after unlocking.
	local function transaction(player: Player, fn: () -> ()): boolean
		local release = beginTransaction(player)
		if not release then
			return false
		end
		local ok, err = pcall(function()
			fn()
		end)
		release()
		if not ok then
			error(err, 0)
		end
		return true
	end

	local function claimOnce(player: Player, claimKey: string): boolean
		local claimed = claims[player]
		if not claimed then
			claimed = {}
			claims[player] = claimed
		end
		if claimed[claimKey] then
			return false
		end
		claimed[claimKey] = true
		return true
	end

	local function shopPosition(shop: Instance): Vector3?
		if shop:IsA("BasePart") then
			return shop.Position
		elseif shop:IsA("Model") then
			return shop:GetPivot().Position
		end
		return nil
	end

	-- Returns (near, reason, suspicious). Only absurd distances are
	-- suspicious; walking away while the purchase is in flight is normal.
	local function isNearShop(player: Player, shopId: string): (boolean, string?, boolean)
		local position = deps.getRootPosition(player)
		if not position then
			return false, "NoCharacter", false
		end
		local shops = deps.getShops(shopId)
		if #shops == 0 then
			if not warnedShops[shopId] then
				warnedShops[shopId] = true
				warn(`[AntiCheat] no instance tagged "{config.ShopTag}" has ShopId "{shopId}"; purchases there are refused`)
			end
			return false, "UnknownShop", false
		end

		local slack = config.ShopSlack + deps.getPing(player) * deps.getWalkSpeed(player)
		local closest = math.huge
		local closestAllowed = config.DefaultShopRadius + slack
		for _, shop in shops do
			if shop:GetAttribute("Active") == false then
				continue
			end
			local shopAt = shopPosition(shop)
			if not shopAt then
				continue
			end
			local radius = shop:GetAttribute("Radius")
			if not isFinite(radius) or (radius :: number) <= 0 then
				radius = config.DefaultShopRadius
			end
			local allowed = (radius :: number) + slack
			local distance = (shopAt - position).Magnitude
			if distance <= allowed then
				return true, nil, false
			end
			if distance < closest then
				closest = distance
				closestAllowed = allowed
			end
		end
		if closest == math.huge then
			return false, "ShopClosed", false
		end
		return false, "TooFar", closest > closestAllowed * 3 + 50
	end

	local function removePlayer(player: Player)
		ledgers[player] = nil
		locks[player] = nil
		claims[player] = nil
	end

	return {
		isValidAmount = isValidAmount,
		isValidQuantity = isValidQuantity,
		canAfford = canAfford,
		applyChange = applyChange,
		getLedger = getLedger,
		lookup = lookup,
		beginTransaction = beginTransaction,
		transaction = transaction,
		claimOnce = claimOnce,
		isNearShop = isNearShop,
		removePlayer = removePlayer,
	}
end

return EconomyValidator
