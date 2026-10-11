--!strict
--[[
	ForgePilot / UI / SettingsView
	General, AI, Agent and Data sections. The provider manager lives in its own
	tab inside this view so the settings screen stays navigable.
]]

local Components = require(script.Parent.Components)
local ContextManager = require(script.Parent.Parent.AI.ContextManager)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local ProviderView = require(script.Parent.ProviderView)
local SessionManager = require(script.Parent.Parent.Core.SessionManager)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local SmartRetry = require(script.Parent.Parent.Core.SmartRetrySettings)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local ToolValidator = require(script.Parent.Parent.Roblox.ToolValidator)

local AgentAccessView = require(script.Parent.AgentAccessView)
local SettingsView = {}

local SECTIONS = { "General", "AI & Provider", "Agent Access", "Agent", "Retry", "Data" }

function SettingsView.build(parent: GuiObject): (Frame, any)
	local view = Instance.new("Frame")
	view.Name = "SettingsView"
	view.Size = UDim2.fromScale(1, 1)
	view.BackgroundTransparency = 1
	Theme.passThrough(view)
	view.Parent = parent

	local header = Instance.new("Frame")
	header.Name = "SettingsHeader"
	header.Size = UDim2.new(1, 0, 0, 50)
	Theme.passThrough(header)
	header.Parent = view
	local breadcrumb = Theme.label("Settings", { size = Theme.TextSizes.Caption, color = Theme.Extra.Muted })
	breadcrumb.Name = "Breadcrumb"
	breadcrumb.Size = UDim2.new(1, 0, 0, 16)
	breadcrumb.Parent = header
	local pageTitle = Theme.label("General", { size = Theme.TextSizes.Heading, font = Theme.Fonts.Medium, truncate = true })
	pageTitle.Name = "PageTitle"
	pageTitle.Position = UDim2.fromOffset(0, 19)
	pageTitle.Size = UDim2.new(1, 0, 0, 26)
	pageTitle.Parent = header

	local sectionRow = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	sectionRow.Name = "SettingsNavigation"
	sectionRow.BackgroundTransparency = 1
	sectionRow.ScrollingDirection = Enum.ScrollingDirection.Y
	sectionRow.Parent = view
	Theme.listLayout(4).Parent = sectionRow

	local pageHolder = Instance.new("Frame")
	pageHolder.Name = "Page"
	Theme.passThrough(pageHolder)
	pageHolder.ClipsDescendants = true
	pageHolder.Parent = view

	local sectionButtons: { [string]: TextButton } = {}
	local sectionLabels: { [string]: TextLabel } = {}
	local sectionIcons: { [string]: TextLabel } = {}
	local sectionMarks: { [string]: Frame } = {}
	local compactPicker: Frame? = nil
	local setCompactSelection: any = nil
	local currentSection = SECTIONS[1]
	local function layoutShell()
		local wide = view.AbsoluteSize.X >= 620
		breadcrumb.Visible = wide
		pageTitle.Text = if wide then currentSection else "Settings"
		pageTitle.Position = UDim2.fromOffset(0, if wide then 19 else 0)
		sectionRow.Visible = wide
		if compactPicker then
			compactPicker.Visible = not wide
			compactPicker.Position = UDim2.fromOffset(0, 34)
		end
		if wide then
			sectionRow.Position = UDim2.fromOffset(0, 56)
			sectionRow.Size = UDim2.new(0, 140, 1, -56)
			pageHolder.Position = UDim2.fromOffset(154, 56)
			pageHolder.Size = UDim2.new(1, -154, 1, -56)
		else
			pageHolder.Position = UDim2.fromOffset(0, 70)
			pageHolder.Size = UDim2.new(1, 0, 1, -70)
		end
	end
	view:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutShell)

	--=========================================================================
	-- GENERAL
	--=========================================================================

	local function buildGeneral(): ScrollingFrame
		local scroll = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
		scroll.BackgroundTransparency = 1
		Theme.passThrough(scroll)
		Theme.padding(6).Parent = scroll
		Theme.listLayout(10).Parent = scroll

		local _, body = (function()
			local card, cardBody = Components.section("Assistant", { order = 1 })
			card.Parent = scroll
			return card, cardBody
		end)()

		local nameRow, nameHolder = Components.field("AI Display Name", {
			hint = "Shown in the chat and window title. Independent of the provider name.",
		})
		nameRow.Parent = body

		local nameBox = Theme.input(SettingsManager.getValue("assistantName"))
		nameBox.Name = "AssistantName"
		nameBox.Text = SettingsManager.getValue("assistantName")
		nameBox.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight)
		nameBox.Parent = nameHolder

		nameBox.FocusLost:Connect(function()
			if nameBox.Text ~= SettingsManager.getValue("assistantName") then
				SettingsManager.setAssistantName(nameBox.Text)
				nameBox.Text = SettingsManager.getValue("assistantName")
				EventBus.emit(EventBus.Events.Toast, {
					kind = "success",
					message = string.format('Assistant renamed to "%s".', SettingsManager.getValue("assistantName")),
				})
			end
		end)

		local themeRow = Components.field("Theme")
		local themeHolder = themeRow:FindFirstChild("Value")
		if themeHolder then themeHolder:Destroy() end
		themeRow.Parent = body
		local themeNote = Theme.label(
			"A dark theme with a purple accent and comfortable contrast.",
			{ size = Theme.TextSizes.Caption, color = Theme.Extra.Muted, alignY = Enum.TextYAlignment.Top, wrap = true }
		)
		themeNote.Size = UDim2.new(1, 0, 0, 0)
		themeNote.AutomaticSize = Enum.AutomaticSize.Y
		themeNote.LayoutOrder = 2
		themeNote.Parent = themeRow

		local languageRow = Components.field("Language")
		local languageHolder = languageRow:FindFirstChild("Value")
		if languageHolder then languageHolder:Destroy() end
		languageRow.Parent = body
		local languageNote = Theme.label(
			"The interface is English only right now. The model itself answers in whatever language you ask for.",
			{ size = Theme.TextSizes.Caption, color = Theme.Extra.Muted, alignY = Enum.TextYAlignment.Top, wrap = true }
		)
		languageNote.Size = UDim2.new(1, 0, 0, 0)
		languageNote.AutomaticSize = Enum.AutomaticSize.Y
		languageNote.LayoutOrder = 2
		languageNote.Parent = languageRow

		local animationsRow = Components.toggle("Animations", SettingsManager.getValue("animations"), function(value)
			SettingsManager.setValue("animations", value)
		end, { hint = "Hover fades, toasts and panel transitions." })
		animationsRow.Parent = body

		local reducedRow = Components.toggle("Reduce motion", SettingsManager.getValue("reducedMotion"), function(value)
			SettingsManager.setValue("reducedMotion", value)
		end, { hint = "Disables non-essential animation." })
		reducedRow.Parent = body

		local confirmRow = Components.toggle(
			"Confirm tool calls",
			SettingsManager.getValue("confirmToolCalls"),
			function(value)
				SettingsManager.setValue("confirmToolCalls", value)
			end,
			{ hint = "Ask before running any write tool." }
		)
		confirmRow.Parent = body

		local destructiveRow = Components.toggle(
			"Confirm destructive actions",
			SettingsManager.getValue("confirmDestructive"),
			function(value)
				SettingsManager.setValue("confirmDestructive", value)
			end,
			{ hint = "Always ask before deletions, script replacement and terrain fills." }
		)
		destructiveRow.Parent = body

		return scroll
	end

	--=========================================================================
	-- AGENT
	--=========================================================================

	local function buildAgent(): ScrollingFrame
		local scroll = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
		scroll.BackgroundTransparency = 1
		Theme.passThrough(scroll)
		Theme.padding(6).Parent = scroll
		Theme.listLayout(10).Parent = scroll

		local card1, body1 = Components.section("Behaviour", { order = 1 })
		card1.Parent = scroll

		local modeField, _, _, selectMode = Components.dropdown(
			"Default mode",
			{ "Plan", "Build" },
			function(selected)
				SettingsManager.setValue("defaultMode", if selected == "Build" then "build" else "plan")
			end
		)
		modeField.Parent = body1
		selectMode(if SettingsManager.getValue("defaultMode") == "build" then "Build" else "Plan")

		local autoAskRow = Components.toggle("Auto-ask", SettingsManager.getValue("autoAsk"), function(value)
			SettingsManager.setValue("autoAsk", value)
		end, { hint = "Let the assistant pause and ask when a decision materially changes the result." })
		autoAskRow.Parent = body1

		local aiDecideRow = Components.toggle(
			"Let AI Decide",
			SettingsManager.getValue("letAiDecide"),
			function(value)
				SettingsManager.setValue("letAiDecide", value)
			end,
			{ hint = "Show the \"Let AI decide\" button on questions. Consequential actions still require approval." }
		)
		aiDecideRow.Parent = body1

		local readOnlyRow = Components.toggle(
			"Auto-approve read-only tools",
			SettingsManager.getValue("autoApproveReadOnly"),
			function(value)
				SettingsManager.setValue("autoApproveReadOnly", value)
			end
		)
		readOnlyRow.Parent = body1

		local card2, body2 = Components.section("Limits", { order = 2 })
		card2.Parent = scroll

		local maxToolsRow, maxToolsHolder = Components.field("Maximum tool calls per task", {
			hint = "The agent stops and reports when the limit is reached.",
		})
		maxToolsRow.Parent = body2
		local maxToolsBox = Theme.input(tostring(SettingsManager.getValue("maxToolCalls")))
		maxToolsBox.Size = UDim2.fromOffset(100, Theme.Metrics.InputHeight)
		maxToolsBox.Parent = maxToolsHolder
		maxToolsBox.FocusLost:Connect(function(enterPressed)
			local parsed = tonumber(maxToolsBox.Text)
			if parsed and enterPressed then
				SettingsManager.setValue("maxToolCalls", math.clamp(math.floor(parsed), 1, 500))
				maxToolsBox.Text = tostring(SettingsManager.getValue("maxToolCalls"))
			end
		end)

		local maxActionsRow, maxActionsHolder = Components.field("Maximum build actions per task")
		maxActionsRow.Parent = body2
		local maxActionsBox = Theme.input(tostring(SettingsManager.getValue("maxBuildActions")))
		maxActionsBox.Size = UDim2.fromOffset(100, Theme.Metrics.InputHeight)
		maxActionsBox.Parent = maxActionsHolder
		maxActionsBox.FocusLost:Connect(function(enterPressed)
			local parsed = tonumber(maxActionsBox.Text)
			if parsed and enterPressed then
				SettingsManager.setValue("maxBuildActions", math.clamp(math.floor(parsed), 1, 5000))
				maxActionsBox.Text = tostring(SettingsManager.getValue("maxBuildActions"))
			end
		end)

		local card3, body3 = Components.section("Tool permissions", {
			subtitle = "Disable a tool to block it entirely. Write tools are additionally gated by mode.",
			order = 3,
		})
		card3.Parent = scroll

		local permissionsBody = Instance.new("Frame")
		permissionsBody.Name = "Permissions"
		permissionsBody.Size = UDim2.new(1, 0, 0, 0)
		permissionsBody.AutomaticSize = Enum.AutomaticSize.Y
		permissionsBody.BackgroundTransparency = 1
		Theme.passThrough(permissionsBody)
		permissionsBody.Parent = body3
		Theme.listLayout(4).Parent = permissionsBody

		for index, tool in ToolValidator.ordered do
			local permissions = SettingsManager.getValue("toolPermissions")
			local allowed = permissions[tool.name] ~= false

			local chip = Theme.textButton(
				string.format("%s %s", if allowed then "✓" else "✕", tool.name),
				{ height = 22 }
			)
			chip.Name = tool.name
			chip.LayoutOrder = index
			chip.TextSize = Theme.TextSizes.Caption
			chip.TextXAlignment = Enum.TextXAlignment.Left
			chip.BackgroundColor3 = if allowed then Theme.withAlpha(Theme.Colors.Success, 0.16) else Theme.Extra.SurfaceRaised
			chip.TextColor3 = if allowed then Theme.Colors.Success else Theme.Extra.Muted
			chip.Parent = permissionsBody

			chip.MouseButton1Click:Connect(function()
				local current = SettingsManager.getValue("toolPermissions")
				local next = current[tool.name] ~= false
				current[tool.name] = next
				SettingsManager.setValue("toolPermissions", current)
				chip.Text = string.format("%s %s", if next then "✓" else "✕", tool.name)
				chip.BackgroundColor3 = if next then Theme.withAlpha(Theme.Colors.Success, 0.16) else Theme.Extra.SurfaceRaised
				chip.TextColor3 = if next then Theme.Colors.Success else Theme.Extra.Muted
			end)
		end

		return scroll
	end

	--=========================================================================
	-- SMART AUTO RETRY
	--=========================================================================

	local function numberRow(parent: Instance, label: string, key: string, value: number, hint: string?, order: number): (TextBox, (number) -> ())
		local row, holder = Components.field(label, { hint = hint })
		row.LayoutOrder = order
		local box = Theme.input(tostring(value))
		box.Name = "Input"
		box:SetAttribute("RetrySetting", key)
		box.Size = UDim2.fromOffset(110, Theme.Metrics.InputHeight)
		box.Parent = holder

		local function commit()
			local parsed = tonumber(box.Text)
			if parsed then
				SmartRetry.set(key, parsed)
				box.Text = tostring(SmartRetry.get(key))
			else
				box.Text = tostring(SmartRetry.get(key))
			end
		end

		box.FocusLost:Connect(commit)

		row.Parent = parent
		return box, commit
	end

	local function buildRetry(): ScrollingFrame
		-- Declared up front: the strategy dropdown updates the schedule preview.
		local schedulePreview = Theme.label("", {
			size = Theme.TextSizes.Caption,
			color = Theme.Extra.Muted,
			alignY = Enum.TextYAlignment.Top,
			wrap = true,
		})

		local scroll = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
		scroll.BackgroundTransparency = 1
		Theme.passThrough(scroll)
		Theme.padding(6).Parent = scroll
		Theme.listLayout(10).Parent = scroll

		local card1, body1 = Components.section("Smart Auto Retry", {
			subtitle = "Retries temporary provider failures in chat and streaming. OpenCode preset: 2s base, doubling, 25% jitter, 30s fallback cap. Stop cancels the wait.",
			order = 1,
		})
		card1.Parent = scroll

		local enabledRow = Components.toggle(
			"Enable Auto Retry",
			SmartRetry.get("enabled") == true,
			function(value)
				SmartRetry.set("enabled", value)
			end,
			{ hint = "When off, a provider failure is reported immediately with no automatic retry." }
		)
		enabledRow.Parent = body1

		local strategyField, _, _, selectStrategy = Components.dropdown(
			"Retry Strategy",
			{ "OpenCode", "Adaptive Smart Retry", "Exponential", "Linear", "Custom sequence" },
			function(selected)
				local key = if selected == "OpenCode" then "opencode" elseif selected == "Adaptive Smart Retry"
					then "adaptive"
					elseif selected == "Linear" then "linear" elseif selected == "Custom sequence" then "custom" else "exponential"
				SmartRetry.set("strategy", key)
				schedulePreview.Text = SmartRetry.describe()
			end
		)
		local strategyLabels = { opencode = "OpenCode", adaptive = "Adaptive Smart Retry", exponential = "Exponential", linear = "Linear", custom = "Custom sequence" }
		selectStrategy(strategyLabels[SmartRetry.get("strategy")] or "OpenCode")
		strategyField.Parent = body1

		numberRow(body1, "Maximum Retries", "maxRetries", SmartRetry.get("maxRetries") or 5, "Additional attempts after the first request; default 5. Applies to every strategy.", 3)
		numberRow(body1, "Initial Delay (s)", "initialDelaySeconds", SmartRetry.get("initialDelaySeconds") or 2, "Used by Adaptive, Exponential and Linear. OpenCode uses 2s.", 4)
		numberRow(body1, "Backoff Multiplier", "multiplier", SmartRetry.get("multiplier") or 2, "Adaptive and Exponential growth. OpenCode uses 2.", 5)
		numberRow(body1, "Linear Step (s)", "linearStepSeconds", SmartRetry.get("linearStepSeconds") or 3, "Used by the Linear strategy.", 6)
		numberRow(body1, "Maximum Delay (s)", "maxDelaySeconds", SmartRetry.get("maxDelaySeconds") or 120, "Caps local backoff; OpenCode also caps it at 30s. Provider cooldowns are respected.", 7)
		numberRow(body1, "Maximum Automatic Wait (s)", "maxAutoWaitSeconds", SmartRetry.get("maxAutoWaitSeconds") or 120,
			"Past this, retries PAUSE rather than violating a provider cooldown.", 8)
		numberRow(body1, "Jitter (%)", "jitterPercent", SmartRetry.get("jitterPercent") or 25,
			"Randomised local waits. OpenCode uses up to 25% extra time.", 9)

		local customRow, customHolder = Components.field("Custom Delay Sequence", {
			hint = "Comma-separated seconds, used when the Custom strategy is selected. Example: 3, 6, 12, 30, 60",
		})
		customRow.Parent = body1

		local customBox = Theme.input("3, 6, 12, 30, 60")
		customBox.Name = "CustomSequence"
		customBox.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight)
		customBox.Parent = customHolder
		customBox.FocusLost:Connect(function(enterPressed)
			if not enterPressed then
				return
			end
			local sequence: { number } = {}
			for token in string.gmatch(customBox.Text, "[^,%s]+") do
				local value = tonumber(token)
				if value then
					sequence[#sequence + 1] = value
				end
			end
			SmartRetry.set("customSequence", if #sequence > 0 then sequence else nil)
			schedulePreview.Text = SmartRetry.describe()
		end)

		local behaviourRow = Components.toggle(
			"Respect Retry-After",
			SmartRetry.get("respectRetryAfter") ~= false,
			function(value)
				SmartRetry.set("respectRetryAfter", value)
			end,
			{ hint = "Honours Retry-After seconds, HTTP-date forms and retry-after-ms." }
		)
		behaviourRow.Parent = body1

		local cooldownRow = Components.toggle(
			"Dynamic Provider Cooldown",
			SmartRetry.get("dynamicCooldown") ~= false,
			function(value)
				SmartRetry.set("dynamicCooldown", value)
			end,
			{ hint = "After a rate-limit error, hold requests until the window clears." }
		)
		cooldownRow.Parent = body1

		local schedulerRow = Components.toggle(
			"Rate Limit Scheduler",
			SmartRetry.get("rateLimitScheduler") ~= false,
			function(value)
				SmartRetry.set("rateLimitScheduler", value)
				local ProviderRateLimitScheduler = require(script.Parent.Parent.AI.ProviderRateLimitScheduler)
				ProviderRateLimitScheduler.setEnabled(value)
			end,
			{ hint = "Sliding-window admission control and a FIFO queue per provider." }
		)
		schedulerRow.Parent = body1

		local multilingualRow = Components.toggle(
			"Multilingual Error Detection",
			SmartRetry.get("multilingualErrors") ~= false,
			function(value)
				SmartRetry.set("multilingualErrors", value)
			end,
			{ hint = "Classifies English, Simplified/Traditional Chinese, Japanese, Korean, Indonesian and Spanish provider messages." }
		)
		multilingualRow.Parent = body1

		local countdownRow = Components.toggle(
			"Show Retry Countdown",
			SmartRetry.get("showCountdown") ~= false,
			function(value)
				SmartRetry.set("showCountdown", value)
			end,
			{ hint = "Renders the live countdown card in the chat." }
		)
		countdownRow.Parent = body1

		local logsRow = Components.toggle(
			"Show Retry Logs",
			SmartRetry.get("showRetryLogs") ~= false,
			function(value)
				SmartRetry.set("showRetryLogs", value)
			end,
			{ hint = "Writes retry, cooldown and rate-limit events to the Logs tab." }
		)
		logsRow.Parent = body1

		-- Preview ------------------------------------------------------------
		local card2, body2 = Components.section("Schedule preview", {
			subtitle = "The exact delays the current settings produce, before any jitter.",
			order = 2,
		})
		card2.Parent = scroll

		schedulePreview.Name = "Preview"
		schedulePreview.Size = UDim2.new(1, 0, 0, 0)
		schedulePreview.AutomaticSize = Enum.AutomaticSize.Y
		schedulePreview.Parent = body2

		local refreshRow, addRefreshButton = Components.buttonRow({ columns = 2 })
		refreshRow.Parent = body2
		local refreshButton = addRefreshButton("Recalculate", { order = 1 })
		local resetButton = addRefreshButton("Reset Defaults", { order = 2 })

		local RetryDelayCalculator = require(script.Parent.Parent.AI.RetryDelayCalculator)

		local function recalculate()
			local config = RetryDelayCalculator.fromSettings(SmartRetry.get())
			local lines: { string } = {}
			for attempt = 1, math.min(5, config.maxRetries) do
				local seconds: number
				local source: string
				if config.strategy == "opencode" then
					seconds = math.min(30, config.maxDelaySeconds, 2 * 2 ^ (attempt - 1))
					source = "OpenCode base"
				elseif config.strategy == "linear" then
					seconds = RetryDelayCalculator.linear(attempt, config)
					source = "linear"
				elseif config.strategy == "custom" then
					seconds = RetryDelayCalculator.custom(attempt, config)
					source = "custom"
				else
					seconds = RetryDelayCalculator.exponential(attempt, config)
					source = "exponential"
				end
				lines[#lines + 1] = string.format("Retry %d: %.0fs (%s)", attempt, seconds, source)
			end
			if not config.enabled or #lines == 0 then
				lines[1] = "Automatic retry is disabled."
			end
			schedulePreview.Text = table.concat(lines, "\n")
				.. string.format(
					"\n\nJitter: %.0f%% · Mandatory provider waits are never shortened by jitter.",
					if config.strategy == "opencode" then 25 else config.jitterPercent
				)
		end

		refreshButton.MouseButton1Click:Connect(recalculate)
		resetButton.MouseButton1Click:Connect(function()
			SmartRetry.resetDefaults()
			recalculate()
			EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "retryReset" })
			EventBus.emit(EventBus.Events.Toast, { kind = "success", message = "Retry settings reset to defaults." })
		end)

		recalculate()

		-- Current scheduler state ---------------------------------------------
		local card3, body3 = Components.section("Current rate-limit state", { order = 3 })
		card3.Parent = scroll

		local stateLabel = Theme.label("", {
			size = Theme.TextSizes.Caption,
			color = Theme.Extra.Muted,
			alignY = Enum.TextYAlignment.Top,
			wrap = true,
		})
		stateLabel.Name = "SchedulerState"
		stateLabel.Size = UDim2.new(1, 0, 0, 0)
		stateLabel.AutomaticSize = Enum.AutomaticSize.Y
		stateLabel.Parent = body3

		local function refreshScheduler()
			local profile = SettingsManager.getActiveProvider()
			if not profile then
				stateLabel.Text = "No provider selected."
				return
			end
			local ProviderRateLimitScheduler = require(script.Parent.Parent.AI.ProviderRateLimitScheduler)
			stateLabel.Text = ProviderRateLimitScheduler.describe(profile.id, profile.modelId, profile.baseUrl)
				.. "\n\nForgePilot only sees requests it sent itself. Requests from other apps using the same account are invisible, so learned cooldowns are conservative and labelled as estimates."
		end

		local schedulerRefresh = Components.textButton("Refresh", { order = 1 })
		schedulerRefresh.Parent = body3
		schedulerRefresh.MouseButton1Click:Connect(refreshScheduler)

		local clearCooldown = Components.textButton("Clear Cooldown", { order = 2 })
		clearCooldown.Parent = body3
		clearCooldown.MouseButton1Click:Connect(function()
			local profile = SettingsManager.getActiveProvider()
			if profile then
				local ProviderRateLimitScheduler = require(script.Parent.Parent.AI.ProviderRateLimitScheduler)
				ProviderRateLimitScheduler.clearCooldown(profile.id, profile.modelId, profile.baseUrl)
				ProviderRateLimitScheduler.cancelQueue(profile.id, profile.modelId, profile.baseUrl, "Cleared by the user.")
				refreshScheduler()
			end
		end)

		refreshScheduler()

		-- Per-provider overrides ---------------------------------------------
		local card4, body4 = Components.section("Per-provider overrides", {
			subtitle = "One provider can behave differently without affecting the others.",
			order = 4,
		})
		card4.Parent = scroll

		local overrideBody = Instance.new("Frame")
		overrideBody.Name = "Overrides"
		overrideBody.Size = UDim2.new(1, 0, 0, 0)
		overrideBody.AutomaticSize = Enum.AutomaticSize.Y
		overrideBody.BackgroundTransparency = 1
		Theme.passThrough(overrideBody)
		overrideBody.Parent = body4
		Theme.listLayout(6).Parent = overrideBody

		local function renderOverrides()
			for _, child in overrideBody:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end

			local overrides = SmartRetry.get("providerOverrides") or {}
			local providers = SettingsManager.getValue("providers") or {}
			if #providers == 0 then
				local empty = Theme.label("No provider profiles yet.", {
					size = Theme.TextSizes.Caption,
					color = Theme.Extra.Muted,
				})
				empty.Size = UDim2.new(1, 0, 0, 18)
				empty.Parent = overrideBody
				return
			end

			for index, profile in providers do
				local providerOverride = overrides[profile.id] or {}
				local retries = tonumber(providerOverride.maxRetries) or SmartRetry.get("maxRetries") or 5

				local row = Instance.new("Frame")
				row.Name = "Override_" .. profile.id
				row.LayoutOrder = index
				row.Size = UDim2.new(1, 0, 0, 30)
				row.BackgroundTransparency = 1
				Theme.passThrough(row)
				row.Parent = overrideBody

				local label = Theme.label(profile.displayName, { size = Theme.TextSizes.Caption, truncate = true })
				label.Name = "Label"
				label.Size = UDim2.new(0.5, -60, 1, 0)
				label.Position = UDim2.fromOffset(0, 0)
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.Parent = row

				local box = Theme.input(tostring(retries))
				box.Name = "MaxRetries"
				box.AnchorPoint = Vector2.new(1, 0)
				box.Position = UDim2.new(1, -76, 0, 2)
				box.Size = UDim2.fromOffset(56, 26)
				box.Parent = row

				local clearButton = Components.textButton("Reset", { order = 1 })
				clearButton.Name = "Reset"
				clearButton.AnchorPoint = Vector2.new(1, 0)
				clearButton.Position = UDim2.new(1, 0, 0, 2)
				clearButton.Size = UDim2.fromOffset(64, 26)
				clearButton.Parent = row

				box.FocusLost:Connect(function(enterPressed)
					if not enterPressed then
						return
					end
					local parsed = tonumber(box.Text)
					if parsed then
						SmartRetry.setProviderOverride(profile.id, { maxRetries = math.clamp(math.floor(parsed), 0, 20) })
					end
					box.Text = tostring(SmartRetry.getProviderOverride(profile.id).maxRetries or SmartRetry.get("maxRetries"))
				end)

				clearButton.MouseButton1Click:Connect(function()
					SmartRetry.setProviderOverride(profile.id, nil)
					renderOverrides()
				end)
			end
		end

		renderOverrides()

		return scroll
	end

	--=========================================================================
	-- DATA
	--=========================================================================

	local function buildData(): ScrollingFrame
		local function requireIdle(): boolean
			if not StateManager.isBusy() then return true end
			EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Finish or stop the task before changing conversation data." })
			return false
		end
		local scroll = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
		scroll.BackgroundTransparency = 1
		Theme.passThrough(scroll)
		Theme.padding(6).Parent = scroll
		Theme.listLayout(10).Parent = scroll

		local card1, body1 = Components.section("Local data", {
			subtitle = "Conversations are stored through Plugin:SetSetting in your Studio profile. Secrets are not.",
			order = 1,
		})
		card1.Parent = scroll

		local statsLabel = Theme.label("", {
			size = Theme.TextSizes.Caption,
			color = Theme.Extra.Muted,
			alignY = Enum.TextYAlignment.Top,
			wrap = true,
		})
		statsLabel.Name = "Stats"
		statsLabel.Size = UDim2.new(1, 0, 0, 0)
		statsLabel.AutomaticSize = Enum.AutomaticSize.Y
		statsLabel.Parent = body1

		local function refreshStats()
			local conversations = SessionManager.getConversations()
			local messages = 0
			for _, conversation in conversations do
				messages += #conversation.messages
			end
			statsLabel.Text = string.format(
				"%d conversation(s) · %d message(s) · %d log entr(ies) · %d session credential(s)",
				#conversations,
				messages,
				#Logger.getEntries(),
				CredentialStore.count()
			)
		end

		local row1, addDataButton = Components.buttonRow({ columns = 2 })
		row1.Parent = body1
		local newChatButton = addDataButton("New chat", { order = 1 })
		local clearContextButton = addDataButton("Clear context", { order = 2 })
		local clearLogsButton = addDataButton("Clear logs", { order = 3 })

		newChatButton.MouseButton1Click:Connect(function()
			if not requireIdle() then return end
			SessionManager.createConversation()
			EventBus.emit(EventBus.Events.Toast, { kind = "success", message = "New conversation started." })
			refreshStats()
		end)

		clearContextButton.MouseButton1Click:Connect(function()
			if not requireIdle() then return end
			local conversation = SessionManager.getActive()
			if conversation then
				conversation.messages = {}
				conversation.summary = nil
				conversation.editorContext = nil
				conversation.summarisedUpTo = 0
				SessionManager.persist()
				EventBus.emit(EventBus.Events.ConversationChanged, { conversationId = conversation.id })
			end
			ContextManager.reset()
			EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Context cleared for this conversation." })
		end)

		clearLogsButton.MouseButton1Click:Connect(function()
			Logger.clear()
			EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Activity log cleared." })
			refreshStats()
		end)

		local card2, body2 = Components.section("Credentials & profile", { order = 2 })
		card2.Parent = scroll

		local forgetRow, addForgetButton = Components.buttonRow({ columns = 2 })
		forgetRow.Parent = body2
		local forgetButton = addForgetButton("Forget keys", { order = 1 })
		local forgetProfileButton = addForgetButton("Reset settings", { order = 2 })

		forgetButton.MouseButton1Click:Connect(function()
			if not requireIdle() then return end
			CredentialStore.clearAll()
			Logger.warn("Data", "Session credentials cleared.")
			EventBus.emit(EventBus.Events.Toast, {
				kind = "info",
				message = "All session API keys were removed from memory.",
			})
			refreshStats()
		end)

		forgetProfileButton.MouseButton1Click:Connect(function()
			if not requireIdle() then return end
			SettingsManager.resetAll()
			CredentialStore.clearAll()
			ContextManager.configure(nil)
			Logger.warn("Data", "Settings reset to defaults.")
			EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Settings reset to defaults." })
			refreshStats()
		end)

		local card3, body3 = Components.section("Reset", { subtitle = "These cannot be undone.", order = 3 })
		card3.Parent = scroll

		local row3, addHistoryButton = Components.buttonRow()
		row3.Parent = body3
		local clearHistoryButton = addHistoryButton("Clear conversation history", { order = 1 })

		clearHistoryButton.MouseButton1Click:Connect(function()
			if not requireIdle() then return end
			if not SessionManager.clearAll() then return end
			ContextManager.reset()
			Logger.warn("Data", "Conversation history cleared.")
			EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "All conversation history cleared." })
			EventBus.emit(EventBus.Events.Navigate, { section = "chat" })
		end)

		-- Self tests ---------------------------------------------------------
		local card4, body4 = Components.section("Self tests", {
			subtitle = "Checks chat rendering and controls locally. Results appear in the activity log.",
			order = 4,
		})
		card4.Parent = scroll

		local testRow4, addTestButton = Components.buttonRow()
		testRow4.Parent = body4
		local runTestsButton = addTestButton("Check UI", { accent = true, order = 1 })

		runTestsButton.MouseButton1Click:Connect(function()
			if not requireIdle() then return end
			local report = require(script.Parent.Parent.Utilities.UIHealthCheck).run()
			local message = string.format("UI checks: %d/%d passed.", report.passed, report.total)
			if #report.errors == 0 then Logger.success("UI checks", message)
			else Logger.error("UI checks", message, { detail = table.concat(report.errors, "\n") }) end
			EventBus.emit(EventBus.Events.Toast, { kind = if #report.errors == 0 then "success" else "error", message = message })
		end)

		refreshStats()
		return scroll
	end

	--=========================================================================
	-- NAVIGATION
	--=========================================================================

	local pages: { [string]: Instance } = {}

	local function paintNavigation()
		for _, section in SECTIONS do
			local active = currentSection == section
			local button = sectionButtons[section]
			if button then
				button.BackgroundColor3 = if active then Theme.Extra.HighlightSoft else Theme.Colors.Background
				sectionLabels[section].TextColor3 = if active then Theme.Colors.MainText else Theme.Extra.Muted
				sectionIcons[section].TextColor3 = if active then Theme.Colors.Highlight else Theme.Extra.Muted
				sectionMarks[section].Visible = active
			end
		end
	end
	local function setSection(name: string)
		if not table.find(SECTIONS, name) then return end
		Components.closeMenus()
		currentSection = name
		pageTitle.Text = name
		layoutShell()
		if setCompactSelection then setCompactSelection(name) end
		for section, page in pages do page.Visible = section == name end
		paintNavigation()
	end
	local iconKeys = { General = "Settings", ["AI & Provider"] = "Sparkle", ["Agent Access"] = "Builder", Agent = "Builder", Retry = "Refresh", Data = "Doc" }
	for index, section in SECTIONS do
		local button = Theme.textButton("", { height = 34, radius = Theme.Metrics.RadiusSmall, color = Theme.Colors.Background })
		button.Name = "Section_" .. section
		button.LayoutOrder = index
		button.Size = UDim2.new(1, -6, 0, 34)
		button.Parent = sectionRow
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Transparency = 1 end
		local icon = Icons.glyph(iconKeys[section], 13)
		icon.Size = UDim2.fromOffset(18, 18)
		icon.Position = UDim2.fromOffset(8, 8)
		icon.Parent = button
		sectionIcons[section] = icon
		local label = Theme.label(section, { size = Theme.TextSizes.Small, font = Theme.Fonts.Medium, truncate = true })
		label.Name = "Label"
		label.Position = UDim2.fromOffset(32, 0)
		label.Size = UDim2.new(1, -38, 1, 0)
		label.Parent = button
		sectionLabels[section] = label
		local mark = Instance.new("Frame")
		mark.Name = "Selected"
		mark.BorderSizePixel = 0
		mark.BackgroundColor3 = Theme.Colors.Highlight
		mark.Size = UDim2.new(0, 2, 1, -12)
		mark.Position = UDim2.fromOffset(0, 6)
		mark.Parent = button
		sectionMarks[section] = mark
		sectionButtons[section] = button
		button.MouseButton1Click:Connect(function() setSection(section) end)
		button.MouseLeave:Connect(paintNavigation)
	end
	local picker, _, _, selectSection = Components.dropdown("Settings section", SECTIONS, setSection)
	picker.Name = "SettingsSectionPicker"
	local pickerLabel = picker:FindFirstChild("Label")
	if pickerLabel then pickerLabel:Destroy() end
	picker.AutomaticSize = Enum.AutomaticSize.None
	picker.Position = UDim2.fromOffset(0, 52)
	picker.Size = UDim2.new(1, 0, 0, 30)
	picker.Parent = view
	compactPicker = picker
	setCompactSelection = selectSection
	layoutShell()

	-- General
	local generalPage = buildGeneral()
	generalPage.Parent = pageHolder
	pages["General"] = generalPage

	-- AI & Provider (delegates to ProviderView)
	local providerHolder = Instance.new("Frame")
	providerHolder.Name = "ProviderPage"
	providerHolder.Size = UDim2.fromScale(1, 1)
	providerHolder.BackgroundTransparency = 1
	Theme.passThrough(providerHolder)
	providerHolder.Visible = false
	providerHolder.Parent = pageHolder
	local providerPage, providerApi = ProviderView.build(providerHolder)
	-- The page table drives visibility. It must reference the HOLDER, not the
	-- inner view: toggling the inner view left the holder invisible, so the
	-- whole AI & Provider screen rendered as an empty frame.
	pages["AI & Provider"] = providerHolder
	_ = providerPage

	local accessPage, accessApi = AgentAccessView.build()
	accessPage.Parent = pageHolder
	pages["Agent Access"] = accessPage

	-- Agent
	local agentPage = buildAgent()
	agentPage.Parent = pageHolder
	pages["Agent"] = agentPage

	-- Smart Auto Retry
	local retryPage = buildRetry()
	retryPage.Parent = pageHolder
	pages["Retry"] = retryPage

	-- Data
	local dataPage = buildData()
	dataPage.Parent = pageHolder
	pages["Data"] = dataPage

	local disconnect = EventBus.on(EventBus.Events.Navigate, function(payload)
		if payload.section == "settings" then
			if payload.tab then setSection(payload.tab) end
		end
	end)

	setSection("General")

	-- Roblox Instances reject new members, so the API is a plain table returned
	-- alongside the frame rather than fields hung off the Frame itself.
	-- ProviderView owns its own teardown (it rebuilds in place rather than
	-- being destroyed), so there is no providerPage hook to call here.
	local api: { [string]: any } = {
		showSection = setSection,
		getSection = function()
			return currentSection
		end,
		destroy = function()
			disconnect()
			if providerApi then providerApi.destroy() end
			accessApi.destroy()
		end,
	}

	return view, api
end

return SettingsView
