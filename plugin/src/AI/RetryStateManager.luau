--!strict
--[[
	ForgePilot / AI / RetryStateManager
	Retry-aware view over Core/StateManager.

	The core machine gains seven retry states. This module is the single place
	that decides when the agent should be considered "waiting on the provider"
	versus "thinking", so the UI never shows contradictory states.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local Time = require(script.Parent.Parent.Utilities.Time)

local RetryStateManager = {}

--=============================================================================
-- RETRY STATES
--=============================================================================

export type RetryState =
	| "RATE_LIMIT_DETECTED"
	| "WAITING_FOR_QUOTA"
	| "RETRY_SCHEDULED"
	| "RETRYING"
	| "PROVIDER_RECOVERED"
	| "RETRIES_EXHAUSTED"
	| "RETRY_CANCELLED"

local allRetryStates: { RetryState } = {
	"RATE_LIMIT_DETECTED",
	"WAITING_FOR_QUOTA",
	"RETRY_SCHEDULED",
	"RETRYING",
	"PROVIDER_RECOVERED",
	"RETRIES_EXHAUSTED",
	"RETRY_CANCELLED",
}

RetryStateManager.States = allRetryStates

local displayLabels: { [string]: string } = {
	RATE_LIMIT_DETECTED = "Rate limit detected",
	WAITING_FOR_QUOTA = "Waiting for quota",
	RETRY_SCHEDULED = "Retry scheduled",
	RETRYING = "Retrying request",
	PROVIDER_RECOVERED = "Provider recovered",
	RETRIES_EXHAUSTED = "Retries exhausted",
	RETRY_CANCELLED = "Retry cancelled",
}

--- Short strings shown next to the spinner, per the spec's examples.
local shortLabels: { [string]: (payload: any) -> string } = {
	RATE_LIMIT_DETECTED = function()
		return "Rate limited"
	end,
	WAITING_FOR_QUOTA = function(payload)
		local seconds = tonumber(payload and payload.delaySeconds) or 0
		return string.format("Rate limited • Waiting %ds", math.ceil(seconds))
	end,
	RETRY_SCHEDULED = function(payload)
		local attempt = tonumber(payload and payload.attempt) or 1
		local maximum = tonumber(payload and payload.maxRetries) or 5
		local seconds = tonumber(payload and payload.delaySeconds) or 0
		return string.format("Retrying request • Attempt %d/%d in %ds", attempt, maximum, math.ceil(seconds))
	end,
	RETRYING = function(payload)
		local attempt = tonumber(payload and payload.attempt) or 1
		local maximum = tonumber(payload and payload.maxRetries) or 5
		return string.format("Retrying request • Attempt %d/%d", attempt, maximum)
	end,
	PROVIDER_RECOVERED = function(payload)
		return "Provider recovered • Continuing task"
	end,
	RETRIES_EXHAUSTED = function()
		return "Retries exhausted"
	end,
	RETRY_CANCELLED = function()
		return "Retry cancelled"
	end,
}

RetryStateManager.displayLabel = displayLabels
RetryStateManager.shortLabel = shortLabels

--=============================================================================
-- SUBSCRIPTION
--=============================================================================

local active: {
	operationId: string,
	taskId: string?,
	state: RetryState,
	attempt: number,
	maxRetries: number,
	delaySeconds: number,
	provider: string,
	model: string,
	category: string?,
	message: string?,
	pauseReason: string?,
	updatedAt: number,
}? = nil

local unsub: (() -> ())? = nil

--- Starts listening. Safe to call more than once.
function RetryStateManager.init()
	if unsub then
		return
	end
	unsub = EventBus.on("retry:state", function(payload)
		local next = payload.state
		if type(next) ~= "string" or not StateManager.States[next :: any] then
			return
		end

		active = {
			operationId = payload.operationId,
			taskId = payload.taskId,
			state = next,
			attempt = tonumber(payload.attempt) or tonumber(payload.retryCount) or 0,
			maxRetries = tonumber(payload.maxRetries) or 0,
			delaySeconds = tonumber(payload.delaySeconds) or 0,
			provider = payload.provider or "Provider",
			model = payload.model or "(not set)",
			category = payload.category,
			message = payload.message,
			pauseReason = payload.pauseReason,
			updatedAt = os.clock(),
		}

		-- Mirror into the agent state machine so the header and logs agree.
		if StateManager.transition(next :: any, {
			taskId = payload.taskId,
			activity = RetryStateManager.describe(),
		}) then
			return
		end
	end)
end

function RetryStateManager.shutdown()
	if unsub then
		unsub()
		unsub = nil
	end
end

--=============================================================================
-- QUERIES
--=============================================================================

function RetryStateManager.getActive()
	return active
end

function RetryStateManager.isRetrying(): boolean
	if not active then
		return false
	end
	return active.state == "RETRYING"
		or active.state == "RETRY_SCHEDULED"
		or active.state == "WAITING_FOR_QUOTA"
		or active.state == "RATE_LIMIT_DETECTED"
end

function RetryStateManager.isTerminal(): boolean
	if not active then
		return false
	end
	return active.state == "RETRIES_EXHAUSTED"
		or active.state == "RETRY_CANCELLED"
		or active.state == "PROVIDER_RECOVERED"
end

--- Human line for the thinking indicator, e.g. "Retrying request • Attempt 3/5".
function RetryStateManager.shortText(): string?
	if not active then
		return nil
	end
	local formatter = RetryStateManager.shortLabel[active.state]
	if not formatter then
		return RetryStateManager.displayLabel[active.state]
	end
	local text = formatter(active)
	local elapsed = Time.formatDuration(os.clock() - active.updatedAt)
	return string.format("%s • %s", text, elapsed)
end

--- One-line detail for logs and the retry card.
function RetryStateManager.describe(): string?
	if not active then
		return nil
	end
	local parts: { string } = {
		RetryStateManager.displayLabel[active.state],
		string.format("attempt %d", active.attempt),
		active.provider,
		active.model,
	}
	if active.delaySeconds > 0 then
		parts[#parts + 1] = string.format("%.0fs", active.delaySeconds)
	end
	if active.pauseReason then
		parts[#parts + 1] = active.pauseReason
	end
	return table.concat(parts, "  ·  ")
end

function RetryStateManager.clear()
	active = nil
end

return RetryStateManager