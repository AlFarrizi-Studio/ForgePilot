--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Utilities / UniversalErrorDetector
	Classifies provider failures regardless of language or shape.

	DETECTION PRIORITY (highest first)
	  1. HTTP status
	  2. Structured provider error code
	  3. Provider error category
	  4. Response headers
	  5. Documented provider error schema
	  6. Multilingual message classification
	  7. Unknown fallback

	CRITICAL GUARANTEE
	The detector only ever runs on FAILURE paths: a non-2xx status, a 2xx body
	that carries a provider error object, an SSE error event, or a transport
	error. It is never applied to ordinary assistant chat text, so a user asking
	"why does 429 mean rate limited?" can never trigger a retry.
]]

local Redact = require(script.Parent.Redact)

local UniversalErrorDetector = {}

--=============================================================================
-- CATEGORIES
--=============================================================================

export type Category =
	| "RATE_LIMITED"
	| "CONCURRENCY_LIMITED"
	| "PROVIDER_OVERLOADED"
	| "QUOTA_WINDOW_EXHAUSTED"
	| "DAILY_QUOTA_EXHAUSTED"
	| "INSUFFICIENT_CREDITS"
	| "INVALID_API_KEY"
	| "INVALID_MODEL"
	| "INVALID_ENDPOINT"
	| "INVALID_REQUEST"
	| "CONTEXT_LENGTH_EXCEEDED"
	| "UNSUPPORTED_FEATURE"
	| "INVALID_ATTACHMENT"
	| "CONTENT_FILTERED"
	| "PERMISSION_DENIED"
	| "SERVER_ERROR"
	| "NETWORK_ERROR"
	| "TIMEOUT"
	| "STREAM_INTERRUPTED"
	| "UNKNOWN_ERROR"

local categories: { [string]: Category } = {
	RATE_LIMITED = "RATE_LIMITED",
	CONCURRENCY_LIMITED = "CONCURRENCY_LIMITED",
	PROVIDER_OVERLOADED = "PROVIDER_OVERLOADED",
	QUOTA_WINDOW_EXHAUSTED = "QUOTA_WINDOW_EXHAUSTED",
	DAILY_QUOTA_EXHAUSTED = "DAILY_QUOTA_EXHAUSTED",
	INSUFFICIENT_CREDITS = "INSUFFICIENT_CREDITS",
	INVALID_API_KEY = "INVALID_API_KEY",
	INVALID_MODEL = "INVALID_MODEL",
	INVALID_ENDPOINT = "INVALID_ENDPOINT",
	INVALID_REQUEST = "INVALID_REQUEST",
	CONTEXT_LENGTH_EXCEEDED = "CONTEXT_LENGTH_EXCEEDED",
	UNSUPPORTED_FEATURE = "UNSUPPORTED_FEATURE",
	INVALID_ATTACHMENT = "INVALID_ATTACHMENT",
	CONTENT_FILTERED = "CONTENT_FILTERED",
	PERMISSION_DENIED = "PERMISSION_DENIED",
	SERVER_ERROR = "SERVER_ERROR",
	NETWORK_ERROR = "NETWORK_ERROR",
	TIMEOUT = "TIMEOUT",
	STREAM_INTERRUPTED = "STREAM_INTERRUPTED",
	UNKNOWN_ERROR = "UNKNOWN_ERROR",
}

UniversalErrorDetector.Categories = categories

--- Categories a Smart Retry controller may retry automatically.
local RETRYABLE: { [string]: boolean } = {
	RATE_LIMITED = true,
	CONCURRENCY_LIMITED = true,
	PROVIDER_OVERLOADED = true,
	QUOTA_WINDOW_EXHAUSTED = true,
	SERVER_ERROR = true,
	NETWORK_ERROR = true,
	TIMEOUT = true,
	STREAM_INTERRUPTED = true,
	UNKNOWN_ERROR = false,
}

--- Categories that must never be retried automatically.
local NEVER_RETRY: { [string]: boolean } = {
	INVALID_API_KEY = true,
	INVALID_MODEL = true,
	INVALID_ENDPOINT = true,
	PERMISSION_DENIED = true,
	INSUFFICIENT_CREDITS = true,
	DAILY_QUOTA_EXHAUSTED = true,
	CONTEXT_LENGTH_EXCEEDED = true,
	UNSUPPORTED_FEATURE = true,
	CONTENT_FILTERED = true,
}

