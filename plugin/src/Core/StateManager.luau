--!strict
--[[
	ForgePilot / Core / StateManager
	The agent state machine.

	Every transition is validated against an explicit table, illegal transitions
	are rejected, and duplicate work is suppressed while a task is already running.
]]

local EventBus = require(script.Parent.EventBus)

local StateManager = {}

export type State =
	| "IDLE"
	| "CONNECTING"
	| "THINKING"
	| "ANALYZING"
	| "PLANNING"
	| "AWAITING_USER_ANSWER"
	| "AWAITING_APPROVAL"
	| "BUILDING"
	| "VERIFYING"
	| "COMPLETED"
	| "FAILED"
	| "CANCELLED"
	-- Provider-recovery states (V3.3). Fed by RetryStateManager.
	| "RATE_LIMIT_DETECTED"
	| "WAITING_FOR_QUOTA"
	| "RETRY_SCHEDULED"
	| "RETRYING"
	| "PROVIDER_RECOVERED"
	| "RETRIES_EXHAUSTED"
	| "RETRY_CANCELLED"

-- A SET of every valid state name. Transitions are checked against this, so it
-- must be keyed by state name (`States.THINKING`), not a positional array.
local allStates: { [State]: boolean } = {
	IDLE = true,
	CONNECTING = true,
	THINKING = true,
	ANALYZING = true,
	PLANNING = true,
	AWAITING_USER_ANSWER = true,
	AWAITING_APPROVAL = true,
	BUILDING = true,
	VERIFYING = true,
	COMPLETED = true,
	FAILED = true,
	CANCELLED = true,
	RATE_LIMIT_DETECTED = true,
	WAITING_FOR_QUOTA = true,
	RETRY_SCHEDULED = true,
	RETRYING = true,
	PROVIDER_RECOVERED = true,
	RETRIES_EXHAUSTED = true,
	RETRY_CANCELLED = true,
}

StateManager.States = allStates

--- Which states may follow which.
local ALLOWED: { [State]: { [State]: boolean } } = {
	IDLE = { CONNECTING = true, THINKING = true, PLANNING = true, CANCELLED = true },
	-- CONNECTING transitions are defined below together with rate-limit recovery.
	THINKING = { ANALYZING = true, PLANNING = true, BUILDING = true, AWAITING_USER_ANSWER = true, AWAITING_APPROVAL = true, COMPLETED = true, FAILED = true, CANCELLED = true },
	ANALYZING = { THINKING = true, PLANNING = true, BUILDING = true, AWAITING_USER_ANSWER = true, AWAITING_APPROVAL = true, COMPLETED = true, FAILED = true, CANCELLED = true },
	PLANNING = { AWAITING_USER_ANSWER = true, AWAITING_APPROVAL = true, COMPLETED = true, FAILED = true, CANCELLED = true, THINKING = true },
	AWAITING_USER_ANSWER = { THINKING = true, ANALYZING = true, PLANNING = true, BUILDING = true, CANCELLED = true, FAILED = true },
	AWAITING_APPROVAL = { PLANNING = true, BUILDING = true, THINKING = true, CANCELLED = true, FAILED = true },
	BUILDING = { VERIFYING = true, THINKING = true, AWAITING_USER_ANSWER = true, COMPLETED = true, FAILED = true, CANCELLED = true },
	VERIFYING = { THINKING = true, BUILDING = true, COMPLETED = true, FAILED = true, CANCELLED = true },
	COMPLETED = { IDLE = true, THINKING = true, PLANNING = true, CANCELLED = true },
	FAILED = { IDLE = true, THINKING = true, PLANNING = true, CANCELLED = true },
	CANCELLED = { IDLE = true, THINKING = true, PLANNING = true },

	-- Provider recovery. Any active work state may hit a provider failure and
	-- enter the retry chain; the chain can only return to active work once the
	-- provider actually responds.
	CONNECTING = { THINKING = true, FAILED = true, CANCELLED = true, IDLE = true, RATE_LIMIT_DETECTED = true, WAITING_FOR_QUOTA = true, RETRYING = true },
}

-- States that mean "the agent is mid-task and may still transition to work".
local ACTIVE_STATES: { [State]: boolean } = {
	CONNECTING = true,
	THINKING = true,
	ANALYZING = true,
	PLANNING = true,
	AWAITING_USER_ANSWER = true,
	AWAITING_APPROVAL = true,
	BUILDING = true,
	VERIFYING = true,
}

