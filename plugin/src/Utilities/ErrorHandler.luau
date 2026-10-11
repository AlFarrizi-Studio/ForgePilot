--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Utilities / ErrorHandler
	Normalises errors thrown by pcall/HTTP providers into user-presentable text,
	and classifies provider HTTP failures into actionable messages.
]]

local Redact = require(script.Parent.Redact)

local ErrorHandler = {}

--=============================================================================
-- GENERIC NORMALISATION
--=============================================================================

local NETWORK_HINTS = {
	["not enabled"] = "HTTP requests are disabled for this experience. Enable `Allow HTTP Requests` in Game Settings, then reopen the plugin.",
	["http requests are not enabled"] = "HTTP requests are disabled for this experience. Enable `Allow HTTP Requests` in Game Settings, then reopen the plugin.",
	["blocked by client"] = "Roblox blocked this request. Check that the domain is on the HTTP allowlist and that the URL uses HTTPS.",
	["dns"] = "The host name could not be resolved. Check the base URL spelling.",
	["timed out"] = "The provider did not respond in time. Increase Request Timeout or try again.",
	["timeout"] = "The provider did not respond in time. Increase Request Timeout or try again.",
	["ssl"] = "TLS negotiation failed. The endpoint may not support HTTPS properly.",
	["connection reset"] = "The connection was closed before the response completed.",
	["too many requests"] = "The provider is rate limiting this key. Wait a moment before retrying.",
	["service unavailable"] = "The provider is temporarily unavailable.",
}

local STATUS_HINTS: { [number]: string } = {
	[400] = "The provider rejected the request body. Check the Base URL, Model ID and protocol.",
	[401] = "Authentication failed. The API Key is missing, malformed, or not valid for this endpoint.",
	[403] = "Access denied. The key may lack permission for this model, region, or the domain may be restricted.",
	[404] = "Endpoint or model not found. Verify the API Base URL and Model ID.",
	[405] = "The endpoint does not accept this HTTP method. The provider protocol may be mismatched.",
	[408] = "The provider timed out while reading the request.",
	[413] = "The payload was too large. Reduce attachments or max output tokens.",
	[422] = "The provider could not process the request parameters. Check model capabilities for this input.",
	[429] = "Rate limited or out of quota. Check the provider billing status and retry later.",
	[500] = "The provider had an internal error. Retrying may succeed.",
	[501] = "The provider does not implement this endpoint. The chosen protocol may be unsupported.",
	[502] = "Bad gateway from the provider. Retry shortly.",
	[503] = "The provider is overloaded or in maintenance. Retry later.",
	[529] = "The provider is overloaded. Retry later.",
}

--- Converts any error value into a single clean line.
function ErrorHandler.describe(err: any): string
	if err == nil then
		return "Unknown error."
	end
	local text = if type(err) == "string" then err else tostring(err)
	text = Redact.scrubText(text)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if #text == 0 then
		return "Unknown error."
	end
	return text
end

--- Adds a network-specific hint when the message matches a known failure mode.
function ErrorHandler.hint(err: any): string?
	local text = string.lower(ErrorHandler.describe(err))
	for needle, hint in NETWORK_HINTS do
		if string.find(text, needle, 1, true) then
			return hint
		end
	end
	return nil
end

--- Full user-facing text for an error, including any actionable hint.
function ErrorHandler.explain(err: any): string
	local base = ErrorHandler.describe(err)
	local hint = ErrorHandler.hint(err)
	if hint and not string.find(base, hint, 1, true) then
		return base .. "  —  " .. hint
	end
	return base
end

--=============================================================================
-- PROVIDER HTTP FAILURES
--=============================================================================

export type HttpFailure = {
	statusCode: number?,
	body: string?,
	headers: { [string]: string }?,
	success: boolean,
	timeoutMs: number?,
}

--- Extracts a provider error message from a JSON error body when possible.
function ErrorHandler.providerMessage(failure: HttpFailure): string?
	if type(failure.body) ~= "string" or #failure.body == 0 then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, failure.body)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local err = decoded.error or decoded
	if type(err) == "table" then
		if type(err.message) == "string" then
			return Redact.scrubText(err.message)
		end
		if type(err[1]) == "table" and type(err[1].message) == "string" then
			return Redact.scrubText((err[1] :: any).message)
		end
	end
	return nil
end

--- Builds the message shown to the user for a failed provider request.
function ErrorHandler.fromHttp(failure: HttpFailure, providerLabel: string): string
	local providerMessage = ErrorHandler.providerMessage(failure)
	local status = failure.statusCode

	if failure.success == false and status == nil then
		return string.format(
			"%s: request failed before a response was received. %s",
			providerLabel,
			ErrorHandler.hint("network error") or "Check network connectivity and the Base URL."
		)
	end

	if status and STATUS_HINTS[status] then
		local parts = { string.format("%s returned HTTP %d.", providerLabel, status) }
		if providerMessage then
			parts[#parts + 1] = providerMessage
		end
		parts[#parts + 1] = STATUS_HINTS[status]
		return Redact.scrubText(table.concat(parts, " "))
	end

	if providerMessage then
		return string.format("%s: %s", providerLabel, providerMessage)
	end

	local bodyPreview = if type(failure.body) == "string" and #failure.body > 0
		then string.sub(failure.body, 1, 400)
		else "(empty response body)"

	return string.format(
		"%s returned an unexpected response (HTTP %s).\n%s",
		providerLabel,
		tostring(status),
		Redact.scrubText(bodyPreview)
	)
end

--=============================================================================
-- PLATFORM LIMITATIONS
--=============================================================================

--- Explains a capability that Roblox Studio does not allow, without inventing a
--- workaround. Used so unsupported features are reported honestly in the UI.
function ErrorHandler.platformLimitation(feature: string, reason: string): string
	return string.format("%s is unavailable in Roblox Studio plugins: %s", feature, reason)
end

return ErrorHandler