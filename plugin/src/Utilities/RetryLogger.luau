--!strict
--[[
	ForgePilot / Utilities / RetryLogger
	Provider and retry events in ForgePilot's Activity Log.

	Every line here corresponds to something that actually happened. API keys,
	authorization headers and response bodies are never logged; endpoints are shown
	through BaseURLResolver.forDisplay, which strips query strings.
]]

local BaseURLResolver = require(script.Parent.Parent.AI.BaseURLResolver)
local Logger = require(script.Parent.Logger)
local Redact = require(script.Parent.Redact)

local RetryLogger = {}

--=============================================================================
-- PROVIDER EVENTS
--=============================================================================

function RetryLogger.providerSelected(profile: any)
	Logger.info("AI Provider", "Provider selected.", {
		detail = string.format(
			"%s · %s · %s",
			tostring(profile.displayName),
			tostring(profile.modelId ~= "" and profile.modelId or "(no model)"),
			tostring(profile.protocol)
		),
	})
end

function RetryLogger.requestStarted(profile: any, url: string, streaming: boolean)
	Logger.info("API", string.format("%s %s", if streaming then "STREAM" else "POST", BaseURLResolver.forDisplay(url)), {
		detail = string.format("%s · %s", profile.displayName, profile.modelId),
	})
end

function RetryLogger.requestFinished(provider: string, model: string, status: number?, durationMs: number, usage: any?)
	local detail = string.format("%s · %s · %.0f ms", provider, model, durationMs)
	if type(usage) == "table" and usage.inputTokens then
		detail ..= string.format(" · %d in / %d out", usage.inputTokens, usage.outputTokens or 0)
	end
	Logger.info("API", string.format("Provider responded HTTP %s.", tostring(status)), { detail = detail })
end

--=============================================================================
-- ERROR EVENTS
--=============================================================================

function RetryLogger.errorDetected(normalised: any)
	local UED = require(script.Parent.UniversalErrorDetector)
	local upstreamNote = if normalised.upstreamRetry and normalised.upstreamRetry.present
		then string.format(
			" · upstream reported retry attempt %s%s",
			tostring(normalised.upstreamRetry.attempt),
			if normalised.upstreamRetry.delaySeconds
				then string.format(" in %.0fs", normalised.upstreamRetry.delaySeconds)
				else ""
		)
		else ""

	Logger.error("ERROR", "Provider error detected.", {
		detail = string.format(
			"%s · %s%s",
			normalised.message,
			normalised.classificationSource,
			upstreamNote
		),
	})

	Logger.info("ERROR", string.format(
		"Classified as %s (confidence %.2f).",
		normalised.category,
		normalised.confidence
	), {
		detail = string.format(
			"HTTP %s · code %s · request %s",
			tostring(normalised.httpStatus),
			tostring(normalised.providerCode),
			tostring(normalised.requestId)
		),
	})

	if normalised.rateLimit and normalised.rateLimit.limit and normalised.rateLimit.windowMs then
		Logger.warn("Rate Limit", string.format(
			"%d requests per %.0f seconds.",
			normalised.rateLimit.limit,
			normalised.rateLimit.windowMs / 1000
		), {
			detail = if normalised.rateLimit.estimated
				then "Window not reported by the provider; this is a conservative estimate."
				else "Window was stated by the provider.",
		})
	end

	_ = UED
end

function RetryLogger.retryScheduled(
	provider: string,
	model: string,
	attempt: number,
	maxRetries: number,
	decision: any
)
	Logger.info("RETRY", string.format(
		"Retry %d/%d scheduled in %.1fs.",
		attempt,
		maxRetries,
		decision.delaySeconds
	), {
		detail = string.format(
			"%s · %s · %s%s%s",
			provider,
			model,
			decision.source,
			if decision.mandatory then " (provider-mandated)" else "",
			if decision.estimated then " (estimated)" else ""
		),
	})
end

function RetryLogger.retryPaused(provider: string, model: string, reason: string)
	Logger.warn("Retry", "Retries paused.", { detail = string.format("%s · %s · %s", provider, model, reason) })
end

function RetryLogger.providerRecovered(provider: string, model: string, attempts: number)
	Logger.success("Retry", "Provider recovered.", {
		detail = string.format("%s · %s succeeded after %d attempt(s).", provider, model, attempts),
	})
end

function RetryLogger.retriesExhausted(provider: string, model: string, attempts: number, reason: string)
	Logger.error("Retry", "Automatic retries exhausted.", {
		detail = string.format("%s · %s · %d attempt(s) · %s", provider, model, attempts, reason),
	})
end

function RetryLogger.retryCancelled(provider: string, model: string, attempts: number, reason: string)
	Logger.warn("Retry", "Retry cancelled.", {
		detail = string.format("%s · %s · %d attempt(s) · %s", provider, model, attempts, reason),
	})
end

function RetryLogger.cooldownActivated(provider: string, seconds: number, estimated: boolean)
	Logger.warn("Rate Limit", "Provider cooldown activated.", {
		detail = string.format(
			"%s · %.0fs%s",
			provider,
			seconds,
			if estimated then " · estimated (ForgePilot cannot see other apps' usage)" else ""
		),
	})
end

--=============================================================================
-- CONFIGURATION EVENTS
--=============================================================================

function RetryLogger.protocolConfirmed(profile: any, protocolId: string, source: string)
	Logger.success("API", string.format("Protocol: %s", protocolId), {
		detail = string.format("%s · determined by %s", profile.displayName, source),
	})
end

function RetryLogger.protocolRejected(profile: any, protocolId: string, reason: string)
	Logger.warn("API", string.format("Protocol %s not available.", protocolId), {
		detail = string.format("%s · %s", profile.displayName, Redact.scrubText(reason)),
	})
end

function RetryLogger.capabilities(result: string, detail: string?)
	Logger.info("Capabilities", result, { detail = detail })
end

return RetryLogger