--!strict
--[[
	RateLimiter (ModuleScript)
	Location: ServerScriptService > AntiCheat > Modules > RateLimiter

	Token buckets, one per player per action. A bucket holds up to `burst`
	tokens and refills at `rate` tokens per second; every request spends one.
	Requests with no token left are dropped, never queued, so spamming a remote
	can't build up a backlog of hidden actions.

	For an action with a real cooldown (rolling), use fromCooldown. A request
	may arrive up to `jitter` seconds early (network jitter) and still count:
	the bucket just goes into a small debt that the next interval repays, so
	over any longer stretch it's still exactly one per cooldown.

		local limiter = RateLimiter.new()
		local rule = RateLimiter.fromCooldown(1.5)
		if not limiter.consume(player, "RollDice", rule) then return end
]]

export type Rule = {
	rate: number, -- tokens per second
	burst: number, -- bucket size
	tolerance: number?, -- fraction of a token a request may be short (0-0.9)
}

type Bucket = {
	tokens: number,
	updated: number,
	windowStart: number,
	denied: number, -- denied requests in the current one-second window
}

export type RateLimiter = {
	-- Returns whether the request is allowed, and how many requests this
	-- bucket has denied in the last second (for flood detection).
	consume: (owner: any, action: string, rule: Rule) -> (boolean, number),
	reset: (owner: any, action: string?) -> (),
	remove: (owner: any) -> (),
}

local RateLimiter = {}

-- `jitter` is how many seconds early a request may arrive (default 0.3).
function RateLimiter.fromCooldown(cooldown: number, jitter: number?): Rule
	local seconds = math.max(cooldown, 0.01)
	return { rate = 1 / seconds, burst = 1, tolerance = math.min((jitter or 0.3) / seconds, 0.9) }
end

function RateLimiter.new(clock: (() -> number)?): RateLimiter
	local now = clock or os.clock
	local owners: { [any]: { [string]: Bucket } } = {}

	local function consume(owner: any, action: string, rule: Rule): (boolean, number)
		local t = now()
		local buckets = owners[owner]
		if not buckets then
			buckets = {}
			owners[owner] = buckets
		end
		local bucket = buckets[action]
		if not bucket then
			bucket = { tokens = rule.burst, updated = t, windowStart = t, denied = 0 }
			buckets[action] = bucket
		end

		bucket.tokens = math.min(rule.burst, bucket.tokens + (t - bucket.updated) * rule.rate)
		bucket.updated = t
		if t - bucket.windowStart >= 1 then
			bucket.windowStart = t
			bucket.denied = 0
		end

		if bucket.tokens >= 1 - math.clamp(rule.tolerance or 0, 0, 0.9) then
			bucket.tokens -= 1
			return true, bucket.denied
		end
		bucket.denied += 1
		return false, bucket.denied
	end

	local function reset(owner: any, action: string?)
		local buckets = owners[owner]
		if buckets and action then
			buckets[action] = nil
		elseif buckets then
			owners[owner] = nil
		end
	end

	local function remove(owner: any)
		owners[owner] = nil
	end

	return {
		consume = consume,
		reset = reset,
		remove = remove,
	}
end

return RateLimiter
