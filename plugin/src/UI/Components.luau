--!strict
local UserInputService = game:GetService("UserInputService")
--[[
	ForgePilot / UI / Components
	Small reusable widgets shared across every view: sections, labelled fields,
	text inputs, toggles, chips, empty states and buttons.
]]

local Theme = require(script.Parent.Parent.Utilities.Theme)
local Icons = require(script.Parent.Parent.Utilities.Icons)

local Components = {}

--=============================================================================
-- SECTION
--=============================================================================

--- A titled card with a body frame. Returns (card, body).
---
--- The card is a vertical UIListLayout. Title, subtitle and body each own their
--- height, so a three-line section description can never be painted over the
--- first control inside the body.
function Components.section(title: string, options: { subtitle: string?, order: number?, padded: boolean? }?): (Frame, Frame)
	local o = options or {}
	local card = Instance.new("Frame")
	card.Name = "Section_" .. title:gsub("%s+", "")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Theme.Extra.Surface
	card.BorderSizePixel = 0
	card.LayoutOrder = o.order or 0
	card.ClipsDescendants = false
	Theme.corner(Theme.Metrics.Radius).Parent = card
	Theme.stroke(Theme.Extra.Border, 1, 0.45).Parent = card
	Theme.padding4(Theme.Space.MD, Theme.Space.MD, Theme.Space.MD, Theme.Space.MD).Parent = card

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.Space.XS)
	layout.Parent = card

	local titleLabel = Theme.autoText(title, {
		size = Theme.TextSizes.Small,
		font = Theme.Fonts.Medium,
		color = Theme.Colors.MainText,
	})
	titleLabel.Name = "Title"
	titleLabel.LayoutOrder = 1
	titleLabel.AutomaticSize = Enum.AutomaticSize.Y
	titleLabel.Parent = card
	Theme.minSize(titleLabel, Vector2.new(0, 16))

	if o.subtitle then
		local subtitleLabel = Theme.autoText(o.subtitle, {
			size = Theme.TextSizes.Caption,
			color = Theme.Extra.Muted,
		})
		subtitleLabel.Name = "Subtitle"
		subtitleLabel.LayoutOrder = 2
		subtitleLabel.AutomaticSize = Enum.AutomaticSize.Y
		subtitleLabel.Parent = card
	end

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.BackgroundTransparency = 1
	Theme.passThrough(body)
	body.LayoutOrder = 10
	body.ClipsDescendants = false
	body.Parent = card

	if o.padded ~= false then
		Theme.padding(0).Parent = body
	end

	Theme.listLayout(Theme.Space.MD).Parent = body

	return card, body
end

--=============================================================================
-- FIELD
--=============================================================================

--- A labelled row. Returns (row, valueHolderFrame).
---
--- The row stacks label -> hint -> control, each sized by its own content. It is
--- the *stacked* form: the control sits under its label and uses the full width,
--- which is the only arrangement that survives a 320px window. `Components.toggle`
--- is the side-by-side variant and builds its own row rather than reusing this.
function Components.field(label: string, options: { hint: string?, order: number? }?): (Frame, Frame)
	local o = options or {}
	local row = Instance.new("Frame")
	row.Name = "Field_" .. label:gsub("%s+", "")
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	Theme.passThrough(row)
	row.ClipsDescendants = false
	row.LayoutOrder = o.order or 0

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.Space.XS)
	layout.Parent = row

	local labelText = Theme.autoText(label, {
		size = Theme.TextSizes.Small,
		color = Theme.Colors.SecondaryText,
		font = Theme.Fonts.Medium,
	})
	labelText.Name = "Label"
	labelText.LayoutOrder = 1
	labelText.Parent = row

	if o.hint then
		local hint = Theme.autoText(o.hint, {
			size = Theme.TextSizes.Caption,
			color = Theme.Extra.Muted,
		})
		hint.Name = "Hint"
		hint.LayoutOrder = 20
		hint.Parent = row
	end

	local holder = Instance.new("Frame")
	holder.Name = "Value"
	holder.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.BackgroundTransparency = 1
	Theme.passThrough(holder)
	holder.ClipsDescendants = false
	holder.LayoutOrder = 10
	holder.Parent = row

	-- A field can hold more than one control (the API-key row has a textbox, a
	-- reveal button and a status line). Without a layout they all default to
	-- Position (0,0) and stack on top of each other, which is exactly what
	-- Roblox renders.
	local holderLayout = Instance.new("UIListLayout")
	holderLayout.SortOrder = Enum.SortOrder.LayoutOrder
	holderLayout.Padding = UDim.new(0, Theme.Space.XS)
	holderLayout.Parent = holder

	return row, holder
