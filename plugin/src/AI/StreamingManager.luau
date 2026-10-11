--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / AI / StreamingManager
	Owns one live provider turn at a time and delegates transport + retries to
	ProviderService, so there is exactly one retry controller per operation.

	Fallback behaviour is explicit: when the endpoint or the Studio build cannot
	stream, the request runs non-streaming and the UI says so. Token-by-token
	output is never faked.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ProviderService = require(script.Parent.ProviderService)
local SmartAutoRetryManager = require(script.Parent.SmartAutoRetryManager)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local ProviderErrorNormalizer = require(script.Parent.ProviderErrorNormalizer)
local Redact = require(script.Parent.Parent.Utilities.Redact)

local StreamingManager = {}

local activeTaskId: string? = nil
local generation = 0

--=============================================================================
-- STATE
--=============================================================================

function StreamingManager.isBusy(): boolean
	return activeTaskId ~= nil
end

function StreamingManager.getActiveTaskId(): string?
	return activeTaskId
end

--- Cancels the active turn and any retry chain behind it.
function StreamingManager.cancel(taskId: string?): boolean
	local ProviderRateLimitScheduler = require(script.Parent.ProviderRateLimitScheduler)

	if not activeTaskId then
		return false
	end
	if taskId and activeTaskId ~= taskId then
		return false
	end

	SmartAutoRetryManager.cancel(activeTaskId, "Cancelled by the user.")
	generation += 1
	activeTaskId = nil
	-- Cancelling the retry operation also releases any provider rate-limit queue
	-- for it; a bucket keyed by nil created an unrelated, never-read entry.
	Logger.warn("Streaming", "Generation cancelled.", { taskId = taskId })
	return true
end

function StreamingManager.cancelAll()
	SmartAutoRetryManager.cancelAll("Cancelled by the user.")
	generation += 1
	activeTaskId = nil
end

--=============================================================================
-- CAPABILITY DISCOVERY
--=============================================================================

--- Reports whether this Studio build + protocol combination can stream.
function StreamingManager.streamingStatus(profile: any?): { available: boolean, reason: string }
	local UniversalHTTPClient = require(script.Parent.Parent.Utilities.UniversalHTTPClient)
	local UniversalProviderRegistry = require(script.Parent.UniversalProviderRegistry)

	if not UniversalHTTPClient.supportsStreaming() then
		return {
			available = false,
			reason = "This Studio build does not expose HttpService:CreateWebStreamClient. Responses arrive in one piece instead.",
		}
	end
	if not profile then
		return { available = true, reason = "Streaming is available once a provider is configured." }
	end
	local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)
	if not protocol.supportsStreaming then
		return { available = false, reason = protocol.label .. " does not stream over this endpoint." }
	end
	if profile.streaming == false then
		return { available = false, reason = "Streaming is turned off for this provider." }
	end
	return { available = true, reason = "Streaming is available for this protocol." }
end

--=============================================================================
-- RUN
--=============================================================================

