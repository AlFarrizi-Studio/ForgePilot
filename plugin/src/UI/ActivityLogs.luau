--!strict
--[[
	ForgePilot / UI / ActivityLogs
	Terminal-style activity panel with auto-scroll, pause, filter, search,
	copy, clear and expandable tool details.

	Everything shown here came from a real event. Nothing is synthesised.
]]

local Clipboard = require(script.Parent.Parent.Utilities.Clipboard)
local Components = require(script.Parent.Components)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local Theme = require(script.Parent.Parent.Utilities.Theme)

local ActivityLogs = {}

local LEVEL_KEYS: { [string]: string } = {
	INFO = "INFO",
	SUCCESS = "OK",
	WARN = "WARN",
	ERROR = "ERR",
	CONNECT = "CONN",
	AGENT = "AGNT",
	PLAN = "PLAN",
	QUESTION = "QSTN",
	TOOL = "TOOL",
	DEBUG = "DBUG",
}

function ActivityLogs.build(parent: GuiObject): Frame
	local view = Instance.new("Frame")
	view.Name = "LogsView"
	view.Size = UDim2.fromScale(1, 1)
	view.BackgroundTransparency = 1
	Theme.passThrough(view)
	view.Parent = parent

	-- Controls ------------------------------------------------------------
	local controls = Instance.new("Frame")
	controls.Name = "Controls"
	controls.Size = UDim2.new(1, 0, 0, 28)
	controls.BackgroundTransparency = 1
	Theme.passThrough(controls)
	controls.Parent = view

	local searchBox = Theme.input("Filter logs…")
	searchBox.Name = "Search"
	searchBox.Size = UDim2.new(1, -230, 0, 26)
	searchBox.Position = UDim2.fromOffset(0, 1)
	searchBox.TextSize = Theme.TextSizes.Small
	searchBox.Parent = controls

	local pauseButton = Theme.textButton("Pause", { height = 26 })
	pauseButton.Name = "Pause"
	pauseButton.AnchorPoint = Vector2.new(1, 0)
	pauseButton.Position = UDim2.new(1, 0, 0, 1)
	pauseButton.Size = UDim2.fromOffset(72, 26)
	pauseButton.TextSize = Theme.TextSizes.Caption
	pauseButton.TextColor3 = Theme.Colors.SecondaryText
	pauseButton.Parent = controls
	Icons.setButton(pauseButton, "Stop", "Pause")

	local copyButton = Theme.textButton("", { height = 26 })
	copyButton.Name = "Copy"
	copyButton.AnchorPoint = Vector2.new(1, 0)
	copyButton.Position = UDim2.new(1, -76, 0, 1)
	copyButton.Size = UDim2.fromOffset(36, 26)
	Icons.setButton(copyButton, "Copy")
	copyButton.TextSize = 12
	copyButton.TextColor3 = Theme.Colors.SecondaryText
	copyButton.Parent = controls

	local clearButton = Theme.textButton("", { height = 26 })
	clearButton.Name = "Clear"
	clearButton.AnchorPoint = Vector2.new(1, 0)
	clearButton.Position = UDim2.new(1, -116, 0, 1)
	clearButton.Size = UDim2.fromOffset(36, 26)
	Icons.setButton(clearButton, "Trash")
	clearButton.TextSize = 12
	clearButton.TextColor3 = Theme.Colors.SecondaryText
	clearButton.Parent = controls

	local autoScrollButton = Theme.textButton("Auto", { height = 26 })
	autoScrollButton.Name = "AutoScroll"
	autoScrollButton.AnchorPoint = Vector2.new(1, 0)
	autoScrollButton.Position = UDim2.new(1, -156, 0, 1)
	autoScrollButton.Size = UDim2.fromOffset(58, 26)
	autoScrollButton.TextSize = Theme.TextSizes.Caption
	autoScrollButton.TextColor3 = Theme.Colors.Success
	autoScrollButton.Parent = controls
	Icons.setButton(autoScrollButton, "ChevronDown", "Auto")

	-- Filter chips --------------------------------------------------------
	local filterRow = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	filterRow.Name = "Filters"
	filterRow.Size = UDim2.new(1, 0, 0, 0)
	filterRow.AutomaticSize = Enum.AutomaticSize.Y
	filterRow.Position = UDim2.fromOffset(0, 32)
	filterRow.BackgroundTransparency = 1
	Theme.passThrough(filterRow)
	filterRow.ScrollingDirection = Enum.ScrollingDirection.X
	filterRow.Parent = view

	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	filterLayout.Padding = UDim.new(0, 4)
	filterLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	filterLayout.Parent = filterRow
	filterRow.AutomaticSize = Enum.AutomaticSize.Y

	local filterPad = Instance.new("UIPadding")
	filterPad.PaddingBottom = UDim.new(0, 6)
	filterPad.PaddingRight = UDim.new(0, 4)
	filterPad.Parent = filterRow

	-- Console -------------------------------------------------------------
	local console = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	console.Name = "Console"
	console.Size = UDim2.new(1, 0, 1, -66)
	console.Position = UDim2.fromOffset(0, 62)
	console.BackgroundColor3 = Theme.Extra.Overlay
	console.BorderSizePixel = 0
	console.Parent = view
	Theme.corner(Theme.Metrics.RadiusSmall).Parent = console
	Theme.padding(8).Parent = console
	Theme.listLayout(2).Parent = console

	-- State ---------------------------------------------------------------
	local paused = false
	local autoScroll = true
	local activeFilter: string? = nil
	local query = ""
	local renderedCount = 0

	local function passesFilter(entry): boolean
		if activeFilter and entry.category ~= activeFilter then
			return false
		end
		if #query >= 2 then
			local needle = string.lower(query)
			local haystack = string.lower(
				string.format("%s %s %s %s", entry.level, entry.category, entry.message, entry.detail or "")
			)
			if not string.find(haystack, needle, 1, true) then
				return false
			end
		end
		return true
	end

	local function atBottom(): boolean
		local maxScroll = math.max(0, console.AbsoluteCanvasSize.Y - console.AbsoluteWindowSize.Y)
		return (maxScroll - console.CanvasPosition.Y) < 40
	end

	local function scrollToBottom()
		console.CanvasPosition = Vector2.new(0, math.max(0, console.AbsoluteCanvasSize.Y - console.AbsoluteWindowSize.Y))
	end

	local function renderEntry(entry)
		local row = Instance.new("Frame")
		row.Name = "LogRow"
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.BackgroundTransparency = 1
		Theme.passThrough(row)

		-- The line, the details toggle and the detail stack themselves. Parking
		-- them all at y = 0 is what made "details" paint over the log text.
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Padding = UDim.new(0, 1)
		rowLayout.Parent = row

		local line = Instance.new("TextLabel")
		line.Name = "Line"
		line.RichText = true
		line.TextWrapped = true
		line.TextXAlignment = Enum.TextXAlignment.Left
		line.TextYAlignment = Enum.TextYAlignment.Top
		line.Size = UDim2.new(1, -16, 0, 0)
		line.AutomaticSize = Enum.AutomaticSize.Y
		line.BackgroundTransparency = 1
		Theme.passThrough(line)
		line.Font = Theme.Fonts.Mono
		line.TextSize = 11
		line.LayoutOrder = 1

		-- FormatLocalTime already renders in the viewer's local zone, so there is no
		-- ToLocal() step here. Calling it was both redundant and rejected by the
		-- real engine.
		local stamp = DateTime.fromUnixTimestampMillis(entry.timestamp * 1000)
			:FormatLocalTime("HH:mm:ss", "short")

		local levelText = LEVEL_KEYS[entry.level] or entry.level:sub(1, 4)
		local color = Logger.levelColor[entry.level] or Theme.Colors.SecondaryText
		local hex = string.format("#%02X%02X%02X", math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))

		local body = Redact.scrubText(entry.message):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
		line.Text = string.format(
			'<font color="#6B6377">%s</font>  <font color="%s">[%s]</font>  <font color="#F4F1F8">%s</font>',
			stamp,
			hex,
			levelText,
			body
		)
		line.Parent = row

		if entry.detail and #entry.detail > 0 then
			local detailToggle = Instance.new("TextButton")
			detailToggle.Name = "Toggle"
			detailToggle.Size = UDim2.new(1, 0, 0, 16)
			detailToggle.BackgroundTransparency = 1
			Icons.setButton(detailToggle, "ChevronRight", "details")
			detailToggle.TextXAlignment = Enum.TextXAlignment.Left
			detailToggle.TextColor3 = Theme.Extra.Muted
			detailToggle.TextSize = 10
			detailToggle.Font = Theme.Fonts.Medium
			detailToggle.LayoutOrder = 2
			detailToggle.Parent = row

			local detailLabel = Theme.autoText(Redact.scrubText(entry.detail), {
				size = 10,
				color = Theme.Extra.Muted,
			})
			detailLabel.Name = "Detail"
			detailLabel.Font = Theme.Fonts.Mono
			detailLabel.Visible = false
			detailLabel.AutomaticSize = Enum.AutomaticSize.Y
			detailLabel.LayoutOrder = 3
			detailLabel.Parent = row
			local detailIndent = Instance.new("UIPadding")
			detailIndent.PaddingLeft = UDim.new(0, 14)
			detailIndent.Parent = detailLabel

			detailToggle.MouseButton1Click:Connect(function()
				detailLabel.Visible = not detailLabel.Visible
				Icons.setButton(detailToggle, if detailLabel.Visible then "ChevronDown" else "ChevronRight", "details")
			end)
		end

		return row
	end

	local function append(entry)
		renderedCount += 1
		local row = renderEntry(entry)
		row.LayoutOrder = entry.id
		row.Parent = console
		return row
	end

	local function renderAll()
		for _, child in console:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		renderedCount = 0

		local entries = Logger.getEntries()
		for _, entry in entries do
			if passesFilter(entry) then
				append(entry)
			end
		end
		if autoScroll then
			task.defer(scrollToBottom)
		end
	end

	local function renderFilters()
		for _, child in filterRow:GetChildren() do
			if child:IsA("GuiButton") then
				child:Destroy()
			end
		end

		local categories = Logger.getCategoryList()
		local all = Instance.new("TextButton")
		all.Name = "Filter_All"
		all.LayoutOrder = 0
		all.Size = UDim2.fromOffset(0, 22)
		all.AutomaticSize = Enum.AutomaticSize.X
		all.BackgroundColor3 = if activeFilter == nil then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised
		all.BorderSizePixel = 0
		all.Text = "All"
		all.TextColor3 = if activeFilter == nil then Theme.Colors.Background else Theme.Colors.SecondaryText
		all.TextSize = Theme.TextSizes.Caption
		all.Font = Theme.Fonts.Medium
		all.Parent = filterRow
		Theme.corner(11).Parent = all
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = all
		all.MouseButton1Click:Connect(function()
			activeFilter = nil
			renderFilters()
			renderAll()
		end)

		for index, category in categories do
			local chip = Instance.new("TextButton")
			chip.Name = "Filter_" .. category
			chip.LayoutOrder = index
			chip.Size = UDim2.fromOffset(0, 22)
			chip.AutomaticSize = Enum.AutomaticSize.X
			chip.BackgroundColor3 = if activeFilter == category then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised
			chip.BorderSizePixel = 0
			chip.Text = category
			chip.TextColor3 = if activeFilter == category then Theme.Colors.Background else Theme.Colors.SecondaryText
			chip.TextSize = Theme.TextSizes.Caption
			chip.Font = Theme.Fonts.Medium
			chip.Parent = filterRow
			Theme.corner(11).Parent = chip
			local chipPad = Instance.new("UIPadding")
			chipPad.PaddingLeft = UDim.new(0, 10)
			chipPad.PaddingRight = UDim.new(0, 10)
			chipPad.Parent = chip
			chip.MouseButton1Click:Connect(function()
				activeFilter = if activeFilter == category then nil else category
				renderFilters()
				renderAll()
			end)
		end
	end

	-- Behaviour -----------------------------------------------------------
	local unsubscribe = Logger.subscribe(function(entry)
		if paused or not passesFilter(entry) then
			return
		end
		local stick = autoScroll or atBottom()
		append(entry)
		if stick then
			task.defer(scrollToBottom)
		end
	end)

	pauseButton.MouseButton1Click:Connect(function()
		paused = not paused
		Icons.setButton(pauseButton, if paused then "Play" else "Stop", if paused then "Resume" else "Pause")
		pauseButton.TextColor3 = if paused then Theme.Extra.Warning else Theme.Colors.SecondaryText
		if not paused then
			renderAll()
		end
	end)

	autoScrollButton.MouseButton1Click:Connect(function()
		autoScroll = not autoScroll
		autoScrollButton.TextColor3 = if autoScroll then Theme.Colors.Success else Theme.Extra.Muted
		if autoScroll then
			scrollToBottom()
		end
	end)

	clearButton.MouseButton1Click:Connect(function()
		Logger.clear()
		renderAll()
		renderFilters()
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Activity log cleared." })
	end)

	copyButton.MouseButton1Click:Connect(function()
		local copied, reason, presented = Clipboard.copy(Logger.copyAll())
		if not copied then
			if presented then return end
			EventBus.emit(EventBus.Events.Toast, {
				kind = "error",
				message = reason or "Could not copy the log.",
			})
			return
		end
		EventBus.emit(EventBus.Events.Toast, {
			kind = "success",
			message = "Log copied. API keys and sensitive values are redacted.",
		})
	end)

	local debounce: thread? = nil
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		if debounce then
			task.cancel(debounce)
		end
		local snapshot = searchBox.Text
		debounce = task.spawn(function()
			task.wait(0.2)
			query = snapshot
			renderAll()
		end)
	end)

	console:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if not atBottom() and autoScroll then
			autoScroll = false
			autoScrollButton.TextColor3 = Theme.Extra.Muted
		end
	end)

	-- Roblox Instances reject new members, so the API is a plain table returned
	-- alongside the frame rather than fields hung off the Frame itself.
	local api: { [string]: any } = {
		renderAll = renderAll,
		setLevel = function(level: string)
			Logger.setLevel(level :: any)
			renderAll()
		end,
		destroy = function()
			unsubscribe()
			if debounce then
				task.cancel(debounce)
			end
		end,
	}

	renderFilters()
	renderAll()
	return view, api
end

return ActivityLogs
