--[[
	Rough cost of the anti-cheat's movement loop, run with Lune:

		lune run tests/anticheat/bench            (40 players, 60 s)
		lune run tests/anticheat/bench -- 100 120 (players, seconds)

	Prints the engine queries it makes per player per second, and the time
	spent in its own Luau code per sample. The stand-in raycasts here are slow
	Luau, so their time is measured separately and left out; in Roblox they're
	native code and cost a few microseconds each. Lune's Luau also runs without
	Roblox's native code generation, so real servers should be faster still.
]]

local process = require("@lune/process")
local H = require("./harness")

local Vector3 = H.Vector3

local numbers = {}
for _, arg in process.args do
	if tonumber(arg) then
		table.insert(numbers, tonumber(arg))
	end
end
local PLAYERS = numbers[1] or 40
local SECONDS = numbers[2] or 60

math.randomseed(3)

local sim = H.newWorld()
-- A few walls and a platform so the world queries have something to find.
for index = 1, 20 do
	sim.addPart({ name = "Wall", position = Vector3.new(index * 40 - 400, 10, 60), size = Vector3.new(30, 20, 2) })
end

local DIRECTIONS = { Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(0, 0, -1) }
local records = {}
for index = 1, PLAYERS do
	local player, record = sim.addPlayer({ name = `P{index}`, ping = 0.05 + (index % 5) * 0.05, jitter = 0.03 })
	sim.spawn(player, Vector3.new((index % 10) * 30 - 150, 0, math.floor(index / 10) * 30 - 150))
	record.phase = index
	table.insert(records, record)
end

sim.advance(4) -- past the spawn grace
for key in sim.stats do
	sim.stats[key] = 0
end

-- Everyone walks and jumps now and then: the busiest normal case.
sim.advance(SECONDS, function(t)
	for _, record in records do
		local leg = math.floor(t / 3 + record.phase) % 4 + 1
		record.client.move = DIRECTIONS[leg]
		if record.client.grounded and math.floor(t * 7 + record.phase) % 23 == 0 then
			record.client.jump = true
		end
	end
end)

local stats = sim.stats
local samples = PLAYERS * SECONDS * 4 -- SampleInterval 0.25
local ownTime = stats.heartbeatTime - stats.queryTime
local perPlayerSecond = function(count)
	return string.format("%.2f", count / (PLAYERS * SECONDS))
end

print(`{PLAYERS} players walking and jumping for {SECONDS} s ({samples} samples)`)
print(`  raycasts per player per second:        {perPlayerSecond(stats.raycasts)}`)
print(`  overlap queries per player per second: {perPlayerSecond(stats.overlaps)}`)
print(`  terrain reads per player per second:   {perPlayerSecond(stats.voxelReads)}`)
print(string.format("  anti-cheat Luau time per sample:       %.1f us", ownTime / samples * 1e6))
print(string.format("  anti-cheat Luau time per server frame: %.3f ms (60 fps frame = 16.7 ms)", ownTime / stats.frames * 1e3))
local points = 0
for _, record in records do
	points += sim.pointsFor(record.player)
end
print(`  points given to these normal players:  {points}`)
