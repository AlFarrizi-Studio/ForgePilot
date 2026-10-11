--!strict
--[[
	ForgePilot / AI / UniversalProviderRegistry
	The single source of truth for AI providers, protocols and authentication.

	Supports nine wire protocols and five authentication styles. Nothing here is
	hardcoded to a particular company beyond optional presets: any HTTPS base URL
	plus a protocol plus an auth style is a valid provider.
]]

local APIEndpointRouter = require(script.Parent.APIEndpointRouter)
local BaseURLResolver = require(script.Parent.BaseURLResolver)
local Time = require(script.Parent.Parent.Utilities.Time)

local UniversalProviderRegistry = {}

--=============================================================================
-- TYPES
--=============================================================================

export type ProtocolId =
	| "openai_chat"
	| "openai_text_completions"
	| "openai_responses"
	| "openrouter"
	| "anthropic_messages"
	| "gemini_native"
	| "gemini_openai"
	| "openai_compatible"
	| "custom_rest"

export type AuthStyle =
	| "bearer" -- Authorization: Bearer KEY
	| "header" -- a named header carries the key (x-api-key …)
	| "query" -- key appended as a query parameter
	| "none" -- unauthenticated endpoint
	| "custom" -- an arbitrary header with an optional prefix, user-defined

export type ProviderType = "openai" | "openrouter" | "anthropic" | "gemini" | "openai_compatible" | "custom_rest"

export type Protocol = {
	id: ProtocolId,
	label: string,
	description: string,
	authStyle: AuthStyle,
	authHeaderName: string?,
	authHeaderPrefix: string?,
	authQueryParam: string?,
	defaultHeaders: { [string]: string },
	sse: boolean,
	supportsStreaming: boolean,
	supportsToolCalling: boolean,
	supportsSystemRole: boolean,
	supportsImages: boolean,
	supportsDocuments: boolean,
	supportsJsonMode: boolean,
	supportsReasoningEffort: boolean,
	supportsReasoningSummaries: boolean,
	supportsPromptCaching: boolean,
	supportsTextCompletions: boolean,
	supportsNativeImages: boolean,
	usageField: string,
	--- Endpoint paths, mirrored from APIEndpointRouter for convenience.
	path: string,
	streamPath: string,
	modelsPath: string?,
}

--=============================================================================
-- PROTOCOLS
--=============================================================================

local function base(overrides: { [string]: any }): Protocol
	local defaults: Protocol = {
		id = "openai_compatible",
		label = "OpenAI-Compatible",
		description = "Chat Completions schema served over HTTPS.",
		authStyle = "bearer",
		authHeaderName = nil,
		authHeaderPrefix = nil,
		authQueryParam = nil,
		defaultHeaders = {},
		sse = true,
		supportsStreaming = true,
		supportsToolCalling = true,
		supportsSystemRole = true,
		supportsImages = true,
		supportsDocuments = false,
		supportsJsonMode = true,
		supportsReasoningEffort = false,
		supportsReasoningSummaries = false,
		supportsPromptCaching = false,
		supportsTextCompletions = false,
		supportsNativeImages = true,
		usageField = "usage",
	}
	for key, value in overrides do
		(defaults :: any)[key] = value
	end

	-- Endpoint paths come from the router so there is exactly one source.
	local route = APIEndpointRouter.get(defaults.id)
	local withPaths = defaults :: any
	withPaths.path = route.chat
	withPaths.streamPath = route.stream or route.chat
	withPaths.modelsPath = route.models
	return defaults
end

