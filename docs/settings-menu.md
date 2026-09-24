# Settings Menu + BGM Volume Slider

A Settings button in the top-right corner opens a centred Settings menu. The menu
has a 0–100% Background Music slider that changes only `SoundService.BGMGroup`,
so SFX and UI sounds keep their own volume.

| File | What it is |
| --- | --- |
| `src/StarterGui/SettingsGui/SettingsController.client.luau` | The LocalScript. It handles the animations and the slider. |
| `tools/BuildSettingsGui.luau` | Optional. Paste it into the Studio Command Bar to build the whole hierarchy below. |

## 1. UI hierarchy

The **names** and **classes** must match exactly, because the script looks up
each object by name. Colours, fonts, corner radii and strokes are up to you.

```
StarterGui
└── SettingsGui                      ScreenGui
    ├── SettingsController           LocalScript   ← paste the .client.luau here
    ├── SettingsButton               TextButton or ImageButton (any GuiButton)
    │   ├── UICorner
    │   ├── UIStroke                 (optional, cosmetic)
    │   └── UIScale                  ← hover scale-up
    └── SettingsMenu                 Frame
        ├── UICorner
        ├── UIStroke                 (optional, cosmetic)
        ├── UISizeConstraint         ← keeps it phone-friendly
        ├── UIScale                  ← pop-in / pop-out
        ├── Title                    TextLabel     "Settings"
        ├── CloseButton              TextButton    "X"
        │   └── UICorner
        └── BGMRow                   Frame
            ├── NameLabel            TextLabel     "Music"
            ├── Slider               TextButton    ← invisible hit area
            │   ├── Track            Frame         ← the visible bar
            │   │   ├── UICorner
            │   │   └── Fill         Frame         ← coloured part (0 → knob)
            │   │       └── UICorner
            │   └── Knob             Frame
            │       ├── UICorner
            │       └── UIStroke     (optional, cosmetic)
            └── ValueLabel           TextLabel     "50%"

SoundService
└── BGMGroup                         SoundGroup    Volume = 0.5
```

### Required properties

Anything not listed can stay at its default or be styled however you like.
UDim2 values are written as `{XScale, XOffset}, {YScale, YOffset}`, the way the
Studio Properties window shows them.

**SettingsGui** (ScreenGui)

| Property | Value | Why |
| --- | --- | --- |
| IgnoreGuiInset | `true` | Y = 0 is the real top of the screen, so the menu centres on the whole screen. |
| ResetOnSpawn | `false` | Keeps the menu state and slider value when the character respawns. |
| ZIndexBehavior | `Sibling` | Makes the Knob's ZIndex draw it over the Track. |
| DisplayOrder | `10` | Draws above your other HUD ScreenGuis. |

**SettingsButton**

| Property | Value |
| --- | --- |
| AnchorPoint | `0.5, 0.5` |
| Position | `{1, -44}, {0, 44}` |
| Size | `{0, 56}, {0, 56}` |

The centred AnchorPoint makes the hover scale grow from the middle. A 56 px
button centred 44 px from the corner leaves a 16 px margin. At runtime the
script moves it down by the height of Roblox's top bar (`GuiService:GetGuiInset()`)
so it never overlaps the Roblox buttons.

**SettingsButton > UIScale**: Scale `1`

**SettingsMenu** (Frame)

