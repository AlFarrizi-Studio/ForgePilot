--!strict
--[[
	ForgePilot / AI / ProviderErrorNormalizer
	Turns any transport outcome into one stable error shape.

	Every field is either read from the response or explicitly nil. Missing
	metadata is never invented — `confidence` and `classificationSource` tell the
	caller how much to trust the result.
]]

local BaseURLResolver = require(script.Parent.BaseURLResolver)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local UniversalErrorDetector = require(script.Parent.Parent.Utilities.UniversalErrorDetector)

local ProviderErrorNormalizer = {}

export type Normalised = {
	provider: string,
	model: string,
	category: string,
	httpStatus: number?,
	providerCode: string?,
	message: string,
	requestId: string?,
	endpoint: string,
	retryable: boolean,
	retryAfterMs: number?,
	retryAfterSource: string?,
	rateLimit: {
		limit: number?,
		windowMs: number?,
		estimated: boolean,
	},
	upstreamRetry: {
		present: boolean,
		attempt: number?,
		delaySeconds: number?,
	},
	classificationSource: string,
	confidence: number,
	elapsedMs: number,
	timestamp: number,
}

--=============================================================================
-- REQUEST ID
--=============================================================================

local REQUEST_ID_HEADERS = {
	"x-request-id",
	"request-id",
	"x-requestid",
	"x-correlation-id",
	"cf-ray",
	"x-amzn-requestid",
	"openai-request-id",
	"anthropic-request-id",
	"x-goog-request-id",
}

--- Extracts a provider request id from headers or from the error body.
function ProviderErrorNormalizer.findRequestId(
	headers: { [string]: string }?,
	body: string?
): string?
	local lookup = headers or {}
	for _, name in REQUEST_ID_HEADERS do
		local value = lookup[name]
		if type(value) == "string" and #value > 0 then
			return Redact.scrubText(value)
		end
	end

	if type(body) == "string" then
		-- "(request id: 20261010...)" — a very common localised format.
		local fromText = string.match(body, "%(request%s+id:%s*([^%)]+)%)")
		if fromText then
			return Redact.scrubText(StringUtil.trim(fromText))
		end
		local fromJson = string.match(body, '"request_?id"%s*:%s*"([^"]+)"')
		if fromJson then
			return Redact.scrubText(fromJson)
		end
	end
	return nil
end

--=============================================================================
-- NORMALISE
--=============================================================================

export type Input = {
	provider: string,
	model: string,
	endpoint: string,
	statusCode: number?,
	body: string?,
	headers: { [string]: string }?,
	transportError: string?,
	streamInterrupted: boolean?,
	elapsedMs: number,
}

function ProviderErrorNormalizer.normalise(input: Input): Normalised
	local classification = UniversalErrorDetector.classify({
		statusCode = input.statusCode,
		body = input.body,
		headers = input.headers,
		transportError = input.transportError,
		streamInterrupted = input.streamInterrupted,
	})

	local message = classification.message
	if type(message) ~= "string" or #message == 0 then
		message = if input.transportError
			then Redact.scrubText(input.transportError)
			else string.format("Provider returned HTTP %s with no message.", tostring(input.statusCode))
	end

	local category = classification.category
	local neverRetry = UniversalErrorDetector.NEVER_RETRY[category] == true

	return {
		provider = input.provider or "Unknown provider",
		model = input.model or "(not set)",
		category = category,
		httpStatus = input.statusCode,
		providerCode = classification.providerCode,
		message = Redact.scrubText(message),
		requestId = ProviderErrorNormalizer.findRequestId(input.headers, input.body),
		endpoint = BaseURLResolver.forDisplay(input.endpoint),
		retryable = (not neverRetry) and UniversalErrorDetector.isRetryable(category),
		retryAfterMs = nil,
		retryAfterSource = nil,
		rateLimit = {
			limit = classification.rateWindow.limit,
			windowMs = classification.rateWindow.windowMs,
			estimated = false,
		},
		upstreamRetry = classification.upstreamRetry,
		classificationSource = classification.source,
		confidence = classification.confidence,
		elapsedMs = input.elapsedMs or 0,
		timestamp = os.clock(),
	}
end

--=============================================================================
-- DISPLAY
--=============================================================================