local protocols: { [ProtocolId]: Protocol } = {
	openai_chat = base({
		id = "openai_chat",
		label = "OpenAI Chat Completions",
		description = "POST /chat/completions. Streams SSE `data:` lines ending with `data: [DONE]`.",
		authStyle = "bearer",
		supportsReasoningEffort = true,
		supportsReasoningSummaries = true,
		supportsPromptCaching = true,
		supportsDocuments = true,
	}),

	openai_text_completions = base({
		id = "openai_text_completions",
		label = "OpenAI Text Completions (Legacy)",
		description = "POST /completions using `prompt`. Only legacy completion models support this.",
		supportsToolCalling = false,
		supportsImages = false,
		supportsTextCompletions = true,
	}),

	openai_responses = base({
		id = "openai_responses",
		label = "OpenAI Responses API",
		description = "POST /responses. Typed SSE events; tool calls and reasoning are output items.",
		supportsReasoningEffort = true,
		supportsReasoningSummaries = true,
		supportsPromptCaching = true,
		supportsDocuments = true,
	}),

	openrouter = base({
		id = "openrouter",
		label = "OpenRouter Chat Completions",
		description = "POST /chat/completions. Add HTTP-Referer and X-Title headers if required.",
		authStyle = "bearer",
		supportsReasoningEffort = true,
		supportsReasoningSummaries = true,
		supportsPromptCaching = true,
	}),

	anthropic_messages = base({
		id = "anthropic_messages",
		label = "Anthropic Messages",
		description = "POST /v1/messages with x-api-key and anthropic-version headers. Named SSE events.",
		authStyle = "header",
		authHeaderName = "x-api-key",
		defaultHeaders = { ["anthropic-version"] = "2023-06-01" },
		supportsJsonMode = false,
		supportsReasoningSummaries = true,
		supportsPromptCaching = true,
		supportsDocuments = true,
		usageField = "usage",
	}),

	gemini_native = base({
		id = "gemini_native",
		label = "Google Gemini (Native)",
		description = "POST /v1beta/models/{model}:generateContent with x-goog-api-key. Streams with ?alt=sse.",
		authStyle = "header",
		authHeaderName = "x-goog-api-key",
		supportsJsonMode = true,
		supportsReasoningSummaries = true,
		supportsPromptCaching = true,
		supportsDocuments = true,
		usageField = "usageMetadata",
	}),

	gemini_openai = base({
		id = "gemini_openai",
		label = "Google Gemini (OpenAI-Compatible)",
		description = "Gemini's OpenAI-compatible surface at /v1beta/openai/chat/completions.",
		authStyle = "bearer",
		supportsJsonMode = true,
		supportsReasoningSummaries = true,
		usageField = "usage",
	}),

	openai_compatible = base({
		id = "openai_compatible",
		label = "Custom OpenAI-Compatible",
		description = "Any server implementing the Chat Completions schema.",
	}),

	custom_rest = base({
		id = "custom_rest",
		label = "Custom REST (Explicit Schema)",
		description = "Any JSON REST endpoint. Requires an explicit request/response field mapping.",
		authStyle = "bearer",
		sse = false,
		supportsStreaming = false,
		supportsToolCalling = false,
		supportsImages = false,
		supportsJsonMode = false,
		usageField = "",
	}),
}

UniversalProviderRegistry.Protocols = protocols

function UniversalProviderRegistry.getProtocol(id: any): Protocol
	if type(id) == "string" and protocols[id] then
		return protocols[id :: any]
	end
	return protocols.openai_compatible
end

