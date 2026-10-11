--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Utilities / UniversalHTTPClient
	The single transport layer. Every provider adapter goes through here.

	Responsibilities
	  * URL validation and HTTPS enforcement
	  * Request IDs (ForgePilot's own, plus provider ids from the response)
	  * Timeout management and caller-enforced deadlines
	  * Response header collection
	  * Streaming via CreateWebStreamClient with guaranteed cleanup
	  * Sanitised logging (never logs headers, keys or bodies)
	  * Error normalisation hooks

	Retry is deliberately NOT here: one SmartAutoRetryManager owns retries for an
	entire operation so retry loops can never be nested.
]]

local BaseURLResolver = require(script.Parent.Parent.AI.BaseURLResolver)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Logger = require(script.Parent.Logger)
local Redact = require(script.Parent.Redact)
local StringUtil = require(script.Parent.StringUtil)
local JSONValidator = require(script.Parent.JSONValidator)

local Time = require(script.Parent.Time)

local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local UniversalHTTPClient = {}

--=============================================================================
-- TYPES
--=============================================================================

export type Headers = { [string]: string }

export type Response = {
	ok: boolean,
	statusCode: number?,
	statusMessage: string?,
	headers: Headers,
	body: string,
	durationMs: number,
	requestId: string?,
	url: string,
	transportError: string?,
}

export type RequestOptions = {
	headers: Headers?,
	json: any?,
	body: string?,
	timeoutMs: number?,
	shouldCancel: (() -> boolean)?,
	label: string?,
	method: "GET" | "POST" | "PUT" | "DELETE" | "PATCH"?,
	accept: string?,
}

--=============================================================================
-- CAPABILITIES
--=============================================================================

local streamingAvailable: boolean? = nil

--- Probes HttpService once and caches the answer.
function UniversalHTTPClient.supportsStreaming(): boolean
	if BridgeClient.isConnected() then return true end
	if streamingAvailable ~= nil then
		return streamingAvailable
	end
	local ok, result = pcall(function()
		return typeof(HttpService.CreateWebStreamClient) == "function"
	end)
	streamingAvailable = ok and result == true
	return streamingAvailable
end

function UniversalHTTPClient.resetCapabilityCache()
	streamingAvailable = nil
end

--=============================================================================
-- INTERNAL
--=============================================================================

local MAX_ERROR_BODY = 4000
local requestCounter = 0

local function nextRequestId(): string
	requestCounter += 1
	return string.format("fp-%d-%d", math.floor(os.clock() * 1000) % 100000, requestCounter)
end

local function headerMap(raw: any): Headers
	local out: Headers = {}
	if type(raw) ~= "table" then
		return out
	end
	for key, value in raw do
		out[string.lower(tostring(key))] = tostring(value)
	end
	return out
end

--- Finds the provider's own request id in a response.
local function extractProviderRequestId(headers: Headers): string?
	for _, name in { "x-request-id", "request-id", "openai-request-id", "anthropic-request-id", "cf-ray" } do
		local value = headers[name]
		if type(value) == "string" and #value > 0 then
			return Redact.scrubText(value)
		end
	end
	return nil
end

--- Validates a URL before anything is sent.
function UniversalHTTPClient.validateUrl(url: string): (string?, string?)
	return BaseURLResolver.normaliseBase(url)
end

local function buildFailure(url: string, message: string, started: number, requestId: string): Response
	return {
		ok = false,
		statusCode = nil,
		statusMessage = nil,
		headers = {},
		body = "",
		durationMs = (os.clock() - started) * 1000,
		requestId = requestId,
		url = url,
		transportError = Redact.scrubText(message),
	}
end

--=============================================================================
-- REQUEST
--=============================================================================