end

--=============================================================================
-- INPUTS
--=============================================================================

function Components.textInput(placeholder: string, options: { multiLine: boolean?, height: number?, secret: boolean? }?): TextBox
	local o = options or {}
	local box = Theme.input(placeholder, { multiLine = o.multiLine, height = o.height })
	if o.secret then
		-- Masked by default. The caller toggles TextTransparency-based masking.
		box.Text = ""
	end
	return box
end

function Components.textButton(text: string, options: { order: number?, accent: boolean?, height: number?, width: UDim2? }?): TextButton
	local o = options or {}
	local button = Theme.textButton(text, {
		size = Theme.TextSizes.Small,
		height = o.height or Theme.Metrics.ButtonHeight,
		width = o.width,
		color = if o.accent then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised,
		textColor = if o.accent then Theme.Colors.Background else Theme.Colors.MainText,
		font = if o.accent then Theme.Fonts.Bold else Theme.Fonts.Medium,
		radius = Theme.Metrics.RadiusSmall,
	})
	button.Name = text:gsub("%s+", "")
	-- Buttons inside a row are sized by UIFlexItem, never by AutomaticSize.X.
	-- An intrinsically-sized button in a horizontal UIListLayout overflows the
	-- window as soon as the labels get long or the window gets narrow.
	button.AutomaticSize = Enum.AutomaticSize.None
	button.LayoutOrder = o.order or 0
	return button
end

--- A row of buttons that shrinks instead of overflowing.
---
--- Every button is a flex item, so a row of six actions ("Test connection",
--- "Test chat", "Detect capabilities", ...) always fits inside its parent —
--- shrinking to a readable minimum rather than running off the right edge.
---
--- Pass `columns` when even a shrunk button would be too narrow to read. The
--- row then becomes a fixed-column grid that wraps, so a 320px window shows the
--- actions on three lines of two instead of six buttons crushed into 40px each.
function Components.buttonRow(options: {
	order: number?,
	padding: number?,
	align: Enum.HorizontalAlignment?,
	columns: number?,
	minColumnWidth: number?,
}?): (Frame, any)
	local o = options or {}
	local columns = o.columns
	local activeColumns = columns or 1
	local grid: UIGridLayout? = nil
	local count = 0
	local padding = o.padding or Theme.Space.SM
	local height = Theme.Metrics.ButtonHeight
	local row = Instance.new("Frame")
	row.Name = "ButtonRow"
	row.Size = UDim2.new(1, 0, 0, height)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	Theme.passThrough(row)
	row.ClipsDescendants = false
	row.LayoutOrder = o.order or 0

	if columns and columns > 1 then
		grid = Instance.new("UIGridLayout")
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.CellSize = UDim2.new(1 / columns, -padding * (columns - 1) / columns, 0, height)
		grid.CellPadding = UDim2.fromOffset(padding, padding)
		grid.FillDirectionMaxCells = columns
		grid.FillDirection = Enum.FillDirection.Horizontal
		grid.HorizontalAlignment = o.align or Enum.HorizontalAlignment.Left
		grid.VerticalAlignment = Enum.VerticalAlignment.Center
		grid.Parent = row
		row.AutomaticSize = Enum.AutomaticSize.None
	else
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, padding)
		layout.HorizontalAlignment = o.align or Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Parent = row
	end

	local function reflow()
		if not grid then return end
		if o.minColumnWidth then
			activeColumns = math.clamp(math.floor((row.AbsoluteSize.X + padding) / (o.minColumnWidth + padding)), 1, columns or 1)
		end
		grid.CellSize = UDim2.new(1 / activeColumns, -padding * (activeColumns - 1) / activeColumns, 0, height)
		grid.FillDirectionMaxCells = activeColumns
		local rows = math.max(1, math.ceil(count / activeColumns))
		row.Size = UDim2.new(1, 0, 0, rows * height + (rows - 1) * padding)
	end
	if o.minColumnWidth then row:GetPropertyChangedSignal("AbsoluteSize"):Connect(reflow) end
	return row, function(text: string, buttonOptions: { accent: boolean?, order: number?, height: number? }?)
		local bo = buttonOptions or {}
		local buttonHeight = bo.height or height
		local button = Components.textButton(text, {
			accent = bo.accent,
			order = bo.order,
			height = buttonHeight,
		})
		if columns and columns > 1 then
			count += 1
			reflow()
			-- Fill the grid cell it lands in; the grid decides the wrap.
			button.Size = UDim2.new(1, 0, 0, buttonHeight)
			Theme.minSize(button, Vector2.new(0, buttonHeight))
		else
			-- FlexMode.Fill lets the UIListLayout hand the row's spare width to
			-- the buttons in proportion to their GrowRatio, and take it back
			-- when the window narrows. The button therefore always fits and
			-- never overlaps its neighbour.
			button.Size = UDim2.new(0, 0, 0, buttonHeight)
			Theme.flexItem(button, 1, 1)
			Theme.minSize(button, Vector2.new(0, buttonHeight))
		end
		button.Parent = row
		return button
	end
