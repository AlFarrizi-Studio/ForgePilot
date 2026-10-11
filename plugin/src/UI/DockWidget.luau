--!strict
--[[
	ForgePilot / UI / DockWidget
	Builds the dockable ForgePilot window and its navigation shell.

	Structure (a single vertical UIListLayout, no absolute Y offsets):

	    Root
	      Header    - brand, plugin name, assistant name, provider status
	      Nav       - five tabs that always tile the strip, icons-only when narrow
	      Content   - the active page, given whatever height is left over

	Every band sizes itself, so the window reflows when the DockWidget is
	resized instead of colliding at narrow widths.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local Theme = require(script.Parent.Parent.Utilities.Theme)

local DockWidget = {}

export type Section = "chat" | "builder" | "history" | "logs" | "settings"

local sectionOrder: { Section } = { "chat", "builder", "history", "logs", "settings" }

DockWidget.SectionOrder = sectionOrder

local sectionMeta: { [Section]: { label: string, icon: string } } = {
	chat = { label = "Chat", icon = "Chat" },
	builder = { label = "Builder", icon = "Builder" },
	history = { label = "History", icon = "History" },
	logs = { label = "Logs", icon = "Logs" },
	settings = { label = "Settings", icon = "Settings" },
}

DockWidget.SectionMeta = sectionMeta

--=============================================================================
-- BUILD
--=============================================================================

function DockWidget.build(plugin: Plugin): PluginGui
	local gui = plugin:CreateDockWidgetPluginGuiAsync(
		"ForgePilotMain",
		DockWidgetPluginGuiInfo.new(
			Enum.InitialDockState.Right,
			false, -- initially enabled
			false, -- override previous state
			440, -- default width
			760, -- default height
			300, -- minimum width
			400 -- minimum height
		)
	)

	gui.Name = "ForgePilot"
	gui.Title = "ForgePilot"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui:SetAttribute("ForgePilotBrand", "ForgePilot")
	-- DockWidgetPluginGui does not expose ScreenGui.ResetOnSpawn.

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Theme.Colors.Background
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Parent = gui

	-- Subtle brand gradient behind the header strip.
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Theme.Colors.Background
	backdrop.BorderSizePixel = 0
	backdrop.ZIndex = 1
	backdrop.Parent = root
	backdrop.ClipsDescendants = true

	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.Size = UDim2.new(1, 0, 0, 220)
	glow.BackgroundTransparency = 1
	Theme.passThrough(glow)
	glow.BorderSizePixel = 0
	glow.Parent = backdrop
	Theme.gradient(
		Theme.withAlpha(Theme.Colors.Highlight, 0.10),
		Theme.withAlpha(Theme.Colors.Highlight, 0)
	).Parent = glow

	-- The window shell: three bands, stacked. Nothing below the nav knows or
	-- cares what the nav's height is.
	local shell = Instance.new("Frame")
	shell.Name = "Shell"
	shell.Size = UDim2.fromScale(1, 1)
	shell.BackgroundTransparency = 1
	Theme.passThrough(shell)
	shell.BorderSizePixel = 0
	shell.Parent = root

	local shellPadding = Instance.new("UIPadding")
	shellPadding.PaddingLeft = UDim.new(0, Theme.Space.SM)
	shellPadding.PaddingRight = UDim.new(0, Theme.Space.SM)
	shellPadding.PaddingTop = UDim.new(0, Theme.Space.SM)
	shellPadding.PaddingBottom = UDim.new(0, Theme.Space.SM)
	shellPadding.Parent = shell

	local shellLayout = Instance.new("UIListLayout")
	shellLayout.SortOrder = Enum.SortOrder.LayoutOrder
	shellLayout.Padding = UDim.new(0, Theme.Space.SM)
	shellLayout.Parent = shell

	-- Header -------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, Theme.Metrics.HeaderHeight)
	header.BackgroundTransparency = 1
	Theme.passThrough(header)
	header.LayoutOrder = 1
	header.Parent = shell

	-- A horizontal UIListLayout with a flexible text column is what keeps the
	-- plugin name from sliding under the provider pill. The old version sized
	-- the title with `UDim2.new(1, -180, ...)` next to a fixed 150px pill,
	-- which overlapped at EVERY width, not just narrow ones.
	local headerLayout = Instance.new("UIListLayout")
	headerLayout.FillDirection = Enum.FillDirection.Horizontal
	headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	headerLayout.Padding = UDim.new(0, Theme.Space.SM)
	headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	headerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	headerLayout.Parent = header

	local markSlot = Instance.new("Frame")
	markSlot.Name = "MarkSlot"
	markSlot.Size = UDim2.fromOffset(26, 26)
	markSlot.BackgroundTransparency = 1
	Theme.passThrough(markSlot)
	markSlot.LayoutOrder = 1
	markSlot.Parent = header
	Theme.minSize(markSlot, Vector2.new(26, 26)).Parent = markSlot

	local mark = Icons.brandMark(26)
	mark.Name = "BrandMark"
	mark.Parent = markSlot

	local textColumn = Instance.new("Frame")
	textColumn.Name = "Titles"
	textColumn.Size = UDim2.new(0, 0, 0, 36)
	textColumn.BackgroundTransparency = 1
	Theme.passThrough(textColumn)
	textColumn.ClipsDescendants = true
	textColumn.LayoutOrder = 2
	textColumn.Parent = header
	Theme.flexItem(textColumn, 1, 1)
	Theme.minSize(textColumn, Vector2.new(0, 0))

	local textLayout = Instance.new("UIListLayout")
	textLayout.SortOrder = Enum.SortOrder.LayoutOrder
	textLayout.Padding = UDim.new(0, 0)
	textLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	textLayout.Parent = textColumn

	local titleLabel = Theme.label("ForgePilot", {
		size = Theme.TextSizes.Title,
		font = Theme.Fonts.Bold,
	})
	titleLabel.Name = "BrandTitle"
	titleLabel.Size = UDim2.new(1, 0, 0, 20)
	titleLabel.LayoutOrder = 1
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.ClipsDescendants = true
	titleLabel.Parent = textColumn

	local subtitleLabel = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Muted,
	})
	subtitleLabel.Name = "BrandSubtitle"
	subtitleLabel.Size = UDim2.new(1, 0, 0, 14)
	subtitleLabel.LayoutOrder = 2
	subtitleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	subtitleLabel.ClipsDescendants = true
	subtitleLabel.Parent = textColumn

	-- Provider status pill ------------------------------------------------
	local statusPill = Instance.new("TextButton")
	statusPill.Name = "ProviderStatus"
	statusPill.Size = UDim2.new(0, 132, 0, 24)
	statusPill.BackgroundColor3 = Theme.Extra.Surface
	statusPill.BorderSizePixel = 0
	statusPill.AutoButtonColor = false
	statusPill.ClipsDescendants = true
	statusPill.Text = ""
	statusPill.TextColor3 = Theme.Extra.Muted
	statusPill.TextSize = Theme.TextSizes.Caption
	statusPill.Font = Theme.Fonts.Medium
	statusPill.TextTruncate = Enum.TextTruncate.AtEnd
	statusPill.LayoutOrder = 3
	statusPill.Parent = header
	Theme.flexItem(statusPill, 0, 0)
	Theme.corner(12).Parent = statusPill
	local pillStroke = Theme.stroke(Theme.Extra.Border)
	pillStroke.Parent = statusPill

	local pillLayout = Instance.new("UIListLayout")
	pillLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pillLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pillLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	pillLayout.Parent = statusPill

	local pillLabel = Theme.label("No AI Provider", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Muted,
		font = Theme.Fonts.Medium,
		alignX = Enum.TextXAlignment.Center,
	})
	pillLabel.Name = "Text"
	pillLabel.AutomaticSize = Enum.AutomaticSize.None
	pillLabel.Size = UDim2.new(1, -8, 1, 0)
	pillLabel.ClipsDescendants = true
	pillLabel.TextTruncate = Enum.TextTruncate.AtEnd
	pillLabel.Parent = statusPill
	-- Shares whatever room the pill has and truncates, instead of running out
	-- through the right-hand edge at narrow widths.
	Theme.flexItem(pillLabel, 1, 1)

	-- Navigation ---------------------------------------------------------
	local nav = Instance.new("Frame")
	nav.Name = "Nav"
	nav.Size = UDim2.new(1, 0, 0, Theme.Metrics.NavHeight)
	nav.BackgroundTransparency = 1
	Theme.passThrough(nav)
	nav.LayoutOrder = 2
	nav.Parent = shell

	local navBackground = Instance.new("Frame")
	navBackground.Name = "Track"
	navBackground.Size = UDim2.fromScale(1, 1)
	navBackground.BackgroundColor3 = Theme.Extra.Surface
	navBackground.BorderSizePixel = 0
	navBackground.Parent = nav
	Theme.corner(Theme.Metrics.Radius).Parent = navBackground

	local trackLayout = Instance.new("UIListLayout")
	trackLayout.FillDirection = Enum.FillDirection.Horizontal
	trackLayout.SortOrder = Enum.SortOrder.LayoutOrder
	trackLayout.Padding = UDim.new(0, Theme.Space.XS)
	trackLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	trackLayout.Parent = navBackground
	Theme.padding(3).Parent = navBackground

	local tabButtons: { [Section]: TextButton } = {}
	local tabIcons: { [Section]: TextLabel } = {}
	local tabLabels: { [Section]: TextLabel } = {}

	for index, section in DockWidget.SectionOrder do
		local meta = DockWidget.SectionMeta[section]
		local button = Theme.textButton("", {
			height = Theme.Metrics.NavHeight - 6,
			radius = Theme.Metrics.RadiusSmall,
			color = Theme.Extra.Surface,
			font = Theme.Fonts.Medium,
		})
		button.Name = "Tab_" .. section
		button.LayoutOrder = index
		button.AutoButtonColor = false
		button.BackgroundTransparency = 1
		button.Text = ""
		-- Equal custom grow ratios make the five tabs share the strip, so they can
		-- never overlap or spill past the edge no matter how narrow it gets.
		button.Size = UDim2.new(0, 0, 1, 0)
		Theme.flexItem(button, 1, 1)
		Theme.minSize(button, Vector2.new(0, Theme.Metrics.NavHeight - 6))
		button.ClipsDescendants = true

		local buttonLayout = Instance.new("UIListLayout")
		buttonLayout.FillDirection = Enum.FillDirection.Horizontal
		buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
		buttonLayout.Padding = UDim.new(0, Theme.Space.XS)
		buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		buttonLayout.Parent = button
		Theme.padding4(0, Theme.Space.XS, 0, Theme.Space.XS).Parent = button

		local icon = Icons.glyph(meta.icon, 14, Theme.Colors.SecondaryText)
		icon.Name = "Icon"
		icon.Size = UDim2.fromOffset(16, 16)
		icon.LayoutOrder = 1
		icon.Parent = button

		local text = Theme.label(meta.label, {
			size = Theme.TextSizes.Small,
			font = Theme.Fonts.Medium,
			color = Theme.Colors.SecondaryText,
			alignX = Enum.TextXAlignment.Left,
		})
		text.Name = "Label"
		text.Size = UDim2.new(0, 0, 1, 0)
		text.AutomaticSize = Enum.AutomaticSize.X
		text.LayoutOrder = 2
		text.TextTruncate = Enum.TextTruncate.AtEnd
		text.ClipsDescendants = true
		text.Parent = button

		button.Parent = navBackground
		tabButtons[section] = button
		tabIcons[section] = icon
		tabLabels[section] = text
	end

	-- Content host -------------------------------------------------------
	-- The only element with a percentage height: it takes whatever the header
	-- and navigation left behind, at every window size.
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 0, 0)
	content.BackgroundTransparency = 1
	Theme.passThrough(content)
	content.ClipsDescendants = true
	content.LayoutOrder = 3
	content.Parent = shell
	-- A flex item in the shell's vertical list: the page claims whatever height
	-- the header and navigation did not use, at every window height. No magic
	-- "102" constant, and nothing to go stale when the header wraps.
	Theme.flexItem(content, 1, 1)

	-- Overlay layer ------------------------------------------------------
	-- Toasts, dropdown menus and dialogs live here so nothing can clip them.
	Theme.overlayHost(content)

	-- Resize handling ----------------------------------------------------
	local currentSection: Section = "chat"
	local currentBucket: string? = nil

	local function applyWidthRules(width: number)
		local bucket = Theme.bucketFor(width)
		if bucket == currentBucket then
			return
		end
		currentBucket = bucket

		local showLabels = width >= 440
		local showIcons = true
		for _, section in DockWidget.SectionOrder do
			local label = tabLabels[section]
			if label then
				label.Visible = showLabels
				label.AutomaticSize = if showLabels then Enum.AutomaticSize.X else Enum.AutomaticSize.None
				label.Size = UDim2.new(0, 0, 1, 0)
				label.TextXAlignment = Enum.TextXAlignment.Left
			end
			tabIcons[section].Visible = showIcons
			Theme.flexItem(tabButtons[section], 1, 1)
		end

		-- A narrower window needs less chrome around the status pill.
		statusPill.Size = UDim2.new(0, if bucket == "compact" then 96 else 132, 0, 24)
		textColumn.Size = UDim2.new(0, 0, 0, 36)
	end

	local function setSection(section: Section, notify: boolean?)
		if not sectionMeta[section] then return end
		currentSection = section
		for _, other in DockWidget.SectionOrder do
			local active = other == section
			local button = tabButtons[other]
			Theme.tween(button, {
				BackgroundTransparency = if active then 0 else 1,
				BackgroundColor3 = Theme.Extra.SurfaceHover,
			}, Theme.Motion.Fast):Play()
			local label = tabLabels[other]
			if label then
				Theme.tween(label, {
					TextColor3 = if active then Theme.Colors.MainText else Theme.Colors.SecondaryText,
				}, Theme.Motion.Fast):Play()
			end
			tabIcons[other].TextColor3 = if active then Theme.Colors.Highlight else Theme.Extra.Muted
		end
		if notify ~= false then EventBus.emit(EventBus.Events.Navigate, { section = section }) end
	end

	for _, section in DockWidget.SectionOrder do
		local captured = section
		tabButtons[section].MouseButton1Click:Connect(function()
			setSection(captured)
		end)
		tabButtons[section].MouseEnter:Connect(function()
			Theme.tween(tabButtons[section], { BackgroundColor3 = Theme.Extra.SurfaceHover }, Theme.Motion.Fast):Play()
		end)
		tabButtons[section].MouseLeave:Connect(function()
			Theme.tween(tabButtons[section], {
				BackgroundColor3 = Theme.Extra.SurfaceHover,
				BackgroundTransparency = if currentSection == section then 0 else 1,
			}, Theme.Motion.Fast):Play()
		end)
	end

	statusPill.MouseButton1Click:Connect(function()
		setSection("settings")
	end)

	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		applyWidthRules(root.AbsoluteSize.X)
	end)

	applyWidthRules(420)

	-- Public surface -----------------------------------------------------
	gui:SetAttribute("ForgePilotWidget", true)
	DockWidget.root = root
	DockWidget.content = content
	DockWidget.statusPill = statusPill
	DockWidget.subtitleLabel = subtitleLabel
	DockWidget.header = header
	DockWidget.nav = nav
	DockWidget.overlay = content:FindFirstChild("OverlayLayer")

	function DockWidget.setStatus(text: string, color: Color3)
		statusPill.Text = ""
		statusPill.TextColor3 = color
		pillLabel.Text = text
		pillLabel.TextColor3 = color
		pillStroke.Color = Theme.withAlpha(color, 0.4)
	end

	function DockWidget.setSubtitle(text: string)
		subtitleLabel.Text = text
	end

	function DockWidget.getSection(): Section
		return currentSection
	end

	function DockWidget.navigate(section: Section)
		setSection(section)
	end

	local unsubscribe = EventBus.on(EventBus.Events.Navigate, function(payload)
		if sectionMeta[payload.section] then setSection(payload.section, false) end
	end)
	gui.Destroying:Connect(unsubscribe)
	setSection("chat")

	return gui
end

return DockWidget
