--[[
	BuildSettingsGui (Studio Command Bar helper, optional)

	Paste into View > Command Bar in Roblox Studio and press Enter. It builds
	StarterGui.SettingsGui exactly as described in docs/settings-menu.md and
	creates SoundService.BGMGroup if it doesn't exist yet.

	Afterwards, insert a LocalScript named SettingsController inside
	StarterGui.SettingsGui and paste in
	src/StarterGui/SettingsGui/SettingsController.client.luau.

	It refuses to run if StarterGui.SettingsGui already exists, so it never
	overwrites your work.
]]

local StarterGui = game:GetService("StarterGui")
local SoundService = game:GetService("SoundService")

if StarterGui:FindFirstChild("SettingsGui") then
	warn("[BuildSettingsGui] StarterGui.SettingsGui already exists. Rename or delete it first.")
	return
end

-- Placeholder styling. Swap in your own colours, fonts and icons freely;
-- the LocalScript only cares about names, classes and layout.
local FONT = Enum.Font.FredokaOne
local PANEL = Color3.fromRGB(32, 34, 48)
local ACCENT = Color3.fromRGB(255, 196, 64)
local TRACK = Color3.fromRGB(64, 68, 90)
local TEXT = Color3.fromRGB(255, 255, 255)
local DANGER = Color3.fromRGB(235, 80, 80)

local function make(className: string, props: { [string]: any }, children: { Instance }?): Instance
	local instance = Instance.new(className)
	if instance:IsA("GuiObject") then
		instance.BorderSizePixel = 0
	end
	for key, value in props do
		(instance :: any)[key] = value
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	return instance
end

local function corner(radius: UDim): Instance
	return make("UICorner", { CornerRadius = radius })
end

local gui = make("ScreenGui", {
	Name = "SettingsGui",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 10,
}, {
	make("TextButton", {
		Name = "SettingsButton",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -44, 0, 44),
		Size = UDim2.fromOffset(56, 56),
		BackgroundColor3 = PANEL,
		Font = FONT,
		Text = "⚙️",
		TextColor3 = TEXT,
		TextSize = 30,
	}, {
		corner(UDim.new(0.3, 0)),
		make("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = ACCENT,
			Thickness = 2,
		}),
		make("UIScale", { Scale = 1 }),
	}),

	make("Frame", {
		Name = "SettingsMenu",
		Active = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, 160),
		BackgroundColor3 = PANEL,
		Visible = false,
	}, {
		corner(UDim.new(0, 16)),
		make("UIStroke", { Color = ACCENT, Thickness = 3 }),
		make("UISizeConstraint", { MaxSize = Vector2.new(420, 160) }),
		make("UIScale", { Scale = 0 }),

		make("TextLabel", {
			Name = "Title",
			Position = UDim2.fromOffset(24, 16),
			Size = UDim2.new(1, -96, 0, 36),
			BackgroundTransparency = 1,
			Font = FONT,
			Text = "Settings",
			TextColor3 = TEXT,
			TextSize = 28,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),

		make("TextButton", {
			Name = "CloseButton",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 16),
			Size = UDim2.fromOffset(36, 36),
			BackgroundColor3 = DANGER,
			Font = FONT,
			Text = "X",
			TextColor3 = TEXT,
			TextSize = 22,
		}, {
			corner(UDim.new(0.3, 0)),
		}),

		make("Frame", {
			Name = "BGMRow",
			Position = UDim2.fromOffset(24, 88),
			Size = UDim2.new(1, -48, 0, 40),
			BackgroundTransparency = 1,
		}, {
			make("TextLabel", {
				Name = "NameLabel",
				Size = UDim2.new(0, 80, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT,
				Text = "Music",
				TextColor3 = TEXT,
				TextSize = 22,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),

			-- Invisible, touch-friendly hit area. Track and Knob are just visuals.
			make("TextButton", {
				Name = "Slider",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 92, 0.5, 0),
				Size = UDim2.new(1, -160, 0, 32),
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Text = "",
			}, {
				make("Frame", {
					Name = "Track",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.new(1, 0, 0, 8),
					BackgroundColor3 = TRACK,
				}, {
					corner(UDim.new(1, 0)),
					make("Frame", {
						Name = "Fill",
						Size = UDim2.fromScale(0.5, 1),
						BackgroundColor3 = ACCENT,
					}, {
						corner(UDim.new(1, 0)),
					}),
				}),

				make("Frame", {
					Name = "Knob",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(22, 22),
					BackgroundColor3 = TEXT,
					ZIndex = 2,
				}, {
					corner(UDim.new(1, 0)),
					make("UIStroke", { Color = ACCENT, Thickness = 2 }),
				}),
			}),

			make("TextLabel", {
				Name = "ValueLabel",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.new(0, 56, 1, 0),
				BackgroundTransparency = 1,
				Font = FONT,
				Text = "50%",
				TextColor3 = TEXT,
				TextSize = 22,
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		}),
	}),
})

gui.Parent = StarterGui

if not SoundService:FindFirstChild("BGMGroup") then
	make("SoundGroup", { Name = "BGMGroup", Volume = 0.5 }).Parent = SoundService
end

print("[BuildSettingsGui] Built StarterGui.SettingsGui. Next: add the SettingsController LocalScript inside it,")
print("[BuildSettingsGui] and set each music Sound's SoundGroup property to SoundService.BGMGroup.")
