--!strict
--[[
	ForgePilot / AI / ProviderService
	Adapter dispatch plus the single request path every provider call goes through.

	Retry lives here, not in the adapters: one SmartAutoRetryManager per operation
	means retry loops can never nest.
]]

local BaseURLResolver = require(script.Parent.BaseURLResolver)
local ContextManager = require(script.Parent.ContextManager)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local CustomProviderManager = require(script.Parent.CustomProviderManager)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ProviderErrorNormalizer = require(script.Parent.ProviderErrorNormalizer)
local ProviderRateLimitScheduler = require(script.Parent.ProviderRateLimitScheduler)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local RetryDelayCalculator = require(script.Parent.RetryDelayCalculator)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local SmartAutoRetryManager = require(script.Parent.SmartAutoRetryManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local UniversalErrorDetector = require(script.Parent.Parent.Utilities.UniversalErrorDetector)
local UniversalHTTPClient = require(script.Parent.Parent.Utilities.UniversalHTTPClient)
local UniversalProviderRegistry = require(script.Parent.UniversalProviderRegistry)

local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local ProviderService = {}

-- Rate-limit buckets are keyed by HOST, so every reader and writer of the bucket
-- has to agree on that string. recordRequest used to pass the full request URL,
-- which created a second, never-read bucket.
local function endpointKey(profile: any): string
	return (BaseURLResolver.hostOf(profile.baseUrl) or profile.baseUrl) or ""
end

--=============================================================================
-- ADAPTER REGISTRY
--=============================================================================

local CustomJSON = require(script.Parent.Adapters.CustomJSONAdapter)
local Gemini = require(script.Parent.Adapters.GeminiAdapter)
local GeminiOpenAI = require(script.Parent.Adapters.GeminiOpenAIAdapter)
local OpenAICompatible = require(script.Parent.Adapters.OpenAICompatibleAdapter)
local OpenAICompletion = require(script.Parent.Adapters.OpenAICompletionAdapter)
local OpenAIResponses = require(script.Parent.Adapters.OpenAIResponsesAdapter)
local OpenRouter = require(script.Parent.Adapters.OpenRouterAdapter)
local Anthropic = require(script.Parent.Adapters.AnthropicAdapter)

local ADAPTERS = {
	openai_chat = OpenAICompatible,
	openai_text_completions = OpenAICompletion,
	openai_responses = OpenAIResponses,
	openrouter = OpenRouter,
	anthropic_messages = Anthropic,
	gemini_native = Gemini,
	gemini_openai = GeminiOpenAI,
	openai_compatible = OpenAICompatible,
	custom_rest = CustomJSON,
}

function ProviderService.getAdapter(protocolId: string): any
	return ADAPTERS[protocolId] or OpenAICompatible
end

function ProviderService.supportedProtocols(): { string }
	local list = {}
	for protocolId in pairs(ADAPTERS) do
		list[#list + 1] = protocolId
	end
	table.sort(list)
	return list
end

--=============================================================================
-- REQUEST ASSEMBLY
--=============================================================================

export type PreparedRequest = {
	url: string,
	headers: { [string]: string },
	body: string,
	jsonBody: any,
	streaming: boolean,
}

--- Builds a fully-formed request or returns nil plus an actionable message.
function ProviderService.prepare(profile: any, spec: any, apiKey: string?, forceStreaming: boolean?): (PreparedRequest?, string?)
	local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)

	local streaming = false
	if profile.streaming and (forceStreaming ~= false) and protocol.supportsStreaming then
		-- A caller may force a single non-streaming request (capability probes,
		-- connection tests, and the streaming fallback). Without this the
		-- fallback would re-enter stream() for ever.
		if spec.streaming ~= false and UniversalHTTPClient.supportsStreaming() then
			streaming = true
		end
	end

	local adapter = ProviderService.getAdapter(profile.protocol)
    local requestSpec = spec
    if profile.viaRouter and profile.routerAlias then
        requestSpec = table.clone(spec)
        local prefix = profile.routerAlias .. "/"
        if string.sub(spec.model or "", 1, #prefix) ~= prefix then requestSpec.model = prefix .. (spec.model or "") end
    end
	local built, buildError = adapter.buildRequest(profile, requestSpec, streaming)
	if not built then
		return nil, tostring(buildError)
	end

	-- Protocol-level auth first, so a profile that did not set a style still gets
	-- the credential header its protocol requires (Gemini native, Anthropic).
	local authStyle = profile.authStyle
	if authStyle == nil or authStyle == "" then
		authStyle = protocol.authStyle
	end

	local authHeaders, authQuery = UniversalProviderRegistry.buildAuthHeaders({
		style = authStyle,
		headerName = profile.authHeaderName or protocol.authHeaderName,
		headerPrefix = profile.authHeaderPrefix or protocol.authHeaderPrefix,
		queryParam = profile.authQueryParam or protocol.authQueryParam,
	}, apiKey)

	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }
	for key, value in authHeaders do
		headers[key] = value
	end
	for key, value in (protocol.defaultHeaders or {}) do
		headers[key] = value
	end
	for key, value in (profile.defaultHeaders or {}) do
		headers[key] = value
	end
	for key, value in (profile.extraHeaders or {}) do
		if type(key) == "string" and type(value) == "string" and #value > 0 then
			headers[key] = value
		end
	end

	local url = built.url
	if authQuery then
		url ..= (if string.find(url, "?", 1, true) then "&" else "?") .. authQuery
	end

	-- Warn before a credential is sent to an unfamiliar host.
	if apiKey and #apiKey > 0 and not UniversalProviderRegistry.isTrustedHost(url) then
		local host = require(script.Parent.BaseURLResolver).hostOf(url) or "unknown host"
		Logger.warn("AI Provider", "API key is being sent to an unrecognised host.", {
			detail = string.format("Host: %s. Confirm you trust this provider before continuing.", host),
		})
	end

	return {
		url = url,
		headers = headers,
		body = built.body,
		jsonBody = built.jsonBody,
		streaming = streaming,
	}, nil
end

--=============================================================================
-- RESPONSE PARSING
--=============================================================================

--- Parses a provider body using the adapter for a profile.
function ProviderService.parseAdapterResponse(profile: any, body: string): (any?, string?)
	local adapter = ProviderService.getAdapter(profile.protocol)
	-- The custom REST adapter needs the profile's schema mapping.
	if profile.protocol == "custom_rest" then
		return adapter.parseResponse(body, profile)
	end
	return adapter.parseResponse(body)
end

--=============================================================================
-- RETRY CONFIGURATION
--=============================================================================

function ProviderService.getRetryConfig(profile: any?): RetryDelayCalculator.Config
	local settings = SettingsManager.getValue("smartRetry")
	if type(settings) ~= "table" then
		settings = {}
	end
	local config = RetryDelayCalculator.fromSettings(settings, profile and profile.id)
	-- Diagnostic profiles are temporary copies. Respect their one-attempt
	-- override without persisting changes to the user's chat retry settings.
	if profile and type(profile.retryOverrides) == "table" then
		local merged = table.clone(config)
		for key, value in profile.retryOverrides do
			if (merged :: any)[key] ~= nil then (merged :: any)[key] = value end
		end
		merged.providerOverrides = nil
		return RetryDelayCalculator.fromSettings(merged, nil)
	end
	return config
end

--=============================================================================
-- SINGLE ATTEMPT
--=============================================================================

export type AttemptOutcome = {
	ok: boolean,
	body: string?,
	statusCode: number?,
	headers: { [string]: string }?,
	transportError: string?,
	streamInterrupted: boolean?,
	durationMs: number,
	requestId: string?,
}

--- Performs exactly one HTTP request. Never retries.
function ProviderService.attempt(profile: any, spec: any, apiKey: string?, shouldCancel: (() -> boolean)?): AttemptOutcome
	local prepared, prepareError = ProviderService.prepare(profile, spec, apiKey, false)
	if not prepared then
		return {
			ok = false,
			body = nil,
			statusCode = nil,
			headers = nil,
			transportError = Redact.scrubText(prepareError or "Could not build the request."),
			durationMs = 0,
			requestId = nil,
		}
	end

	ProviderRateLimitScheduler.recordRequest(profile.id, profile.modelId, endpointKey(profile))

	local response = UniversalHTTPClient.postJson(prepared.url, prepared.headers, prepared.jsonBody, {
		timeoutMs = profile.timeoutMs,
		label = profile.displayName,
		shouldCancel = shouldCancel,
	})

	-- A 200 body that is really an error object is a failure.
	if response.ok then
		if UniversalErrorDetector.bodyIsError(response.body) then
			response.ok = false
		end
	end

	return {
		ok = response.ok,
		body = response.body,
		statusCode = response.statusCode,
		headers = response.headers,
		transportError = response.transportError,
		streamInterrupted = false,
		durationMs = response.durationMs,
		requestId = response.requestId,
	}
end

--=============================================================================
-- COMPLETE (WITH RETRY)
--=============================================================================

export type CompleteResult = {
	ok: boolean,
	response: any?,
	error: ProviderErrorNormalizer.Normalised?,
	attempts: number,
	durationMs: number,
	operationId: string?,
}

--- Runs a request to completion, retrying through the single retry controller.
function ProviderService.complete(
	profile: any,
	spec: any,
	apiKey: string?,
	callbacks: {
		operationId: string?,
		taskId: string?,
		onWait: ((waitSeconds: number, decision: RetryDelayCalculator.Decision, attempt: number) -> ())?,
		onAttempt: ((attempt: number, decision: RetryDelayCalculator.Decision?) -> ())?,
		shouldCancel: (() -> boolean)?,
	}?
): CompleteResult
	local opts = callbacks or {}
	local config = ProviderService.getRetryConfig(profile)

	local operation = SmartAutoRetryManager.run({
		operationId = opts.operationId,
		taskId = opts.taskId,
		providerId = profile.id,
		providerName = profile.displayName or profile.providerName or "Provider",
		model = profile.modelId or "(not set)",
		endpoint = endpointKey(profile),
		config = config,
		onWait = opts.onWait,
		onAttempt = opts.onAttempt,
		shouldCancel = opts.shouldCancel,
		request = function()
			local outcome = ProviderService.attempt(profile, spec, apiKey, opts.shouldCancel)
			if outcome.ok then
				return outcome, nil
			end
			return nil, {
				statusCode = outcome.statusCode,
				body = outcome.body,
				headers = outcome.headers,
				transportError = outcome.transportError,
				streamInterrupted = outcome.streamInterrupted,
			}
		end,
	})

	if not operation.ok then
		return {
			ok = false,
			response = nil,
			error = operation.error,
			attempts = operation.attemptsMade,
			durationMs = operation.totalElapsedSeconds * 1000,
			operationId = operation.operationId,
		}
	end

	local raw = operation.value
	local body = if type(raw) == "table" and raw.body ~= nil then raw.body else nil
	if type(body) ~= "string" then
		return {
			ok = false,
			response = nil,
			error = ProviderErrorNormalizer.normalise({
				provider = profile.displayName,
				model = profile.modelId,
				endpoint = profile.baseUrl,
				transportError = "The provider returned no body.",
				elapsedMs = operation.totalElapsedSeconds * 1000,
			}),
			attempts = operation.attemptsMade,
			durationMs = operation.totalElapsedSeconds * 1000,
			operationId = operation.operationId,
		}
	end

	local parsed, parseError = ProviderService.parseAdapterResponse(profile, body)
	if not parsed then
		Logger.error("AI Provider", "Could not parse the provider response.", {
			detail = tostring(parseError),
		})
		return {
			ok = false,
			response = nil,
			error = ProviderErrorNormalizer.normalise({
				provider = profile.displayName,
				model = profile.modelId,
				endpoint = profile.baseUrl,
				statusCode = tonumber(type(raw) == "table" and raw.statusCode or nil),
				body = body,
				transportError = tostring(parseError),
				elapsedMs = operation.totalElapsedSeconds * 1000,
			}),
			attempts = operation.attemptsMade,
			durationMs = operation.totalElapsedSeconds * 1000,
			operationId = operation.operationId,
		}
	end

	local usage = parsed.usage
	if usage and usage.source == "provider" then
		ContextManager.recordRequest(usage, operation.totalElapsedSeconds * 1000, nil)
	end

	return {
		ok = true,
		response = parsed,
		error = nil,
		attempts = operation.attemptsMade,
		durationMs = operation.totalElapsedSeconds * 1000,
		operationId = operation.operationId,
	}
end

--=============================================================================
-- CONNECTION TEST
--=============================================================================

export type ConnectionResult = {
	ok: boolean,
	statusCode: number?,
	message: string,
	latencyMs: number,
	usage: any?,
	model: string?,
	endpoint: string,
	streamingAvailable: boolean,
	category: string?,
	remedy: string?,
	preview: CustomProviderManager.Preview?,
}

--- Sends a minimal real request so the test exercises the whole path.
function ProviderService.testConnection(
	profile: any,
	apiKey: string?,
	options: { onProgress: ((note: string) -> ())?, maxProbes: number?, shouldCancel: (() -> boolean)? }?
): ConnectionResult
	local opts = options or {}
	local started = os.clock()
	local preview = CustomProviderManager.preview(profile)

	local function failure(message: string, category: string?, statusCode: number?): ConnectionResult
		return {
			ok = false,
			statusCode = statusCode,
			message = message,
			latencyMs = (os.clock() - started) * 1000,
			usage = nil,
			model = profile.modelId,
			endpoint = preview.display,
			streamingAvailable = UniversalHTTPClient.supportsStreaming(),
			category = category,
			remedy = ProviderErrorNormalizer.remedy(category or "UNKNOWN_ERROR"),
			preview = preview,
		}
	end

	if type(profile.baseUrl) ~= "string" or #StringUtil.trim(profile.baseUrl) == 0 then
		return failure("Set an API Base URL before testing.", "INVALID_ENDPOINT")
	end
	if type(profile.modelId) ~= "string" or #StringUtil.trim(profile.modelId) == 0 then
		return failure(
			"Set a Model ID before testing. Any model your provider exposes can be entered manually.",
			"INVALID_MODEL"
		)
	end

	local validation = CustomProviderManager.validate(profile)
	if not validation.ok then
		return failure(validation.errors[1].message, "INVALID_REQUEST")
	end

	if opts.onProgress then
		opts.onProgress(string.format("POST %s", preview.display))
	end

	local spec = {
		messages = { { role = "user", content = "Reply with the single word: ok" } },
		system = "Reply with exactly one short word.",
		model = profile.modelId,
		maxOutputTokens = 16,
		streaming = false,
		jsonMode = false,
		toolChoice = "none",
	}
	if profile.protocol == "openai_text_completions" then
		spec.messages = {}
		spec.system = nil
	end

	local result = ProviderService.complete(profile, spec, apiKey, {
		operationId = ("test-%d"):format(math.floor(os.clock() * 1000) % 100000),
		shouldCancel = opts.shouldCancel,
		onWait = function(seconds, decision, attempt)
			if opts.onProgress then
				opts.onProgress(
					string.format(
						"Rate limited. Retry %d in %.0fs (%s).",
						attempt,
						seconds,
						decision.source
					)
				)
			end
		end,
	})

	if not result.ok then
		local normalised = result.error
		return {
			ok = false,
			statusCode = normalised and normalised.httpStatus or nil,
			message = if normalised then normalised.message else "The connection test failed.",
			latencyMs = result.durationMs,
			usage = nil,
			model = profile.modelId,
			endpoint = preview.display,
			streamingAvailable = UniversalHTTPClient.supportsStreaming(),
			category = normalised and normalised.category or nil,
			remedy = if normalised then ProviderErrorNormalizer.remedy(normalised.category) else nil,
			preview = preview,
		}
	end

	local response = result.response
	local preview2 = string.gsub(string.sub(response.text or "", 1, 80), "%s+", " ")

	Logger.success("CONNECT", "Connection test succeeded.", {
		detail = string.format(
			"%s · %s · HTTP %s · %d attempt(s) · %.0f ms",
			profile.displayName,
			profile.modelId,
			tostring(result.response and response and response.raw and "200" or "200"),
			result.attempts,
			result.durationMs
		),
	})

	return {
		ok = true,
		statusCode = 200,
		message = string.format(
			"Connected on attempt %d. Model replied: \"%s\"%s",
			result.attempts,
			preview2,
			if result.attempts > 1
				then string.format(" (recovered after %d retries)", result.attempts - 1)
				else ""
		),
		latencyMs = result.durationMs,
		usage = response.usage,
		model = profile.modelId,
		endpoint = preview.display,
		streamingAvailable = UniversalHTTPClient.supportsStreaming(),
		category = nil,
		remedy = nil,
		preview = preview,
	}
end

--=============================================================================
-- MODEL LIST
--=============================================================================

--- Refreshes the model list where the provider exposes a real endpoint.
function ProviderService.listModels(profile: any, apiKey: string?, shouldCancel: (() -> boolean)?): ({ string }?, string?)
    if profile.viaRouter and BridgeClient.isConnected() then return BridgeClient.listModels(profile, apiKey, shouldCancel) end
	local url, urlError = UniversalProviderRegistry.modelListUrl(profile)
	if not url then
		return nil, urlError
	end

	local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)
	local headers: { [string]: string } = {}
	local authHeaders, authQuery = UniversalProviderRegistry.buildAuthHeaders({
		style = profile.authStyle or protocol.authStyle,
		headerName = profile.authHeaderName or protocol.authHeaderName,
		queryParam = profile.authQueryParam or protocol.authQueryParam,
	}, apiKey)
	for key, value in authHeaders do
		headers[key] = value
	end
	for key, value in (profile.defaultHeaders or {}) do
		headers[key] = value
	end
	for key, value in (profile.extraHeaders or {}) do
		headers[key] = value
	end
	if authQuery then
		url ..= (if string.find(url, "?", 1, true) then "&" else "?") .. authQuery
	end

	local response = UniversalHTTPClient.get(url, headers, {
		timeoutMs = profile.timeoutMs,
		label = "models",
		shouldCancel = shouldCancel,
	})

	if not response.ok then
		local normalised = ProviderErrorNormalizer.normalise({
			provider = profile.displayName,
			model = profile.modelId,
			endpoint = url,
			statusCode = response.statusCode,
			body = response.body,
			headers = response.headers,
			transportError = response.transportError,
			elapsedMs = response.durationMs,
		})
		return nil, normalised.message
	end

	local decoded = require(script.Parent.Parent.Utilities.JSONValidator).decode(response.body)
	if type(decoded) ~= "table" then
		return nil, "The /models response was not a JSON object."
	end

	local list = decoded.data or decoded.models
	if type(list) ~= "table" then
		return nil, "The /models response did not contain a model array."
	end

	local ids: { string } = {}
	for _, entry in list do
		if type(entry) == "string" then
			ids[#ids + 1] = entry
		elseif type(entry) == "table" and type(entry.id) == "string" then
			ids[#ids + 1] = entry.id
		elseif type(entry) == "table" and type(entry.name) == "string" then
			-- Gemini returns "models/gemini-2.0-flash".
			ids[#ids + 1] = (string.gsub(entry.name, "^models/", ""))
		end
	end
    if profile.viaRouter and profile.routerAlias then
        local prefix = profile.routerAlias .. "/"
        local filtered = {}
        for _, id in ids do if string.sub(id, 1, #prefix) == prefix then filtered[#filtered + 1] = id end end
        ids = filtered
    end
	table.sort(ids)
	return ids, nil
end

--=============================================================================
-- STREAMING WITH RETRY
--=============================================================================

export type StreamCallbacks = {
	onActivity: (() -> ())?,
	onReset: (() -> ())?,
	onText: ((delta: string) -> ())?,
	onReasoning: ((delta: string) -> ())?,
	onDone: ((result: any) -> ())?,
	onError: ((normalised: ProviderErrorNormalizer.Normalised, attempts: number) -> ())?,
	onWait: ((waitSeconds: number, decision: RetryDelayCalculator.Decision, attempt: number) -> ())?,
	onAttempt: ((attempt: number) -> ())?,
	shouldCancel: (() -> boolean)?,
	operationId: string?,
	taskId: string?,
}

--- Retries one provider turn; tool execution happens only after a complete result.
function ProviderService.stream(profile: any, spec: any, apiKey: string?, callbacks: StreamCallbacks)
	local prepared, prepareError = ProviderService.prepare(profile, spec, apiKey, nil)
	if not prepared then
		if callbacks.onError then
			callbacks.onError(ProviderErrorNormalizer.normalise({
				provider = profile.displayName, model = profile.modelId, endpoint = profile.baseUrl,
				transportError = prepareError or "Could not build the request.", elapsedMs = 0,
			}), 0)
		end
		return
	end

	if not prepared.streaming then
		Logger.info("Streaming", "Streaming unavailable; using a single response.", {
			detail = UniversalProviderRegistry.getProtocol(profile.protocol).label,
		})
		local result = ProviderService.complete(profile, spec, apiKey, {
			operationId = callbacks.operationId, taskId = callbacks.taskId,
			onWait = callbacks.onWait, onAttempt = callbacks.onAttempt, shouldCancel = callbacks.shouldCancel,
		})
		if result.ok and result.response then
			if callbacks.onText and (result.response.text or "") ~= "" then callbacks.onText(result.response.text) end
			if callbacks.onReasoning and result.response.reasoning then callbacks.onReasoning(result.response.reasoning) end
			if callbacks.onDone then
				local response = table.clone(result.response)
				response.durationMs = result.durationMs
				response.attempts = result.attempts
				callbacks.onDone(response)
			end
		elseif callbacks.onError then
			callbacks.onError(result.error, result.attempts)
		end
		return
	end

	local adapter = ProviderService.getAdapter(profile.protocol)
	local currentText = ""
	local currentReasoning = ""
	local bestText = ""
	local bestReasoning = ""
	local operation = SmartAutoRetryManager.run({
		operationId = callbacks.operationId, taskId = callbacks.taskId,
		providerId = profile.id, providerName = profile.displayName or "Provider",
		model = profile.modelId or "(not set)", endpoint = endpointKey(profile),
		config = ProviderService.getRetryConfig(profile),
		onWait = callbacks.onWait, onAttempt = callbacks.onAttempt, shouldCancel = callbacks.shouldCancel,
		request = function(attemptIndex)
			if attemptIndex > 1 and callbacks.onReset then callbacks.onReset() end
			currentText = ""
			currentReasoning = ""
			local streamState = adapter.newStreamState()
			local streamError: string? = nil
			local errorInfo: any = {}
			local providerDone = false
			local settled = false
			local cancelled = false
			local lastActivity = os.clock()
			local statusCode: number? = nil
			local responseHeaders: { [string]: string } = {}
			local function activity()
				lastActivity = os.clock()
				if callbacks.onActivity then callbacks.onActivity() end
			end
			local function failed(message: string, info: any?)
				streamError = message
				if type(info) == "table" then errorInfo = info end
			end

			ProviderRateLimitScheduler.recordRequest(profile.id, profile.modelId, endpointKey(profile))
			local handle, openError = UniversalHTTPClient.stream({
				url = prepared.url, headers = prepared.headers, body = prepared.body,
				timeoutMs = profile.timeoutMs, label = profile.displayName,
			}, {
				onActivity = function() if not settled then activity() end end,
				onOpen = function(status, headers) statusCode = status; responseHeaders = headers or {}; activity() end,
				onChunk = function(chunk)
					if settled or cancelled then return end
					activity()
					for _, event in adapter.parseStreamChunk(streamState, chunk) do
						if event.kind == "text" and event.text then
							currentText ..= event.text
							if callbacks.onText then callbacks.onText(event.text) end
						elseif event.kind == "reasoning" and event.reasoning then
							currentReasoning ..= event.reasoning
							if callbacks.onReasoning then callbacks.onReasoning(event.reasoning) end
						elseif event.kind == "done" then
							providerDone = true
						elseif event.kind == "error" and event.message then
							failed(event.message, { body = event.body or event.message })
						end
					end
				end,
				onError = function(message, info) if not settled then failed(message, info) end end,
				onComplete = function() end,
			})
			if not handle then
				-- A failed connection is a retryable attempt, not a second request
				-- hidden inside a fallback retry loop.
				return nil, { transportError = openError or "Could not open the provider stream." }
			end

			local idleSeconds = math.clamp((profile.timeoutMs or 120000) / 1000, 1, 600)
			while not handle.isDone() and not providerDone and not streamError do
				if callbacks.shouldCancel and callbacks.shouldCancel() then cancelled = true; break end
				if os.clock() - lastActivity >= idleSeconds then
					streamError = "Provider stream timed out: no upstream data within the configured idle timeout."
					break
				end
				task.wait()
			end
			settled = true
			if not handle.isDone() then handle.cancel() end
			if callbacks.shouldCancel and callbacks.shouldCancel() then cancelled = true end
			if cancelled then return nil, { transportError = "Cancelled." } end
			local stopReason = streamState.finishReason or streamState.stopReason or streamState.status
			if not streamError and not providerDone and not stopReason and profile.protocol ~= "custom_rest" then
				streamError = "The provider connection closed before a completion marker. The partial answer was preserved."
			end
			if streamError then
				if #currentText > #bestText then bestText = currentText; bestReasoning = currentReasoning end
				errorInfo.statusCode = errorInfo.statusCode or statusCode
				errorInfo.headers = errorInfo.headers or responseHeaders
				if not errorInfo.body then errorInfo.transportError = errorInfo.transportError or streamError end
				errorInfo.streamInterrupted = #currentText > 0 or #currentReasoning > 0
				return nil, errorInfo
			end
			return {
				text = currentText, reasoning = if currentReasoning ~= "" then currentReasoning else nil,
				toolCalls = adapter.finalizeStream(streamState), usage = adapter.streamStateUsage(streamState),
				stopReason = stopReason,
			}, nil
		end,
	})

	if operation.ok then
		local result = operation.value
		result.durationMs = operation.totalElapsedSeconds * 1000
		result.attempts = operation.attemptsMade
		if callbacks.onDone then callbacks.onDone(result) end
	else
		-- Failed retries must not erase an answer received before a disconnect.
		-- Partial tool calls are never restored or executed.
		if not operation.cancelled and #bestText > #currentText then
			if callbacks.onReset then callbacks.onReset() end
			if callbacks.onText then callbacks.onText(bestText) end
			if callbacks.onReasoning and bestReasoning ~= "" then callbacks.onReasoning(bestReasoning) end
		end
		local normalised = if operation.cancelled then ProviderErrorNormalizer.normalise({
			provider = profile.displayName, model = profile.modelId, endpoint = profile.baseUrl,
			transportError = "Cancelled.", elapsedMs = operation.totalElapsedSeconds * 1000,
		}) else operation.error
		if callbacks.onError then callbacks.onError(normalised, operation.attemptsMade) end
	end
end

return ProviderService
