--!strict
--[[
	ForgePilot / UI / RetryStatusUI
	The retry card shown in the chat while ForgePilot waits on a provider.

	Displays real values only: the live countdown, the real attempt counter and
	the provider's own reason. "Retry Now" still respects a mandatory cooldown.
]]

local Components = require(script.Parent.Components)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local ProviderErrorNormalizer = require(script.Parent.Parent.AI.ProviderErrorNormalizer)
local ProviderRateLimitScheduler = require(script.Parent.Parent.AI.ProviderRateLimitScheduler)
local RetryDelayCalculator = require(script.Parent.Parent.AI.RetryDelayCalculator)
local SmartAutoRetryManager = require(script.Parent.Parent.AI.SmartAutoRetryManager)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local Time = require(script.Parent.Parent.Utilities.Time)

local RetryStatusUI = {}

local CATEGORY_COLOR: { [string]: Color3 } = {
	RATE_LIMITED = Theme.Extra.Warning,
	CONCURRENCY_LIMITED = Theme.Extra.Warning,
	QUOTA_WINDOW_EXHAUSTED = Theme.Extra.Warning,
	DAILY_QUOTA_EXHAUSTED = Theme.Colors.Error,
	INSUFFICIENT_CREDITS = Theme.Colors.Error,
	PROVIDER_OVERLOADED = Theme.Extra.Warning,
	SERVER_ERROR = Theme.Extra.Warning,
	TIMEOUT = Theme.Extra.Warning,
	NETWORK_ERROR = Theme.Extra.Warning,
	STREAM_INTERRUPTED = Theme.Extra.Warning,
	INVALID_API_KEY = Theme.Colors.Error,
	INVALID_MODEL = Theme.Colors.Error,
	INVALID_ENDPOINT = Theme.Colors.Error,
}

local HEADLINE: { [string]: string } = {
	RATE_LIMITED = "Provider Rate Limited",
	CONCURRENCY_LIMITED = "Too Many Concurrent Requests",
	PROVIDER_OVERLOADED = "Provider Overloaded",
	QUOTA_WINDOW_EXHAUSTED = "Quota Window Exhausted",
	DAILY_QUOTA_EXHAUSTED = "Daily Quota Exhausted",
	INSUFFICIENT_CREDITS = "Insufficient Credits",
	INVALID_API_KEY = "Invalid API Key",
	INVALID_MODEL = "Invalid Model",
	INVALID_ENDPOINT = "Invalid Endpoint",
	CONTEXT_LENGTH_EXCEEDED = "Context Window Exceeded",
	CONTENT_FILTERED = "Blocked By Content Filter",
	SERVER_ERROR = "Provider Server Error",
	TIMEOUT = "Request Timed Out",
	NETWORK_ERROR = "Network Error",
	STREAM_INTERRUPTED = "Stream Interrupted",
}