UniversalErrorDetector.RETRYABLE = RETRYABLE
UniversalErrorDetector.NEVER_RETRY = NEVER_RETRY

--=============================================================================
-- BODY DECODING
--=============================================================================

--- Decodes an error body.
---
--- Providers routinely append human text to their JSON — a request id, a
--- bracketed retry notice, a stack hint. Decoding the WHOLE body then fails, so
--- the leading balanced JSON object is extracted as a fallback. Anything that is
--- not JSON at all is returned as nil so the text rules can still run.
local function decodeErrorBody(body: any): any
	if type(body) ~= "string" or #body == 0 then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
	if ok and type(decoded) == "table" then
		return decoded
	end

	-- Fall back to the leading balanced object.
	local JSONValidator = require(script.Parent.JSONValidator)
	local extracted = JSONValidator.extractObject(body)
	if extracted and type(extracted) == "table" then
		return extracted
	end
	return nil
end

--=============================================================================
-- CLASSIFICATION TABLES
--=============================================================================
-- Patterns live in Utilities/UniversalPatternTables so they can be extended
-- without touching this file. Every row is a plain literal: no alternation, no
-- non-capturing groups, no multi-byte character classes. The first match wins.

local Tables = require(script.Parent.UniversalPatternTables)

type Row = { pattern: string, category: Category }

local function rows(list: { string }, category: Category): { Row }
	local out: { Row } = {}
	for index, pattern in list do
		out[index] = { pattern = pattern, category = category }
	end
	return out
end

local RATE_LIMIT_ROWS = rows(Tables.RATE_LIMIT, "RATE_LIMITED")
local CONCURRENCY_ROWS = rows(Tables.CONCURRENCY, "CONCURRENCY_LIMITED")
local OVERLOAD_ROWS = rows(Tables.OVERLOAD, "PROVIDER_OVERLOADED")
local QUOTA_DAILY_ROWS = rows(Tables.DAILY_QUOTA, "DAILY_QUOTA_EXHAUSTED")

--- A window/plan rate limit is distinct from a plain rate limit, so it is
--- matched first and separately.
local QUOTA_WINDOW_ROWS: { Row } = {
	{ pattern = "exceeded your current quota", category = "QUOTA_WINDOW_EXHAUSTED" },
	{ pattern = "quota exceeded", category = "QUOTA_WINDOW_EXHAUSTED" },
	{ pattern = "requests per minute", category = "RATE_LIMITED" },
	{ pattern = "requests per minute", category = "RATE_LIMITED" },
}
local CREDITS_ROWS = rows(Tables.CREDITS, "INSUFFICIENT_CREDITS")
local AUTH_ROWS = rows(Tables.AUTH, "INVALID_API_KEY")
local MODEL_ROWS = rows(Tables.MODEL, "INVALID_MODEL")
local ENDPOINT_ROWS = rows(Tables.ENDPOINT, "INVALID_ENDPOINT")
local REQUEST_ROWS = rows(Tables.REQUEST, "INVALID_REQUEST")
local CONTEXT_ROWS = rows(Tables.CONTEXT, "CONTEXT_LENGTH_EXCEEDED")
local UNSUPPORTED_ROWS = rows(Tables.UNSUPPORTED, "UNSUPPORTED_FEATURE")
local ATTACHMENT_ROWS = rows(Tables.ATTACHMENT, "INVALID_ATTACHMENT")
local FILTER_ROWS = rows(Tables.FILTER, "CONTENT_FILTERED")
local PERMISSION_ROWS = rows(Tables.PERMISSION, "PERMISSION_DENIED")

--=============================================================================-- Order matters: the first matching group wins. A window-specific rate limit is
-- distinguished from a generic rate limit BEFORE the generic table is reached.
local GROUPS: { { name: string, rows: { Row } } } = {
	{ name = "credits", rows = CREDITS_ROWS },
	{ name = "quota_window", rows = QUOTA_WINDOW_ROWS },
	{ name = "daily_quota", rows = QUOTA_DAILY_ROWS },
	{ name = "auth", rows = AUTH_ROWS },
	{ name = "model", rows = MODEL_ROWS },
	{ name = "endpoint", rows = ENDPOINT_ROWS },
	{ name = "attachment", rows = ATTACHMENT_ROWS },
	{ name = "filter", rows = FILTER_ROWS },
	{ name = "context", rows = CONTEXT_ROWS },
	{ name = "unsupported", rows = UNSUPPORTED_ROWS },
	{ name = "permission", rows = PERMISSION_ROWS },
	{ name = "concurrency", rows = CONCURRENCY_ROWS },
	{ name = "rate_limit", rows = RATE_LIMIT_ROWS },
	{ name = "overload", rows = OVERLOAD_ROWS },
	{ name = "request", rows = REQUEST_ROWS },
}

