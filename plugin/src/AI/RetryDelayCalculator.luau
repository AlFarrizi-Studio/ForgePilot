--!strict
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / AI / RetryDelayCalculator
	Computes how long to wait before the next attempt.

	PRIORITY (the longest applicable MANDATORY wait always wins)
	  1. Provider cooldown already established by the scheduler
	  2. Retry-After (seconds or HTTP-date)
	  3. retry-after-ms
	  4. Rate-limit reset headers
	  5. JSON retry hints in the error body
	  6. Tracked request history for the provider window
	  7. Error-specific fallback delay
	  8. Exponential / linear backoff with bounded jitter

	Pure and deterministic apart from an injectable clock, so every branch is
	testable without waiting.
]]

local RetryDelayCalculator = {}

--=============================================================================
-- TYPES
--=============================================================================

export type Strategy = "adaptive" | "linear" | "exponential" | "custom"

export type Config = {
	enabled: boolean,
	strategy: Strategy,
	maxRetries: number,
	initialDelaySeconds: number,
	multiplier: number,
	linearStepSeconds: number,
	maxDelaySeconds: number,
	jitterPercent: number,
	respectRetryAfter: boolean,
	dynamicCooldown: boolean,
	maxAutoWaitSeconds: number,
	customSequence: { number }?,
	--- Per-provider overrides, keyed by provider profile id.
	providerOverrides: { [string]: Partial<Config> }?,
}

export type Source =
	| "provider_cooldown"
	| "retry_after_seconds"
	| "retry_after_http_date"
	| "retry_after_ms"
	| "rate_limit_reset_header"
	| "body_retry_hint"
	| "tracked_window"
	| "category_fallback"
	| "exponential_backoff"
	| "linear_backoff"
	| "custom_sequence"
	| "none"

export type Decision = {
	delaySeconds: number,
	source: Source,
	--- True when the wait is a provider requirement rather than our own choice.
	mandatory: boolean,
	estimated: boolean,
	--- Set when the wait exceeds maxAutoWaitSeconds and retries must pause.
	exceedsAutoWait: boolean,
	reason: string,
}

local DEFAULT_CONFIG: Config = {
	enabled = true,
	strategy = "adaptive",
	maxRetries = 5,
	initialDelaySeconds = 2,
	multiplier = 2,
	linearStepSeconds = 3,
	maxDelaySeconds = 120,
	jitterPercent = 25,
	respectRetryAfter = true,
	dynamicCooldown = true,
	maxAutoWaitSeconds = 120,
	customSequence = nil,
	providerOverrides = nil,
}

RetryDelayCalculator.DEFAULT_CONFIG = DEFAULT_CONFIG

--=============================================================================
-- ERROR-SPECIFIC FALLBACKS
--=============================================================================
-- Deliberately conservative: a fallback must never be shorter than the wait the
-- provider is likely to need.

local CATEGORY_FALLBACK: { [string]: number } = {
	RATE_LIMITED = 60,
	QUOTA_WINDOW_EXHAUSTED = 60,
	CONCURRENCY_LIMITED = 5,
	PROVIDER_OVERLOADED = 8,
	SERVER_ERROR = 4,
	NETWORK_ERROR = 3,
	TIMEOUT = 4,
	STREAM_INTERRUPTED = 3,
	UNKNOWN_ERROR = 4,
}

function RetryDelayCalculator.categoryFallback(category: string?): number
	if type(category) ~= "string" then
		return 4
	end
	return CATEGORY_FALLBACK[category] or 4
end

--=============================================================================
-- CONFIG
--=============================================================================

function RetryDelayCalculator.defaultConfig(): Config
	local copy: Config = {}
	for key, value in RetryDelayCalculator.DEFAULT_CONFIG do
		(copy :: any)[key] = if type(value) == "table" then table.clone(value) else value
	end
	copy.customSequence = nil
	copy.providerOverrides = {}
	return copy
end