local CATEGORY_HEADLINES: { [string]: string } = {
	RATE_LIMITED = "Provider Rate Limited",
	CONCURRENCY_LIMITED = "Too Many Concurrent Requests",
	PROVIDER_OVERLOADED = "Provider Overloaded",
	QUOTA_WINDOW_EXHAUSTED = "Quota Window Exhausted",
	DAILY_QUOTA_EXHAUSTED = "Daily Quota Exhausted",
	INSUFFICIENT_CREDITS = "Insufficient Credits",
	INVALID_API_KEY = "Invalid API Key",
	INVALID_MODEL = "Invalid Model",
	INVALID_ENDPOINT = "Invalid Endpoint",
	INVALID_REQUEST = "Invalid Request",
	CONTEXT_LENGTH_EXCEEDED = "Context Window Exceeded",
	UNSUPPORTED_FEATURE = "Unsupported Feature",
	INVALID_ATTACHMENT = "Invalid Attachment",
	CONTENT_FILTERED = "Blocked By Content Filter",
	PERMISSION_DENIED = "Permission Denied",
	SERVER_ERROR = "Provider Server Error",
	NETWORK_ERROR = "Network Error",
	TIMEOUT = "Request Timed Out",
	STREAM_INTERRUPTED = "Stream Interrupted",
	UNKNOWN_ERROR = "Unknown Provider Error",
}

function ProviderErrorNormalizer.headline(category: string): string
	return CATEGORY_HEADLINES[category] or "Provider Error"
end

--- A short, actionable hint. Never suggests something impossible.
function ProviderErrorNormalizer.remedy(category: string, normalised: Normalised?): string?
	if category == "RATE_LIMITED" then
		if normalised and normalised.rateLimit.limit and normalised.rateLimit.windowMs then
			return string.format(
				"The provider allows %d request(s) per %d seconds. ForgePilot will wait for the window to clear.",
				normalised.rateLimit.limit,
				math.floor(normalised.rateLimit.windowMs / 1000)
			)
		end
		return "ForgePilot will wait for the rate-limit window to clear before retrying."
	elseif category == "INVALID_API_KEY" then
		return "Check the API Key field in Settings. Keys are never auto-retried."
	elseif category == "INVALID_MODEL" then
		return "Check the Model ID, or use Refresh Models to list what this provider serves."
	elseif category == "INVALID_ENDPOINT" then
		return "Check the Base URL and Endpoint Path. ForgePilot will not guess other endpoints."
	elseif category == "CONTEXT_LENGTH_EXCEEDED" then
		return "Shorten the conversation, remove attachments, or raise Max Output Tokens / Context Window in Settings."
	elseif category == "INSUFFICIENT_CREDITS" or category == "DAILY_QUOTA_EXHAUSTED" then
		return "Top up or wait for the quota period to reset. ForgePilot will not keep retrying."
	elseif category == "PERMISSION_DENIED" then
		return "This key may not have access to that model or region."
	elseif category == "CONTENT_FILTERED" then
		return "The provider blocked this request. Rephrase the prompt or attached content."
	elseif category == "INVALID_ATTACHMENT" then
		return "Try a different file, or a smaller one."
	elseif category == "STREAM_INTERRUPTED" then
		return "The connection dropped mid-response. Retrying resumes the request from the start."
	end
	return nil
end

--=============================================================================
-- LOG FORMATTING
--=============================================================================

--- Renders one sanitised line for the Activity Logs panel.
function ProviderErrorNormalizer.formatForLog(normalised: Normalised): string
	local parts: { string } = {}
	parts[#parts + 1] = normalised.category
	if normalised.httpStatus then
		parts[#parts + 1] = "HTTP " .. tostring(normalised.httpStatus)
	end
	if normalised.providerCode then
		parts[#parts + 1] = "code " .. normalised.providerCode
	end
	if normalised.requestId then
		parts[#parts + 1] = "request " .. normalised.requestId
	end
	parts[#parts + 1] = string.format(
		"(%s, confidence %.2f)",
		normalised.classificationSource,
		normalised.confidence
	)
	return table.concat(parts, "  ·  ") .. "\n" .. normalised.message
end

return ProviderErrorNormalizer