--- Builds the card and returns (frame, api).
function RetryStatusUI.build(options: {
	operationId: string,
	providerName: string,
	model: string,
	category: string,
	reason: string,
	maxRetries: number,
	providerId: string?,
	endpoint: string?,
	attempt: number,
	delaySeconds: number,
	paused: boolean,
	pauseReason: string?,
	onCancel: (() -> ())?,
}): (Frame, any)
	local card = Instance.new("Frame")
	card.Name = "RetryCard"
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Theme.Extra.Surface
	card.BorderSizePixel = 0
	card.LayoutOrder = 900
	card.ClipsDescendants = false
	Theme.corner(Theme.Metrics.Radius).Parent = card

	local colour = CATEGORY_COLOR[options.category] or Theme.Extra.Warning
	Theme.stroke(Theme.withAlpha(colour, 0.5)).Parent = card
	Theme.padding(12).Parent = card

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = card

	-- Header ------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 20)
	header.BackgroundTransparency = 1
	header.LayoutOrder = 1
	header.Parent = card

	local icon = Icons.glyph("Warning", 14, colour)
	icon.Name = "Icon"
	icon.Size = UDim2.fromOffset(17, 17)
	icon.Position = UDim2.fromOffset(0, 1)
	icon.Parent = header

	local headline = Theme.label(
		HEADLINE[options.category] or "Provider Error",
		{ size = Theme.TextSizes.Body, font = Theme.Fonts.Bold, color = colour }
	)
	headline.Name = "Headline"
	headline.Position = UDim2.fromOffset(22, 0)
	headline.Size = UDim2.new(1, -22, 1, 0)
	headline.TextTruncate = Enum.TextTruncate.AtEnd
	headline.Parent = header

	-- Facts ---------------------------------------------------------------
	local facts = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Colors.SecondaryText,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	facts.Name = "Facts"
	facts.Size = UDim2.new(1, 0, 0, 0)
	facts.AutomaticSize = Enum.AutomaticSize.Y
	facts.LayoutOrder = 2
	facts.Parent = card

	local countdownLabel = Theme.label("", {
		size = Theme.TextSizes.Body,
		font = Theme.Fonts.Bold,
		color = colour,
	})
	countdownLabel.Name = "Countdown"
	countdownLabel.Size = UDim2.new(1, 0, 0, 0)
	countdownLabel.AutomaticSize = Enum.AutomaticSize.Y
	countdownLabel.LayoutOrder = 3
	countdownLabel.Parent = card

	local statusLabel = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Muted,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	statusLabel.Name = "Status"
	statusLabel.Size = UDim2.new(1, 0, 0, 0)
	statusLabel.AutomaticSize = Enum.AutomaticSize.Y
	statusLabel.LayoutOrder = 4
	statusLabel.Parent = card

	-- Progress bar --------------------------------------------------------
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, 0, 0, 5)
	track.LayoutOrder = 5
	track.BackgroundColor3 = Theme.Extra.SurfaceRaised
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = card
	Theme.corner(3).Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = colour
	fill.BorderSizePixel = 0
	fill.Parent = track

	-- Details ------------------------------------------------------------
	local details = Theme.label("", {
		size = 10,
		color = Theme.Extra.Muted,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	details.Name = "Details"
	details.Size = UDim2.new(1, 0, 0, 0)
	details.AutomaticSize = Enum.AutomaticSize.Y
	details.Visible = false
	details.LayoutOrder = 6
	details.Parent = card

	-- Actions ------------------------------------------------------------
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.Size = UDim2.new(1, 0, 0, 28)
	actions.BackgroundTransparency = 1
	actions.LayoutOrder = 7
	actions.Parent = card
	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection = Enum.FillDirection.Horizontal
	actionLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionLayout.Padding = UDim.new(0, 6)
	actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	actionLayout.Parent = actions

	local retryNowButton = Components.textButton("Retry Now", { order = 1 })
	retryNowButton.Size = UDim2.fromOffset(88, 26)
	retryNowButton.Parent = actions

	local cancelButton = Components.textButton("Cancel Retry", { order = 2 })
	cancelButton.Size = UDim2.fromOffset(96, 26)
	cancelButton.Parent = actions

	local detailsButton = Components.textButton("Show Details", { order = 3 })
	detailsButton.Size = UDim2.fromOffset(100, 26)
	detailsButton.Parent = actions
	for _, button in { retryNowButton, cancelButton, detailsButton } do
		Theme.flexItem(button, 1, 1)
		button.TextSize = 11
		button.TextTruncate = Enum.TextTruncate.AtEnd
	end

	--=============================================================================
	-- STATE
	--=============================================================================

	local state = {
		attempt = options.attempt,
		maxRetries = options.maxRetries,
		delaySeconds = options.delaySeconds,
		deadline = if options.delaySeconds > 0 then os.clock() + options.delaySeconds else nil,
		paused = options.paused,
		pauseReason = options.pauseReason,
		finished = false,
	}

	local function renderFacts()
		local lines: { string } = {
			string.format("Provider: %s", options.providerName),
			string.format("Model: %s", options.model ~= "" and options.model or "(not set)"),
		}
		if options.reason and #options.reason > 0 then
			lines[#lines + 1] = string.format("Reason: %s", options.reason)
		end
		facts.Text = table.concat(lines, "\n")
	end

	local function renderStatus()
		if state.finished then
			statusLabel.Text = "No more automatic retries."
			statusLabel.TextColor3 = Theme.Colors.Error
			return
		end
		if state.paused then
			statusLabel.Text = string.format(
				"Paused. %s",
				state.pauseReason or "The provider requires a longer wait than the automatic limit."
			)
			statusLabel.TextColor3 = Theme.Extra.Warning
			return
		end
		statusLabel.Text = string.format("Retry: %d / %d", state.attempt, state.maxRetries)
		statusLabel.TextColor3 = Theme.Extra.Muted
	end

	local heartbeat: thread? = nil
	local generation = 0
	local destroyed = false

	local function stopHeartbeat()
		generation += 1
		if heartbeat then
			pcall(task.cancel, heartbeat)
			heartbeat = nil
		end
	end

	local function paintCountdown()
		if state.paused or state.finished or not state.deadline then
			countdownLabel.Text = if state.paused then "Waiting for the provider" else ""
			Theme.tween(fill, { Size = UDim2.fromScale(1, 1) }, Theme.Motion.Normal):Play()
			return
		end

		local remaining = math.max(0, state.deadline - os.clock())
		local total = math.max(0.001, state.delaySeconds)
		local ratio = math.clamp(1 - remaining / total, 0, 1)

		countdownLabel.Text = if remaining > 0.05
			then string.format("Next Attempt: %s", Time.formatDuration(remaining))
			else "Next Attempt: now"
		Theme.tween(fill, { Size = UDim2.fromScale(ratio, 1) }, 0.15):Play()

	end

	local function renderCountdown()
		stopHeartbeat()
		if destroyed then return end
		paintCountdown()
		if state.paused or state.finished or not state.deadline then return end
		local current = generation
		-- Painting never schedules another worker. One deferred ticker yields
		-- between updates and is replaced only when a new attempt is scheduled.
		heartbeat = task.defer(function()
			while not destroyed and generation == current and card.Parent and not state.finished and not state.paused and state.deadline do
				paintCountdown()
				if state.deadline - os.clock() <= 0.05 then break end
				task.wait(0.25)
			end
			if generation == current then heartbeat = nil end
		end)
	end

	local function renderDetails()
		local operation = SmartAutoRetryManager.getOperation(options.operationId)
		local lines: { string } = {
			string.format("Operation: %s", options.operationId),
			string.format("Category: %s", options.category),
		}
		if operation then
			lines[#lines + 1] = string.format("Attempts made: %d", operation.attemptsMade)
			lines[#lines + 1] = string.format("Elapsed: %.1fs", operation.totalElapsedSeconds)
			if operation.upstreamRetryNotices > 0 then
				lines[#lines + 1] = string.format(
					"Upstream retries reported: %d (not issued by ForgePilot)",
					operation.upstreamRetryNotices
				)
			end
			for _, attempt in operation.attempts do
				lines[#lines + 1] = string.format(
					"#%d  %s  %s  delay %s (%s)",
					attempt.index,
					if attempt.ok then "ok" else "failed",
					tostring(attempt.status or attempt.category or "-"),
					string.format("%.1fs", attempt.delaySeconds),
					attempt.delaySource
				)
			end
		end
		if options.providerId then
			lines[#lines + 1] = ProviderRateLimitScheduler.describe(options.providerId, options.model, options.endpoint)
		end
		details.Text = table.concat(lines, "\n")
	end

	--=============================================================================
	-- ACTIONS
	--=============================================================================

	detailsButton.MouseButton1Click:Connect(function()
		details.Visible = not details.Visible
		detailsButton.Text = if details.Visible then "Hide Details" else "Show Details"
		if details.Visible then
			renderDetails()
		end
	end)

	cancelButton.MouseButton1Click:Connect(function()
		if destroyed or state.finished then return end
		state.finished = true
		stopHeartbeat()
		SmartAutoRetryManager.cancel(options.operationId, "Cancelled by the user from the retry card.")
		if options.onCancel then
			options.onCancel()
		end
		card.BackgroundTransparency = 0.5
		countdownLabel.Text = "Retry cancelled."
		renderStatus()
		retryNowButton.Active = false
		cancelButton.Active = false
		retryNowButton.Interactable = false
		cancelButton.Interactable = false
	end)

	retryNowButton.MouseButton1Click:Connect(function()
		if destroyed or state.finished then return end
		-- A mandatory provider cooldown is never overridden by this button.
		if options.providerId then
			local cooldown = ProviderRateLimitScheduler.getCooldown(options.providerId, options.model, options.endpoint)
			if cooldown.active then
				EventBus.emit(EventBus.Events.Toast, {
					kind = "warning",
					message = string.format(
						"The provider requires another %.0fs. ForgePilot will not send the request early.",
						cooldown.remainingSeconds
					),
				})
				return
			end
		end
		if state.deadline then
			-- The retry controller owns this deadline; keep the real countdown.
			EventBus.emit(EventBus.Events.Toast, {
				kind = "info",
				message = string.format("The next attempt is scheduled in %.0fs.", math.max(0, state.deadline - os.clock())),
			})
			return
		end
		retryNowButton.Text = "Waiting…"
		retryNowButton.Active = false
		task.delay(0.5, function()
			if retryNowButton.Parent then
				retryNowButton.Text = "Retry Now"
				retryNowButton.Active = true
			end
		end)
	end)

	--=============================================================================
	-- EVENTS
	--=============================================================================

	local unsubs: { () -> () } = {}

	unsubs[#unsubs + 1] = EventBus.on(SmartAutoRetryManager.STATE_EVENT, function(payload)
		if payload.operationId ~= options.operationId then
			return
		end

		if payload.state == "RETRY_SCHEDULED" then
			state.attempt = tonumber(payload.attempt) or state.attempt
			state.delaySeconds = tonumber(payload.delaySeconds) or state.delaySeconds
			state.deadline = if state.delaySeconds > 0 then os.clock() + state.delaySeconds else nil
			state.paused = false
			renderStatus()
			renderCountdown()
		elseif payload.state == "RETRYING" then
			stopHeartbeat()
			state.deadline = nil
			countdownLabel.Text = string.format(
				"Retrying request · Attempt %d / %d",
				state.attempt,
				state.maxRetries
			)
			renderStatus()
		elseif payload.state == "WAITING_FOR_QUOTA" or payload.state == "RATE_LIMIT_DETECTED" then
			stopHeartbeat()
			state.deadline = nil
			state.paused = payload.paused == true
			state.pauseReason = payload.pauseReason
			countdownLabel.Text = ""
			renderStatus()
		elseif payload.state == "PROVIDER_RECOVERED" then
			state.finished = true
			stopHeartbeat()
			headline.Text = "Provider Recovered"
			headline.TextColor3 = Theme.Colors.Success
			countdownLabel.Text = "Continuing task."
			statusLabel.TextColor3 = Theme.Colors.Success
			Theme.tween(card, { BackgroundTransparency = 0.4 }, Theme.Motion.Slow):Play()
		elseif payload.state == "RETRIES_EXHAUSTED" then
			state.finished = true
			stopHeartbeat()
			headline.Text = "Retries Exhausted"
			headline.TextColor3 = Theme.Colors.Error
			countdownLabel.Text = payload.reason or "No further automatic attempts."
			renderStatus()
			if details.Visible then
				renderDetails()
			end
		elseif payload.state == "RETRY_CANCELLED" then
			state.finished = true
			stopHeartbeat()
			headline.Text = "Retry Cancelled"
			countdownLabel.Text = payload.reason or "Cancelled."
			renderStatus()
		end
	end)

	--=============================================================================
	-- INIT
	--=============================================================================
	card.Destroying:Connect(function()
		destroyed = true
		stopHeartbeat()
		for _, unsubscribe in unsubs do unsubscribe() end
	end)

	renderFacts()
	renderStatus()
	if not state.paused then
		renderCountdown()
	end

	return card, {
		destroy = function()
			destroyed = true
			stopHeartbeat()
			for _, unsubscribe in unsubs do
				unsubscribe()
			end
			if card.Parent then
				card:Destroy()
			end
		end,
		setAttempt = function(attempt: number, delaySeconds: number)
			if destroyed or state.finished then return end
			state.attempt = attempt
			state.delaySeconds = delaySeconds
			state.deadline = if delaySeconds > 0 then os.clock() + delaySeconds else nil
			renderStatus()
			renderCountdown()
		end,
		headline = headline,
		setCategory = function(category: string, reason: string)
			headline.Text = HEADLINE[category] or "Provider Error"
			options.category = category
			options.reason = reason
			renderFacts()
			renderDetails()
		end,
		remedy = function()
			return ProviderErrorNormalizer.remedy(options.category)
		end,
		RetryDelayCalculator = RetryDelayCalculator,
	}
end

return RetryStatusUI