end

function Components.iconButton(iconKey: string, tooltip: string, order: number?): TextButton
	local button = Theme.textButton("", { height = 24, width = UDim2.fromOffset(26, 24) })
	button.Name = "IconButton_" .. iconKey
	button.LayoutOrder = order or 0
	Icons.setButton(button, iconKey)
	button.TextSize = 14
	button.TextColor3 = Theme.Colors.SecondaryText
	return button
end

--- A toggle switch. Returns (row, getValue).
---
--- Label and description on the left, switch flush right and vertically centred
--- in the row. This is deliberately NOT built on Components.field: a field
--- stacks the control under its label, which is why switches used to appear
--- below the text they belong to, at an arbitrary offset, never aligned with
--- each other.
function Components.toggle(label: string, initial: boolean, onChange: (boolean) -> (), options: { hint: string?, order: number? }?): (Frame, () -> boolean, (boolean) -> ())
	local o = options or {}

	local row = Instance.new("Frame")
	row.Name = "ToggleRow"
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	Theme.passThrough(row)
	row.ClipsDescendants = false
	row.LayoutOrder = o.order or 0

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.Space.SM)
	-- Horizontal, so the label column and the switch share one row; Right, so
	-- the switch is flush against the edge instead of being guessed at. Without
	-- an explicit FillDirection this defaults to Vertical and the switch drops
	-- BELOW its own label.
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	-- Vertical centring is declarative: the switch stays vertically aligned with
	-- its label whether the description is one line or four.
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row

	local textColumn = Instance.new("Frame")
	textColumn.Name = "Text"
	textColumn.Size = UDim2.new(1, -(Theme.Metrics.ToggleWidth + Theme.Space.SM), 0, 0)
	textColumn.AutomaticSize = Enum.AutomaticSize.Y
	textColumn.BackgroundTransparency = 1
	Theme.passThrough(textColumn)
	textColumn.ClipsDescendants = false
	textColumn.LayoutOrder = 1
	textColumn.Parent = row

	local textLayout = Instance.new("UIListLayout")
	textLayout.SortOrder = Enum.SortOrder.LayoutOrder
	textLayout.Padding = UDim.new(0, 2)
	textLayout.Parent = textColumn

	local labelText = Theme.autoText(label, {
		size = Theme.TextSizes.Small,
		color = Theme.Colors.MainText,
		font = Theme.Fonts.Medium,
	})
	labelText.Name = "Label"
	labelText.LayoutOrder = 1
	labelText.Parent = textColumn

	if o.hint then
		local hint = Theme.autoText(o.hint, {
			size = Theme.TextSizes.Caption,
			color = Theme.Extra.Muted,
		})
		hint.Name = "Hint"
		hint.LayoutOrder = 2
		hint.Parent = textColumn
	end

	-- The switch is a top-level sibling of the text column. The row's
	-- VerticalAlignment.Center does the centring, so the track is never placed
	-- with a guessed Y offset.
	local switchHolder = Instance.new("Frame")
	switchHolder.Name = "SwitchHolder"
	switchHolder.Size = UDim2.new(0, Theme.Metrics.ToggleWidth, 0, Theme.Metrics.ToggleHeight)
	switchHolder.BackgroundTransparency = 1
	Theme.passThrough(switchHolder)
	switchHolder.ClipsDescendants = false
	switchHolder.LayoutOrder = 2
	switchHolder.Parent = row

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.fromScale(1, 1)
	track.BackgroundColor3 = if initial then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised
	track.BorderSizePixel = 0
	track.Parent = switchHolder
	Theme.corner(math.floor(Theme.Metrics.ToggleHeight / 2)).Parent = track
	local trackStroke = Theme.stroke(Theme.Extra.Border)
	trackStroke.Parent = track

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.Size = UDim2.fromOffset(Theme.Metrics.ToggleKnob, Theme.Metrics.ToggleKnob)
	knob.Position = if initial then UDim2.fromOffset(Theme.Metrics.ToggleWidth - Theme.Metrics.ToggleKnob - 2, 2)
		else UDim2.fromOffset(2, 2)
	knob.BackgroundColor3 = Theme.Colors.MainText
	knob.BorderSizePixel = 0
	knob.Parent = track
	Theme.corner(math.floor(Theme.Metrics.ToggleKnob / 2)).Parent = knob

	-- The whole track is the hit target.
	local hitArea = Instance.new("TextButton")
	hitArea.Name = "Hit"
	hitArea.Size = UDim2.fromScale(1, 1)
	hitArea.BackgroundTransparency = 1
	hitArea.Text = ""
	hitArea.ZIndex = track.ZIndex + 1
	hitArea.Parent = switchHolder

	local state = { value = initial }

	local function apply()
		Theme.tween(track, {
			BackgroundColor3 = if state.value then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised,
		}, Theme.Motion.Fast):Play()
		trackStroke.Color = if state.value then Theme.withAlpha(Theme.Colors.Highlight, 0.5) else Theme.Extra.Border
		Theme.tween(knob, {
			Position = if state.value
				then UDim2.fromOffset(Theme.Metrics.ToggleWidth - Theme.Metrics.ToggleKnob - 2, 2)
				else UDim2.fromOffset(2, 2),
		}, Theme.Motion.Fast):Play()
	end

	hitArea.MouseButton1Click:Connect(function()
		state.value = not state.value
		apply()
		onChange(state.value)
	end)

	return row, function()
		return state.value
	end, function(value: boolean)
		state.value = value == true
		apply()
	end