--- Performs one HTTP request. Never retries; never throws.
function UniversalHTTPClient.request(url: string, options: RequestOptions?): Response
	local opts = options or {}
	local started = os.clock()
	local requestId = nextRequestId()

	local normalised, urlError = UniversalHTTPClient.validateUrl(url)
	if not normalised then
		return buildFailure(url, urlError or "Invalid URL.", started, requestId)
	end
	url = normalised

	local headers: Headers = table.clone(opts.headers or {})
	if opts.accept then
		headers["Accept"] = opts.accept
	end

	local bodyText: string? = opts.body
	if bodyText == nil and opts.json ~= nil then
		local encoded = JSONValidator.encode(opts.json)
		if type(encoded) ~= "string" or encoded == "" then
			return buildFailure(url, "Could not serialise the request body to JSON.", started, requestId)
		end
		bodyText = encoded
		headers["Content-Type"] = headers["Content-Type"] or "application/json"
	end

	local request = {
		Url = url,
		Method = opts.method or "POST",
		Headers = headers,
	}
	if bodyText then
		request.Body = bodyText
	end
	if opts.timeoutMs and opts.timeoutMs > 0 and opts.timeoutMs <= 30000 then
		-- Roblox accepts an integer that shortens its native request timeout.
		-- Longer caller deadlines are enforced below, rather than sent as an
		-- unsupported attempt to extend the engine timeout.
		request.Timeout = math.max(1, math.ceil(opts.timeoutMs / 1000))
	end

	Logger.debug("Connection", string.format("%s %s", request.Method, BaseURLResolver.forDisplay(url)), {
		detail = string.format("request %s", requestId),
	})

	local done = false
	local ok, response = false, nil :: any
	if opts.shouldCancel and opts.shouldCancel() then
		return buildFailure(url, "Cancelled.", started, requestId)
	end
	local worker = task.spawn(function()
		ok, response = pcall(HttpService.RequestAsync, HttpService, request)
		done = true
	end)
	local deadline = started + math.max(1, opts.timeoutMs or 120000) / 1000
	while not done do
		local cancelled = opts.shouldCancel and opts.shouldCancel()
		if cancelled or os.clock() >= deadline then
			-- Some engine yield states cannot be cancelled. Their eventual result
			-- is discarded; this caller and its UI do not wait for it.
			pcall(task.cancel, worker)
			return buildFailure(url, if cancelled then "Cancelled." else "Request timed out.", started, requestId)
		end
		task.wait(0.05)
	end
	local durationMs = (os.clock() - started) * 1000

	if not ok then
		local message = ErrorHandler.describe(response)
		Logger.error("Connection", "Request failed before a response.", {
			detail = string.format("%s · %s", BaseURLResolver.forDisplay(url), message),
		})
		return buildFailure(url, message, started, requestId)
	end

	local statusCode = tonumber(response.StatusCode)
	local success = statusCode ~= nil and statusCode >= 200 and statusCode < 300
	local textBody: string = if type(response.Body) == "string"
		then response.Body
		else if response.Body ~= nil then tostring(response.Body) else ""

	if not success and #textBody > MAX_ERROR_BODY then
		textBody = string.sub(textBody, 1, MAX_ERROR_BODY) .. "\n…(truncated)"
	end

	local parsedHeaders = headerMap(response.Headers)

	local result: Response = {
		ok = success,
		statusCode = statusCode,
		statusMessage = response.StatusMessage,
		headers = parsedHeaders,
		body = textBody,
		durationMs = durationMs,
		requestId = extractProviderRequestId(parsedHeaders),
		url = url,
		transportError = nil,
	}

	-- A 200 that actually carries a provider error object is NOT a success.
	if success then
		local okDetect, isError = pcall(function()
			return require(script.Parent.UniversalErrorDetector).bodyIsError(textBody)
		end)
		if okDetect and isError then
			result.ok = false
		end
	end

	-- Headers are never logged; only a safe summary is.
	Logger.debug("Connection", string.format("%s → HTTP %s in %.0f ms", opts.label or "request", tostring(statusCode), durationMs), {
		detail = string.format("request %s", requestId),
	})

	return result
end

--- POSTs a JSON body.
function UniversalHTTPClient.postJson(url: string, headers: Headers?, json: any, options: { timeoutMs: number?, label: string?, shouldCancel: (() -> boolean)? }?): Response
	local opts = options or {}
	return UniversalHTTPClient.request(url, {
		method = "POST",
		headers = headers,
		json = json,
		timeoutMs = opts.timeoutMs,
		label = opts.label,
		shouldCancel = opts.shouldCancel,
		accept = "application/json",
	})
end

--- GETs a resource.
function UniversalHTTPClient.get(url: string, headers: Headers?, options: { timeoutMs: number?, label: string?, accept: string?, shouldCancel: (() -> boolean)? }?): Response
	local opts = options or {}
	return UniversalHTTPClient.request(url, {
		method = "GET",
		headers = headers,
		timeoutMs = opts.timeoutMs,
		label = opts.label,
		shouldCancel = opts.shouldCancel,
		accept = opts.accept or "application/json",
	})
end

--=============================================================================
-- STREAMING
--=============================================================================

export type StreamCallbacks = {
	onActivity: (() -> ())?,
	onOpen: ((statusCode: number?, headers: Headers) -> ())?,
	onActivity: (() -> ())?,
	onChunk: ((chunk: string) -> ())?,
	onComplete: ((body: string, durationMs: number, requestId: string?) -> ())?,
	onError: ((message: string, info: any?) -> ())?,
}

export type StreamHandle = {
	cancel: () -> (),
	isCancelled: () -> boolean,
	isDone: () -> boolean,
	--- Server-Sent Events frames already decoded. Useful for SSE error events.
	frames: { string },
}

