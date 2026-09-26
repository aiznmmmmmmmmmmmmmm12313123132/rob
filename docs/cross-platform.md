# Cross-platform input, UI scaling and Performance Mode

Three scripts make Cartoon Dice play the same on PC, mobile and console
(Xbox and PlayStation). They also add a Performance Mode switch to the
Settings menu.

| Script | Type | Location in Studio | Source file |
| --- | --- | --- | --- |
| InputManager | ModuleScript | `ReplicatedStorage > Source > InputManager` | `src/ReplicatedStorage/Source/InputManager.luau` |
| UIScaleController | LocalScript | `StarterPlayer > StarterPlayerScripts > UIScaleController` | `src/StarterPlayer/StarterPlayerScripts/UIScaleController.client.luau` |
| PerformanceController | LocalScript | `StarterPlayer > StarterPlayerScripts > PerformanceController` | `src/StarterPlayer/StarterPlayerScripts/PerformanceController.client.luau` |

`SettingsController` (see [settings-menu.md](settings-menu.md)) was updated to
work with them, so replace your copy too.

## Setup

1. In **ReplicatedStorage**, add a Folder named `Source` with a ModuleScript
   named `InputManager` inside it. Paste in `InputManager.luau`.
2. In **StarterPlayer > StarterPlayerScripts**, add two LocalScripts named
   `UIScaleController` and `PerformanceController`, and paste each file in.
3. Select **StarterPlayer** and turn off **EnableMouseLockOption**. InputManager
   has its own Shift Lock that also works on console and mobile. With the
   built-in one on as well, Shift would toggle both.
4. In `UIScaleController`, change `"HUD"` in `MANAGED_SCREEN_GUIS` to the name
   of your main HUD ScreenGui. Add any other HUD ScreenGuis to the list.
5. Tag the models whose shadows Performance Mode should turn off. Use the Tags
   section of the Properties window, or tag them in the code that spawns them:
   - dice roll animation models: `DiceRoll`, e.g. `rollModel:AddTag("DiceRoll")`
   - units placed on plots: `PlotUnit`
6. Replace `SettingsGui > SettingsController` with the updated file.
7. Hook your HUD's Roll button up to InputManager (see the example below).

## 1. InputManager

### Controls

| Action | PC | Mobile | Console |
| --- | --- | --- | --- |
| Roll Dice | Space, or click the Roll button | Tap the Roll button | ButtonA (Xbox A / PlayStation ✕) or R2 |
| Shift Lock | Left Shift | "LOCK" button above the jump button | Left stick click (L3) |

- **Space and ButtonA are Roblox's jump keys.** With
  `ROLL_KEYS_REPLACE_JUMP = true` (the default) they roll instead of jumping,
  on PC and console. Mobile keeps its jump button. Set it to `false` if you
  want those keys to roll and jump at the same time.
- **Menus win.** While a TextBox is focused, a gamepad player is navigating
  UI (`GuiService.SelectedObject` is set), or the Roblox menu is open, the keys
  go to the UI and don't roll. So ButtonA presses the selected button instead.
- **Reaching the Settings button on console:** press the View / Share button
  to enter Roblox's UI navigation, then move to it with the D-pad.

### Detection

- **Input mode:** `"KeyboardMouse"`, `"Gamepad"` or `"Touch"`. It follows the
  most recent input, and ignores a nudged mouse or a resting thumbstick so the
  hints don't flicker.
- **Gamepad style:** `"Xbox"` or `"PlayStation"`, from
  `UserInputService:GetStringForKeyCode(ButtonA)`. That returns `"ButtonCross"`
  on PlayStation.
- **Platform:** `"Desktop"`, `"Mobile"` or `"Console"`, from
  `GuiService:IsTenFootInterface()` and the device's touch and keyboard
  support.

### API

| Member | What it does |
| --- | --- |
| `InputDeviceChanged` | Signal `(inputMode, gamepadStyle)`. Fires when the player switches device. Also exists as a BindableEvent at `ReplicatedStorage.Source.InputManager.InputDeviceChanged` once the module has been required on that client. |
| `ActionTriggered` | Signal `(action, inputMode)`. Fires for every action. |
| `onAction(action, callback)` | Calls `callback(inputMode)` whenever `action` triggers on any device. |
| `bindButton(action, guiButton)` | Makes a GuiButton trigger the action on click, tap, or gamepad A. |
| `getHint(action)` | Text for the current device: `"Space"`, `"A"`, `"X"` (PlayStation), `"Tap"`. |
| `getHintImage(action)` | Roblox's controller glyph image in Gamepad mode, or `nil`. |
| `getInputMode()` / `getGamepadStyle()` / `getPlatform()` | Current values. |
| `isShiftLockEnabled()` / `setShiftLockEnabled(bool)` | Shift Lock state. |

### HUD example

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local InputManager = require(ReplicatedStorage.Source.InputManager)

local hud = script.Parent
local rollRemote = ReplicatedStorage.Remotes.RollDice

InputManager.bindButton("RollDice", hud.RollButton) -- click / tap / gamepad A
InputManager.onAction("RollDice", function()
	rollRemote:FireServer() -- the server enforces the cooldown (anti-cheat.md)
end)

local function refreshHint()
	hud.RollButton.Hint.Text = InputManager.getHint("RollDice")
