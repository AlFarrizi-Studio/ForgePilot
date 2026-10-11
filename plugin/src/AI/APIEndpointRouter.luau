--!strict
--[[
	ForgePilot / AI / APIEndpointRouter
	Maps a protocol to its endpoint paths.

	Each protocol declares:
	  * chat      - the non-streaming request path
	  * stream    - the streaming request path (falls back to chat)
	  * models    - the model-list path (nil when the provider has none we can read)
	  * template  - whether the path carries a "{model}" placeholder

	Nothing here ever invents a "/v1". The path is exactly what the protocol's
	documentation specifies, and BaseURLResolver decides whether to append it.
]]

local APIEndpointRouter = {}

export type Route = {
	chat: string,
	stream: string?,
	models: string?,
	usesModelInPath: boolean,
	streamNeedsQuery: string?,
}

local ROUTES: { [string]: Route } = {
	openai_chat = {
		chat = "/chat/completions",
		stream = "/chat/completions",
		models = "/models",
		usesModelInPath = false,
	},
	openai_text_completions = {
		chat = "/completions",
		stream = "/completions",
		models = "/models",
		usesModelInPath = false,
	},
	openai_responses = {
		chat = "/responses",
		stream = "/responses",
		models = "/models",
		usesModelInPath = false,
	},
	openrouter = {
		chat = "/chat/completions",
		stream = "/chat/completions",
		models = "/models",
		usesModelInPath = false,
	},
	anthropic_messages = {
		chat = "/v1/messages",
		stream = "/v1/messages",
		models = nil,
		usesModelInPath = false,
	},
	gemini_native = {
		chat = "/v1beta/models/{model}:generateContent",
		stream = "/v1beta/models/{model}:streamGenerateContent",
		models = "/v1beta/models",
		usesModelInPath = true,
		streamNeedsQuery = "alt=sse",
	},
	gemini_openai = {
		chat = "/v1beta/openai/chat/completions",
		stream = "/v1beta/openai/chat/completions",
		models = "/v1beta/openai/models",
		usesModelInPath = false,
	},
	openai_compatible = {
		chat = "/chat/completions",
		stream = "/chat/completions",
		models = "/models",
		usesModelInPath = false,
	},
	custom_rest = {
		chat = "",
		stream = nil,
		models = nil,
		usesModelInPath = false,
	},
}

--- A safe default for protocols we have no explicit entry for.
local DEFAULT_ROUTE: Route = {
	chat = "/chat/completions",
	stream = "/chat/completions",
	models = "/models",
	usesModelInPath = false,
}

function APIEndpointRouter.get(protocolId: string?): Route
	if type(protocolId) ~= "string" then
		return DEFAULT_ROUTE
	end
	return ROUTES[protocolId] or DEFAULT_ROUTE
end

--- The non-streaming path for a protocol.
function APIEndpointRouter.chatPath(protocolId: string?): string
	return APIEndpointRouter.get(protocolId).chat
end

--- The streaming path for a protocol, falling back to the chat path.
function APIEndpointRouter.streamPath(protocolId: string?): string
	local route = APIEndpointRouter.get(protocolId)
	return route.stream or route.chat
end

--- The model-list path, or nil when the provider exposes none we can read.
function APIEndpointRouter.modelsPath(protocolId: string?): string?
	return APIEndpointRouter.get(protocolId).models
end

--- True when the path embeds the model id (Gemini native).
function APIEndpointRouter.usesModelInPath(protocolId: string?): boolean
	return APIEndpointRouter.get(protocolId).usesModelInPath
end

--- Query parameters a streaming request needs (Gemini needs alt=sse).
function APIEndpointRouter.streamQuery(protocolId: string?): string?
	return APIEndpointRouter.get(protocolId).streamNeedsQuery
end

--- True when the protocol has a readable model-list endpoint.
function APIEndpointRouter.supportsModelList(protocolId: string?): boolean
	return APIEndpointRouter.modelsPath(protocolId) ~= nil
end

return APIEndpointRouter