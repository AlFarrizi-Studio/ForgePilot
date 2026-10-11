--!strict
--[[
	ForgePilot / AI / SmartAutoRetryManager
	ONE retry controller per operation. Adapters never retry on their own.

	Contract
	  * maxRetries means ADDITIONAL attempts after the first request.
	  * A mandatory provider cooldown is never shortened by jitter or backoff.
	  * When the required wait exceeds the configured automatic wait limit, retries
	    PAUSE and the reason is surfaced instead of violating the cooldown.
	  * Upstream retry notices ("[retrying in 3s attempt #2]") are recorded as
	    metadata; they never spawn a second, nested retry loop here.
	  * Cancellation is immediate and prevents any further attempt.

	The clock, the sleep and the request function are all injectable so the whole
	controller is deterministically testable.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ProviderErrorNormalizer = require(script.Parent.ProviderErrorNormalizer)
local ProviderRateLimitScheduler = require(script.Parent.ProviderRateLimitScheduler)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local RetryDelayCalculator = require(script.Parent.RetryDelayCalculator)
local Time = require(script.Parent.Parent.Utilities.Time)
local UniversalErrorDetector = require(script.Parent.Parent.Utilities.UniversalErrorDetector)

local SmartAutoRetryManager = {}

--=============================================================================
-- STATES
--=============================================================================

export type RetryState =
	| "IDLE"
	| "RATE_LIMIT_DETECTED"
	| "WAITING_FOR_QUOTA"
	| "RETRY_SCHEDULED"
	| "RETRYING"
	| "PROVIDER_RECOVERED"
	| "RETRIES_EXHAUSTED"
	| "RETRY_CANCELLED"

local STATE_EVENT = "retry:state"

--=============================================================================
-- ATTEMPT RECORD
--=============================================================================

export type Attempt = {
	index: number,
	startedAt: number,
	finishedAt: number?,
	delaySeconds: number,
	delaySource: string,
	delayMandatory: boolean,
	delayEstimated: boolean,
	category: string?,
	status: number?,
	requestId: string?,
	ok: boolean,
}

export type Operation = {
	id: string,
	taskId: string?,
	providerId: string,
	providerName: string,
	model: string,
	endpoint: string,
	state: RetryState,
	attempts: { Attempt },
	attemptsMade: number,
	startedAt: number,
	finishedAt: number?,
	lastError: ProviderErrorNormalizer.Normalised?,
	upstreamAttempts: number?,
	upstreamRetryNotices: number,
	totalElapsedSeconds: number,
	paused: boolean,
	pauseReason: string?,
	cancelled: boolean,
}

local operations: { [string]: Operation } = {}

--=============================================================================
-- INJECTABLE RUNTIME
--=============================================================================

local runtime = {
	clock = function(): number
		return os.clock()
	end,
	wait = function(_seconds: number)
		task.wait(1)
	end,
	random = math.random,
	sleep = function(seconds: number)
		task.wait(seconds)
	end,
}

function SmartAutoRetryManager.setRuntime(overrides: {
	clock: (() -> number)?,
	sleep: ((seconds: number) -> ())?,
	random: (() -> number)?,
}?)
	if type(overrides) ~= "table" then
		return
	end
	if type(overrides.clock) == "function" then
		runtime.clock = overrides.clock
	end
	if type(overrides.sleep) == "function" then
		runtime.sleep = overrides.sleep
	end
	if type(overrides.random) == "function" then
		runtime.random = overrides.random
	end
end

function SmartAutoRetryManager.resetRuntime()
	runtime.clock = function()
		return os.clock()
	end
	runtime.random = math.random
	runtime.sleep = function(seconds: number)
		task.wait(seconds)
	end
end

--=============================================================================
-- STATE EMISSION
--=============================================================================

local function setState(operation: Operation, next: RetryState, detail: { [string]: any }?)
	local previous = operation.state
	if previous == next then
		return
	end
	operation.state = next

	local payload = {
		operationId = operation.id,
		taskId = operation.taskId,
		provider = operation.providerName,
		model = operation.model,
		state = next,
		previous = previous,
		attempt = operation.attemptsMade,
		maxRetries = 0,
		retryCount = operation.attemptsMade,
		totalAttempts = operation.attemptsMade + 1,
		elapsedSeconds = runtime.clock() - operation.startedAt,
	}
	for key, value in detail or {} do
		payload[key] = value
	end
	EventBus.emit(STATE_EVENT, payload)
end

function SmartAutoRetryManager.getOperation(id: string): Operation?
	return operations[id]
end

function SmartAutoRetryManager.getActiveOperations(): { Operation }
	local list = {}
	for _, operation in operations do
		if operation.state ~= "IDLE"
			and operation.state ~= "RETRIES_EXHAUSTED"
			and operation.state ~= "RETRY_CANCELLED"
			and operation.state ~= "PROVIDER_RECOVERED"
		then
			list[#list + 1] = operation
		end
	end
	table.sort(list, function(a, b)
		return a.startedAt < b.startedAt
	end)
	return list
end

function SmartAutoRetryManager.cancel(operationId: string, reason: string?)
	local operation = operations[operationId]
	if not operation then
		return false
	end
	if operation.cancelled then
		return false
	end
	operation.cancelled = true
	operation.paused = false
	setState(operation, "RETRY_CANCELLED", { reason = reason or "Cancelled by the user." })
	ProviderRateLimitScheduler.cancelQueue(
		operation.providerId,
		operation.model,
		operation.endpoint,
		reason or "Cancelled by the user."
	)
	operation.finishedAt = runtime.clock()
	Logger.warn("Retry", "Retry cancelled.", {
		detail = string.format(
			"%s · %s · %d attempt(s) made%s",
			operation.providerName,
			operation.model,
			operation.attemptsMade,
			if reason then (" · " .. reason) else ""
		),
		taskId = operation.taskId,
	})
	return true
end

function SmartAutoRetryManager.cancelAll(reason: string?)
	for id in pairs(operations) do
		SmartAutoRetryManager.cancel(id, reason)
	end
end

function SmartAutoRetryManager.clearHistory()
	for id, operation in operations do
		if
			operation.state == "RETRIES_EXHAUSTED"
			or operation.state == "RETRY_CANCELLED"
			or operation.state == "PROVIDER_RECOVERED"
			or operation.state == "IDLE"
		then
			operations[id] = nil
		end
	end
end

--=============================================================================
-- RESULT TYPE
--=============================================================================

export type RunResult = {
	ok: boolean,
	value: any?,
	error: ProviderErrorNormalizer.Normalised?,
	category: string?,
	attemptsMade: number,
	totalElapsedSeconds: number,
	operationId: string,
	cancelled: boolean,
	exhausted: boolean,
	paused: boolean,
	pauseReason: string?,
	lastDecision: RetryDelayCalculator.Decision?,
}

--=============================================================================
-- RUN
--=============================================================================

export type RunOptions = {
	operationId: string?,
	taskId: string?,
	providerId: string,
	providerName: string,
	model: string,
	endpoint: string,
	config: RetryDelayCalculator.Config,
	--- The unit of work. Must perform ONE request and return (result, errorInfo).
	request: (attemptIndex: number) -> (any?, { [string]: any }?),
	--- Called before each sleep so the UI can count down.
	onWait: ((waitSeconds: number, decision: RetryDelayCalculator.Decision, attempt: number) -> ())?,
	--- Called before each attempt.
	onAttempt: ((attempt: number, decision: RetryDelayCalculator.Decision?) -> ())?,
	shouldCancel: (() -> boolean)?,
	now: number?,
	epoch: number?,
}

local function classifyOutcome(
	providerName: string,
	model: string,
	endpoint: string,
	outcome: any?,
	elapsedMs: number
): (ProviderErrorNormalizer.Normalised?, any?)
	-- A request returns (result, nil) on success, or (nil, errorInfo) on failure.
	if outcome == nil then
		return nil, nil
	end

	local info: { [string]: any } = outcome
	local normalised = ProviderErrorNormalizer.normalise({
		provider = providerName,
		model = model,
		endpoint = endpoint,
		statusCode = info.statusCode,
		body = info.body,
		headers = info.headers,
		transportError = info.transportError,
		streamInterrupted = info.streamInterrupted,
		elapsedMs = elapsedMs,
	})
	return normalised, outcome
end

--- Runs `request` with adaptive retries. Resolves once, never throws.
function SmartAutoRetryManager.run(options: RunOptions): RunResult
	local config = RetryDelayCalculator.sanitise(options.config)
	local operationId = options.operationId or Time.newId("op")
	local now = runtime.clock()

	local operation: Operation = {
		id = operationId,
		taskId = options.taskId,
		providerId = options.providerId,
		providerName = options.providerName,
		model = options.model,
		endpoint = options.endpoint,
		state = "IDLE",
		attempts = {},
		attemptsMade = 0,
		startedAt = now,
		lastError = nil,
		upstreamAttempts = nil,
		upstreamRetryNotices = 0,
		totalElapsedSeconds = 0,
		paused = false,
		cancelled = false,
	}
	operations[operationId] = operation

	local function finish(
		ok: boolean,
		value: any?,
		normalised: ProviderErrorNormalizer.Normalised?,
		decision: RetryDelayCalculator.Decision?
	): RunResult
		operation.finishedAt = runtime.clock()
		operation.totalElapsedSeconds = operation.finishedAt - operation.startedAt
		return {
			ok = ok,
			value = value,
			error = normalised,
			category = normalised and normalised.category or nil,
			attemptsMade = operation.attemptsMade,
			totalElapsedSeconds = operation.totalElapsedSeconds,
			operationId = operationId,
			cancelled = operation.cancelled,
			exhausted = operation.state == "RETRIES_EXHAUSTED",
			paused = operation.paused,
			pauseReason = operation.pauseReason,
			lastDecision = decision,
		}
	end

	-- Initial attempt counts as attempt 1.
	local maxAttempts = config.maxRetries + 1
	local retryIndex = 0
	local lastDecision: RetryDelayCalculator.Decision? = nil

	while true do
		if options.shouldCancel and options.shouldCancel() then
			operation.cancelled = true
			setState(operation, "RETRY_CANCELLED", { reason = "Cancelled before an attempt." })
			return finish(false, nil, operation.lastError, lastDecision)
		end

		operation.attemptsMade += 1
		local attemptStarted = runtime.clock()

		if options.onAttempt then
			options.onAttempt(operation.attemptsMade, lastDecision)
		end

		local ok, value, errorInfo = pcall(options.request, operation.attemptsMade)
		if not ok then
			local requestError = tostring(value)
			value = nil
			errorInfo = { transportError = requestError }
		end

		local elapsedMs = (runtime.clock() - attemptStarted) * 1000
		local normalised: ProviderErrorNormalizer.Normalised? = nil

		if errorInfo ~= nil then
			normalised, _ = classifyOutcome(
				options.providerName,
				options.model,
				options.endpoint,
				errorInfo,
				elapsedMs
			)
		end

		local attempt: Attempt = {
			index = operation.attemptsMade,
			startedAt = attemptStarted,
			finishedAt = runtime.clock(),
			delaySeconds = lastDecision and lastDecision.delaySeconds or 0,
			delaySource = lastDecision and lastDecision.source or "initial",
			delayMandatory = lastDecision and lastDecision.mandatory or false,
			delayEstimated = lastDecision and lastDecision.estimated or false,
			category = normalised and normalised.category or nil,
			status = normalised and normalised.httpStatus or nil,
			requestId = normalised and normalised.requestId or nil,
			ok = value ~= nil,
		}
		table.insert(operation.attempts, attempt)

		if normalised then
			operation.lastError = normalised
			if normalised.upstreamRetry.present then
				operation.upstreamRetryNotices += 1
				operation.upstreamAttempts = normalised.upstreamRetry.attempt
			end
		end

		-- Success.
		if errorInfo == nil and value ~= nil then
			operation.paused = false
			ProviderRateLimitScheduler.clearCooldown(options.providerId, options.model, options.endpoint)
			if retryIndex > 0 then
				setState(operation, "PROVIDER_RECOVERED", {
					recoveredAfterAttempts = operation.attemptsMade,
				})
				Logger.success("Retry", "Provider recovered.", {
					detail = string.format(
						"%s · %s succeeded on attempt %d after %d retr%s.",
						options.providerName,
						options.model,
						operation.attemptsMade,
						retryIndex,
						if retryIndex == 1 then "y" else "ies"
					),
					taskId = options.taskId,
				})
			end
			setState(operation, "IDLE", { succeeded = true })
			return finish(true, value, nil, lastDecision)
		end

		-- No error info and no value: treat as an unknown failure.
		if errorInfo == nil and value == nil then
			errorInfo = { transportError = "The request produced no response." }
			normalised = ProviderErrorNormalizer.normalise({
				provider = options.providerName,
				model = options.model,
				endpoint = options.endpoint,
				transportError = errorInfo.transportError,
				elapsedMs = elapsedMs,
			})
			operation.lastError = normalised
		end

		if not normalised then
			break
		end

		-- Learn from rate-limit errors and activate any provider cooldown.
		if normalised.category == "RATE_LIMITED" or normalised.category == "QUOTA_WINDOW_EXHAUSTED" then
			local learned = ProviderRateLimitScheduler.learnFromError(
				options.providerId,
				options.model,
				options.endpoint,
				{
					limit = normalised.rateLimit.limit,
					windowMs = normalised.rateLimit.windowMs,
					category = normalised.category,
				}
			)
			normalised.rateLimit.estimated = learned.estimated

			Logger.warn("Rate Limit", string.format(
				"%s (%s).",
				if learned.learned
					then string.format(
						"%d requests per %.0fs detected",
						normalised.rateLimit.limit or 0,
						(normalised.rateLimit.windowMs or 0) / 1000
					)
				else "Rate limit detected; window unknown",
				if learned.estimated then "conservative estimate" else "reported by provider"
			), {
				detail = string.format("%s · %s", options.providerName, options.model),
				taskId = options.taskId,
			})
		end

		-- Decide whether to retry at all.
		local retryable = normalised.retryable and config.enabled
		if not retryable then
			if config.enabled then
				Logger.warn("Retry", string.format("Not retrying a %s error.", normalised.category), {
					detail = string.format("%s · %s · %s", options.providerName, options.model, normalised.message),
					taskId = options.taskId,
				})
			end
			setState(operation, "RETRIES_EXHAUSTED", {
				reason = "This error cannot be fixed by retrying.",
				category = normalised.category,
			})
			return finish(false, nil, normalised, lastDecision)
		end

		if operation.attemptsMade >= maxAttempts then
			setState(operation, "RETRIES_EXHAUSTED", {
				reason = string.format(
					"Used all %d automatic retr%s.",
					config.maxRetries,
					if config.maxRetries == 1 then "y" else "ies"
				),
				category = normalised.category,
			})
			Logger.error("Retry", "Automatic retries exhausted.", {
				detail = string.format(
					"%s · %s · %d attempt(s) · %s",
					options.providerName,
					options.model,
					operation.attemptsMade,
					normalised.message
				),
				taskId = options.taskId,
			})
			return finish(false, nil, normalised, lastDecision)
		end

		retryIndex += 1

		if normalised.category == "RATE_LIMITED" or normalised.category == "QUOTA_WINDOW_EXHAUSTED" then
			setState(operation, "RATE_LIMIT_DETECTED", {
				category = normalised.category,
				message = normalised.message,
				rateLimit = normalised.rateLimit,
			})
			setState(operation, "WAITING_FOR_QUOTA", { category = normalised.category })
		end

		local advisory = ProviderRateLimitScheduler.advisory(
			options.providerId,
			options.model,
			options.endpoint
		)

		lastDecision = RetryDelayCalculator.calculate({
			attempt = retryIndex,
			config = config,
			category = normalised.category,
			errorStatus = normalised.httpStatus,
			-- The provider's Retry-After / x-ratelimit-* headers are the most
			-- reliable backoff signal; without them every retry is a blind guess.
			headers = (errorInfo :: any).headers,
			body = (errorInfo :: any).body,
			cooldownSeconds = advisory.cooldownSeconds,
			windowWaitSeconds = advisory.windowWaitSeconds,
			now = runtime.clock(),
			random = runtime.random,
		})

		if lastDecision.exceedsAutoWait then
			operation.paused = true
			operation.pauseReason = lastDecision.reason
			Logger.warn("Retry", "Paused: the provider requires a longer wait than the automatic limit.", {
				detail = lastDecision.reason,
				taskId = options.taskId,
			})
			setState(operation, "WAITING_FOR_QUOTA", {
				paused = true,
				pauseReason = lastDecision.reason,
				delaySeconds = lastDecision.delaySeconds,
			})
			return finish(false, nil, normalised, lastDecision)
		end

		setState(operation, "RETRY_SCHEDULED", {
			delaySeconds = lastDecision.delaySeconds,
			source = lastDecision.source,
			attempt = retryIndex,
			mandatory = lastDecision.mandatory,
			estimated = lastDecision.estimated,
		})

		Logger.info("Retry", string.format(
			"Retry %d/%d scheduled in %.1fs.",
			retryIndex,
			config.maxRetries,
			lastDecision.delaySeconds
		), {
			detail = string.format(
				"%s · %s · %s · %s%s",
				options.providerName,
				options.model,
				normalised.category,
				lastDecision.source,
				if lastDecision.mandatory then " (provider-mandated)" else ""
			),
			taskId = options.taskId,
		})

		if lastDecision.delaySeconds > 0 then
			if options.onWait then
				options.onWait(lastDecision.delaySeconds, lastDecision, retryIndex)
			end
			if not runtime.sleep(lastDecision.delaySeconds) then
				operation.cancelled = true
				setState(operation, "RETRY_CANCELLED", { reason = "Cancelled while waiting." })
				return finish(false, nil, normalised, lastDecision)
			end
		end

		if operation.cancelled or (options.shouldCancel and options.shouldCancel()) then
			setState(operation, "RETRY_CANCELLED", { reason = "Cancelled before the next attempt." })
			return finish(false, nil, normalised, lastDecision)
		end

		setState(operation, "RETRYING", {
			attempt = retryIndex,
			category = normalised.category,
		})
	end

	return finish(false, nil, operation.lastError, lastDecision)
end

--=============================================================================
-- REPORTING
--=============================================================================

function SmartAutoRetryManager.describe(operationId: string): string?
	local operation = operations[operationId]
	if not operation then
		return nil
	end
	local parts: { string } = {}
	parts[#parts + 1] = string.format(
		"%s · %s",
		operation.providerName,
		operation.model
	)
	parts[#parts + 1] = string.format("%d attempt(s)", operation.attemptsMade)
	parts[#parts + 1] = string.format("%.1fs elapsed", operation.totalElapsedSeconds)
	if operation.upstreamRetryNotices > 0 then
		parts[#parts + 1] = string.format(
			"%d upstream retr%s reported (not ours)",
			operation.upstreamRetryNotices,
			if operation.upstreamRetryNotices == 1 then "y" else "ies"
		)
	end
	return table.concat(parts, "  ·  ")
end

-- Sanitised one-line summary used by the retry log.
function SmartAutoRetryManager.logLine(normalised: ProviderErrorNormalizer.Normalised?): string
	if not normalised then
		return ""
	end
	return string.format(
		"[%s] %s%s",
		normalised.category,
		Redact.scrubText(normalised.message),
		if normalised.requestId then ("  · request " .. normalised.requestId) else ""
	)
end

SmartAutoRetryManager.STATE_EVENT = STATE_EVENT

return SmartAutoRetryManager