--=============================================================================
-- STRUCTURED CODES
--=============================================================================
-- Providers expose stable machine codes. These win over message text.

local CODE_MAP: { [string]: Category } = {
	["rate_limit_exceeded"] = "RATE_LIMITED",
	["rate_limit"] = "RATE_LIMITED",
	["too_many_requests"] = "RATE_LIMITED",
	["requests_per_minute"] = "RATE_LIMITED",
	["throttling"] = "RATE_LIMITED",
	["resource_exhausted"] = "RATE_LIMITED",
	["overloaded"] = "PROVIDER_OVERLOADED",
	["service_unavailable"] = "PROVIDER_OVERLOADED",
	["high_load"] = "PROVIDER_OVERLOADED",
	["concurrency_limit"] = "CONCURRENCY_LIMITED",
	["quota_exceeded"] = "QUOTA_WINDOW_EXHAUSTED",
	["billing_hard_limit_reached"] = "DAILY_QUOTA_EXHAUSTED",
	["insufficient_quota"] = "INSUFFICIENT_CREDITS",
	["insufficient_credits"] = "INSUFFICIENT_CREDITS",
	["insufficient_balance"] = "INSUFFICIENT_CREDITS",
	["credit_balance_is_too_low"] = "INSUFFICIENT_CREDITS",
	["account_depleted"] = "INSUFFICIENT_CREDITS",
	["invalid_api_key"] = "INVALID_API_KEY",
	["invalid_authentication"] = "INVALID_API_KEY",
	["unauthorized"] = "INVALID_API_KEY",
	["authentication_error"] = "INVALID_API_KEY",
	["model_not_found"] = "INVALID_MODEL",
	["invalid_model"] = "INVALID_MODEL",
	["model_not_available"] = "INVALID_MODEL",
	["not_found"] = "INVALID_ENDPOINT",
	["invalid_url"] = "INVALID_ENDPOINT",
	["invalid_request_error"] = "INVALID_REQUEST",
	["invalid_request"] = "INVALID_REQUEST",
	["bad_request"] = "INVALID_REQUEST",
	["context_length_exceeded"] = "CONTEXT_LENGTH_EXCEEDED",
	["max_tokens_exceeded"] = "CONTEXT_LENGTH_EXCEEDED",
	["content_policy_violation"] = "CONTENT_FILTERED",
	["content_filter"] = "CONTENT_FILTERED",
	["blocked"] = "CONTENT_FILTERED",
	["safety_violation"] = "CONTENT_FILTERED",
	["permission_denied"] = "PERMISSION_DENIED",
	["forbidden"] = "PERMISSION_DENIED",
	["region_not_supported"] = "PERMISSION_DENIED",
	["unsupported_feature"] = "UNSUPPORTED_FEATURE",
	["invalid_file"] = "INVALID_ATTACHMENT",
	["unsupported_media_type"] = "INVALID_ATTACHMENT",
	["timeout"] = "TIMEOUT",
	["deadline_exceeded"] = "TIMEOUT",
	["internal_error"] = "SERVER_ERROR",
	["internal_server_error"] = "SERVER_ERROR",
	["api_error"] = "SERVER_ERROR",
	["upstream_error"] = "SERVER_ERROR",
}

--=============================================================================
-- HELPERS
--=============================================================================

local function normaliseMessage(text: any): string
	if type(text) ~= "string" then
		return ""
	end
	return Redact.scrubText(string.lower(text))
end

local function matches(haystack: string, pattern: string): boolean
	-- Patterns are plain literals. A guarded find keeps a malformed row from
	-- throwing and silently disabling every rule behind it.
	local ok, result = pcall(string.find, haystack, pattern, 1, true)
	return ok and result ~= nil
end

--=============================================================================
-- UPSTREAM RETRY METADATA
--=============================================================================

export type UpstreamRetry = {
	present: boolean,
	attempt: number?,
	delaySeconds: number?,
}