-- Any active work state may drop into the retry chain, including cancellation.
for from in pairs(ACTIVE_STATES) do
	local row = ALLOWED[from]
	row.CONNECTING = true
	row.RATE_LIMIT_DETECTED = true
	row.WAITING_FOR_QUOTA = true
	row.RETRY_SCHEDULED = true
	row.RETRYING = true
	row.RETRY_CANCELLED = true
	row.RETRIES_EXHAUSTED = true
end

-- IDLE and the terminal states can only reach the chain's own end states.
ALLOWED.IDLE.RETRY_CANCELLED = true
ALLOWED.IDLE.RETRIES_EXHAUSTED = true

-- The retry chain itself.
ALLOWED.RATE_LIMIT_DETECTED = {
	WAITING_FOR_QUOTA = true,
	RETRYING = true,
	PROVIDER_RECOVERED = true,
	RETRIES_EXHAUSTED = true,
	RETRY_CANCELLED = true,
	FAILED = true,
	CANCELLED = true,
}
ALLOWED.WAITING_FOR_QUOTA = {
	RETRY_SCHEDULED = true,
	RETRYING = true,
	RETRY_CANCELLED = true,
	RETRIES_EXHAUSTED = true,
	FAILED = true,
	CANCELLED = true,
}
ALLOWED.RETRY_SCHEDULED = {
	RETRYING = true,
	RETRY_CANCELLED = true,
	WAITING_FOR_QUOTA = true,
	RETRIES_EXHAUSTED = true,
	FAILED = true,
	CANCELLED = true,
}
ALLOWED.RETRYING = {
	PROVIDER_RECOVERED = true,
	RETRY_SCHEDULED = true,
	RATE_LIMIT_DETECTED = true,
	WAITING_FOR_QUOTA = true,
	RETRIES_EXHAUSTED = true,
	RETRY_CANCELLED = true,
	FAILED = true,
	CANCELLED = true,
}
ALLOWED.PROVIDER_RECOVERED = {
	THINKING = true,
	ANALYZING = true,
	PLANNING = true,
	BUILDING = true,
	VERIFYING = true,
	AWAITING_USER_ANSWER = true,
	AWAITING_APPROVAL = true,
	COMPLETED = true,
	FAILED = true,
	CANCELLED = true,
	IDLE = true,
}
ALLOWED.RETRIES_EXHAUSTED = {
	FAILED = true,
	IDLE = true,
	THINKING = true,
	CANCELLED = true,
}
ALLOWED.RETRY_CANCELLED = {
	IDLE = true,
	FAILED = true,
	THINKING = true,
	PLANNING = true,
	CANCELLED = true,
}

StateManager.RETRY_STATES = {
	"RATE_LIMIT_DETECTED",
	"WAITING_FOR_QUOTA",
	"RETRY_SCHEDULED",
	"RETRYING",
	"PROVIDER_RECOVERED",
	"RETRIES_EXHAUSTED",
	"RETRY_CANCELLED",
}

local displayLabels: { [State]: string } = {
	IDLE = "Ready",
	CONNECTING = "Connecting",
	THINKING = "Thinking",
	ANALYZING = "Analyzing",
	PLANNING = "Planning",
	AWAITING_USER_ANSWER = "Waiting for your answer",
	AWAITING_APPROVAL = "Waiting for approval",
	BUILDING = "Building",
	VERIFYING = "Verifying",
	COMPLETED = "Completed",
	FAILED = "Failed",
	CANCELLED = "Cancelled",
	RATE_LIMIT_DETECTED = "Rate limit detected",
	WAITING_FOR_QUOTA = "Waiting for quota",
	RETRY_SCHEDULED = "Retry scheduled",
	RETRYING = "Retrying request",
	PROVIDER_RECOVERED = "Provider recovered",
	RETRIES_EXHAUSTED = "Retries exhausted",
	RETRY_CANCELLED = "Retry cancelled",
}

StateManager.displayLabel = displayLabels

local currentState: State = "IDLE"
local currentTaskId: string? = nil
local activeActivity: string? = nil
local busy = false
local history: { { state: State, at: number, taskId: string? } } = {}

