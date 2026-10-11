--!strict
--[[
	ForgePilot / UI / WelcomeDialog
	First-run naming prompt. Optional: skipping keeps the default assistant name
	and does NOT require a provider to be configured.
]]

local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local Theme = require(script.Parent.Parent.Utilities.Theme)

local WelcomeDialog = {}

export type Result = { named: boolean, name: string }

--- Shows the welcome prompt. Resolves with `{ named, name }`.
function WelcomeDialog.show(parent: GuiObject): any
	local promise = promise.create()

	local settled = false
	local overlay: Frame = nil :: any

	local overlayInstance = Instance.new("Frame")
	overlayInstance.Name = "WelcomeOverlay"
	overlayInstance.Size = UDim2.fromScale(1, 1)
	overlayInstance.BackgroundColor3 = Theme.Extra.Overlay
	overlayInstance.BackgroundTransparency = 0.15
	overlayInstance.BorderSizePixel = 0
	overlayInstance.ZIndex = 90
	overlayInstance.Parent = parent
	overlay = overlayInstance

	Theme.tween(overlayInstance, { BackgroundTransparency = 0.35 }, Theme.Motion.Slow):Play()

	local card = Instance.new("Frame")
	card.Name = "WelcomeCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.45)
	card.Size = UDim2.new(1, -40, 0, 224)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Theme.Colors.Secondary
	card.BorderSizePixel = 0
	card.ZIndex = 91
	card.Parent = overlay
	Theme.corner(Theme.Metrics.RadiusLarge).Parent = card
	local stroke = Theme.stroke(Theme.Extra.BorderStrong)
	stroke.Parent = card
	Theme.padding(18).Parent = card

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = card

	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.Size = UDim2.fromOffset(34, 34)
	mark.BackgroundTransparency = 1
	mark.LayoutOrder = 1
	mark.Parent = card

	local Title = Theme.label("Welcome to ForgePilot", {
		size = 19,
		font = Theme.Fonts.Bold,
		alignX = Enum.TextXAlignment.Center,
	})
	Title.Name = "Title"
	Title.Size = UDim2.new(1, 0, 0, 26)
	Title.LayoutOrder = 2
	Title.Parent = card

	local subtitle = Theme.label("What would you like to call your AI assistant?", {
		size = Theme.TextSizes.Body,
		color = Theme.Colors.SecondaryText,
		alignX = Enum.TextXAlignment.Center,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(1, 0, 0, 36)
	subtitle.LayoutOrder = 3
	subtitle.Parent = card

	local inputHolder = Instance.new("Frame")
	inputHolder.Name = "Input"
	inputHolder.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight)
	inputHolder.LayoutOrder = 4
	inputHolder.BackgroundTransparency = 1
	inputHolder.Parent = card

	local box = Theme.input("ForgePilot Assistant")
	box.Name = "NameBox"
	box.Text = SettingsManager.getValue("assistantName")
	box.Size = UDim2.fromScale(1, 1)
	box.TextXAlignment = Enum.TextXAlignment.Center
	box.Parent = inputHolder

	local hint = Theme.label(
		"You can change this any time in Settings → General. No AI provider is required yet.",
		{ size = Theme.TextSizes.Caption, color = Theme.Extra.Muted, alignX = Enum.TextXAlignment.Center, wrap = true }
	)
	hint.Name = "Hint"
	hint.Size = UDim2.new(1, 0, 0, 28)
	hint.LayoutOrder = 5
	hint.Parent = card

	local buttons = Instance.new("Frame")
	buttons.Name = "Buttons"
	buttons.Size = UDim2.new(1, 0, 0, 32)
	buttons.LayoutOrder = 6
	buttons.BackgroundTransparency = 1
	buttons.Parent = card
	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Padding = UDim.new(0, 8)
	buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	buttonLayout.Parent = buttons

	local function makeButton(text: string, accent: boolean, order: number): TextButton
		local button = Instance.new("TextButton")
		button.Name = text
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(0, 30)
		button.AutomaticSize = Enum.AutomaticSize.X
		button.BackgroundColor3 = if accent then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised
		button.BorderSizePixel = 0
		button.Text = text
		button.TextColor3 = if accent then Theme.Colors.Background else Theme.Colors.MainText
		button.TextSize = Theme.TextSizes.Body
		button.Font = if accent then Theme.Fonts.Bold else Theme.Fonts.Medium
		button.Parent = buttons
		Theme.corner(Theme.Metrics.RadiusSmall).Parent = button
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 18)
		pad.PaddingRight = UDim.new(0, 18)
		pad.Parent = button

		local base = button.BackgroundColor3
		local hover = Theme.lighten(base, 0.12)
		button.MouseEnter:Connect(function()
			Theme.tween(button, { BackgroundColor3 = hover }, Theme.Motion.Fast):Play()
		end)
		button.MouseLeave:Connect(function()
			Theme.tween(button, { BackgroundColor3 = base }, Theme.Motion.Fast):Play()
		end)
		return button
	end

	local startButton = makeButton("Start building", true, 1)
	local skipButton = makeButton("Skip", false, 2)

	local function finish(name: string, named: boolean)
		if settled then
			return
		end
		settled = true
		local fade = Theme.tween(overlay, { BackgroundTransparency = 1 }, Theme.Motion.Normal)
		overlay.BackgroundTransparency = 1
		fade:Play()
		task.delay(0.18, function()
			if overlay.Parent then
				overlay:Destroy()
			end
		end)
		promise:resolve({ named = named, name = name })
	end

	startButton.MouseButton1Click:Connect(function()
		local name = StringUtil.trim(box.Text)
		if #name == 0 then
			name = "ForgePilot Assistant"
		end
		SettingsManager.setAssistantName(name)
		finish(name, true)
	end)

	skipButton.MouseButton1Click:Connect(function()
		finish(SettingsManager.getValue("assistantName"), false)
	end)

	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			startButton:Activate()
		end
	end)

	task.defer(function()
		box:CaptureFocus()
	end)

	return promise:await()
end

return WelcomeDialog