--- Starts one provider turn. Returns a handle, or nil plus a reason.
function StreamingManager.run(options: {
	profile: any,
	spec: any,
	apiKey: string?,
	taskId: string,
	operationId: string?,
	onText: ((delta: string) -> ())?,
	onReasoning: ((delta: string) -> ())?,
	onDone: ((result: {
		text: string,
		reasoning: string?,
		toolCalls: { any },
		usage: any,
		durationMs: number,
		attempts: number,
	}) -> ())?,
	onError: ((normalised: any, attempts: number?) -> ())?,
	onWait: ((waitSeconds: number, decision: any, attempt: number) -> ())?,
	onAttempt: ((attempt: number) -> ())?,
	shouldCancel: (() -> boolean)?,
})
	local profile = options.profile
	local taskId = options.taskId

	if activeTaskId then
		return nil, "A request is already in progress. Stop it before starting another."
	end

	activeTaskId = taskId
	generation += 1
	local current = generation
	local function isCurrent(): boolean return current == generation and activeTaskId == taskId end
	local function failure(message: string)
		if not isCurrent() then return end
		activeTaskId = nil
		local safe = Redact.scrubText(message)
		Logger.error("Streaming", "Provider turn stopped unexpectedly.", { taskId = taskId, detail = safe })
		if options.onError then
			options.onError(ProviderErrorNormalizer.normalise({
				provider = profile.displayName, model = profile.modelId,
				endpoint = profile.baseUrl, transportError = safe, elapsedMs = 0,
			}), 1)
		end
	end

    local lastActivity = os.clock()
    local function activity() lastActivity = os.clock() end
    if profile.streaming ~= false then
        local idleSeconds = math.clamp((profile.timeoutMs or 120000) / 1000, 1, 600) + 20
        task.spawn(function()
            while isCurrent() do
                if os.clock() - lastActivity >= idleSeconds then
                    SmartAutoRetryManager.cancel(options.operationId or taskId, "Provider turn timed out.")
                    failure("Provider turn timed out while inactive. The partial answer was preserved; you can send another message.")
                    break
                end
                task.wait(0.25)
            end
        end)
    end

	task.spawn(function()
		local ok, reason = pcall(function()
		StateManager.transition("CONNECTING", { taskId = taskId, activity = "Contacting the provider" })

		ProviderService.stream(profile, options.spec, options.apiKey, {
			onActivity = function() if isCurrent() then activity() end end,
			operationId = options.operationId,
			taskId = taskId,
			onText = function(delta) if isCurrent() then activity(); if options.onText then options.onText(delta) end end end,
			onReasoning = function(delta) if isCurrent() then activity(); if options.onReasoning then options.onReasoning(delta) end end end,
			onWait = function(seconds, decision, attempt) if isCurrent() then lastActivity = os.clock() + math.max(0, seconds); if options.onWait then options.onWait(seconds, decision, attempt) end end end,
			onAttempt = function(attempt) if isCurrent() then activity(); if options.onAttempt then options.onAttempt(attempt) end end end,
			shouldCancel = function() return not isCurrent() or (options.shouldCancel and options.shouldCancel()) == true end,
			onDone = function(result)
				if not isCurrent() then return end
				if StateManager.get() == "CONNECTING" then StateManager.transition("THINKING", { taskId = taskId }) end
				activeTaskId = nil
				if options.onDone then
					options.onDone(result)
				end
			end,
			onError = function(normalised, attempts)
				if not isCurrent() then return end
				activeTaskId = nil
				if options.onError then
					options.onError(normalised, attempts)
				end
			end,
		})
		end)
		if not ok then failure(tostring(reason))
		elseif isCurrent() then failure("Provider turn ended without a completion result.") end
	end)

	return { taskId = taskId }, nil
end

--=============================================================================
-- WAIT
--=============================================================================

--- Blocks until the active turn (including retries) settles.
function StreamingManager.wait(taskId: string, timeoutSeconds: number?): boolean
	local started = os.clock()
	local limit = timeoutSeconds or 600
	while activeTaskId == taskId do
		if StateManager.get() == "CANCELLED" then
			StreamingManager.cancel(taskId)
			return false
		end
		if os.clock() - started > limit then
			Logger.warn("Streaming", "Turn did not settle within the wait limit.", { taskId = taskId })
			StreamingManager.cancel(taskId)
			return false
		end
		task.wait(0.1)
	end
	return true
end

-- Surfaced as an activity hint so the header reflects a rate-limit wait even
-- when the thinking strip is collapsed.
EventBus.on(SmartAutoRetryManager.STATE_EVENT, function(payload)
	if payload.state == "RATE_LIMIT_DETECTED" then
		EventBus.emit(EventBus.Events.ActivityChanged, { activity = "Provider rate limit detected" })
	end
end)

return StreamingManager