--=============================================================================
-- RETRY CHAIN MEMBERSHIP
--=============================================================================

local RETRY_SET: { [string]: boolean } = {}
for _, name in StateManager.RETRY_STATES do
	RETRY_SET[name] = true
end

--- True when the agent is inside the provider-recovery chain.
function StateManager.isInRetryChain(): boolean
	return RETRY_SET[currentState] == true
end

--- True when a rate-limit or quota wait is in progress.
function StateManager.isWaitingOnProvider(): boolean
	return currentState == "WAITING_FOR_QUOTA" or currentState == "RATE_LIMIT_DETECTED"
end

--=============================================================================
-- QUERIES
--=============================================================================

function StateManager.get(): State
	return currentState
end

function StateManager.getTaskId(): string?
	return currentTaskId
end

function StateManager.getActivity(): string?
	return activeActivity
end

local taskRunning = false
--- True only while an agent run owns the request lock, including cleanup.
function StateManager.isRunActive(): boolean
	return taskRunning
end

function StateManager.isBusy(): boolean
	return busy or taskRunning
end

function StateManager.beginRun(): boolean
	if StateManager.isBusy() then return false end
	taskRunning = true
	EventBus.emit(EventBus.Events.StateChanged, {
		state = currentState, taskId = currentTaskId, busy = true, activity = activeActivity,
	})
	return true
end

function StateManager.endRun()
	taskRunning = false
	EventBus.emit(EventBus.Events.StateChanged, {
		state = currentState, taskId = currentTaskId, busy = busy, activity = activeActivity,
	})
end

--- True when the agent is mid-task and must not start another one.
function StateManager.isTerminal(): boolean
	return currentState == "COMPLETED" or currentState == "FAILED" or currentState == "CANCELLED"
end

function StateManager.history(): { { state: State, at: number, taskId: string? } }
	return table.clone(history)
end

--=============================================================================
-- TRANSITIONS
--=============================================================================

--- Attempts a transition. Returns `true` when the move was accepted.
function StateManager.transition(next: State, options: { taskId: string?, activity: string?, force: boolean? }?)
	if not StateManager.States[next] then
		warn("[ForgePilot] unknown state requested: " .. tostring(next))
		return false
	end

	if next == currentState and not (options and options.force) then
		return true
	end

	local allowed = ALLOWED[currentState]
	if allowed and not allowed[next] and not (options and options.force) then
		warn(string.format("[ForgePilot] rejected transition %s -> %s", currentState, next))
		return false
	end

	local previous = currentState
	currentState = next
	if options and options.taskId then
		currentTaskId = options.taskId
	end
	if options and options.activity ~= nil then
		activeActivity = options.activity
	end

	busy = next ~= "IDLE"
		and next ~= "COMPLETED"
		and next ~= "FAILED"
		and next ~= "CANCELLED"

	history[#history + 1] = { state = next, at = os.clock(), taskId = currentTaskId }
	if #history > 500 then
		table.remove(history, 1)
	end

	EventBus.emit(EventBus.Events.StateChanged, {
		previous = previous,
		state = next,
		label = StateManager.displayLabel[next],
		taskId = currentTaskId,
		busy = busy,
		activity = activeActivity,
	})
	return true
end

--- Sets the free-text activity line shown next to the state (e.g. "Analyzing Workspace...").
function StateManager.setActivity(activity: string?)
	if activeActivity == activity then
		return
	end
	activeActivity = activity
	EventBus.emit(EventBus.Events.ActivityChanged, { activity = activity, state = currentState })
end

--- Clears activity text (state label remains).
function StateManager.clearActivity()
	StateManager.setActivity(nil)
end

function StateManager.setTaskId(taskId: string?)
	currentTaskId = taskId
end

--=============================================================================
-- CANCELLATION
--=============================================================================

--- Marks the current task cancelled and returns the id that was cancelled.
function StateManager.cancel(): string?
	local cancelled = currentTaskId
	if busy then
		StateManager.transition("CANCELLED", { taskId = cancelled, activity = nil, force = true })
		busy = false
	end
	return cancelled
end

function StateManager.reset()
	StateManager.transition("IDLE", { taskId = nil, activity = nil, force = true })
	busy = false
end

--- True when the agent should accept a new user message.
function StateManager.canAcceptInput(): boolean
	return not StateManager.isBusy()
end

return StateManager
