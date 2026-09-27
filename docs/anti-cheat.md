# Anti-cheat

A server-side security layer for Cartoon Dice. It checks movement, validates
and rate-limits every gameplay remote, and makes currency changes
explainable. It is built to avoid false positives first: one odd measurement
never punishes anyone, lag is tolerated, the game's own teleports and rides
are exempt, and nothing ever bans automatically.

It started from the free "Anti Cheat System v1.5" model. That model turned
out to be broken and unsafe (see [the audit](#audit-of-anti-cheat-system-v15)),
so almost everything was replaced.

It makes the server the authority and closes the common exploit paths. It is
not exploit-proof: nothing that runs on a Roblox client can be.

## Files

```
ServerScriptService
└── AntiCheat                  Folder
    ├── AntiCheat              Script        starts everything (AntiCheat.server.luau)
    ├── Api                    ModuleScript  the only module game code requires
    ├── Config                 ModuleScript  every tunable number
    ├── RemoteContracts        ModuleScript  one contract per gameplay remote
    └── Modules                Folder
        ├── MovementValidator  speed, fly, teleport, noclip, impossible physics
        ├── RemoteValidator    argument checks + the remote gateway
        ├── EconomyValidator   balance changes, ledger, locks, claims, shop distance
        ├── RateLimiter        token buckets
        ├── ViolationTracker   suspicion score, decay, levels
        ├── ExemptionManager   exemptions, movement modifiers (rides), staff roles
        ├── EvidenceLogger     recent evidence + throttled output
        └── Enforcement        level -> action; the moderator ban path

StarterPlayer > StarterPlayerScripts
└── AntiCheatTester            LocalScript   Studio-only test buttons (optional)
```

Sources are in `src/ServerScriptService/AntiCheat/` and
`src/StarterPlayer/StarterPlayerScripts/AntiCheatTester.client.luau`. Tests
are in `tests/anticheat/`.

## Install

1. If you installed the free model, delete its two scripts and
   `ReplicatedStorage.AntiCheatEvent`.
2. In the Explorer, right-click **ServerScriptService** > **Insert from
   File...** and pick `AntiCheat.rbxm` from the package (dragging the file onto
   ServerScriptService works too). This gives the whole hierarchy above.
   Build the package with `lune run tools/build_anticheat_package`; it
   writes `dist/CartoonDice_AntiCheat/` and `dist/CartoonDice_AntiCheat.zip`.
   Without Lune, build the hierarchy by hand and paste each file in:
   `.server.luau` is a Script, every other `.luau` file is a ModuleScript.
3. Optional: insert `AntiCheatTester.rbxm` into **StarterPlayer >
   StarterPlayerScripts** the same way. It only runs in Studio.
4. In `Config.Permissions`, add your team's UserIds to `DeveloperUserIds` /
   `ModeratorUserIds`. The place owner is a developer automatically.
5. Move each gameplay remote's handler into `AntiCheat.bindRemote` (see
   [Integrating](#integrating-with-cartoon-dice)). **Delete the old
   `OnServerEvent:Connect` for that remote**, or its unprotected handler
   keeps running next to the new one.
6. Play in Studio. The output shows
   `[AntiCheat] started (TEST_MODE: kicks are simulated, ...)`. Five seconds
   later it lists every remote in ReplicatedStorage that doesn't go through
   the gateway yet.

## How it works

```
client asks  -->  remote gateway  -->  your handler (server decides the outcome)
                  rate limit, restriction, argument schema,
                  one-at-a-time, shop distance

server loop  -->  MovementValidator samples every character 4x per second

detections   -->  ViolationTracker (score, decay)  -->  Enforcement (level -> action)
                                                    -->  EvidenceLogger (output, reports)
```

### Levels

Each detection adds `weight x severity` points to the player's score. After
10 seconds without a new violation the score drops by 0.1 per second.

| Score | Level | Action |
| --- | --- | --- |
| 0 | 0 | normal |
| >= 1 | 1 | silent observation |
| >= 3 | 2 | logged to the server output |
| >= 6 | 3 | movement detections: set back to the last trusted spot |
| >= 10 | 4 | movement: set back, then the server holds the character's physics for 8 s; remote/economy: economy remotes refused for 8 s (once per 30 s) |
| >= 18 | 5 | kick, only with 6+ separate violations in the last 5 minutes |

- **No automatic bans.** `Api.moderatorBan` is the only ban path. A
  moderator has to call it after reading the evidence.
- **Staff bypass.** Outside `TEST_MODE`, developers' and moderators'
  movement isn't checked (admin tools stay usable). Their remote and economy
  detections are logged as `Bypass` and never acted on.
- **Low-confidence evidence is capped.** Noclip (score cap 4), remote
  flooding (5) and malformed remotes (8) can't reach setbacks, restriction
  or kicks on their own.
- **Collisions carry no points.** A movement detection made while another
  character is within 8 studs (or was, in the last 3 seconds) is logged with
  no points. Collisions and flings by other players can't get anyone kicked.

### Movement checks

Everything is read from the server's copy of the character. `allowed` is the
speed the SERVER permits:

```
allowed = max( max(Humanoid.WalkSpeed as the server sees it, 16) x modifier multipliers,
               highest modifier maxSpeed )
          + speed of the moving platform stood on          (120 while seated)
```

| Detection | What's measured | Tolerance (good ping) | Points |
| --- | --- | --- | --- |
| Speed | net horizontal distance over the last 2 s | `allowed x 1.25 + 3` studs/s, over for at least 1 s; at most once per 1.5 s | 1-3 by how far over |
| Teleport | one sample (0.25 s) to the next | `allowed x 1.25 x time since the server last saw movement (max 3 s) + 30` studs; rising: `(jump + allowed) x time + 25` | 2.5, or 5 if 3x over: one teleport is only logged |
| Fly | nothing under the character (down ray), beside it (touch box) or around it (terrain water), then either higher than the highest legal jump + 8 studs, or airborne longer than max(2.5 s, jump time + 0.5 s) while falling less than 3 studs in 1.5 s | + latency extras | 2, or 4 if 3x over |
| Noclip | root- and head-height rays both cross an anchored wall at least 0.8 studs deep, 3 times in 10 s | evidence only | 0.5 (capped) |
| Impossible physics | NaN / infinite values, coordinates beyond 100,000, speed over 3000, spin over 400 rad/s | always corrected | 4, at most once per 2 s |

Latency profiles, from `Player:GetNetworkPing()`:

| Profile | Ping | Speed multiplier | Extra teleport / rise slack | Extra air time |
| --- | --- | --- | --- | --- |
| Good | <= 120 ms | 1.25 | 0 | 0 |
| Normal | <= 300 ms | 1.4 | 10 studs | 0.5 s |
| HighLatency | above | 1.7 | 25 studs | 1.5 s |

**Setbacks:** the target is the last position where the character stood on
something with nothing suspicious happening, and no older than 20 seconds.
There is at most one setback every 2 seconds and at most 4 per 30 seconds.
A 5th is refused and recorded as `SetbackLoop` evidence instead. After a
setback, the checks pause for 1 second plus the player's ping, so the
player's in-flight packets aren't flagged.

**Skipped automatically:** dead characters, anchored roots (held by the
server), the 3 seconds after spawning, anything exempt, bypassed staff,
restricted players, and seated players for speed and fly.

**Server moves are never flagged.** Use `AntiCheat.teleport` /
`AntiCheat.exempt`. As a safety net, any server script that moves a root
(`PivotTo`, `CFrame =`) gets the same grace, because the server can see its
own CFrame writes. Replicated client physics doesn't fire that signal. If the
signal ever fired at physics rates, the safety net switches itself off and
warns (`AutoExemptServerMoves`).

### Remote gateway

`AntiCheat.bindRemote(name, handler, options?)` creates or uses
`ReplicatedStorage.Remotes.<name>` and connects `handler` behind these
checks, in order:

1. **Rate limit.** Per player and per remote. Excess requests are dropped,
   never queued. 30 or more refused in one second is `RemoteFlood`
   evidence.
2. **Restriction.** Contracts marked `restrictable` are refused while
   Enforcement restricts the player.
3. **Schema.** Types, finite numbers, ranges, whole numbers, string length,
   UTF-8, no control characters, id patterns, enums, real arrays (no holes,
   no extra keys, length limits, duplicates if `unique`), no extra arguments.
   Arrays are rebuilt, so a client table can't smuggle keys into saved data.
   A failure is `InvalidRemote` evidence.
4. **Shop distance.** For contracts with a `shop`, the player must be within
   the shop's `Radius` plus slack. An absurd distance is `EconomyTamper`
   evidence.
5. **One at a time.** Contracts marked `exclusive` refuse a second call while
   the first is still running.
6. **Handler.** Runs in a protected call with validated arguments only.
   Errors are logged on the server and never reach the client. A refused
   RemoteFunction call returns `nil, reason`.

Remotes without a contract can't be bound.

### Remote contracts

The contract is what the client may send. The last column is what the
handler must work out itself: the client only asks.

| Remote | Client sends (validated) | Limit | The server decides |
| --- | --- | --- | --- |
| RollDice | nothing | the real cooldown (0.3 s early is tolerated) | dice owned + equipped; rarity, character, mutation with its own RNG and luck |
| SetAutoRoll | boolean | 2/s | runs Auto Roll itself (no client-fired rolls) |
| DiceShop | dice id, `"Buy"` / `"Equip"` | 3/s, one at a time | catalog, progression, price, balance, ownership |
| BuyUpgrade | upgrade id | 3/s, one at a time | current level, price |
| UnlockSkill | node id | 3/s, one at a time | prerequisites, gem cost, not owned |
| BuyCosmetic / BuyRide | item id | 2/s, one at a time | Dream Essence price, ownership |
| EquipRide | ride id or nil | 2/s | ownership, then `setMovementModifier` |
| EquipCharacter / UnequipCharacter | character unique id | 8/s | in this player's inventory, slot free / equipped |
| PlaceCharacter | unique id, slot 1-100 | 8/s | ownership, slot exists on own plot and is unlocked |
| EquipBest | nothing | 1/s | "best" from its own data |
| SellCharacters | up to 200 unique ids, no duplicates | 2/s, one at a time | each owned, not equipped / locked; sale value |
| SetAutoSell | up to 6 rarities | 2/s | does the selling itself |
| CollectCash | nothing | 2/s, one at a time | amount from placed characters and elapsed time |
| ClaimIndexReward | entry id | 2/s, one at a time | discovered and not claimed (saved data + `claimOnce`) |
| ClaimDailyReward | nothing | 1 per 2 s | last claim time (`os.time`) |
| ClaimAfkReward | nothing | 1 per 5 s | AFK time from its own timestamps |
| RedeemCode (RemoteFunction) | code | 1 per 2 s (burst 3) | code list, expiry, saved redemptions |
| Rebirth | nothing | 1 per 2 s, one at a time | requirement; reset and reward in one transaction; move via `AntiCheat.teleport` |

Rename or remove entries in `RemoteContracts` to match the game.

## Integrating with Cartoon Dice

Game server code:

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local AntiCheat = require(ServerScriptService.AntiCheat.Api)
local Economy = AntiCheat.Economy
```

**Rolling.** The client keeps calling `Remotes.RollDice:FireServer()`, as in
the InputManager example in [cross-platform.md](cross-platform.md).

```lua
AntiCheat.bindRemote("RollDice", function(player)
	RollService.roll(player) -- server RNG, server-side luck, owned + equipped dice only
end, {
	cooldown = function(player)
		return RollService.getCooldown(player) -- includes roll-speed upgrades
	end,
})
```

Auto Roll should call `RollService.roll` from a server loop, not fire the
remote.

**Dice shop.** The client sends `ShopAction`'s `(itemId, action)` (see
[dice-shop-ui.md](dice-shop-ui.md)).

```lua
AntiCheat.bindRemote("DiceShop", function(player, diceId, action)
	local dice = DiceCatalog[diceId] -- exists: checked below
	local data = PlayerData.get(player)
	if action == "Equip" then
		if data.OwnedDice[diceId] then
			data.EquippedDice = diceId
		end
		return
	end
	if data.OwnedDice[diceId] or data.Rebirths < dice.rebirthsRequired then
		return
	end
	Economy.transaction(player, function() -- refuses a second purchase while this runs
		local ok, newCash = Economy.applyChange(player, "Cash", data.Cash, -dice.price, "DicePurchase")
		if ok then
			data.Cash = newCash
			data.OwnedDice[diceId] = true
		end
	end)
end, {
	checks = { [1] = function(id) return DiceCatalog[id] ~= nil end },
})
```

**Every balance change** goes through `Economy.applyChange` with a reason
from `Config.Economy.Reasons`, including income ticks:
`Economy.applyChange(player, "Cash", data.Cash, income, "CharacterIncome")`.
It refuses NaN, infinity, negative balances, balances over `MaxBalance`, and
a reason used the wrong way round (a purchase that adds cash). Accepted
changes go into a ledger: `Economy.getLedger(player)`.

**One-time rewards:** check the saved data, then
`Economy.claimOnce(player, "Index:" .. entryId)` for the moment before the
save lands.

**World shops.** Tag the shop part or model `Shop`, give it a `ShopId`
attribute (and optionally `Radius` and `Active`), and bind with
`{ shop = "RideShop" }`. The current Dice Shop opens from the top bar, so it
has no distance check.

**Moving players.** Server-side moves must never look like cheating:

```lua
AntiCheat.teleport(player, spawnCFrame, "Rebirth")   -- moves, exempts, re-baselines
AntiCheat.exempt(player, "Knockback", 1.5)            -- before a launch / knockback
```

**Speed.** Set `Humanoid.WalkSpeed` on the SERVER. A LocalScript sprint
doesn't replicate, so it looks exactly like a speed hack and gets flagged.
Rides and buffs:

```lua
AntiCheat.setMovementModifier(player, "Ride", { maxSpeed = 60, allowFlight = true })
AntiCheat.setMovementModifier(player, "SpeedPotion", { speedMultiplier = 1.5 }, 30) -- seconds
AntiCheat.clearMovementModifier(player, "Ride") -- plus a short grace while slowing down
```

**Reporting what the game catches itself:** use
`AntiCheat.flag(player, "EconomyTamper", "details")`, but only for requests
a real client can't produce. A stale UI clicking "Buy" on something already
owned isn't tampering.

## Configuration

Everything is in `Config`:

- **`TEST_MODE`** is on automatically in Studio. Every check runs,
  developers included, setbacks happen, and kicks and bans are only logged
  (`WouldKick`). `FORCE_TEST_MODE` does the same on a live test server.
- **`DEBUG`** (Studio by default) prints every evidence entry. Otherwise only
  level 2 and above print. The same player + detection prints at most once
  per 5 seconds.
- **`Violations`:** weights, caps and decay.
- **`Enforcement`:** levels, and switches for setback, restrict and kick.
- **`Movement`:** every tolerance in the tables above.
- **`Remotes`:** folder name, flood threshold and the start-up audit.
- **`Economy`:** currencies, reasons, max balance and shop tag.
- **`Logging`:** the evidence buffer and kick reports.

### Evidence and moderation

An evidence line looks like this:

```
[AntiCheat] Name (UserId) Speed | sev 2 +2 -> score 6 L3 Setback | action=Setback |
speed 48.0 vs allowed 23.0 | pos (...) | vel (...) | state Running | ping 80ms | 2.0s window, ...
```

- In code: `AntiCheat.getEvidence(player)`, `AntiCheat.getSummary(player)`,
  `AntiCheat.getScore(player)`, `AntiCheat.onEvidence(callback)`.
- On a kick, a short summary is saved to the DataStore `AntiCheatReports_v1`,
  key `user_<UserId>` (last 10 kicks).
- `AntiCheat.moderatorBan(moderator, userId, seconds, reason)` refuses
  anyone without the Moderator or Developer role, and only logs in
  TEST_MODE. `seconds <= 0` is permanent.

## Testing

### In Studio

With the `AntiCheatTester` LocalScript installed, a play-test shows a
**TEST_MODE** panel. Each button does what an exploit would do from the
client:

| Button | Expected server output |
| --- | --- |
| WalkSpeed hack (hold W) | `Speed` after ~1-2 s, a setback at level 3 |
| CFrame speed hack | `Speed`, then a setback |
| Hover / fly | `Fly` (too high, then not falling) |
| Teleport x3 | `Teleport`; the first is only logged, the second sets back and restricts |
| Noclip (face a thick wall) | `Noclip` evidence (0.5 points, capped) |
| Fling spin | `ImpossiblePhysics`, velocity reset |
| Invalid remote args | one `InvalidRemote` per bad call; handlers never run |
| Roll spam | about one accepted roll per cooldown, one `RemoteFlood` |
| Replay reward claims | rate-limited; your handler pays once |

Until you bind your own handlers, TEST_MODE puts "demo" handlers on contract
remotes that don't exist yet. They only print what they accepted. A remote
the game already has is never touched.

### Automated (Lune)

`tests/anticheat/` loads the real modules into [Lune](https://lune-org.github.io/docs)
(tested with 0.10.4). It supplies a small simulated engine: services, a world
of boxes that answers raycasts and overlap queries, clients with gravity and
wall collisions, replication with ping, jitter and lag spikes, and a fake
clock.

```
lune run tests/anticheat/run                  # everything
lune run tests/anticheat/run -- --verbose     # print each test's evidence
lune run tests/anticheat/run -- hoverboard    # tests whose name matches
lune run tests/anticheat/bench                # cost per player (see Performance)
```

It covers 51 tests:

- **Must stay clean:** walking, constant jumping, a 150-stud fall, respawns,
  a single unexplained teleport (logged, not corrected),
  400 ms ping with jitter, lag spikes delivered in bursts, `Api.teleport`,
  raw server teleports, hoverboard on/off at speed, server speed buffs,
  vehicles, truss climbing, swimming, conveyors, being flung by another
  player, physics bumps, tight corners, stairs, launch pads, 20 min AFK,
  roll mashing and rapid menus.
- **Must be caught:** client WalkSpeed, CFrame speed, hover, fly-up, super
  jump, teleports, teleport loops, noclip, NaN and fling physics, malformed
  remotes, roll spam, fake ids / prices / amounts, concurrent and duplicate
  purchases and claims, shop distance, code guessing, restriction, contract
  enforcement and the moderator-only ban path.

A test also fails if any anti-cheat code threw an error it had caught
itself.

## Performance

**Players' devices: no cost.** Nothing runs on the client in a live game.
The tester LocalScript exits outside Studio. The anti-cheat adds no remotes
of its own and sends nothing to clients (one attribute on ReplicatedStorage
at start-up), so it can't lower anyone's FPS or add network lag.

**Server: one loop, spread out.**

- A single Heartbeat connection covers every player. Each character is
  sampled 4 times a second, and the players are staggered across frames, so
  the work arrives as a few samples per frame, never in a spike.
- A normal sample does one short downward raycast, plus one short wall
  raycast when the character moved 2+ studs. An overlap query and a
  terrain-water read happen only when nothing is under the character
  (mostly mid-jump).
- There are no Workspace scans, and query filters are built once per
  character.
- The common path allocates no tables: a shared default movement profile,
  a reused ledger ring, and no per-sample closures.
- Remote checks run only when a remote is called.
- Setbacks and freezes happen only at levels 3-4, which none of the
  normal-play tests reach.

Measured with `lune run tests/anticheat/bench` (players walking and
jumping; add `-- <players> <seconds>` to change it):

| | 40 players | 100 players |
| --- | --- | --- |
| Raycasts per player per second | 8 | 7.6 |
| Overlap / terrain queries per player per second | 0.34 / 0.34 | 0.34 / 0.31 |
| Anti-cheat Luau per sample | ~31 µs | ~35 µs |
| Anti-cheat Luau per server frame | ~0.08 ms (0.5% of a 60 fps frame) | ~0.23 ms (1.4%) |

Remote gateway, per call: about 3 µs for a normal 2-argument request, about
1.5 µs to drop a spammed one, and about 50 µs for a 20-id sell request
(limited to 2 per second).

These are upper bounds. Lune has no native code generation and treats
Vector3 as a heap object; in Roblox, Vector3 is a native value and raycasts
are native code, so a real server should be faster. To check on a live
server, open the Developer Console (F9) > Scripts and look at the AntiCheat
Script's activity, or use the MicroProfiler.

If a very full server ever needs it:
- `Movement.SampleInterval = 0.33` does a quarter less work. The windows are
  in seconds, so detection only gets slightly slower.
- `Movement.Noclip.Enabled = false` halves the raycasts.

## Audit of Anti Cheat System v1.5

The model had a Folder with a `StarterPlayerScripts` folder (Script
"anti cheat client") and a `ServerScriptService` folder (Script "Anti cheat
server-side"). Both scripts used RunContext Legacy, and there was no
RemoteEvent. Findings marked (run) were confirmed by running the code.

| # | Finding | Effect |
| --- | --- | --- |
| 1 | The client measures its own "speed" and sends it with `AntiCheatEvent:FireServer({Speed = ...})`; the server trusts that number | An exploiter deletes the script or sends `{Speed = 0}`. The whole detection is client-controlled |
| 2 | The "client" is a `Script` (Legacy) meant for StarterPlayerScripts | Legacy Scripts don't run under PlayerScripts and can't use `LocalPlayer`: the client half never runs |
| 3 | `lastPosition` starts as nil | The first sample errors (`Vector3 - nil`) (run) |
| 4 | "speed" = distance / `HumanoidRootPart:GetMass()` | Not a speed at all, so the threshold means nothing |
| 5 | `kickPlayer` is a local declared *after* `checkSpeed`, which calls it | Resolves to a nil global: "attempt to call a nil value". Nobody is ever kicked (run) |
| 6 | No argument validation | `FireServer(42)` and `{Speed = "x"}` throw on the server; NaN passes, because `NaN > 100` is false (run) |
| 7 | No rate limit on `AntiCheatEvent` | A free way to spam server errors |
| 8 | A fixed `maxSpeed = 100`, no latency, teleport or respawn handling | Had the kick worked, spawns and teleports would have kicked legitimate players |
| 9 | `AntiCheatEvent` isn't in the model; both scripts `WaitForChild` it | Infinite yield unless created by hand |
| 10 | No fly detection, no ban (despite the description); uses deprecated `wait`, `game.Players`, `.magnitude`; its `while true` loop errors when the character is missing | |

It doesn't conflict with Cartoon Dice's movement (it moves nothing), and the
repo had no server scripts for it to clash with.

**What was kept:** the idea of a server-side speed limit taken from a config
value (now `Config.Movement` and `MovementValidator`); a single helper that
logs the reason before acting (now `EvidenceLogger` and `Enforcement`, with
kicking as the last step); and one dispatch point where more checks are
added (now `ViolationTracker`).

**What was replaced:** everything else, including the client-reported
speed, the remote, the kick-on-first-detection rule and the fixed threshold.
The start-up audit warns if `AntiCheatEvent` still exists.

## Known limits

- **Not run in Studio yet.** This environment has no Roblox Studio. The
  automated tests use the real module code with a simulated engine. Things
  only Studio or a live server can confirm:
  - real physics edge cases (ragdolls, avatar scales, seats)
  - how restriction feels in play
  - whether server-side `PivotTo` fires the CFrame signal (if not, the
    safety net does nothing; use `AntiCheat.teleport`)
  - `BanAsync` and DataStores in a published place

  Run the Studio tester once before publishing.
- **The game's server handlers weren't in this repo,** so the real roll,
  shop and economy code couldn't be audited. The contracts are the spec: each
  handler must still do its "server decides" column.
- **A handler still connected with `OnServerEvent:Connect` bypasses the
  gateway.** The audit lists remotes the gateway doesn't own, but it can't
  see who else is connected.
- **Walkable parts with `CanQuery = false`** are invisible to raycasts, so
  standing on one looks like hovering. Keep floors queryable.
- **Client-side speed changes are flagged.** Sprinting, dashes and similar
  must be server-authorised.
- **Blind spots traded for fewer false positives:**
  - noclip through walls thinner than 0.8 studs, or when a sample lands
    inside the wall
  - one teleport of up to ~90 studs after standing still for 3 s (the lag
    allowance); repeated ones are caught
  - movement while touching another player
  - anything while seated, apart from the 120 studs/s teleport bound
- **Humanoid state isn't trusted** (the client controls it). Support is
  judged from geometry only.
- **Group roles** use `Player:GetRankInGroupAsync`, which the latest API dump
  marks deprecated. It is only called when `Config.Permissions.GroupId` is
  set.
