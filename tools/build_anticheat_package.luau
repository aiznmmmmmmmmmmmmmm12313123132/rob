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
		"",
		"NOTE",
		"",
		"  The scripts passed 51 automated tests against a simulated engine, but they",
		"  haven't been run inside Roblox Studio yet. Use the tester panel once before",
		"  publishing.",
		"",
	}, "\n")
)

local zipped = run("zip", { "-r", "-q", PACKAGE .. ".zip", PACKAGE }, "dist") ~= nil

print(`Built {OUT}`)
print(`  AntiCheat.rbxm        {antiCheatBytes} bytes (round trip OK)`)
print(`  AntiCheatTester.rbxm  {testerBytes} bytes (round trip OK)`)
print(table.concat(tree, "\n"))
print(if zipped then `Zipped to {OUT}.zip` else "zip not found: zip the folder by hand")
