--!strict
--[[
	ForgePilot / AI / CustomProviderManager
	CRUD, validation and URL preview for user-defined providers.

	All validation lives here so the settings UI and the request path can never
	disagree about whether a provider is usable.
]]

local APIEndpointRouter = require(script.Parent.APIEndpointRouter)
local BaseURLResolver = require(script.Parent.BaseURLResolver)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local UniversalProviderRegistry = require(script.Parent.UniversalProviderRegistry)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local Time = require(script.Parent.Parent.Utilities.Time)

local CustomProviderManager = {}

--=============================================================================
-- VALIDATION
--=============================================================================

export type ValidationIssue = {
	field: string,
	message: string,
	severity: "error" | "warning",
}

export type ValidationResult = {
	ok: boolean,
	errors: { ValidationIssue },
	warnings: { ValidationIssue },
}

local function issue(field: string, message: string, severity: "error" | "warning"): ValidationIssue
	return { field = field, message = message, severity = severity }
end

--- Validates a provider profile without saving it.
function CustomProviderManager.validate(profile: any): ValidationResult
	local errors: { ValidationIssue } = {}
	local warnings: { ValidationIssue } = {}

	if type(profile) ~= "table" then
		return {
			ok = false,
			errors = { issue("profile", "No provider profile supplied.", "error") },
			warnings = warnings,
		}
	end

	if type(profile.displayName) ~= "string" or #StringUtil.trim(profile.displayName) == 0 then
		errors[#errors + 1] = issue("displayName", "AI Display Name is required.", "error")
	end

	local normalised, urlError = BaseURLResolver.normaliseBase(profile.baseUrl or "")
	if not normalised then
		errors[#errors + 1] = issue("baseUrl", tostring(urlError), "error")
	elseif not BaseURLResolver.isTrustedHost(normalised) then
		warnings[#warnings + 1] = issue(
			"baseUrl",
			"Unrecognised host. Your API key will be sent to this domain. Continue only if you trust it.",
			"warning"
		)
	end

	local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)
	if protocol.id == "custom_rest" then
		local mapping = profile.schemaMapping
		if type(mapping) ~= "table" then
			errors[#errors + 1] = issue(
				"schemaMapping",
				"Custom REST requires a Request Schema Mapping and a Response Schema Mapping.",
				"error"
			)
		else
			if type(mapping.request) ~= "table" or type(mapping.request.prompt) ~= "string" then
				errors[#errors + 1] =
					issue("schemaMapping.request.prompt", "Request mapping needs a `prompt` destination path.", "error")
			end
			if type(mapping.response) ~= "table" or type(mapping.response.text) ~= "string" then
				errors[#errors + 1] =
					issue("schemaMapping.response.text", "Response mapping needs a `text` source path.", "error")
			end
		end
	end

	if type(profile.authStyle) == "string" then
		local valid = {
			bearer = true,
			header = true,
			query = true,
			none = true,
			custom = true,
		}
		if not valid[profile.authStyle] then
			errors[#errors + 1] = issue("authStyle", "Unknown authentication style.", "error")
		elseif
			(profile.authStyle == "header" or profile.authStyle == "custom")
			and (type(profile.authHeaderName) ~= "string" or #profile.authHeaderName == 0)
		then
			errors[#errors + 1] =
				issue("authHeaderName", "This authentication style needs a header name.", "error")
		elseif profile.authStyle == "query" and (type(profile.authQueryParam) ~= "string" or #profile.authQueryParam == 0) then
			errors[#errors + 1] =
				issue("authQueryParam", "Query authentication needs a parameter name.", "error")
		end
	end

	local maxTokens = tonumber(profile.maxOutputTokens)
	if maxTokens and maxTokens < 1 then
		errors[#errors + 1] = issue("maxOutputTokens", "Maximum Output Tokens must be at least 1.", "error")
	end

	local timeout = tonumber(profile.timeoutMs)
	if timeout and (timeout < 1000 or timeout > 600000) then
		errors[#errors + 1] = issue("timeoutMs", "Request Timeout must be between 1000 and 600000 ms.", "error")
	end

	if profile.streaming and protocol.supportsStreaming == false then
		warnings[#warnings + 1] =
			issue("streaming", protocol.label .. " does not stream; ForgePilot will use a single response.", "warning")
	end

	return { ok = #errors == 0, errors = errors, warnings = warnings }
end

--=============================================================================
-- ENDPOINT PREVIEW
--=============================================================================

export type Preview = {
	ok: boolean,
	url: string?,
	display: string,
	mode: string,
	endpointPath: string,
	note: string?,
	error: string?,
	streamingUrl: string?,
}

--- Builds the read-only URL preview shown in the settings panel.
--- Never includes the API key.
function CustomProviderManager.preview(profile: any): Preview
	local route = APIEndpointRouter.get(profile and profile.protocol)
	-- The preview follows the protocol unless the user edited the path by hand.
	local endpointPath: string = if type(profile) == "table"
			and profile.endpointPathCustom == true
			and type(profile.endpointPath) == "string"
			and #profile.endpointPath > 0
		then profile.endpointPath
		else route.chat

	local resolved = BaseURLResolver.resolve(profile and profile.baseUrl or "", {
		endpointPath = endpointPath,
		mode = (if type(profile) == "table" then profile.urlMode else "base") :: any,
		model = if type(profile) == "table" then profile.modelId else nil,
	})

	if not resolved.ok then
		return {
			ok = false,
			url = nil,
			display = "(invalid base URL)",
			mode = "base",
			endpointPath = endpointPath,
			note = nil,
			error = resolved.error,
			streamingUrl = nil,
		}
	end

	local url = resolved.url :: string
	local streamUrl: string? = nil
	if route.stream then
		local streamPath: string = if #endpointPath > 0 and profile and profile.urlMode == "full"
			then endpointPath
			else route.stream
		local streamResolved = BaseURLResolver.resolve(profile.baseUrl, {
			endpointPath = streamPath,
			mode = (profile.urlMode or "base") :: any,
			model = profile.modelId,
		})
		if streamResolved.ok then
			streamUrl = streamResolved.url
			local query = APIEndpointRouter.streamQuery(profile.protocol)
			if query and streamUrl and not string.find(streamUrl, "?", 1, true) then
				streamUrl ..= "?" .. query
			end
		end
	end

	local note: string? = nil
	if resolved.mode == "full" then
		note = "Full Endpoint URL mode: the path you supplied is used verbatim."
	elseif BaseURLResolver.detectMode(
		BaseURLResolver.parse(profile.baseUrl).path,
		endpointPath
	) == "full" then
		note = "This URL already ends with an endpoint path. Nothing will be appended."
	end

	return {
		ok = true,
		url = url,
		display = BaseURLResolver.forDisplay(url),
		mode = resolved.mode,
		endpointPath = endpointPath,
		note = note,
		error = nil,
		streamingUrl = streamUrl,
	}
end

--=============================================================================
-- CRUD
--=============================================================================

--- Opens an unconfigured preset for editing. Required connection fields are
--- validated by save/test, after the user has had a chance to enter them.
function CustomProviderManager.createDraft(presetId: string): (any?, string?)
	if not UniversalProviderRegistry.getPreset(presetId) then
		return nil, "Unknown provider preset."
	end
	local profile = UniversalProviderRegistry.newProfile(presetId)
	SettingsManager.addProvider(profile)
	Logger.info("AI Provider", "Created provider draft.", { detail = profile.providerName })
	return profile, nil
end

--- Creates a provider from a preset and makes it active.
function CustomProviderManager.create(presetId: string, overrides: { [string]: any }?): (any?, string?)
	local profile = UniversalProviderRegistry.newProfile(presetId)
	if type(overrides) == "table" then
		for key, value in overrides do
			(profile :: any)[key] = value
		end
	end
	local validation = CustomProviderManager.validate(profile)
	if not validation.ok then
		return nil, validation.errors[1] and validation.errors[1].message or "Invalid provider."
	end
	SettingsManager.addProvider(profile)
	SettingsManager.setActiveProvider(profile.id)
	Logger.info("AI Provider", string.format("Created provider \"%s\".", profile.displayName), {
		detail = string.format("%s · %s", profile.providerName, profile.protocol),
	})
	return profile, nil
end

--- Validates then saves. Returns nil plus the issue list when invalid.
function CustomProviderManager.save(profile: any, allowIncomplete: boolean?): (boolean, { ValidationIssue })
	local validation = CustomProviderManager.validate(profile)
	if not validation.ok then
		if not allowIncomplete then return false, validation.errors end
		for _, problem in validation.errors do
			local emptyUrl = problem.field == "baseUrl" and StringUtil.trim(profile.baseUrl or "") == ""
			local missingMapping = problem.field == "schemaMapping" and profile.schemaMapping == nil
			if not emptyUrl and not missingMapping then return false, validation.errors end
		end
	end
	SettingsManager.updateProvider(profile.id, {
		displayName = profile.displayName,
		providerName = profile.providerName,
		providerType = profile.providerType,
		presetId = profile.presetId,
		viaRouter = profile.viaRouter,
		routerProviderId = profile.routerProviderId,
		routerAlias = profile.routerAlias,
		providerCategory = profile.providerCategory,
		iconId = profile.iconId,
		hasOAuth = profile.hasOAuth,
		routerNoAuth = profile.routerNoAuth,
		protocol = profile.protocol,
		baseUrl = profile.baseUrl,
		endpointPath = profile.endpointPath,
		endpointPathCustom = profile.endpointPathCustom,
		urlMode = profile.urlMode,
		modelId = profile.modelId,
		authStyle = profile.authStyle,
		authHeaderName = profile.authHeaderName,
		authHeaderPrefix = profile.authHeaderPrefix,
		authQueryParam = profile.authQueryParam,
		defaultHeaders = profile.defaultHeaders,
		extraHeaders = profile.extraHeaders,
		contextWindow = profile.contextWindow,
		contextWindowMode = profile.contextWindowMode,
		maxOutputTokens = profile.maxOutputTokens,
		maxOutputTokensMode = profile.maxOutputTokensMode,
		temperature = profile.temperature,
		topP = profile.topP,
		reasoningEffort = profile.reasoningEffort,
		reasoningIncludeSummary = profile.reasoningIncludeSummary,
		streaming = profile.streaming,
		toolCalling = profile.toolCalling,
		parallelToolCalling = profile.parallelToolCalling,
		jsonMode = profile.jsonMode,
		timeoutMs = profile.timeoutMs,
		retryOverrides = profile.retryOverrides,
		schemaMapping = profile.schemaMapping,
	})
	return true, {}
end

function CustomProviderManager.duplicate(id: string): (any?, string?)
	local source = SettingsManager.getProvider(id)
	if not source then
		return nil, "Provider not found."
	end
	local copy = table.clone(source)
	copy.id = Time.newId("provider")
	copy.displayName = source.displayName .. " (copy)"
	copy.createdAt = os.time()
	copy.updatedAt = os.time()
	copy.extraHeaders = table.clone(source.extraHeaders or {})
	SettingsManager.addProvider(copy)
	SettingsManager.setActiveProvider(copy.id)
	Logger.info("AI Provider", string.format("Duplicated provider \"%s\".", source.displayName))
	return copy, nil
end

function CustomProviderManager.remove(id: string): boolean
	local existed = SettingsManager.getProvider(id) ~= nil
	if existed then
		SettingsManager.removeProvider(id)
		Logger.info("AI Provider", "Removed provider profile.")
	end
	return existed
end

--=============================================================================
-- CREDENTIALS
--=============================================================================

-- Injected so this module never has to depend on the credential store directly.
local credentialClear: (string) -> () = function(_id) end

function CustomProviderManager.setCredentialClear(fn: (string) -> ())
	credentialClear = if type(fn) == "function" then fn else function(_id)
	end
end

--- Clears the active provider and forgets session credentials for it.
function CustomProviderManager.disconnect(id: string?): boolean
	local profile = if id then SettingsManager.getProvider(id) else SettingsManager.getActiveProvider()
	if profile then
		credentialClear(profile.id)
	end
	if not profile or SettingsManager.getValue("activeProviderId") == profile.id then
		SettingsManager.setActiveProvider(nil)
	end
	return true
end

--=============================================================================
-- HEADERS
--=============================================================================

--- Parses `Name: value` lines into a header table. Invalid lines are reported.
function CustomProviderManager.parseHeaders(text: string): ({ [string]: string }, { string })
	local headers: { [string]: string } = {}
	local problems: { string } = {}
	for line in string.gmatch((text or "") .. "\n", "(.-)\r?\n") do
		local trimmed = StringUtil.trim(line)
		if #trimmed > 0 then
			local name, value = string.match(trimmed, "^([%w%-_%.]+)%s*:%s*(.*)$")
			if name then
				headers[name] = StringUtil.trim(value)
			else
				problems[#problems + 1] = string.format("Could not parse %q — expected `Name: value`.", trimmed)
			end
		end
	end
	return headers, problems
end

--- Renders a header table back into `Name: value` lines.
function CustomProviderManager.formatHeaders(headers: { [string]: string }?): string
	if type(headers) ~= "table" then
		return ""
	end
	local lines: { string } = {}
	for name, value in headers do
		lines[#lines + 1] = string.format("%s: %s", name, value)
	end
	table.sort(lines)
	return table.concat(lines, "\n")
end

--=============================================================================
-- ENDPOINT PATH SUGGESTION
--=============================================================================

--- Returns the endpoint path a protocol expects, for the editable field.
function CustomProviderManager.suggestEndpointPath(protocolId: string, streaming: boolean?): string
	local route = APIEndpointRouter.get(protocolId)
	if streaming then
		return route.stream or route.chat
	end
	return route.chat
end

return CustomProviderManager
