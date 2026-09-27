--[[
	Builds the downloadable anti-cheat package, run with Lune from the repo root:

		lune run tools/build_anticheat_package

	Output (dist/ is git-ignored):

		dist/CartoonDice_AntiCheat/
		  README.txt
		  Import into Roblox Studio/
		    AntiCheat.rbxm          -> right-click ServerScriptService > Insert from File
		    AntiCheatTester.rbxm    -> right-click StarterPlayerScripts > Insert from File (optional)
		  Source/                   the same scripts as .luau files, laid out like Studio
		  Docs/anti-cheat.md
		  Tests/anticheat/          Lune tests: `lune run Tests/anticheat/run` from the package root
		  CartoonDice_AntiCheat_FULL.md   everything above in one text file (briefing for
		                                  another AI + docs + every script), to paste or upload
		dist/CartoonDice_AntiCheat.zip

	The .rbxm models are built from src/ with Lune's Roblox library, then read
	back and compared with the source files, so what you import is exactly
	what the tests ran against.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Instance = roblox.Instance

local PACKAGE = "CartoonDice_AntiCheat"
local OUT = "dist/" .. PACKAGE
local IMPORT = OUT .. "/Import into Roblox Studio"

local SERVER_SOURCE = "src/ServerScriptService/AntiCheat"
local TESTER_SOURCE = "src/StarterPlayer/StarterPlayerScripts/AntiCheatTester.client.luau"

assert(fs.isDir(SERVER_SOURCE), "run this from the repository root")

--------------------------------------------------------------------------------
-- Instances from files: *.server.luau = Script, *.client.luau = LocalScript,
-- other *.luau = ModuleScript, directories = Folder.
--------------------------------------------------------------------------------

local function sortedEntries(dir: string): { string }
	local entries = fs.readDir(dir)
	table.sort(entries)
	return entries
end

local function scriptFromFile(path: string)
	local file = string.match(path, "[^/]+$") :: string
	local className, name
	if string.match(file, "%.server%.luau$") then
		className, name = "Script", (string.gsub(file, "%.server%.luau$", ""))
	elseif string.match(file, "%.client%.luau$") then
		className, name = "LocalScript", (string.gsub(file, "%.client%.luau$", ""))
	else
		className, name = "ModuleScript", (string.gsub(file, "%.luau$", ""))
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Source = fs.readFile(path)
	return instance
end

local function folderFromDir(dir: string, name: string)
	local folder = Instance.new("Folder")
	folder.Name = name
	for _, entry in sortedEntries(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			folderFromDir(path, entry).Parent = folder
		elseif string.match(entry, "%.luau$") then
			scriptFromFile(path).Parent = folder
		end
	end
	return folder
end

--------------------------------------------------------------------------------
-- Round-trip check
--------------------------------------------------------------------------------

local function describe(instance, prefix: string, into: { string })
	local line = `{prefix}{instance.Name} [{instance.ClassName}]`
	if instance:IsA("LuaSourceContainer") then
		line ..= ` {#instance.Source} bytes`
	end
	table.insert(into, line)
	local children = instance:GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)
	for _, child in children do
		describe(child, prefix .. "  ", into)
	end
end

local function sameTree(a, b): boolean
	if a.Name ~= b.Name or a.ClassName ~= b.ClassName then
		return false
	end
	if a:IsA("LuaSourceContainer") and a.Source ~= b.Source then
		return false
	end
	local aChildren, bChildren = a:GetChildren(), b:GetChildren()
	if #aChildren ~= #bChildren then
		return false
	end
	for _, child in aChildren do
		local match = b:FindFirstChild(child.Name)
		if not match or not sameTree(child, match) then
			return false
		end
	end
	return true
end

local function writeModel(path: string, instance)
	local bytes = roblox.serializeModel({ instance })
	fs.writeFile(path, bytes)
	local loaded = roblox.deserializeModel(fs.readFile(path))
	assert(#loaded == 1 and sameTree(instance, loaded[1]), `round trip failed for {path}`)
	return #bytes
end

--------------------------------------------------------------------------------
-- Copy helpers
--------------------------------------------------------------------------------

local function copyFile(from: string, to: string)
	fs.writeFile(to, fs.readFile(from))
end

local function copyTree(from: string, to: string)
	fs.writeDir(to)
	for _, entry in sortedEntries(from) do
		local source = from .. "/" .. entry
		if fs.isDir(source) then
			copyTree(source, to .. "/" .. entry)
		else
			copyFile(source, to .. "/" .. entry)
		end
	end
end

local function run(program: string, args: { string }, cwd: string?): string?
	local ok, result = pcall(process.exec, program, args, { cwd = cwd })
	if ok and result.ok then
		return (string.gsub(result.stdout, "%s+$", ""))
	end
	return nil
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

if fs.isDir(OUT) then
	fs.removeDir(OUT)
end
if fs.isFile(OUT .. ".zip") then
	fs.removeFile(OUT .. ".zip")
end
fs.writeDir(IMPORT)

local antiCheat = folderFromDir(SERVER_SOURCE, "AntiCheat")
local tester = scriptFromFile(TESTER_SOURCE)

local antiCheatBytes = writeModel(IMPORT .. "/AntiCheat.rbxm", antiCheat)
local testerBytes = writeModel(IMPORT .. "/AntiCheatTester.rbxm", tester)

copyTree(SERVER_SOURCE, OUT .. "/Source/ServerScriptService/AntiCheat")
fs.writeDir(OUT .. "/Source/StarterPlayer/StarterPlayerScripts")
copyFile(TESTER_SOURCE, OUT .. "/Source/StarterPlayer/StarterPlayerScripts/AntiCheatTester.client.luau")
fs.writeDir(OUT .. "/Docs")
copyFile("docs/anti-cheat.md", OUT .. "/Docs/anti-cheat.md")
copyTree("tests/anticheat", OUT .. "/Tests/anticheat")

local tree = {}
describe(antiCheat, "      ", tree)
local commit = run("git", { "rev-parse", "--short", "HEAD" }) or "unknown"

fs.writeFile(
	OUT .. "/README.txt",
	table.concat({
		"CARTOON DICE - ANTI-CHEAT",
		`Built {os.date("%Y-%m-%d")} from commit {commit}.`,
		"",
		"INSTALL IN ROBLOX STUDIO",
		"",
		"1. If you installed the free \"Anti Cheat System v1.5\" model, delete its two",
		"   scripts and ReplicatedStorage > AntiCheatEvent.",
		"",
		"2. In the Explorer, right-click ServerScriptService > Insert from File...",
		"   and pick \"Import into Roblox Studio/AntiCheat.rbxm\".",
		"   (Dragging the file onto ServerScriptService works too.)",
		"   You should now have:",
		"",
		"   ServerScriptService",
		table.concat(tree, "\n"),
		"",
		"   It must be in ServerScriptService, not Workspace: clients can't see",
		"   anything in ServerScriptService.",
		"",
		"3. Optional, for testing: right-click StarterPlayer > StarterPlayerScripts >",
		"   Insert from File... and pick \"AntiCheatTester.rbxm\". It shows a panel of",
		"   exploit-style test buttons in Studio play-tests and does nothing in live games.",
		"",
		"4. Open AntiCheat > Config. Add your team's UserIds to DeveloperUserIds /",
		"   ModeratorUserIds. The place owner is a developer automatically.",
		"",
		"5. Press Play. The Output shows:",
		"     [AntiCheat] started (TEST_MODE: kicks are simulated, DEBUG on)",
		"   Five seconds later it lists every remote that isn't protected yet.",
		"   In Studio, nobody is ever kicked or banned (TEST_MODE).",
		"",
		"6. Hook up the game's remotes and teleports: Docs/anti-cheat.md, section",
		"   \"Integrating with Cartoon Dice\". Move each remote handler into",
		"   AntiCheat.bindRemote and DELETE its old OnServerEvent:Connect, or the old",
		"   unprotected handler keeps running.",
		"",
		"WHAT'S IN THIS FOLDER",
		"",
		"  Import into Roblox Studio/   the two model files above",
		"  Source/                      the same scripts as plain .luau text, laid out",
		"                               like Studio (to read, diff or paste by hand)",
		"  Docs/anti-cheat.md           how it works, setup, integration, tuning,",
		"                               testing, performance and known limits",
		"  Tests/anticheat/             automated tests for Lune (not needed in Studio):",
		"                               from this folder run  lune run Tests/anticheat/run",
		"  CartoonDice_AntiCheat_FULL.md  everything in one text file: a briefing for another",
		"                               AI assistant, the docs and every script with its",
		"                               Studio location. Paste or upload it to that AI.",
		"",
		"NOTE",
		"",
		"  The scripts passed 51 automated tests against a simulated engine, but they",
		"  haven't been run inside Roblox Studio yet. Use the tester panel once before",
		"  publishing.",
		"",
	}, "\n")
)

--------------------------------------------------------------------------------
-- One-file version for AI assistants
--------------------------------------------------------------------------------

-- Moves every Markdown heading down one level, outside code fences, so the
-- docs nest under this file's own headings.
local function demoteHeadings(markdown: string): string
	local lines = {}
	local inFence = false
	for line in string.gmatch(markdown, "([^\n]*)\n?") do
		if string.match(line, "^```") then
			inFence = not inFence
		elseif not inFence and string.match(line, "^#+ ") then
			line = "#" .. line
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

local function studioPath(file: string): (string, string)
	local relative = string.gsub(file, "^src/", "")
	local className = if string.match(file, "%.server%.luau$")
		then "Script"
		elseif string.match(file, "%.client%.luau$") then "LocalScript"
		else "ModuleScript"
	local path = string.gsub(string.gsub(relative, "%.server%.luau$", ""), "%.client%.luau$", "")
	path = string.gsub(path, "%.luau$", "")
	return (string.gsub(path, "/", " > ")), className
end

local function codeSection(file: string, heading: string?): string
	local source = fs.readFile(file)
	-- A fence longer than any backtick run inside the file, so nothing in it
	-- can close the block early.
	local longest = 0
	for run in string.gmatch(source, "`+") do
		longest = math.max(longest, #run)
	end
	local fence = string.rep("`", math.max(3, longest + 1))
	local title, className = studioPath(file)
	if string.sub(file, 1, 4) ~= "src/" then
		title, className = file, "Lune script, not used in Studio"
	end
	return table.concat({
		`### {heading or title}`,
		"",
		`{className} - file \`{file}\``,
		"",
		fence .. "lua",
		(string.gsub(source, "\n$", "")),
		fence,
		"",
	}, "\n")
end

local SERVER_ORDER = {
	"AntiCheat.server.luau",
	"Api.luau",
	"Config.luau",
	"RemoteContracts.luau",
	"Modules/MovementValidator.luau",
	"Modules/RemoteValidator.luau",
	"Modules/EconomyValidator.luau",
	"Modules/RateLimiter.luau",
	"Modules/ViolationTracker.luau",
	"Modules/ExemptionManager.luau",
	"Modules/EvidenceLogger.luau",
	"Modules/Enforcement.luau",
}

-- Every server file must be listed, so a new module can't be left out.
local listed = {}
for _, name in SERVER_ORDER do
	listed[SERVER_SOURCE .. "/" .. name] = true
end
local function assertListed(dir: string)
	for _, entry in sortedEntries(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			assertListed(path)
		elseif string.match(entry, "%.luau$") then
			assert(listed[path], `{path} is missing from SERVER_ORDER`)
		end
	end
end
assertListed(SERVER_SOURCE)

local BRIEFING = [==[
# Cartoon Dice anti-cheat: complete reference for AI assistants

This one file holds everything about the Cartoon Dice anti-cheat: a briefing,
the full documentation, and the complete source of every script, each with
the exact place it lives in Roblox Studio. Built BUILD_DATE from commit
BUILD_COMMIT.

Contents:

1. Briefing (read first)
2. Documentation
3. Source: ServerScriptService > AntiCheat
4. Source: StarterPlayer > StarterPlayerScripts > AntiCheatTester
5. Tests and tools (optional: Lune only, never used in Studio)

## 1. Briefing

**The game.** Cartoon Dice is a Roblox dice / RNG / character-collection game:
buy dice, roll, receive characters, place them to earn cash, buy upgrades,
rebirth. Currencies: Cash, Gems, Dream Essence. Purchasable rides and
hoverboards are planned.

**What this is.** A server-side security layer: movement validation, a remote
gateway (rate limits and argument validation), economy helpers, a decaying
violation score and graded enforcement. In the developer's place it is
installed like this:

```
ServerScriptService
└── AntiCheat                  Folder
    ├── AntiCheat              Script        starts everything
    ├── Api                    ModuleScript  the only module game code requires
    ├── Config                 ModuleScript  every tunable number
    ├── RemoteContracts        ModuleScript  one contract per gameplay remote
    └── Modules                Folder
        ├── MovementValidator, RemoteValidator, EconomyValidator, RateLimiter,
        └── ViolationTracker, ExemptionManager, EvidenceLogger, Enforcement
StarterPlayer > StarterPlayerScripts
└── AntiCheatTester            LocalScript   Studio-only test panel
```

Files map to Studio like this: `Name.server.luau` is a Script, `Name.client.luau`
is a LocalScript, any other `Name.luau` is a ModuleScript, and folders are
Folders. To apply a change in Studio, replace that script's whole Source with
the new text.

**Rules to keep when changing it:**

1. **The server is the authority.** The client only asks; the server decides
   rolls, rewards, prices, ownership, currency and movement permissions. No
   remote accepts an amount, price, rarity or result from the client.
2. **False positives are worse than missed cheats.** Detections never kick
   directly: they report into the ViolationTracker (the `report` callback or
   `AntiCheat.flag`), and Enforcement acts on the level. Don't add instant
   kicks. Never add automatic bans; `moderatorBan` is the only ban path.
3. **Every gameplay remote goes through the gateway:**
   `AntiCheat.bindRemote(name, handler, options)`, with a contract in
   RemoteContracts (argument schema, rate limit, flags). Never connect
   `OnServerEvent` to a gameplay remote directly.
4. **Server-caused movement is declared.** Use `AntiCheat.teleport` /
   `AntiCheat.exempt`. Set speed on the server's Humanoid or with
   `AntiCheat.setMovementModifier`. Client-side speed changes are flagged on
   purpose.
5. **Every currency change goes through**
   `AntiCheat.Economy.applyChange(player, currency, balance, delta, reason)`,
   with a reason from `Config.Economy.Reasons` (add new reasons there).
   - Purchases and claims run inside `Economy.transaction`.
   - One-time rewards check saved data plus `Economy.claimOnce`.
6. **Tunables belong in Config.** Prefer changing Config to changing logic.
7. **Stay lightweight:**
   - one central Heartbeat loop, 4 samples a second per player
   - no per-player loops, per-frame raycasts or Workspace scans
   - no allocations on the common per-sample path
8. **Style:** `--!strict` Luau; each module is a table of functions made by
   `.new(deps)`; dependencies are passed in, not required across modules;
   comments say why. Keep the module boundaries.
9. **TEST_MODE is automatic in Studio** (kicks and bans are only logged). Keep
   destructive enforcement impossible in Studio.
10. **Verify changes.** With Lune (https://lune-org.github.io/docs), run
    `lune run tests/anticheat/run` from the repo root: all 51 tests must pass.
    Add a test for any new behaviour; the normal-play tests must stay at 0
    points.

**Public API.** Game server code uses
`local AntiCheat = require(game.ServerScriptService.AntiCheat.Api)`.

| Call | Purpose |
| --- | --- |
| `bindRemote(name, handler, options?)` | Bind a remote behind its contract. Options: `cooldown` (seconds, or a function of the player), `rate` `{rate, burst}`, `shop` (ShopId), `checks` `{[argIndex] = function(value): boolean}`, `contract` (for remotes not in RemoteContracts) |
| `teleport(player, cframe, reason)` | Move a player from the server, exempted and re-measured |
| `exempt(player, reason, seconds)` | Ignore a player's movement for up to 120 s (knockback, launch pads) |
| `setMovementModifier(player, key, {speedMultiplier?, maxSpeed?, allowFlight?, allowNoclip?}, seconds?)`, `clearMovementModifier(player, key)` | Rides and buffs |
| `flag(player, kind, details?, severity?)` | Report something the game caught; kinds are the keys of `Config.Violations.Weights` |
| `Economy.applyChange`, `transaction`, `claimOnce`, `lookup`, `isNearShop`, `getLedger`, `canAfford`, `isValidAmount`, `isValidQuantity` | Economy helpers |
| `getScore`, `getEvidence`, `getSummary`, `onEvidence(callback)` | Evidence |
| `getRole`, `isStaff`, `moderatorBan(moderator, userId, seconds, reason)` | Staff |
| `validate(specs, args, count)` | The gateway's argument checks, for hand-written validation |
| `auditRemotes()` | Remotes that aren't behind the gateway |

**Where to make common changes:**

| To change | Edit |
| --- | --- |
| The real roll cooldown, or roll-speed upgrades | `bindRemote("RollDice", handler, { cooldown = function(player) ... end })` |
| Add or rename a remote | its entry in RemoteContracts, then `bindRemote` |
| Check catalog ids | `checks = { [1] = function(id) return Catalog[id] ~= nil end }` |
| How sensitive detection is | `Config.Movement` (tolerances), `Config.Violations` (weights, caps, decay) |
| When corrections and kicks happen | `Config.Enforcement` (Levels, KickMinEvents, the Allow switches) |
| Staff | `Config.Permissions` |
| Currencies or transaction reasons | `Config.Economy.Currencies` / `Reasons` |
| Rides and hoverboards | `setMovementModifier` on equip, `clearMovementModifier` on unequip |
| World shop distance | tag the part or model `Shop` with a `ShopId` (and `Radius`, `Active`), bind with `{ shop = "..." }` |
| Load on very full servers | `Config.Movement.SampleInterval`, `Config.Movement.Noclip.Enabled` |

**Status.**
- It passed 51 automated tests (Lune, simulated engine). The author couldn't
  run it inside Roblox Studio. If the Output shows engine errors, check the
  Roblox API calls first.
- The game's own server handlers (rolling, shop, player data) weren't part of
  this work. RemoteContracts describes what each handler must decide for
  itself.
- More detail is under "Known limits" in the documentation below.

## 2. Documentation

]==]

local parts = {
	(string.gsub(string.gsub(BRIEFING, "BUILD_DATE", os.date("%Y-%m-%d")), "BUILD_COMMIT", commit)),
	demoteHeadings(fs.readFile("docs/anti-cheat.md")),
	"",
	"## 3. Source: ServerScriptService > AntiCheat",
	"",
}
for _, name in SERVER_ORDER do
	table.insert(parts, codeSection(SERVER_SOURCE .. "/" .. name))
end
table.insert(parts, "## 4. Source: StarterPlayer > StarterPlayerScripts > AntiCheatTester\n")
table.insert(parts, codeSection(TESTER_SOURCE))
table.insert(parts, "## 5. Tests and tools (optional: Lune only, never used in Studio)\n")
table.insert(
	parts,
	"Run from the repository root with Lune. `run.luau` is the test suite, `harness.luau` the simulated engine it uses, `bench.luau` the cost benchmark and `build_anticheat_package.luau` builds the importable package.\n"
)
for _, file in { "tests/anticheat/run.luau", "tests/anticheat/harness.luau", "tests/anticheat/bench.luau", "tools/build_anticheat_package.luau" } do
	table.insert(parts, codeSection(file))
end
local full = table.concat(parts, "\n")
fs.writeFile(OUT .. "/" .. PACKAGE .. "_FULL.md", full)

local zipped = run("zip", { "-r", "-q", PACKAGE .. ".zip", PACKAGE }, "dist") ~= nil

print(`Built {OUT}`)
print(`  AntiCheat.rbxm        {antiCheatBytes} bytes (round trip OK)`)
print(`  AntiCheatTester.rbxm  {testerBytes} bytes (round trip OK)`)
print(table.concat(tree, "\n"))
print(`  {PACKAGE}_FULL.md  {#full} bytes`)
print(if zipped then `Zipped to {OUT}.zip` else "zip not found: zip the folder by hand")