--- Detects a provider's OWN retry notice, e.g. "[retrying in 3s attempt #2]".
--- This is upstream metadata and must never be confused with ForgePilot's own
--- retry controller.
function UniversalErrorDetector.detectUpstreamRetry(text: any): UpstreamRetry
	local lowered = string.lower(tostring(text or ""))
	local attempt = string.match(lowered, "attempt%s*#?%s*(%d+)")
	-- "[retrying in 3s attempt #2]" and "retrying in 3 seconds"
	local delay = string.match(lowered, "retrying in%s+(%d+%.?%d*)%s*s")
		or string.match(lowered, "retrying in%s+(%d+%.?%d*)%s*second")
	local retrySeconds = string.match(lowered, "retry_after%s*[:=]%s*(%d+%.?%d*)")
	return {
		present = attempt ~= nil or delay ~= nil or retrySeconds ~= nil,
		attempt = if attempt then tonumber(attempt) else nil,
		delaySeconds = if delay then tonumber(delay) else (if retrySeconds then tonumber(retrySeconds) else nil),
	}
end

--=============================================================================
-- RATE LIMIT WINDOW PARSING
--=============================================================================

export type RateWindow = {
	found: boolean,
	limit: number?,
	windowMs: number?,
	raw: string?,
}

local TIME_UNITS: { [string]: number } = {
	s = 1000,
	sec = 1000,
	secs = 1000,
	second = 1000,
	seconds = 1000,
	m = 60 * 1000,
	min = 60 * 1000,
	mins = 60 * 1000,
	minute = 60 * 1000,
	minutes = 60 * 1000,
	h = 3600 * 1000,
	hr = 3600 * 1000,
	hour = 3600 * 1000,
	hours = 3600 * 1000,
	d = 86400 * 1000,
	day = 86400 * 1000,
	days = 86400 * 1000,
	week = 604800 * 1000,
	month = 2592000 * 1000,
	year = 31536000 * 1000,
	-- Localized units, because providers state windows in the user's language.
	["秒"] = 1000,
	["分"] = 60 * 1000,
	["分钟"] = 60 * 1000,
	["分鐘"] = 60 * 1000,
	["小时"] = 3600 * 1000,
	["小時"] = 3600 * 1000,
	["時間"] = 3600 * 1000,
	["天"] = 86400 * 1000,
	["日"] = 86400 * 1000,
	["周"] = 604800 * 1000,
	["週"] = 604800 * 1000,
	["週間"] = 604800 * 1000,
	["月"] = 2592000 * 1000,
	["月间"] = 2592000 * 1000,
	["月間"] = 2592000 * 1000,
	["年"] = 31536000 * 1000,
	["年間"] = 31536000 * 1000,
	["초"] = 1000,
	["분"] = 60 * 1000,
	["시간"] = 3600 * 1000,
	["일"] = 86400 * 1000,
	["주"] = 604800 * 1000,
	["달"] = 2592000 * 1000,
	["년"] = 31536000 * 1000,
	["detik"] = 1000,
	["menit"] = 60 * 1000,
	["jam"] = 3600 * 1000,
	["hari"] = 86400 * 1000,
	["minggu"] = 604800 * 1000,
	["bulan"] = 2592000 * 1000,
	["tahun"] = 31536000 * 1000,
	["segundo"] = 1000,
	["minuto"] = 60 * 1000,
	["hora"] = 3600 * 1000,
	["día"] = 86400 * 1000,
	["semana"] = 604800 * 1000,
	["mes"] = 2592000 * 1000,
	["año"] = 31536000 * 1000,
}

--- Extracts "<limit> per <window>" from a localized message.
--- Handles "5 requests per 60 seconds", "5 requests/minute",
--- "1分钟内最多请求5次" and "最多5次/分钟".
-- CJK forms put the LIMIT after an "at most" marker and the WINDOW before it:
--   "1分钟内最多请求5次"  -> 5 requests per 1 minute
--   "每分钟最多5次"       -> 5 requests per 1 minute
-- The marker is located with plain finds so multi-byte text is never put into a
-- character class, and the containment suffix is trimmed by byte length.
local CONTAINMENT_IN = string.byte("内")
local CONTAINMENT_YI = string.byte("以")