end

--- A dropdown built from a fixed list. Returns (row, setOptions, getSelected).
---
--- The option list is NOT parented to the button. It is reparented into the
--- window's overlay layer and positioned from the button's AbsolutePosition, so
--- a ScrollingFrame between the button and the window edge cannot clip it, and
--- the list can never render over the Settings navigation it belongs to.
local closeActiveMenu: (() -> ())? = nil
function Components.closeMenus()
	if closeActiveMenu then closeActiveMenu() end
end

-- A compact, persistent tab bar. All tabs remain visible in a narrow dock.
function Components.tabBar(labels: { string }, onSelect: (string) -> ()): (Frame, (string) -> ())
	local row = Instance.new("Frame")
	row.Name = "TabBar"
	row.Size = UDim2.new(1, 0, 0, 32)
	Theme.passThrough(row)
	local layout = Theme.listLayout(2)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row
	local buttons: { [string]: TextButton } = {}
	local marks: { [string]: Frame } = {}
	local current = labels[1]
	local function select(value: string)
		current = value
		for name, button in buttons do
			local active = name == value
			button.TextColor3 = if active then Theme.Colors.MainText else Theme.Extra.Muted
			button.BackgroundColor3 = if active then Theme.Extra.SurfaceRaised else Theme.Colors.Background
			marks[name].Visible = active
		end
	end
	for index, name in labels do
		local button = Theme.textButton(name, {
			height = 30, size = Theme.TextSizes.Small, radius = Theme.Metrics.RadiusSmall,
			color = Theme.Colors.Background, truncate = true,
		})
		button.Name = "Tab_" .. name
		button.Size = UDim2.new(0, 0, 0, 30)
		button.LayoutOrder = index
		Theme.flexItem(button, 1, 1)
		button.Parent = row
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Transparency = 1 end
		local mark = Instance.new("Frame")
		mark.Name = "Selection"
		mark.AnchorPoint = Vector2.new(0, 1)
		mark.Position = UDim2.new(0, 8, 1, 0)
		mark.Size = UDim2.new(1, -16, 0, 2)
		mark.BorderSizePixel = 0
		mark.BackgroundColor3 = Theme.Colors.Highlight
		mark.Parent = button
		buttons[name] = button
		marks[name] = mark
		button.MouseButton1Click:Connect(function()
			Components.closeMenus()
			select(name)
			onSelect(name)
		end)
		button.MouseLeave:Connect(function() select(current) end)
	end
	select(current)
	return row, select