--- Merges stored settings into a config, clamping hostile values.
function RetryDelayCalculator.fromSettings(settings: any, providerId: string?): Config
	local config = RetryDelayCalculator.defaultConfig()

	if type(settings) ~= "table" then
		return config
	end

	local function assign(key: string, value: any, min: number, max: number, integer: boolean?)
		if value == nil then
			return
		end
		local numberValue = tonumber(value)
		if numberValue == nil then
			return
		end
		if integer then
			numberValue = math.floor(numberValue)
		end
		(config :: any)[key] = math.clamp(numberValue, min, max)
	end

	config.enabled = if type(settings.enabled) == "boolean" then settings.enabled else true
	local strategy = settings.strategy
	if strategy == "adaptive" or strategy == "linear" or strategy == "exponential" or strategy == "custom" then
		config.strategy = strategy
	end

	assign("maxRetries", settings.maxRetries, 0, 20, true)
	assign("initialDelaySeconds", settings.initialDelaySeconds, 0.25, 120)
	assign("multiplier", settings.multiplier, 1, 10)
	assign("linearStepSeconds", settings.linearStepSeconds, 1, 60)
	assign("maxDelaySeconds", settings.maxDelaySeconds, 1, 3600)
	assign("jitterPercent", settings.jitterPercent, 0, 100)
	assign("maxAutoWaitSeconds", settings.maxAutoWaitSeconds, 5, 3600)

	config.respectRetryAfter = if type(settings.respectRetryAfter) == "boolean" then settings.respectRetryAfter else true
	config.dynamicCooldown = if type(settings.dynamicCooldown) == "boolean" then settings.dynamicCooldown else true

	if type(settings.customSequence) == "table" then
		local sequence: { number } = {}
		for index, value in settings.customSequence do
			if type(value) == "number" and #sequence < 20 then
				sequence[#sequence + 1] = math.clamp(value, 0, 3600)
			end
			_ = index
		end
		config.customSequence = #sequence > 0 and sequence or nil
	end

	-- Per-provider override.
	if providerId and type(settings.providerOverrides) == "table" then
		local override = settings.providerOverrides[providerId]
		if type(override) == "table" then
			local merged = {
				maxRetries = override.maxRetries,
				initialDelaySeconds = override.initialDelaySeconds,
				multiplier = override.multiplier,
				maxDelaySeconds = override.maxDelaySeconds,
				jitterPercent = override.jitterPercent,
				enabled = override.enabled,
				strategy = override.strategy,
			}
			local base = config
			local target = table.clone(base)
			for key, value in merged do
				if value ~= nil then
					(target :: any)[key] = value
				end
			end
			return RetryDelayCalculator.sanitise(target)
		end
	end

	return RetryDelayCalculator.sanitise(config)
end

function RetryDelayCalculator.sanitise(config: Config): Config
	local out = RetryDelayCalculator.defaultConfig()
	for key, value in config do
		if (out :: any)[key] ~= nil then
			(out :: any)[key] = value
		end
	end
	out.maxRetries = math.clamp(math.floor(out.maxRetries), 0, 20)
	out.initialDelaySeconds = math.clamp(out.initialDelaySeconds, 0.25, 120)
	out.multiplier = math.clamp(out.multiplier, 1, 10)
	out.maxDelaySeconds = math.clamp(out.maxDelaySeconds, 1, 3600)
	out.jitterPercent = math.clamp(out.jitterPercent, 0, 100)
	out.maxAutoWaitSeconds = math.clamp(out.maxAutoWaitSeconds, 5, 3600)
	return out
end

--=============================================================================
-- BACKOFF
--=============================================================================

--- Applies bounded, symmetric jitter. `random` is injectable for tests.
function RetryDelayCalculator.applyJitter(
	delaySeconds: number,
	jitterPercent: number,
	random: () -> number
): number
	if jitterPercent <= 0 then
		return delaySeconds
	end
	local factor = jitterPercent / 100
	-- random() is expected in [0,1); map to [-1,1).
	local offset = (random() * 2 - 1) * factor
	local jittered = delaySeconds * (1 + offset)
	-- Never jitter below zero or below a quarter of the original.
	return math.max(delaySeconds * 0.25, jittered)
end

--- Exponential backoff, clamped to maxDelaySeconds. Retry 1 is the first retry.
function RetryDelayCalculator.exponential(attempt: number, config: Config): number
	if attempt <= 1 then
		return config.initialDelaySeconds
	end
	local delay = config.initialDelaySeconds * (config.multiplier ^ (attempt - 1))
	return math.min(delay, config.maxDelaySeconds)
end

--- Linear backoff: 3s, 6s, 9s, 12s, 15s by default.
function RetryDelayCalculator.linear(attempt: number, config: Config): number
	local delay = config.linearStepSeconds * attempt
	return math.min(delay, config.maxDelaySeconds)
end

--- The configured custom sequence, cycled and clamped.
function RetryDelayCalculator.custom(attempt: number, config: Config): number
	local sequence = config.customSequence
	if type(sequence) ~= "table" or #sequence == 0 then
		return RetryDelayCalculator.exponential(attempt, config)
	end
	local index = math.min(attempt, #sequence)
	return math.clamp(sequence[index], 0, config.maxDelaySeconds)
end

--=============================================================================
-- HEADERS
--=============================================================================

--- Parses Retry-After as seconds or an HTTP date. Returns nil when malformed.
function RetryDelayCalculator.parseRetryAfter(value: any, now: number): (number?, string?)
	if value == nil then
		return nil, nil
	end
	local text = type(value) == "string" and StringUtil.trim(value) or tostring(value)
	if #text == 0 then
		return nil, nil
	end

	local seconds = tonumber(text)
	if seconds ~= nil then
		if seconds ~= seconds or seconds == math.huge or seconds < 0 then
			return nil, nil
		end
		return math.min(seconds, 86400), "retry_after_seconds"
	end

	-- HTTP-date: Sun, 06 Nov 1994 08:49:37 GMT
	local year, month, day, hour, minute, second =
		string.match(text, "%a+,%s+(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+GMT")
	if year then
		local months = {
			jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
			jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
		}
		local monthIndex = months[string.lower(month)]
		if monthIndex then
			local epoch = os.time({
				year = tonumber(year),
				month = monthIndex,
				day = tonumber(day),
				hour = tonumber(hour),
				min = tonumber(minute),
				sec = tonumber(second),
				isdst = false,
			})
			if epoch then
				-- `now` is a monotonic clock (os.clock), not a wall-clock epoch, so
				-- the delta has to be measured against os.time() as well. Clamped
				-- to one day for the same reason as the seconds branch above.
				local delta = epoch - os.time()
				if delta > 0 then
					return math.min(delta, 86400), "retry_after_http_date"
				end
				-- A date in the past means "retry now".
				return 0, "retry_after_http_date"
			end
		end
	end

	return nil, nil
end

--- Reads retry-after-ms / x-ratelimit-reset style headers.
function RetryDelayCalculator.readHeaders(
	headers: { [string]: string }?,
	now: number
): (number?, Source?)
	if type(headers) ~= "table" then
		return nil, nil
	end
	local lookup: { [string]: string } = {}
	for key, value in headers do
		lookup[string.lower(key)] = value
	end

	if lookup["retry-after-ms"] then
		local ms = tonumber(lookup["retry-after-ms"])
		if ms and ms == ms and ms >= 0 then
			return math.min(ms / 1000, 86400), "retry_after_ms"
		end
	end

	if lookup["x-ratelimit-reset-requests"] then
		local reset = string.lower(lookup["x-ratelimit-reset-requests"])
		-- "1s", "6m0s", "20ms" — a duration-until-reset.
		local value, unit = string.match(reset, "(%d+%.?%d*)([a-z]+)")
		if value then
			local seconds = tonumber(value)
			if seconds then
				local factor = if unit == "ms"
					then 0.001
					elseif unit == "m"
						then 60
						elseif unit == "h"
							then 3600
						else 1
				return math.min(seconds * factor, 86400), "rate_limit_reset_header"
			end
		end
	end

	if lookup["retry-after"] then
		local parsed, source = RetryDelayCalculator.parseRetryAfter(lookup["retry-after"], now)
		if parsed ~= nil then
			return parsed, (source :: Source)
		end
	end

	return nil, nil
end

--=============================================================================
-- BODY HINTS
--=============================================================================

--- Reads a retry hint from a JSON error body, e.g. {"retry_after": 3}.
function RetryDelayCalculator.readBodyHint(body: string?): (number?, Source?)
	if type(body) ~= "string" or #body == 0 then
		return nil, nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
	if not ok or type(decoded) ~= "table" then
		return nil, nil
	end
	local containers = { decoded, decoded.error, decoded.data }
	for _, container in containers do
		if type(container) == "table" then
			for _, field in { "retry_after", "retryAfter", "retry_after_seconds", "backoff", "wait_seconds" } do
				local value = tonumber(container[field])
				if value and value == value and value >= 0 then
					return math.min(value, 86400), "body_retry_hint"
				end
			end
		end
	end
	return nil, nil
end

--=============================================================================
-- CALCULATE
--=============================================================================

export type CalculateInput = {
	attempt: number,
	config: Config,
	category: string?,
	errorStatus: number?,
	headers: { [string]: string }?,
	body: string?,
	--- Cooldown already established by ProviderRateLimitScheduler, in seconds.
	cooldownSeconds: number?,
	--- Remaining time in the tracked sliding window, in seconds.
	windowWaitSeconds: number?,
	now: number,
	random: () -> number,
}

--- Resolves the wait before the next attempt.
function RetryDelayCalculator.calculate(input: CalculateInput): Decision
	local config = RetryDelayCalculator.sanitise(input.config)
	local attempt = math.max(1, math.floor(input.attempt))

	local candidates: { { seconds: number, source: Source, mandatory: boolean, estimated: boolean } } = {}

	-- 1. Provider cooldown already established.
	if config.dynamicCooldown and type(input.cooldownSeconds) == "number" and input.cooldownSeconds > 0 then
		candidates[#candidates + 1] = {
			seconds = input.cooldownSeconds,
			source = "provider_cooldown",
			mandatory = true,
			estimated = false,
		}
	end

	-- 2-4. Headers.
	if config.respectRetryAfter then
		local headerDelay, headerSource = RetryDelayCalculator.readHeaders(input.headers, input.now)
		if headerDelay ~= nil then
			candidates[#candidates + 1] = {
				seconds = headerDelay,
				source = (headerSource :: Source),
				mandatory = true,
				estimated = false,
			}
		end
	end

	-- 5. Body hint.
	if config.respectRetryAfter then
		local hint, hintSource = RetryDelayCalculator.readBodyHint(input.body)
		if hint ~= nil then
			candidates[#candidates + 1] = {
				seconds = hint,
				source = (hintSource :: Source),
				mandatory = false,
				estimated = false,
			}
		end
	end

	-- 6. Tracked sliding window.
	if config.dynamicCooldown and type(input.windowWaitSeconds) == "number" and input.windowWaitSeconds > 0 then
		candidates[#candidates + 1] = {
			seconds = input.windowWaitSeconds,
			source = "tracked_window",
			mandatory = false,
			estimated = true,
		}
	end

	-- Longest MANDATORY wait always wins.
	local mandatoryBest: { seconds: number, source: Source, estimated: boolean }? = nil
	for _, candidate in candidates do
		if candidate.mandatory then
			if mandatoryBest == nil or candidate.seconds > mandatoryBest.seconds then
				mandatoryBest = {
					seconds = candidate.seconds,
					source = candidate.source,
					estimated = candidate.estimated,
				}
			end
		end
	end

	local chosen: { seconds: number, source: Source, mandatory: boolean, estimated: boolean }
	if mandatoryBest then
		chosen = {
			seconds = mandatoryBest.seconds,
			source = mandatoryBest.source,
			mandatory = true,
			estimated = mandatoryBest.estimated,
		}
	else
		-- Largest non-mandatory candidate still beats a generic fallback.
		local softBest: { seconds: number, source: Source, estimated: boolean }? = nil
		for _, candidate in candidates do
			if not candidate.mandatory then
				if softBest == nil or candidate.seconds > softBest.seconds then
					softBest = {
						seconds = candidate.seconds,
						source = candidate.source,
						estimated = candidate.estimated,
					}
				end
			end
		end

		if softBest then
			chosen = {
				seconds = softBest.seconds,
				source = softBest.source,
				mandatory = false,
				estimated = softBest.estimated,
			}
		else
			-- 7. Error-specific fallback, then 8. backoff.
			local fallback = RetryDelayCalculator.categoryFallback(input.category)
			local backoff: number
			local backoffSource: Source
			if config.strategy == "linear" then
				backoff = RetryDelayCalculator.linear(attempt, config)
				backoffSource = "linear_backoff"
			elseif config.strategy == "custom" then
				backoff = RetryDelayCalculator.custom(attempt, config)
				backoffSource = "custom_sequence"
			else
				backoff = RetryDelayCalculator.exponential(attempt, config)
				backoffSource = "exponential_backoff"
			end

			if fallback > backoff then
				chosen = {
					seconds = fallback,
					source = "category_fallback",
					mandatory = false,
					estimated = true,
				}
			else
				chosen = {
					seconds = backoff,
					source = backoffSource,
					mandatory = false,
					estimated = false,
				}
			end
		end
	end

	-- A mandatory wait is reported honestly and is NEVER clamped down to
	-- maxDelaySeconds: doing so would violate a provider's cooldown. Only our
	-- own backoff is clamped.
	local delay = chosen.seconds
	if not chosen.mandatory then
		delay = math.min(delay, config.maxDelaySeconds)
		delay = RetryDelayCalculator.applyJitter(delay, config.jitterPercent, input.random)
		delay = math.min(delay, config.maxDelaySeconds)
	end

	local exceeds = delay > config.maxAutoWaitSeconds
	local reason: string
	if chosen.mandatory then
		reason = string.format(
			"Provider requires a %s wait (%s).",
			string.format("%.1fs", delay),
			chosen.source
		)
	elseif chosen.estimated then
		reason = string.format("Estimated %s wait (%s).", string.format("%.1fs", delay), chosen.source)
	else
		reason = string.format("Backing off %s (%s).", string.format("%.1fs", delay), chosen.source)
	end

	if exceeds then
		reason ..= string.format(
			" That exceeds the %.0fs automatic wait limit, so retries are paused.",
			config.maxAutoWaitSeconds
		)
	end

	return {
		delaySeconds = delay,
		source = chosen.source,
		mandatory = chosen.mandatory,
		estimated = chosen.estimated,
		exceedsAutoWait = exceeds,
		reason = reason,
	}
end

return RetryDelayCalculator