local function trimContainment(unit: string): string
	local trimmed = unit
	while true do
		local length = #trimmed
		if length >= 6 and string.byte(trimmed, length - 5) == CONTAINMENT_YI and string.byte(trimmed, length - 2) == CONTAINMENT_IN then
			trimmed = string.sub(trimmed, 1, length - 6)
		elseif length >= 3 and string.byte(trimmed, length - 2) == CONTAINMENT_IN then
			trimmed = string.sub(trimmed, 1, length - 3)
		else
			return trimmed
		end
	end
end

local MARKERS = { "最多请求", "最多", "不得超过", "上限为" }

--- Last plain-text occurrence of a needle, or nil.
local function lastPlainFind(text: string, needle: string): (number?, number?)
	local from = 1
	local lastStart: number? = nil
	local lastEnd: number = 0
	while true do
		local a, b = string.find(text, needle, from, true)
		if not a then
			break
		end
		lastStart = a
		lastEnd = b
		from = b + 1
	end
	return lastStart, lastEnd
end

--- The last run of digits in a string, with its 1-based start and end.
--- Uses repeated `string.find` rather than position captures in `string.gmatch`,
--- because position-capture support varies between Lua-family engines.
local function lastNumber(text: string): (string?, number, number)
	local from = 1
	local lastStart: number? = nil
	local lastEnd = 0

	while true do
		local a, b = string.find(text, "%d+", from)
		if not a then
			break
		end
		lastStart = a
		lastEnd = b
		from = b + 1
	end

	if lastStart then
		return string.sub(text, lastStart, lastEnd), lastStart, lastEnd
	end
	return nil, 0, 0
end

local function parseCjkWindow(lowered: string, raw: string): RateWindow?
	local markerStart: number? = nil
	local markerEnd: number = 0
	for _, marker in MARKERS do
		local a, b = string.find(lowered, marker, 1, true)
		if a then
			markerStart = a
			markerEnd = b
			break
		end
	end
	if not markerStart then
		return nil
	end

	-- The limit is the first number after the marker.
	local limitText = string.match(string.sub(lowered, markerEnd + 1), "%d+")
	if not limitText then
		return nil
	end

	local before = string.sub(lowered, 1, markerStart - 1)

	-- "每<unit>最多N次": no number sits between 每 and the marker.
	local perStart, perEnd = lastPlainFind(before, "每")
	local numberText, _, numberEnd = lastNumber(before)

	if perStart and (not numberText or numberEnd < perEnd) then
		local unit = trimContainment(string.sub(before, perEnd + 1))
		local ms = TIME_UNITS[unit]
		if ms then
			return { found = true, limit = tonumber(limitText), windowMs = ms, raw = raw }
		end
		return nil
	end

	-- "<N><unit>以内最多请求<M>次": the window number is the LAST number before
	-- the marker, and the unit plus containment word follow it.
	if not numberText then
		return nil
	end
	local unit = trimContainment(string.sub(before, numberEnd + 1))
	local ms = TIME_UNITS[unit]
	if not ms then
		return nil
	end

	return {
		found = true,
		limit = tonumber(limitText),
		windowMs = tonumber(numberText) * ms,
		raw = raw,
	}
end

function UniversalErrorDetector.parseRateWindow(text: any): RateWindow
	if type(text) ~= "string" or #text == 0 then
		return { found = false }
	end
	local lowered = string.lower(text)

	-- English / Latin: "5 requests per minute", "5 per min", "max 5/min".
	-- `%a` does not match CJK, so CJK segments are handled separately.
	local count = string.match(lowered, "(%d+)")
	if count then
		local unit = string.match(lowered, "per%s+([%a]+)")
		if unit and TIME_UNITS[unit] then
			return { found = true, limit = tonumber(count), windowMs = TIME_UNITS[unit], raw = text }
		end
		local slashUnit = string.match(lowered, "/%s*([%a]+)")
		if slashUnit and TIME_UNITS[slashUnit] then
			return { found = true, limit = tonumber(count), windowMs = TIME_UNITS[slashUnit], raw = text }
		end
	end

	-- "5次/分钟" and "5/分钟"
	local perFirst, slashSecond = string.match(lowered, "(%d+)%s*次?%s*/%s*([^%d%s]+)")
	if perFirst and TIME_UNITS[slashSecond] then
		return { found = true, limit = tonumber(perFirst), windowMs = TIME_UNITS[slashSecond], raw = text }
	end

	local cjk = parseCjkWindow(lowered, text)
	if cjk then
		return cjk
	end

	return { found = false }
end

--=============================================================================
-- MESSAGE EXTRACTION
--=============================================================================