end

function Components.dropdown(label: string, options: { string }, onSelect: (string) -> (), options_meta: any?): (Frame, any, any, any)
	local o = options_meta or {}
	local row, holder = Components.field(label, { hint = o.hint, order = o.order })
	local list = table.clone(options)
	local current: string? = list[1]
	local button = Theme.textButton(current or "Select…", { height = Theme.Metrics.InputHeight, truncate = true })
	button.Name = "Dropdown"
	button.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight)
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Parent = holder
	Theme.padding4(0, 28, 0, 10).Parent = button
	local chevron = Icons.glyph("ChevronDown", 12)
	chevron.AnchorPoint = Vector2.new(1, 0.5)
	chevron.Position = UDim2.new(1, 20, 0.5, 0)
	chevron.Size = UDim2.fromOffset(14, 14)
	chevron.Parent = button

	local menu = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	menu.Name = "Menu"
	menu.AutomaticSize = Enum.AutomaticSize.None
	menu.Visible = false
	menu.Active = true
	menu.BackgroundTransparency = 0
	menu.BackgroundColor3 = Theme.Extra.SurfaceRaised
	menu.ZIndex = Theme.OverlayZIndex + 2
	Theme.corner(8).Parent = menu
	Theme.stroke(Theme.Extra.BorderStrong).Parent = menu
	Theme.padding(4).Parent = menu
	Theme.listLayout(2).Parent = menu
	local dismiss = Instance.new("TextButton")
	dismiss.Name = "MenuDismiss"
	dismiss.Size = UDim2.fromScale(1, 1)
	dismiss.BackgroundTransparency = 1
	dismiss.Text = ""
	dismiss.ZIndex = Theme.OverlayZIndex + 1
	dismiss.Active = true
	dismiss.Visible = false
	local host: Frame? = nil
	local connections: { RBXScriptConnection } = {}
	local ownerConnections: { RBXScriptConnection } = {}
	local function close()
		menu.Visible = false
		dismiss.Visible = false
		for _, connection in ownerConnections do connection:Disconnect() end
		table.clear(ownerConnections)
		if closeActiveMenu == close then closeActiveMenu = nil end
	end
	local function watchOwner()
		-- The menu is outside its owner in a shared overlay. It must not leave
		-- an invisible full-panel input blocker after that owner goes away.
		local ancestor: Instance? = button
		while ancestor do
			if ancestor:IsA("GuiObject") then
				local object = ancestor
				ownerConnections[#ownerConnections + 1] = object:GetPropertyChangedSignal("Visible"):Connect(function()
					if not object.Visible then close() end
				end)
				ownerConnections[#ownerConnections + 1] = object:GetPropertyChangedSignal("Interactable"):Connect(function()
					if not object.Interactable then close() end
				end)
			elseif ancestor:IsA("LayerCollector") then
				local layer = ancestor
				ownerConnections[#ownerConnections + 1] = layer:GetPropertyChangedSignal("Enabled"):Connect(function()
					if not layer.Enabled then close() end
				end)
			end
			ownerConnections[#ownerConnections + 1] = ancestor.AncestryChanged:Connect(close)
			ancestor = ancestor.Parent
		end
	end
	local function place()
		if not host then return end
		local origin, area = host.AbsolutePosition, host.AbsoluteSize
		local localX = button.AbsolutePosition.X - origin.X
		local localY = button.AbsolutePosition.Y - origin.Y
		local width = math.max(1, math.min(math.max(button.AbsoluteSize.X, o.menuWidth or 0), area.X - 16))
		local x = math.clamp(localX, 8, math.max(8, area.X - width - 8))
		local below = localY + button.AbsoluteSize.Y + 4
		local roomBelow = math.max(0, area.Y - below - 8)
		local roomAbove = math.max(0, localY - 12)
		local wanted = math.min(240, math.max(1, #list) * 30 + 8)
		local down = roomBelow >= wanted or roomBelow >= roomAbove
		local available = if down then roomBelow else roomAbove
		local height = math.min(wanted, math.max(30, available), math.max(1, area.Y - 16))
		local y = if down then below else localY - height - 4
		menu.Size = UDim2.fromOffset(width, height)
		menu.Position = UDim2.fromOffset(x, math.clamp(y, 8, math.max(8, area.Y - height - 8)))
	end
	local function rebuild()
		for _, child in menu:GetChildren() do if child:IsA("GuiObject") then child:Destroy() end end
		for index, entry in list do
			local choice = Theme.textButton(entry, { height = 28, truncate = true, alignX = Enum.TextXAlignment.Left })
			choice.Name = "Option"
			choice.LayoutOrder = index
			choice.BackgroundTransparency = if entry == current then 0 else 1
			choice.Size = UDim2.new(1, -4, 0, 28)
			Theme.padding4(0, 8, 0, 8).Parent = choice
			choice.Parent = menu
			choice.MouseButton1Click:Connect(function()
				current = entry
				button.Text = entry
				close()
				onSelect(entry)
			end)
		end
	end
	button.MouseButton1Click:Connect(function()
		if not button.Interactable or not row.Parent then return end
		if menu.Visible then close(); return end
		Components.closeMenus()
		host = Theme.overlayHost(row)
		if menu.Parent ~= host then
			menu.Parent = host
			dismiss.Parent = host
			connections[#connections + 1] = host:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() if menu.Visible then place() end end)
		end
		rebuild()
		place()
		dismiss.Visible = true
		menu.Visible = true
		closeActiveMenu = close
		watchOwner()
	end)
	dismiss.MouseButton1Click:Connect(close)
	connections[#connections + 1] = button:GetPropertyChangedSignal("AbsolutePosition"):Connect(function() if menu.Visible then place() end end)
	connections[#connections + 1] = button:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() if menu.Visible then place() end end)
	row.Destroying:Connect(function()
		close()
		for _, connection in connections do connection:Disconnect() end
		menu:Destroy(); dismiss:Destroy()
	end)
	local function select(value: string?)
		current = value
		button.Text = value or "Select…"
	end
	return row, function(newOptions: { string })
		list = table.clone(newOptions or {})
		if not table.find(list, current) then select(list[1]) end
		if menu.Visible then rebuild(); place() end
	end, function() return current end, select
end

--=============================================================================
-- CHIPS / STATES
--=============================================================================

function Components.chip(text: string, color: Color3, order: number?): TextLabel
	local label = Theme.label(text, {
		size = Theme.TextSizes.Caption,
		color = color,
		font = Theme.Fonts.Medium,
		alignX = Enum.TextXAlignment.Center,
	})
	label.Name = "Chip"
	label.LayoutOrder = order or 0
	label.AutomaticSize = Enum.AutomaticSize.X
	label.BackgroundColor3 = Theme.withAlpha(color, 0.14)
	label.Size = UDim2.new(0, 0, 0, 20)
	label.BackgroundTransparency = 0
	label.ClipsDescendants = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	Theme.corner(10).Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = label
	return label
end

function Components.emptyState(iconKey: string, title: string, detail: string, actionText: string?, onAction: (() -> ())?): Frame
	local frame = Instance.new("Frame")
	frame.Name = "EmptyState"
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundTransparency = 1
	Theme.passThrough(frame)
	frame.ClipsDescendants = false

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.Space.SM)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = frame

	local iconHolder = Instance.new("Frame")
	iconHolder.Name = "IconHolder"
	iconHolder.Size = UDim2.fromOffset(34, 34)
	iconHolder.BackgroundTransparency = 1
	Theme.passThrough(iconHolder)
	iconHolder.LayoutOrder = 1
	iconHolder.Parent = frame

	local icon = Icons.glyph(iconKey, 26, Theme.Extra.BorderStrong)
	icon.Name = "Icon"
	icon.Size = UDim2.fromOffset(34, 34)
	icon.Parent = iconHolder

	local heading = Theme.autoText(title, {
		size = Theme.TextSizes.Body,
		font = Theme.Fonts.Bold,
		alignX = Enum.TextXAlignment.Center,
	})
	heading.Name = "Title"
	heading.LayoutOrder = 2
	heading.Parent = frame
	Theme.padding4(0, Theme.Space.MD, 0, Theme.Space.MD).Parent = heading

	local body = Theme.autoText(detail, {
		size = Theme.TextSizes.Small,
		color = Theme.Colors.SecondaryText,
		alignX = Enum.TextXAlignment.Center,
	})
	body.Name = "Detail"
	body.LayoutOrder = 3
	body.Parent = frame
	Theme.padding4(0, Theme.Space.LG, 0, Theme.Space.LG).Parent = body

	if actionText and onAction then
		local button = Components.textButton(actionText, { accent = true, height = Theme.Metrics.ButtonHeight })
		button.Name = "Action"
		button.LayoutOrder = 4
		button.Size = UDim2.fromOffset(160, Theme.Metrics.ButtonHeight)
		button.Parent = frame
		button.MouseButton1Click:Connect(onAction)
	end

	return frame
end

function Components.divider(order: number?): Frame
	local line = Theme.separator()
	line.LayoutOrder = order or 0
	line.AutomaticSize = Enum.AutomaticSize.None
	return line
end

--=============================================================================
-- TOASTS
--=============================================================================

function Components.toast(parent: GuiObject, kind: string, message: string)
	local colors = {
		info = Theme.Extra.Info,
		success = Theme.Colors.Success,
		warning = Theme.Extra.Warning,
		error = Theme.Colors.Error,
	}
	local color = colors[kind] or Theme.Extra.Info

	-- Toasts live in the overlay layer: they must be able to clear the
	-- navigation and must never be clipped by a ScrollingFrame inside a page.
	local host = Theme.overlayHost(parent)
	local layer = host:FindFirstChild("ToastLayer")
	if not layer then
		layer = Instance.new("Frame")
		layer.Name = "ToastLayer"
		layer.Size = UDim2.fromScale(1, 1)
		layer.BackgroundTransparency = 1
		Theme.passThrough(layer)
		layer.BorderSizePixel = 0
		layer.ZIndex = Theme.OverlayZIndex + 10
		layer.ClipsDescendants = false
		layer.Parent = host

		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, Theme.Space.SM)
		layout.VerticalAlignment = Enum.VerticalAlignment.Top
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.Parent = layer
	end

	local container = Instance.new("Frame")
	container.Name = "Toast"
	container.Size = UDim2.new(1, -(Theme.Space.XL * 2), 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundColor3 = Theme.Extra.SurfacePressed
	container.BorderSizePixel = 0
	container.BackgroundTransparency = 1
	Theme.passThrough(container)
	container.ZIndex = layer.ZIndex + 1
	container.ClipsDescendants = true
	container.LayoutOrder = 9000 + (math.floor(os.clock() * 1000) % 1000)
	container.Parent = layer
	Theme.corner(Theme.Metrics.Radius).Parent = container
	local stroke = Theme.stroke(Theme.withAlpha(color, 0.55))
	stroke.Parent = container
	Theme.padding(Theme.Space.SM).Parent = container

	-- icon | text, side by side, both centred on each other
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	Theme.passThrough(row)
	row.ClipsDescendants = false
	row.LayoutOrder = 1
	row.Parent = container

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, Theme.Space.SM)
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.Parent = row

	local icon = Icons.glyph(
		if kind == "error" then "Error" elseif kind == "warning" then "Warning" elseif kind == "success" then "Check" else "Info",
		14,
		color
	)
	icon.Name = "Icon"
	icon.Size = UDim2.fromOffset(16, 16)
	icon.LayoutOrder = 1
	icon.Parent = row

	local label = Theme.autoText(message, {
		size = Theme.TextSizes.Small,
		color = Theme.Colors.MainText,
	})
	label.Name = "Text"
	label.LayoutOrder = 2
	label.Size = UDim2.new(0, 0, 0, 0)
	Theme.flexItem(label, 1, 1)
	label.Parent = row

	Theme.tween(container, { BackgroundTransparency = 0 }, Theme.Motion.Normal):Play()

	task.delay(5, function()
		if container.Parent then
			local fade = Theme.tween(container, { BackgroundTransparency = 1 }, Theme.Motion.Slow)
			fade.Completed:Connect(function()
				if container.Parent then
					container:Destroy()
				end
			end)
			fade:Play()
		end
	end)

	-- Keep at most three toasts on screen.
	local siblings = 0
	for _, child in layer:GetChildren() do
		if child.Name == "Toast" then
			siblings += 1
		end
	end
	if siblings > 3 then
		for _, child in layer:GetChildren() do
			if child.Name == "Toast" then
				child:Destroy()
				break
			end
		end
	end
end

return Components