| Property | Value |
| --- | --- |
| AnchorPoint | `0.5, 0.5` |
| Position | `{0.5, 0}, {0.5, 0}` |
| Size | `{0.9, 0}, {0, 160}` |
| Active | `true` (taps on the panel don't fall through to the 3D world) |
| Visible | `false` |

**SettingsMenu > UISizeConstraint**: MaxSize `420, 160`. On a PC the panel is
420 px wide, and on a phone it shrinks to 90% of the screen width.

**SettingsMenu > UIScale**: Scale `0` (the script also sets this at startup)

**Title** (TextLabel): Position `{0, 24}, {0, 16}`, Size `{1, -96}, {0, 36}`,
BackgroundTransparency `1`, Text `Settings`, TextXAlignment `Left`

**CloseButton** (TextButton): AnchorPoint `1, 0`, Position `{1, -16}, {0, 16}`,
Size `{0, 36}, {0, 36}`, Text `X`

**BGMRow** (Frame): Position `{0, 24}, {0, 88}`, Size `{1, -48}, {0, 40}`,
BackgroundTransparency `1`

| Child | Class | AnchorPoint | Position | Size | Notes |
| --- | --- | --- | --- | --- | --- |
| NameLabel | TextLabel | `0, 0` | `{0, 0}, {0, 0}` | `{0, 80}, {1, 0}` | Text `Music`, BackgroundTransparency `1` |
| Slider | TextButton | `0, 0.5` | `{0, 92}, {0.5, 0}` | `{1, -160}, {0, 32}` | Text `""` (empty), BackgroundTransparency `1`, AutoButtonColor `false` |
| ValueLabel | TextLabel | `1, 0.5` | `{1, 0}, {0.5, 0}` | `{0, 56}, {1, 0}` | Text `50%`, TextXAlignment `Right`, BackgroundTransparency `1` |

`Slider` is a 32 px tall invisible button. It is much easier to hit with a
finger than the 8 px bar. Leaving 12 px gaps on either side gives the knob room
to overhang at 0% and 100%.

Inside **Slider**:

| Child | Class | AnchorPoint | Position | Size | Notes |
| --- | --- | --- | --- | --- | --- |
| Track | Frame | `0, 0.5` | `{0, 0}, {0.5, 0}` | `{1, 0}, {0, 8}` | Must span the full Slider width. UICorner `{1, 0}` |
| Track > Fill | Frame | `0, 0` | `{0, 0}, {0, 0}` | `{0.5, 0}, {1, 0}` | Accent colour. UICorner `{1, 0}` |
| Knob | Frame | `0.5, 0.5` | `{0.5, 0}, {0.5, 0}` | `{0, 22}, {0, 22}` | ZIndex `2`, UICorner `{1, 0}` (circle) |

Knob and Fill use **Scale** on X, because the script sets `Knob.Position.X.Scale`
and `Fill.Size.X.Scale` to the 0–1 slider value. Leave Knob and Track as Frames
(not buttons) so a press on them goes to `Slider`.

### Sound setup

1. In **SoundService**, insert a **SoundGroup** named `BGMGroup`. Set its
   Volume between 0 and 1. That number becomes the slider's starting value.
2. On every background-music `Sound`, set the **SoundGroup** property to
   `SoundService.BGMGroup`.
3. Put SFX and UI sounds in a different SoundGroup (for example `SFXGroup`), or
   in none. The slider never touches them.

## 2. Install

**Quick way:** open **View → Command Bar**, paste all of
`tools/BuildSettingsGui.luau`, and press Enter. It builds `StarterGui.SettingsGui`
with the properties above and creates `SoundService.BGMGroup` if it's missing.
It stops without changing anything if `SettingsGui` already exists.

**Then, either way:**

1. Inside `StarterGui > SettingsGui`, insert a **LocalScript** named
   `SettingsController`.
2. Paste in the contents of `src/StarterGui/SettingsGui/SettingsController.client.luau`.
3. Press **Play**. Hover over the button, click it, drag the slider, and close
   the menu with **X**.

## 3. How it works

- **Hover:** `MouseEnter` and `MouseLeave` tween `SettingsButton.UIScale` to 1.1
  and back to 1. The effect is skipped for touch input, because a tap can fire
  `MouseEnter` without a matching `MouseLeave`, which would leave the button
  stuck enlarged.
- **Open:** clicking the button makes the menu visible and tweens
  `SettingsMenu.UIScale` from 0 to 1 with `EasingStyle.Back` / `Out`, which
  overshoots slightly and then settles. Clicking the button again, or **X**,
  plays `Back` / `In` down to 0 and then hides the frame. Reopening in the
  middle of a close cancels the close cleanly.
- **Slider math:** `fraction = math.clamp((pointerX - Track.AbsolutePosition.X) / Track.AbsoluteSize.X, 0, 1)`.
  Dragging past either end clamps to 0 or 1, so the knob stops at the ends. The
  label shows `math.round(fraction * 100) .. "%"`, and `BGMGroup.Volume` is set
  to that whole percent divided by 100, so what you hear matches the number.
- **Dragging:** a press on `Slider` or `Knob` starts the drag and jumps the knob
  to the press point. `UserInputService.InputChanged` follows the pointer
  anywhere on screen. `UserInputService.InputEnded` stops the drag when the
  mouse button is released or the finger lifts, wherever that happens. For
  touch, only the finger that started the drag can move or end it, so the
  movement thumbstick can't interfere. The drag also ends if the window loses
  focus or the menu closes.
- **Isolation:** the script only ever writes `SoundService.BGMGroup.Volume`. A
  change made from a LocalScript only affects that one player. If `BGMGroup`
  is created after the script starts, the chosen volume is applied as soon as
  it appears.

## 4. Notes

- **Leaderboard:** if the game uses `leaderstats`, Roblox's player list sits in
  the top-right corner under the top bar and can cover the button. Either move
  the button left, for example to `{1, -120}, {0, 44}`, or hide the default
  list with `StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)`.
- **Persistence:** the volume resets when the player rejoins. To save it, send
  the value to the server through a RemoteEvent, store it in the player's
  saved data, and pass it to `setSliderFraction` on join.
- **More settings:** copy `BGMRow` for new rows, such as an SFX slider driving
  an `SFXGroup`, and move each copy down by about 56 px. Raise the menu height
  and the UISizeConstraint's MaxSize to match.