end
InputManager.InputDeviceChanged:Connect(refreshHint)
refreshHint()
```

## 2. UIScaleController

For each ScreenGui in `MANAGED_SCREEN_GUIS`, it manages every top-level
GuiObject (for example `HUD > RollButton`, `HUD > UpgradesButton`,
`HUD > BackpackButton`, `SettingsGui > SettingsButton`):

1. **Safe area.** It measures Roblox's top bar (`GuiService:GetGuiInset()`)
   and device cutouts (notch, camera hole, home indicator). On console it
   also keeps a 5% margin on every edge for TVs that crop the picture.
   `GetGuiInset()` doesn't report notches, so cutouts are read from two
   invisible probe ScreenGuis: one set to `ScreenInsets.None` and one to
   `CoreUISafeInsets`.
2. **Anchors.** It snaps each element's AnchorPoint to the edge it sits on
   (left/centre/right, top/middle/bottom), and adjusts Position so it doesn't
   move. Scaling then grows each element inward, never off-screen.
3. **Position.** It measures the Scale part of each element's Position
   against the safe area instead of the full screen. Edge elements clear the
   notch and top bar, and centred ones stay centred in the safe area.
4. **Scale.** One UIScale value is calculated as
   `min(safeWidth / 1280, safeHeight / 720) × device multiplier`, then clamped
   per device. Taking the smaller of the two ratios keeps ultrawide and narrow
   screens in check. Position offsets are scaled too, so gaps between buttons
   grow with the buttons.

### Rules for HUD elements

- Size and position top-level elements with **Offset** values designed at
  about 1280×720 (`REFERENCE_RESOLUTION`). Elements sized with **Scale**
  already stretch with the screen; give them the attribute `AutoScale = false`.
- **Group related buttons** in a container Frame (for example a left column
  with a UIListLayout). The container is what gets anchored and scaled.
- **If a top-level element has its own UIScale** (for example a hover tween),
  the controller doesn't touch its `Scale`. It only writes a `BaseScale`
  attribute on it. Either multiply your tween targets by
  `uiScale:GetAttribute("BaseScale") or 1`, as `SettingsController` does, or
  wrap the element in a plain Frame.
- **Elements that other scripts move** (sliding panels): wrap them in a
  static Frame, or set `AutoScale = false`.
- **Constraints:** an element with a UIAspectRatioConstraint,
  UISizeConstraint or AutomaticSize isn't re-anchored automatically. Set its
  AnchorPoint to its edge yourself. In Studio the script warns you about each
  one.

### Tuning and debugging

- `PLATFORM_RULES` holds each device's multiplier and min/max scale. Phones
  have a floor of 0.8 so buttons stay finger-sized.
- `TV_SAFE_MARGIN` sets the console edge margin.
- While play-testing, select the `UIScaleController` script to watch its
  `Platform`, `Scale`, `AspectRatio` and `Insets` attributes. Use the Test tab's
  device emulator to try notched phones and tablets.

## 3. PerformanceController

It adds a **Performance Mode** On/Off switch under the Music slider in
`SettingsGui > SettingsMenu`, and grows the menu to fit. The switch copies the
menu's own fonts and slider colours. If you build a `PerformanceRow` yourself
(a `Toggle` button with a `Knob` frame inside, plus an optional `StateLabel`),
it uses that instead.

### When it's on

| Target | Change |
| --- | --- |
| ParticleEmitters in Workspace | Rate × `PARTICLE_RATE_MULTIPLIER` (0.25; 0 turns them off) |
| Beams, Trails, Fire, Smoke, Sparkles | Disabled |
| Bloom, Blur, DepthOfField, SunRays (in Lighting or the Camera) | Disabled |
| Parts under `DiceRoll` / `PlotUnit` tagged models | `CastShadow = false` |
| `Lighting.GlobalShadows` | Off only if `DISABLE_GLOBAL_SHADOWS = true` (off by default; it flattens the look) |

- **New effects are covered.** Effects spawned later, such as those from every
  dice roll, get the same treatment.
- **No hitch on big maps.** The first Workspace scan is spread over several
  frames.
- **Switching off restores everything.** Every original value is put back,
  except values another script changed in the meantime; those keep the other
  script's value.
- **No leak during AFK.** Destroyed effects are forgotten, so long AFK roll
  sessions don't grow memory.

### Low frame rate safety net

The frame rate is measured in one-second windows. It starts after a 15-second
warm-up and pauses while the window is unfocused. If it stays below 30 FPS
for 3 windows in a row, the controller does one of two things, depending on
`LOW_FPS_ACTION`:

- `"Prompt"` (the default) shows a Roblox notification with **Turn on** and
  **No thanks** buttons.
- `"AutoEnable"` turns Performance Mode on and tells the player.

It happens at most once per session. It never happens once the player has
used the switch themselves.

### Hooks for other scripts

- **`PerformanceMode` attribute:** the LocalPlayer has a boolean attribute
  `PerformanceMode`. Read it, or listen with
  `player:GetAttributeChangedSignal("PerformanceMode")`, in effect code that
  Rate scaling can't reach. Scripted `emitter:Emit(n)` bursts in the dice roll
  animation are the main example; emit fewer particles when it's `true`.
- **`KeepInPerformanceMode` attribute:** set it to `true` on an effect, or on
  any ancestor, to keep it at full quality.

## Known limits

- **Settings aren't saved between sessions.** Performance Mode, Shift Lock and
  the volume all reset. Saving them needs a RemoteEvent and your data store.
- **Clones made while Performance Mode is on.** If a script clones an effect
  that's already in Workspace during that time, the clone starts with the
  reduced value. Templates in ReplicatedStorage or ServerStorage aren't
  affected.
- **Roblox's own UI.** The mobile Shift Lock button is placed from Roblox's
  `TouchGui > JumpButton`. If Roblox renames that, the button stays at a
  fixed bottom-right fallback position.