function UniversalProviderRegistry.protocolList(): { Protocol }
	local list = {}
	for _, protocol in protocols do
		list[#list + 1] = protocol
	end
	table.sort(list, function(a, b)
		return a.label < b.label
	end)
	return list
end

--=============================================================================
-- AUTH
--=============================================================================

export type AuthConfig = {
	style: AuthStyle,
	headerName: string?,
	headerPrefix: string?,
	queryParam: string?,
}

--- Builds the authentication header/query entry for a provider.
--- Returns `headers`, plus the query string fragment when auth uses a query param.
function UniversalProviderRegistry.buildAuthHeaders(
	auth: AuthConfig?,
	apiKey: string?
): ({ [string]: string }, string?)
	local headers: { [string]: string } = {}
	if type(apiKey) ~= "string" or #apiKey == 0 then
		return headers, nil
	end

	local style = (auth and auth.style) or "bearer"

	if style == "bearer" then
		headers["Authorization"] = "Bearer " .. apiKey
	elseif style == "header" then
		headers[(auth and auth.headerName) or "x-api-key"] = apiKey
	elseif style == "query" then
		local param = (auth and auth.queryParam) or "key"
		return headers, string.format("%s=%s", param, apiKey)
	elseif style == "custom" then
		local name = auth and auth.headerName
		if type(name) == "string" and #name > 0 then
			local prefix = (auth and auth.headerPrefix) or ""
			headers[name] = if #prefix > 0 then (prefix .. apiKey) else apiKey
		end
	end
	-- "none" contributes nothing by design.
	return headers, nil
end

--=============================================================================
-- PRESETS
--=============================================================================

export type ModelMetadata = {
	contextWindow: number,
	maxOutputTokens: number,
	inputCostPerMTok: number?,
	outputCostPerMTok: number?,
	capabilities: { [string]: string },
}

export type Preset = {
	id: string,
	label: string,
	providerType: ProviderType,
	protocol: ProtocolId,
	baseUrl: string,
	docsUrl: string,
	notes: string,
	authStyle: AuthStyle,
	authHeaderName: string?,
	defaultHeaders: { [string]: string },
	providerCapabilities: { [string]: string },
	modelMetadata: { [string]: ModelMetadata },
}

local PRESET_CAPABILITIES = {
	openaiLike = {
		text_input = "yes",
		text_output = "yes",
		vision = "yes",
		image_generation = "no",
		document_input = "yes",
		pdf_input = "yes",
		audio_input = "yes",
		audio_output = "no",
		video_input = "no",
		tool_calling = "yes",
		parallel_tool_calling = "yes",
		structured_json = "yes",
		streaming = "yes",
		reasoning = "yes",
		reasoning_effort = "yes",
		reasoning_summaries = "yes",
		prompt_caching = "yes",
		temperature = "yes",
		top_p = "yes",
		system_instructions = "yes",
		text_completions = "yes",
	},
	anthropicLike = {
		text_input = "yes",
		text_output = "yes",
		vision = "yes",
		image_generation = "no",
		document_input = "yes",
		pdf_input = "no",
		audio_input = "no",
		audio_output = "no",
		video_input = "no",
		tool_calling = "yes",
		parallel_tool_calling = "yes",
		structured_json = "no",
		streaming = "yes",
		reasoning = "yes",
		reasoning_effort = "no",
		reasoning_summaries = "yes",
		prompt_caching = "yes",
		temperature = "yes",
		top_p = "yes",
		system_instructions = "yes",
		text_completions = "no",
	},
	geminiLike = {
		text_input = "yes",
		text_output = "yes",
		vision = "yes",
		image_generation = "yes",
		document_input = "yes",
		pdf_input = "yes",
		audio_input = "yes",
		audio_output = "yes",
		video_input = "yes",
		tool_calling = "yes",
		parallel_tool_calling = "no",
		structured_json = "yes",
		streaming = "yes",
		reasoning = "yes",
		reasoning_effort = "no",
		reasoning_summaries = "yes",
		prompt_caching = "yes",
		temperature = "yes",
		top_p = "yes",
		system_instructions = "yes",
		text_completions = "no",
	},
	unknownAll = {
		text_input = "unknown",
		text_output = "unknown",
		vision = "unknown",
		image_generation = "unknown",
		document_input = "unknown",
		pdf_input = "unknown",
		audio_input = "unknown",
		audio_output = "unknown",
		video_input = "unknown",
		tool_calling = "unknown",
		parallel_tool_calling = "unknown",
		structured_json = "unknown",
		streaming = "unknown",
		reasoning = "unknown",
		reasoning_effort = "unknown",
		reasoning_summaries = "unknown",
		prompt_caching = "unknown",
		temperature = "unknown",
		top_p = "unknown",
		system_instructions = "unknown",
		text_completions = "unknown",
	},
}

local presets: { [string]: Preset } = {
	openai = {
		id = "openai",
		label = "OpenAI",
		providerType = "openai",
		protocol = "openai_chat",
		baseUrl = "https://api.openai.com/v1",
		docsUrl = "https://platform.openai.com/docs/api-reference",
		notes = "Chat Completions by default. Switch protocol for legacy /completions or the Responses API.",
		authStyle = "bearer",
		defaultHeaders = {},
		providerCapabilities = table.clone(PRESET_CAPABILITIES.openaiLike),
		modelMetadata = {
			["gpt-4o"] = {
				contextWindow = 128000,
				maxOutputTokens = 16384,
				inputCostPerMTok = 2.50,
				outputCostPerMTok = 10.00,
				capabilities = { reasoning = "no" },
			},
			["gpt-4o-mini"] = {
				contextWindow = 128000,
				maxOutputTokens = 16384,
				inputCostPerMTok = 0.15,
				outputCostPerMTok = 0.60,
				capabilities = {},
			},
			["gpt-4.1"] = {
				contextWindow = 1047576,
				maxOutputTokens = 32768,
				inputCostPerMTok = 2.00,
				outputCostPerMTok = 8.00,
				capabilities = { reasoning = "no" },
			},
			["gpt-4.1-mini"] = {
				contextWindow = 1047576,
				maxOutputTokens = 32768,
				inputCostPerMTok = 0.40,
				outputCostPerMTok = 1.60,
				capabilities = { reasoning = "no" },
			},
			["o3"] = {
				contextWindow = 200000,
				maxOutputTokens = 100000,
				inputCostPerMTok = 2.00,
				outputCostPerMTok = 8.00,
				capabilities = { temperature = "no", top_p = "no" },
			},
			["o4-mini"] = {
				contextWindow = 200000,
				maxOutputTokens = 100000,
				inputCostPerMTok = 1.10,
				outputCostPerMTok = 4.40,
				capabilities = { temperature = "no", top_p = "no" },
			},
		},
	},

	openrouter = {
		id = "openrouter",
		label = "OpenRouter",
		providerType = "openrouter",
		protocol = "openrouter",
		baseUrl = "https://openrouter.ai/api/v1",
		docsUrl = "https://openrouter.ai/docs",
		notes = "Aggregator. HTTP-Referer and X-Title headers are optional but recommended.",
		authStyle = "bearer",
		defaultHeaders = {},
		providerCapabilities = table.clone(PRESET_CAPABILITIES.openaiLike),
		modelMetadata = {},
	},

	gemini = {
		id = "gemini",
		label = "Google Gemini",
		providerType = "gemini",
		protocol = "gemini_native",
		baseUrl = "https://generativelanguage.googleapis.com",
		docsUrl = "https://ai.google.dev/api",
		notes = "Native generateContent. Audio, video and documents are first-class inlineData parts.",
		authStyle = "header",
		authHeaderName = "x-goog-api-key",
		defaultHeaders = {},
		providerCapabilities = table.clone(PRESET_CAPABILITIES.geminiLike),
		modelMetadata = {
			["gemini-2.0-flash"] = {
				contextWindow = 1048576,
				maxOutputTokens = 8192,
				inputCostPerMTok = 0.10,
				outputCostPerMTok = 0.40,
				capabilities = {},
			},
			["gemini-2.5-flash"] = {
				contextWindow = 1048576,
				maxOutputTokens = 65536,
				inputCostPerMTok = 0.30,
				outputCostPerMTok = 2.50,
				capabilities = {},
			},
			["gemini-2.5-pro"] = {
				contextWindow = 1048576,
				maxOutputTokens = 65536,
				inputCostPerMTok = 1.25,
				outputCostPerMTok = 10.00,
				capabilities = {},
			},
		},
	},

	gemini_openai = {
		id = "gemini_openai",
		label = "Google Gemini (OpenAI surface)",
		providerType = "gemini",
		protocol = "gemini_openai",
		baseUrl = "https://generativelanguage.googleapis.com/v1beta/openai",
		docsUrl = "https://ai.google.dev/gemini-api/docs/openai",
		notes = "Use when an app expects an OpenAI-compatible client against Gemini.",
		authStyle = "bearer",
		defaultHeaders = {},
		providerCapabilities = table.clone(PRESET_CAPABILITIES.geminiLike),
		modelMetadata = {},
	},

	anthropic = {
		id = "anthropic",
		label = "Anthropic",
		providerType = "anthropic",
		protocol = "anthropic_messages",
		baseUrl = "https://api.anthropic.com",
		docsUrl = "https://docs.anthropic.com/en/api",
		notes = "Requires x-api-key and the anthropic-version header (ForgePilot sets 2023-06-01).",
		authStyle = "header",
		authHeaderName = "x-api-key",
		defaultHeaders = { ["anthropic-version"] = "2023-06-01" },
		providerCapabilities = table.clone(PRESET_CAPABILITIES.anthropicLike),
		modelMetadata = {
			["claude-sonnet-4-20250514"] = {
				contextWindow = 200000,
				maxOutputTokens = 64000,
				inputCostPerMTok = 3.00,
				outputCostPerMTok = 15.00,
				capabilities = { structured_json = "yes" },
			},
			["claude-3-5-haiku-latest"] = {
				contextWindow = 200000,
				maxOutputTokens = 8192,
				inputCostPerMTok = 0.80,
				outputCostPerMTok = 4.00,
				capabilities = { reasoning = "no" },
			},
		},
	},

	custom = {
		id = "custom",
		label = "Custom OpenAI-Compatible",
		providerType = "openai_compatible",
		protocol = "openai_compatible",
		baseUrl = "",
		docsUrl = "",
		notes = "Any HTTPS endpoint serving the Chat Completions schema.",
		authStyle = "bearer",
		defaultHeaders = {},
		providerCapabilities = table.clone(PRESET_CAPABILITIES.unknownAll),
		modelMetadata = {},
	},

	rest = {
		id = "rest",
		label = "Custom REST (Explicit Schema)",
		providerType = "custom_rest",
		protocol = "custom_rest",
		baseUrl = "",
		docsUrl = "",
		notes = "Requires an explicit request/response field mapping. Arbitrary REST is never assumed to be OpenAI-compatible.",
		authStyle = "bearer",
		defaultHeaders = {},
		providerCapabilities = table.clone(PRESET_CAPABILITIES.unknownAll),
		modelMetadata = {},
	},
}

-- Match the current 9router chat catalog. Credentials and OAuth protocol
-- differences remain in 9router, not in Roblox plugin preferences.
local RouterCatalog = require(script.Parent.RouterProviderCatalog)
for _, entry in RouterCatalog do
    presets[entry.id] = {
        id = entry.id, label = entry.label, providerType = "openai_compatible",
        protocol = "openai_compatible", baseUrl = "http://127.0.0.1:20128/v1",
        authStyle = "bearer", defaultHeaders = {}, docsUrl = entry.docsUrl,
        notes = "Connect this provider in 9Router. Select a model from Refresh models; account limits apply.",
        providerCapabilities = table.clone(PRESET_CAPABILITIES.unknownAll), modelMetadata = {},
        category = entry.category, iconId = entry.iconId, viaRouter = true,
        routerProviderId = entry.routerProviderId, routerAlias = entry.routerAlias,
        hasOAuth = entry.hasOAuth, noAuth = entry.noAuth, deprecated = entry.deprecated,
    }
end
local nativeIcons = { openai = "openai", openrouter = "openrouter", anthropic = "anthropic", gemini = "gemini", groq = "groq", deepseek = "deepseek", mistral = "mistral", together = "together" }
for id, preset in presets do
    if not preset.viaRouter then
        preset.category = "direct"
        preset.iconId = nativeIcons[id] or ""
    end
end
UniversalProviderRegistry.Presets = presets

function UniversalProviderRegistry.getPreset(id: any): Preset?
	if type(id) == "string" then
		return presets[id]
	end
	return nil
end

function UniversalProviderRegistry.presetList(): { Preset }
	local list = {}
	for _, preset in presets do
		list[#list + 1] = preset
	end
	table.sort(list, function(a, b)
		return a.label < b.label
	end)
	return list
end

function UniversalProviderRegistry.presetsForType(providerType: ProviderType): { Preset }
	local list = {}
	for _, preset in presets do
		if preset.providerType == providerType then
			list[#list + 1] = preset
		end
	end
	table.sort(list, function(a, b)
		return a.label < b.label
	end)
	return list
end

--=============================================================================
-- ENDPOINT RESOLUTION
--=============================================================================

--- Builds the final URL for a provider profile.
function UniversalProviderRegistry.resolveUrl(
	profile: {
		baseUrl: string,
		protocol: string,
		endpointPath: string?,
		urlMode: string?,
		modelId: string?,
	},
	options: { streaming: boolean? }?
): (string?, string?)
	local opts = options or {}
	local protocolId = profile.protocol
	local streaming = opts.streaming == true

	local route = APIEndpointRouter.get(protocolId)

	-- The endpoint path follows the protocol by default, so changing protocols
	-- can never leave a stale path behind. A path is honoured only when the user
	-- explicitly edited it (endpointPathCustom).
	local endpointPath: string = if profile.endpointPathCustom == true
			and type(profile.endpointPath) == "string"
		then profile.endpointPath
		else if streaming then route.stream or route.chat else route.chat

	local resolved = BaseURLResolver.resolve(profile.baseUrl, {
		endpointPath = endpointPath,
		mode = (profile.urlMode or "base") :: any,
		streaming = streaming,
		model = profile.modelId,
	})

	if not resolved.ok then
		return nil, resolved.error
	end

	local url = resolved.url :: string
	local needsQuery = if streaming then APIEndpointRouter.streamQuery(protocolId) else nil
	if needsQuery then
		if string.find(url, "?", 1, true) then
			url ..= "&" .. needsQuery
		else
			url ..= "?" .. needsQuery
		end
	end
	return url, nil
end

--- The model-list URL, or nil plus a reason when the protocol has none.
function UniversalProviderRegistry.modelListUrl(profile: { baseUrl: string, protocol: string, endpointPath: string?, urlMode: string? }): (string?, string?)
	local path = APIEndpointRouter.modelsPath(profile.protocol)
	if not path then
		local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)
		return nil,
			string.format(
				"%s does not expose a model list endpoint ForgePilot can read. Enter the model id manually.",
				protocol.label
			)
	end
	local resolved = BaseURLResolver.resolve(profile.baseUrl, {
		endpointPath = path,
		mode = (profile.urlMode or "base") :: any,
	})
	if not resolved.ok then
		return nil, resolved.error
	end
	return resolved.url, nil
end

function UniversalProviderRegistry.isTrustedHost(url: string?): boolean
	return BaseURLResolver.isTrustedHost(url)
end

--- Normalises a base URL. Kept for backwards compatibility.
function UniversalProviderRegistry.normaliseBaseUrl(raw: string?): (string?, string?)
	return BaseURLResolver.normaliseBase(raw or "")
end

--=============================================================================
-- PROFILE CONSTRUCTION
--=============================================================================

--- Creates a new, blank provider profile. No credentials are ever prefilled.
function UniversalProviderRegistry.newProfile(presetId: string): any
	local preset = UniversalProviderRegistry.getPreset(presetId) or presets.custom
	local route = APIEndpointRouter.get(preset.protocol)
	local profile: any = {
		id = Time.newId("provider"),
		displayName = preset.label,
		providerName = preset.label,
		providerType = preset.providerType,
		presetId = preset.id,
		viaRouter = preset.viaRouter,
		routerProviderId = preset.routerProviderId,
		routerAlias = preset.routerAlias,
		providerCategory = preset.category,
		iconId = preset.iconId,
		hasOAuth = preset.hasOAuth,
		routerNoAuth = preset.noAuth,
		protocol = preset.protocol,
		baseUrl = preset.baseUrl,
		endpointPath = route.chat,
		-- The path follows the protocol until the user edits it by hand.
		endpointPathCustom = false,
		urlMode = "base",
		modelId = "",
		authStyle = preset.authStyle,
		authHeaderName = preset.authHeaderName,
		authHeaderPrefix = nil,
		authQueryParam = nil,
		defaultHeaders = table.clone(preset.defaultHeaders or {}),
		extraHeaders = {},
		contextWindow = 128000,
		contextWindowMode = "auto",
		maxOutputTokens = 8192,
		maxOutputTokensMode = "auto",
		temperature = 0.7,
		topP = 1.0,
		reasoningEffort = "",
		reasoningIncludeSummary = true,
		streaming = true,
		toolCalling = true,
		parallelToolCalling = true,
		jsonMode = false,
		timeoutMs = 120000,
		retryOverrides = nil,
		schemaMapping = nil,
		createdAt = os.time(),
		updatedAt = os.time(),
	}
	-- The endpoint path must track the protocol: Custom REST has no default.
	if profile.protocol == "custom_rest" then
		profile.endpointPath = ""
	end
	return profile
end

--- Applies preset defaults without clobbering what the user already set.
function UniversalProviderRegistry.applyPreset(profile: any, presetId: string): boolean
	local preset = UniversalProviderRegistry.getPreset(presetId)
	if not preset then
		return false
	end
	local route = APIEndpointRouter.get(preset.protocol)
	profile.providerType = preset.providerType
	profile.protocol = preset.protocol
	profile.presetId = preset.id
	profile.viaRouter = preset.viaRouter
	profile.routerProviderId = preset.routerProviderId
	profile.routerAlias = preset.routerAlias
	profile.providerCategory = preset.category
	profile.iconId = preset.iconId
	profile.hasOAuth = preset.hasOAuth
	profile.routerNoAuth = preset.noAuth
	profile.providerName = preset.label
	profile.authStyle = preset.authStyle
	profile.authHeaderName = preset.authHeaderName
	profile.defaultHeaders = table.clone(preset.defaultHeaders or {})
	if type(profile.baseUrl) ~= "string" or #profile.baseUrl == 0 then
		profile.baseUrl = preset.baseUrl
	end
	if type(profile.endpointPath) ~= "string" or #profile.endpointPath == 0 then
		profile.endpointPath = route.chat
	end
	return true
end

return UniversalProviderRegistry