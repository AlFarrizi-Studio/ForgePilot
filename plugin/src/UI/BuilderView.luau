--!strict
--[[
	ForgePilot / UI / BuilderView
	The Build Mode console: mode banner, action log, undo/redo, manual tool
	dispatch and read-only enforcement display.
]]

local ActionExecutor = require(script.Parent.Parent.Roblox.ActionExecutor)
local Components = require(script.Parent.Components)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local HistoryManager = require(script.Parent.Parent.Roblox.HistoryManager)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local JSONValidator = require(script.Parent.Parent.Utilities.JSONValidator)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local SessionManager = require(script.Parent.Parent.Core.SessionManager)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local Theme = require(script.Parent.Parent.Utilities.Theme)
local Time = require(script.Parent.Parent.Utilities.Time)
local ToolValidator = require(script.Parent.Parent.Roblox.ToolValidator)

local BuilderView = {}

function BuilderView.build(parent: GuiObject): Frame
	local view = Instance.new("Frame")
	view.Name = "BuilderView"
	view.Size = UDim2.fromScale(1, 1)
	view.BackgroundTransparency = 1
	Theme.passThrough(view)
	view.Parent = parent

	-- Vertical stack: banner -> toolbar -> tool runner -> action log. The old
	-- version used absolute offsets (0, 0), (0, 54), (0, 86) and a log sized
	-- `1, -92`, so the log was drawn straight over the mode banner.
	local stack = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	stack.Name = "Stack"
	stack.Size = UDim2.fromScale(1, 1)
	stack.BackgroundTransparency = 1
	Theme.passThrough(stack)
	stack.Parent = view

	local stackLayout = Instance.new("UIListLayout")
	stackLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stackLayout.Padding = UDim.new(0, Theme.Space.SM)
	stackLayout.Parent = stack

	local mode: string = SettingsManager.getValue("defaultMode") or "build"

	-- Mode banner ---------------------------------------------------------
	local banner = Instance.new("Frame")
	banner.Name = "ModeBanner"
	banner.Size = UDim2.new(1, 0, 0, 46)
	banner.AutomaticSize = Enum.AutomaticSize.Y
	banner.BackgroundColor3 = Theme.Extra.Surface
	banner.BorderSizePixel = 0
	banner.LayoutOrder = 1
	banner.ClipsDescendants = false
	banner.Parent = stack
	Theme.corner(Theme.Metrics.Radius).Parent = banner
	Theme.padding4(Theme.Space.SM, Theme.Space.SM, Theme.Space.SM, Theme.Space.SM).Parent = banner

	local bannerLayout = Instance.new("UIListLayout")
	bannerLayout.FillDirection = Enum.FillDirection.Vertical
	bannerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bannerLayout.Padding = UDim.new(0, Theme.Space.SM)
	bannerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	bannerLayout.Parent = banner

	local controls = Instance.new("Frame")
	controls.Name = "ModeControls"
	controls.Size = UDim2.new(1, 0, 0, 28)
	controls.LayoutOrder = 1
	Theme.passThrough(controls)
	controls.Parent = banner
	Theme.listLayout(6, Enum.FillDirection.Horizontal).Parent = controls
	local planToggle = Components.textButton("Plan", { order = 1 })
	planToggle.Size = UDim2.new(0, 0, 0, 26)
	Theme.flexItem(planToggle, 1, 1)
	planToggle.Parent = controls

	local buildToggle = Components.textButton("Build", { order = 2 })
	buildToggle.Size = UDim2.new(0, 0, 0, 26)
	Theme.flexItem(buildToggle, 1, 1)
	buildToggle.Parent = controls

	local modeNote = Theme.autoText("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Muted,
	})
	modeNote.Name = "Note"
	modeNote.AutomaticSize = Enum.AutomaticSize.Y
	modeNote.Size = UDim2.new(1, 0, 0, 0)
	modeNote.LayoutOrder = 3
	modeNote.Parent = banner

	local function setMode(next: string)
		mode = next
		planToggle.BackgroundColor3 = if next == "plan" then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised
		planToggle.TextColor3 = if next == "plan" then Theme.Colors.Background else Theme.Colors.MainText
		buildToggle.BackgroundColor3 = if next == "build" then Theme.Extra.Warning else Theme.Extra.SurfaceRaised
		buildToggle.TextColor3 = if next == "build" then Theme.Colors.Background else Theme.Colors.MainText
		modeNote.Text = if next == "plan"
			then "Read-only. Inspection tools only — no object, script or lighting changes can run."
			else "Write mode enabled. Destructive and script actions still ask for approval."
	end

	planToggle.MouseButton1Click:Connect(function()
		if StateManager.isBusy() then return end
		setMode("plan")
		local conversation = SessionManager.getActive()
		if conversation then SessionManager.setConversationMeta(conversation.id, { mode = "plan" }) else EventBus.emit(EventBus.Events.ModeChanged, { mode = "plan" }) end
	end)
	buildToggle.MouseButton1Click:Connect(function()
		if StateManager.isBusy() then return end
		setMode("build")
		local conversation = SessionManager.getActive()
		if conversation then SessionManager.setConversationMeta(conversation.id, { mode = "build" }) else EventBus.emit(EventBus.Events.ModeChanged, { mode = "build" }) end
	end)

	-- Toolbar -------------------------------------------------------------
	local toolbar = Instance.new("Frame")
	toolbar.Name = "Toolbar"
	toolbar.Size = UDim2.new(1, 0, 0, 28)
	toolbar.AutomaticSize = Enum.AutomaticSize.Y
	toolbar.BackgroundTransparency = 1
	Theme.passThrough(toolbar)
	toolbar.LayoutOrder = 2
	toolbar.ClipsDescendants = false
	toolbar.Parent = stack

	local toolbarLayout = Instance.new("UIListLayout")
	toolbarLayout.FillDirection = Enum.FillDirection.Horizontal
	toolbarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toolbarLayout.Padding = UDim.new(0, Theme.Space.SM)
	toolbarLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	toolbarLayout.Parent = toolbar

	local undoButton = Theme.textButton("Undo", {
		height = 26,
		radius = Theme.Metrics.RadiusSmall,
	})
	undoButton.Name = "Undo"
	undoButton.Size = UDim2.new(0, 0, 0, 26)
	undoButton.TextSize = Theme.TextSizes.Caption
	undoButton.TextTruncate = Enum.TextTruncate.AtEnd
	undoButton.Parent = toolbar
	Icons.setButton(undoButton, "Refresh", "Undo")
	Theme.flexItem(undoButton, 1, 1)

	local redoButton = Theme.textButton("Redo", {
		height = 26,
		radius = Theme.Metrics.RadiusSmall,
	})
	redoButton.Name = "Redo"
	redoButton.Size = UDim2.new(0, 0, 0, 26)
	redoButton.TextSize = Theme.TextSizes.Caption
	redoButton.TextTruncate = Enum.TextTruncate.AtEnd
	redoButton.Parent = toolbar
	Icons.setButton(redoButton, "Refresh", "Redo")
	Theme.flexItem(redoButton, 1, 1)

	undoButton.MouseButton1Click:Connect(function()
		HistoryManager.undo()
	end)
	redoButton.MouseButton1Click:Connect(function()
		HistoryManager.redo()
	end)

	-- Manual tool runner --------------------------------------------------
	local manualToggle = Components.textButton("Run a tool", { order = 3 })
	manualToggle.Size = UDim2.new(0, 0, 0, 26)
	manualToggle.TextSize = Theme.TextSizes.Caption
	manualToggle.TextTruncate = Enum.TextTruncate.AtEnd
	manualToggle.Parent = toolbar
	Theme.flexItem(manualToggle, 1, 1)

	local manualPanel = Instance.new("Frame")
	manualPanel.Name = "ManualPanel"
	manualPanel.Size = UDim2.new(1, 0, 0, 0)
	manualPanel.AutomaticSize = Enum.AutomaticSize.Y
	manualPanel.BackgroundTransparency = 1
	Theme.passThrough(manualPanel)
	manualPanel.Visible = false
	manualPanel.LayoutOrder = 3
	manualPanel.Parent = stack

	local manualLayout = Instance.new("UIListLayout")
	manualLayout.SortOrder = Enum.SortOrder.LayoutOrder
	manualLayout.Padding = UDim.new(0, Theme.Space.MD)
	manualLayout.Parent = manualPanel

	local toolOptions: { string } = {}
	for _, tool in ToolValidator.ordered do
		toolOptions[#toolOptions + 1] = tool.name
	end

	local toolRow, setToolOptions, getTool = Components.dropdown(
		"Tool",
		toolOptions,
		function() end
	)
	toolRow.Parent = manualPanel

	local argsRow, argsHolder = Components.field("Arguments (JSON)", {
		hint = "Strictly validated. Unknown fields are ignored; invalid values are rejected.",
	})
	argsRow.Parent = manualPanel

	local argsBox = Theme.input('{"name":"Example"}', { multiLine = true })
	argsBox.Name = "Args"
	argsBox.Size = UDim2.new(1, 0, 0, 74)
	argsBox.TextYAlignment = Enum.TextYAlignment.Top
	argsBox.Font = Theme.Fonts.Code
	argsBox.TextSize = Theme.TextSizes.Small
	argsBox.Parent = argsHolder

	local runRow, runHolder = Components.field(" ")
	runRow.Parent = manualPanel

	local runButton = Components.textButton("Execute", { accent = true, order = 1 })
	runButton.Parent = runHolder

	local manualResult = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Colors.SecondaryText,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	manualResult.Name = "Result"
	manualResult.Size = UDim2.new(1, 0, 0, 0)
	manualResult.AutomaticSize = Enum.AutomaticSize.Y
	manualResult.Parent = manualPanel

	manualToggle.MouseButton1Click:Connect(function()
		manualPanel.Visible = not manualPanel.Visible
		manualToggle.Text = if manualPanel.Visible then "Hide tool runner" else "Run a tool"
	end)

	local function toolListForMode()
		local list = {}
		for _, tool in ToolValidator.forMode(mode) do
			list[#list + 1] = tool.name
		end
		return list
	end
	setToolOptions(toolListForMode())

	local function refreshToolList()
		setToolOptions(toolListForMode())
	end

	runButton.MouseButton1Click:Connect(function()
		local toolName = getTool()
		if not toolName then
			return
		end
		if StateManager.isBusy() then
			EventBus.emit(EventBus.Events.Toast, {
				kind = "warning",
				message = "ForgePilot is busy. Stop the current task first.",
			})
			return
		end

		local argsText = StringUtil.trim(argsBox.Text)
		local arguments: any = {}
		if #argsText > 0 then
			local decoded, err = JSONValidator.decode(argsText)
			if not decoded then
				manualResult.TextColor3 = Theme.Colors.Error
				manualResult.Text = "Arguments are not valid JSON: " .. tostring(err)
				return
			end
			if type(decoded) ~= "table" then
				manualResult.TextColor3 = Theme.Colors.Error
				manualResult.Text = "Arguments must be a JSON object."
				return
			end
			arguments = decoded
		end

		local result, execError = ActionExecutor.execute(toolName, arguments, mode)
		if not result then
			manualResult.TextColor3 = Theme.Colors.Error
			manualResult.Text = execError or "The tool could not be executed."
			return
		end

		manualResult.TextColor3 = if result.verified then Theme.Colors.Success else Theme.Extra.Warning
		manualResult.Text = string.format(
			"[%s] %s\n%s  ·  %.0fms  ·  %s",
			result.toolName,
			if result.verified then "verified" else "unverified",
			result.message,
			result.durationMs,
			Time.timestamp()
		)
	end)

	-- Action log ----------------------------------------------------------
	local log = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	log.Name = "Actions"
	log.Size = UDim2.new(1, 0, 0, 220)
	log.BackgroundColor3 = Theme.Extra.Overlay
	log.BorderSizePixel = 0
	log.LayoutOrder = 4
	log.Parent = stack
	-- The action log claims the leftover height instead of being hardcoded to
	-- `1, -92`, which used to place it straight on top of the mode banner.
	Theme.corner(Theme.Metrics.RadiusSmall).Parent = log
	Theme.padding(Theme.Space.SM).Parent = log
	Theme.listLayout(3).Parent = log

	local function pushAction(text: string, color: Color3, detail: string?)
		local row = Instance.new("Frame")
		row.Name = "Action"
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.BackgroundTransparency = 1
		Theme.passThrough(row)

		-- The line and its detail are stacked by a list, not by two children
		-- both parked at y = 0.
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Padding = UDim.new(0, 2)
		rowLayout.Parent = row

		local label = Theme.autoText(
			string.format("%s  %s", Time.timestamp(), text),
			{ size = Theme.TextSizes.Caption, color = color }
		)
		label.Name = "Text"
		label.LayoutOrder = 1
		label.Font = Theme.Fonts.Mono
		label.Parent = row

		if detail and #detail > 0 then
			local detailLabel = Theme.autoText(detail, {
				size = 10,
				color = Theme.Extra.Muted,
			})
			detailLabel.Name = "Detail"
			detailLabel.LayoutOrder = 2
			detailLabel.Font = Theme.Fonts.Mono
			detailLabel.Parent = row
			local indent = Instance.new("UIPadding")
			indent.PaddingLeft = UDim.new(0, 14)
			indent.Parent = detailLabel
		end

		row.Parent = log
		log.CanvasPosition = Vector2.new(0, math.max(0, log.AbsoluteCanvasSize.Y - log.AbsoluteWindowSize.Y))
	end

	local unsubs: { () -> () } = {}
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ModeChanged, function(payload)
		setMode(payload.mode)
		refreshToolList()
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ConversationChanged, function()
		local conversation = SessionManager.getActive()
		setMode(conversation and conversation.mode or SettingsManager.getValue("defaultMode") or "build")
		refreshToolList()
	end)

	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ToolCallStarted, function(payload)
		pushAction(string.format("%s →", payload.summary), Theme.Extra.Warning)
	end)

	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ToolCallFinished, function(payload)
		pushAction(
			payload.toolName,
			if payload.verified then Theme.Colors.Success else Theme.Extra.Warning,
			payload.message
		)
	end)

	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ToolCallFailed, function(payload)
		pushAction(payload.toolName, Theme.Colors.Error, payload.message)
	end)

	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.BuildProgress, function(payload)
		if payload.phase == "undo" then
			pushAction("Undo requested", Theme.Extra.Info)
		elseif payload.phase == "redo" then
			pushAction("Redo requested", Theme.Extra.Info)
		end
	end)

	setMode(mode)

	pushAction("ForgePilot Builder ready.", Theme.Extra.Info, "Switch to Build Mode to allow write actions.")

	-- Roblox Instances reject new members, so the API is a plain table returned
	-- alongside the frame rather than fields hung off the Frame itself.
	local api: { [string]: any } = {
		setMode = function(next: string)
			setMode(next)
			refreshToolList()
		end,
		getMode = function()
			return mode
		end,
		destroy = function()
			for _, unsubscribe in unsubs do
				unsubscribe()
			end
		end,
	}

	return view, api
end

return BuilderView