--- Opens a streaming request and delivers SSE bytes through callbacks.
---
--- Uses the documented WebStreamClient surface: the body is supplied up front and
--- chunks arrive on the `MessageReceived` signal. Every exit path calls Close()
--- exactly once.
function UniversalHTTPClient.stream(request: {
	url: string,
	headers: Headers,
	body: string,
	timeoutMs: number,
	label: string,
}, callbacks: StreamCallbacks): (StreamHandle?, string?)
    if BridgeClient.isConnected() then return BridgeClient.stream(request, callbacks) end
	if not UniversalHTTPClient.supportsStreaming() then
		return nil,
			"This Studio build does not expose HttpService:CreateWebStreamClient, so streaming is unavailable. Non-streaming requests still work."
	end

	local normalised, urlError = BaseURLResolver.normaliseBase(request.url)
	if not normalised then
		return nil, urlError
	end

	local headers: Headers = table.clone(request.headers)
	headers["Accept"] = "text/event-stream"

	-- HttpService:CreateWebStreamClient(streamClientType, requestOptions).
	-- Enum.WebStreamClientType is { SSE, RawStream, WebSocket } — there is no
	-- "HttpRequest" member. RawStream preserves SSE event names and framing for the adapters.
	-- The body travels in requestOptions.Body and the response arrives through the
	-- client's signals; WebStreamClient has no Write/Flush/ReadChunk members.
	local opened, client = pcall(HttpService.CreateWebStreamClient, HttpService, Enum.WebStreamClientType.RawStream, {
		Url = normalised,
		Method = "POST",
		Headers = headers,
		Body = request.body,
	})

	if not opened or client == nil then
		return nil, "Could not open a stream: " .. ErrorHandler.describe(client)
	end

	local cancelled = false
	local closed = false
	local finished = false
	local started = os.clock()
	local lastDataAt = started
	local frames: { string } = {}
	local collected: { string } = {}

	local function safeClose()
		if closed then
			return
		end
		closed = true
		pcall(function()
			client:Close()
		end)
	end

	local function finishComplete()
		if finished or cancelled then
			return
		end
		finished = true
		safeClose()
		if callbacks.onComplete then
            local ok = pcall(callbacks.onComplete, table.concat(collected), (os.clock() - started) * 1000, nil)
            if not ok and callbacks.onError then pcall(callbacks.onError, "Stream completion callback failed.") end
		end
	end

	local function finishError(message: string, info: any?)
		if finished or cancelled then
			return
		end
		finished = true
		safeClose()
		if callbacks.onError then pcall(callbacks.onError, message, info) end
	end

	-- Idle watchdog: a provider that accepts the connection and then goes quiet.
	local idleWatchdog = math.max(1, (request.timeoutMs or 120000) / 1000)
	task.spawn(function()
		repeat
			task.wait(1)
		until cancelled or finished or (os.clock() - lastDataAt) > idleWatchdog
		if not cancelled and not finished then
			finishError(
				"No data received within the configured timeout. The provider may not support streaming on this endpoint."
			)
		end
	end)

	client.MessageReceived:Connect(function(chunk)
		if cancelled or finished then
			return
		end
		if type(chunk) == "string" and #chunk > 0 then
			lastDataAt = os.clock()
			collected[#collected + 1] = chunk
			frames[#frames + 1] = chunk
            if callbacks.onChunk or callbacks.onActivity then
                local ok = pcall(function()
                    if callbacks.onActivity then callbacks.onActivity() end
                    if callbacks.onChunk then callbacks.onChunk(chunk) end
                end)
                if not ok then finishError("Stream processing failed. Check Logs, then retry the request.") end
			end
		end
	end)

	client.Error:Connect(function(status, message)
		finishError(if type(message) == "string" then ("HTTP " .. tostring(status) .. ": " .. message) else ErrorHandler.describe(status), {
			statusCode = tonumber(status), body = if type(message) == "string" then message else nil,
		})
	end)

	client.Closed:Connect(function()
		finishComplete()
	end)

	local handle: StreamHandle = {
		frames = frames,
		cancel = function()
			cancelled = true
			finished = true
			safeClose()
		end,
		isCancelled = function()
			return cancelled
		end,
		isDone = function()
			return finished or cancelled
		end,
	}

	Logger.debug("Connection", string.format("stream opened: %s", BaseURLResolver.forDisplay(normalised)), {
		detail = Time.timestamp(),
	})
	return handle, nil
end

--- Splits a raw SSE byte stream into decoded `data:` payloads.
--- Shared by every adapter so the framing rules cannot drift between them.
function UniversalHTTPClient.streamSse(raw: string): { string }
	local payloads: { string } = {}
	for frame in string.gmatch(raw or "", "(.-)\n\n") do
		for line in (frame .. "\n"):gmatch("(.-)\r?\n") do
			if string.sub(line, 1, 6) == "data: " then
				payloads[#payloads + 1] = string.sub(line, 7)
			elseif string.sub(line, 1, 5) == "data:" then
				payloads[#payloads + 1] = StringUtil.trim(string.sub(line, 6))
			end
		end
	end
	return payloads
end

--- Extracts an SSE `event:` name plus its `data:` payload from one frame.
function UniversalHTTPClient.parseSseFrame(frame: string): { name: string?, data: string? }
	local name: string? = nil
	local dataLines: { string } = {}
	for line in (frame .. "\n"):gmatch("(.-)\r?\n") do
		if string.sub(line, 1, 7) == "event: " then
			name = StringUtil.trim(string.sub(line, 9))
		elseif string.sub(line, 1, 6) == "data: " then
			dataLines[#dataLines + 1] = string.sub(line, 7)
		elseif string.sub(line, 1, 5) == "data:" then
			dataLines[#dataLines + 1] = StringUtil.trim(string.sub(line, 6))
		end
	end
	return { name = name, data = if #dataLines > 0 then table.concat(dataLines, "") else nil }
end

return UniversalHTTPClient
