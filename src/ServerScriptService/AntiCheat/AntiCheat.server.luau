--!strict
--[[
	AntiCheat (Script)
	Location: ServerScriptService > AntiCheat > AntiCheat

	Starts the anti-cheat: player registry, the single movement loop, the
	remote audit and (in TEST_MODE) the demo remote handlers. Everything else
	lives in the Api module next to this script; game code requires that:

		local AntiCheat = require(game.ServerScriptService.AntiCheat.Api)

	Setup, integration and tuning: docs/anti-cheat.md.
]]

local AntiCheat = require(script.Parent.Api)

AntiCheat.start()