--- Pulls a human message out of any of the common error body shapes.
function UniversalErrorDetector.extractMessage(body: any): string?
	local decoded = decodeErrorBody(body)
	if decoded == nil then
		if type(body) == "string" and #body > 0 and #body < 2000 then
			return body
		end
		return nil
	end

	local cursor = decoded
	local depth = 0
	while type(cursor) == "table" and depth < 6 do
		local err = cursor.error
		if type(err) == "string" then
			return err
		end
		if type(err) == "table" then
			if type(err.message) == "string" then
				return err.message
			end
			if type(err[1]) == "table" and type(err[1].message) == "string" then
				return err[1].message
			end
			-- Providers nest under a variety of wrapper keys.
			local descended = false
			for _, key in { "inner", "error", "cause", "reason", "detail", "details", "data" } do
				if type(err[key]) == "table" then
					cursor = err[key]
					descended = true
					break
				end
			end
			if descended then
				depth += 1
				continue
			end
			break
		end
		if type(cursor.message) == "string" then
			return cursor.message
		end
		if type(cursor.detail) == "string" then
			return cursor.detail
		end
		if type(cursor.description) == "string" then
			return cursor.description
		end
		if type(cursor.reason) == "string" then
			return cursor.reason
		end
		if type(cursor[1]) == "string" then
			return cursor[1]
		end
		if type(cursor[1]) == "table" and type(cursor[1].message) == "string" then
			return cursor[1].message
		end
		if type(cursor.details) == "table" and type(cursor.details[1]) == "string" then
			return cursor.details[1]
		end
		break
	end
	return nil
end

--- Pulls a machine error code out of any of the common shapes.
function UniversalErrorDetector.extractCode(body: any): string?
	local decoded = decodeErrorBody(body)
	if decoded == nil then
		return nil
	end

	local FIELDS = { "code", "type", "error_code", "status" }

	-- Breadth-first so a top-level code always wins over a nested one.
	local queue: { any } = { decoded }
	local seen = 0
	while #queue > 0 and seen < 24 do
		local node = table.remove(queue, 1)
		seen += 1
		if type(node) == "table" then
			for _, field in FIELDS do
				local value = node[field]
				if type(value) == "string" and #value > 0 then
					return value
				end
				if type(value) == "number" then
					return tostring(value)
				end
			end
			-- Descend only into the objects providers actually nest under.
			for _, key in { "error", "error_info", "detail", "details", "data", "meta" } do
				if type(node[key]) == "table" then
					table.insert(queue, node[key])
				end
			end
			if type(node[1]) == "table" then
				table.insert(queue, node[1])
			end
		end
	end
	return nil
end

--- True when a 2xx body actually carries a provider error rather than content.
function UniversalErrorDetector.bodyIsError(body: string?): boolean
	if type(body) ~= "string" or #body == 0 then
		return false
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
	if not ok or type(decoded) ~= "table" then
		return false
	end
	if decoded.error ~= nil then
		return true
	end
	if type(decoded.object) == "string" and decoded.object == "error" then
		return true
	end
	if type(decoded.success) == "boolean" and decoded.success == false then
		return true
	end
	if type(decoded.status) == "string" and string.find(decoded.status:lower(), "fail", 1, true) then
		return true
	end
	if type(decoded.detail) == "string" and decoded.error == nil then
		-- Some gateways return {"detail": "..."} with a 200.
		return decoded.error ~= nil or decoded.message ~= nil
	end
	return false
end

--=============================================================================
-- CLASSIFICATION
--=============================================================================

export type Input = {
	statusCode: number?,
	body: string?,
	headers: { [string]: string }?,
	transportError: string?,
	streamInterrupted: boolean?,
}

export type Classification = {
	category: Category,
	source: string,
	confidence: number,
	providerCode: string?,
	message: string?,
	rateWindow: RateWindow,
	upstreamRetry: UpstreamRetry,
}

--- Classifies a provider failure. Returns the category plus how it was decided.
function UniversalErrorDetector.classify(input: Input): Classification
	local result: Classification = {
		category = "UNKNOWN_ERROR",
		source = "unknown_fallback",
		confidence = 0.1,
		providerCode = nil,
		message = nil,
		rateWindow = { found = false },
		upstreamRetry = { present = false },
	}

	local message = UniversalErrorDetector.extractMessage(input.body)
	result.message = if message then Redact.scrubText(message) else nil
	result.providerCode = UniversalErrorDetector.extractCode(input.body)
	result.upstreamRetry = UniversalErrorDetector.detectUpstreamRetry(input.body or input.transportError)
	result.rateWindow = UniversalErrorDetector.parseRateWindow(input.body or "")

	-- 0. Transport failures (no HTTP response at all).
	if input.transportError then
		local text = string.lower(input.transportError)
		if string.find(text, "timed out", 1, true) or string.find(text, "timeout", 1, true) then
			result.category = "TIMEOUT"
			result.source = "transport_error"
			result.confidence = 0.95
			return result
		end
		result.category = "NETWORK_ERROR"
		result.source = "transport_error"
		result.confidence = 0.8
		result.message = Redact.scrubText(input.transportError)
		return result
	end

	if input.streamInterrupted then
		result.category = "STREAM_INTERRUPTED"
		result.source = "stream_state"
		result.confidence = 0.9
		return result
	end

	-- 1. HTTP status.
	local status = input.statusCode
	if status ~= nil then
		if status == 401 then
			result.category = "INVALID_API_KEY"
			result.source = "http_status"
			result.confidence = 0.97
			return result
		end
		if status == 402 then
			result.category = "INSUFFICIENT_CREDITS"
			result.source = "http_status"
			result.confidence = 0.95
			return result
		end
		if status == 403 then
			result.category = "PERMISSION_DENIED"
			result.source = "http_status"
			result.confidence = 0.9
			return result
		end
		if status == 408 then
			result.category = "TIMEOUT"
			result.source = "http_status"
			result.confidence = 0.9
			return result
		end
		if status == 413 then
			result.category = "INVALID_ATTACHMENT"
			result.source = "http_status"
			result.confidence = 0.8
			return result
		end
		if status == 429 then
			result.category = "RATE_LIMITED"
			result.source = "http_status"
			result.confidence = 0.9
			return result
		end
		if status == 404 then
			result.category = "INVALID_ENDPOINT"
			result.source = "http_status"
			result.confidence = 0.75
			return result
		end
		if status == 405 then
			result.category = "INVALID_ENDPOINT"
			result.source = "http_status"
			result.confidence = 0.8
			return result
		end
		if status >= 500 and status < 600 then
			result.category = "SERVER_ERROR"
			result.source = "http_status"
			result.confidence = 0.85
			return result
		end
	end

	-- 2. Structured provider code.
	if result.providerCode then
		local mapped = CODE_MAP[string.lower(result.providerCode)]
		if mapped then
			result.category = mapped
			result.source = "provider_code"
			result.confidence = 0.9
			return result
		end
	end

	-- 3. Provider error category field.
	if type(input.body) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, input.body)
		if ok and type(decoded) == "table" then
			local providerCategory = (decoded.error :: any)
			if type(providerCategory) == "table" and type(providerCategory.type) == "string" then
				local mapped = CODE_MAP[string.lower(providerCategory.type)]
				if mapped then
					result.category = mapped
					result.source = "provider_category"
					result.confidence = 0.88
					return result
				end
			end
		end
	end

	-- 4. Response headers.
	local headers = input.headers or {}
	for key, value in headers do
		local loweredKey = string.lower(key)
		if loweredKey == "x-error-category" or loweredKey == "x-error-code" then
			local mapped = CODE_MAP[string.lower(tostring(value))]
			if mapped then
				result.category = mapped
				result.source = "response_header"
				result.confidence = 0.85
				return result
			end
		end
	end

	-- 5/6. Multilingual message classification.
	local haystack = normaliseMessage(input.body) .. " " .. normaliseMessage(result.message)
	if #haystack > 1 then
		for _, group in GROUPS do
			for _, row in group.rows do
				if matches(haystack, row.pattern) then
					result.category = row.category
					result.source = "message_" .. group.name
					result.confidence = 0.78
					return result
				end
			end
		end
	end

	-- 7. Unknown fallback.
	if status ~= nil and status >= 400 then
		result.source = "http_status_unknown"
		result.confidence = 0.4
	end
	return result
end

--- Convenience wrapper used by the retry controller.
function UniversalErrorDetector.isRetryable(category: Category): boolean
	if UniversalErrorDetector.NEVER_RETRY[category] then
		return false
	end
	return UniversalErrorDetector.RETRYABLE[category] == true
end

return UniversalErrorDetector