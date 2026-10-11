--!strict
--[[
	ForgePilot / AI / Adapters / CustomJSONAdapter
	A REST endpoint that is NOT OpenAI-compatible, driven by an explicit schema
	mapping the user configures.

	The mapping is deliberately literal — no guessing. Every request and response
	field is named by the user with a dotted path:

	  schemaMapping = {
	    request = {
	      prompt     = "input.text",        -- where to put the prompt
	      model     = "parameters.model",  -- where to put the model id
	      system    = "input.system",       -- optional
	      stream    = "parameters.stream",  -- optional boolean
	      tools     = "tools",              -- optional array
	    },
	    response = {
	      text      = "output.answer",     -- where the reply lives
	      reasoning = "output.thoughts",    -- optional
	      finish    = "meta.finish_reason", -- optional
	      usage = { input = "usage.prompt", output = "usage.completion" },
	    },
	  }

	Without a mapping the adapter refuses to build a request and says exactly what
	is missing. Arbitrary REST is never assumed to be OpenAI-compatible.
]]

local JSONValidator = require(script.Parent.Parent.Parent.Utilities.JSONValidator)
local StringUtil = require(script.Parent.Parent.Parent.Utilities.StringUtil)

local UniversalProviderRegistry = require(script.Parent.Parent.UniversalProviderRegistry)

local Adapter = {}

local AdapterTypes = require(script.Parent.Parent.AdapterTypes)

--=============================================================================
-- PATH HELPERS
--=============================================================================

--- Reads a dotted path out of a decoded table. Returns nil when absent.
local function readPath(root: any, path: any): any
	if type(path) ~= "string" or #path == 0 or type(root) ~= "table" then
		return nil
	end
	local cursor = root
	for segment in string.gmatch(path, "[^%.]+") do
		if type(cursor) ~= "table" then
			return nil
		end
		cursor = cursor[segment]
		if cursor == nil then
			return nil
		end
	end
	return cursor
end

--- Writes a value at a dotted path, creating intermediate tables.
local function writePath(root: { [string]: any }, path: any, value: any): boolean
	if type(path) ~= "string" or #path == 0 then
		return false
	end
	local segments: { string } = {}
	for segment in string.gmatch(path, "[^%.]+") do
		segments[#segments + 1] = segment
	end
	if #segments == 0 then
		return false
	end

	local cursor: any = root
	for index = 1, #segments - 1 do
		local key = segments[index]
		if type(cursor[key]) ~= "table" then
			cursor[key] = {}
		end
		cursor = cursor[key]
	end
	cursor[segments[#segments]] = value
	return true
end

Adapter.readPath = readPath
Adapter.writePath = writePath

--=============================================================================
-- REQUEST
--=============================================================================

function Adapter.buildRequest(profile: any, spec: AdapterTypes.RequestSpec, includeStream: boolean): (any?, string?)
	local mapping = profile.schemaMapping
	if type(mapping) ~= "table" or type(mapping.request) ~= "table" then
		return nil,
			"Custom REST providers need a Request Schema Mapping. Add one in Advanced Settings, for example prompt → \"input.text\"."
	end

	local url, urlError = UniversalProviderRegistry.resolveUrl(profile, { streaming = includeStream })
	if not url then
		return nil, urlError
	end

	local requestMapping = mapping.request
	local body: { [string]: any } = {}

	-- The system prompt and conversation are combined into ONE text block unless
	-- the user mapped a separate `system` destination. An unset `system` path
	-- therefore leaves no key in the body at all.
	local systemText = if spec.system and #StringUtil.trim(spec.system) > 0 then spec.system else nil

	local promptParts: { string } = {}
	if systemText then
		promptParts[#promptParts + 1] = systemText
	end
	for _, message in spec.messages do
		local text = message.content
		if (not text or #text == 0) and message.parts then
			local pieces = {}
			for _, part in message.parts do
				if part.kind == "text" then
					pieces[#pieces + 1] = part.text
				end
			end
			text = table.concat(pieces, "\n")
		end
		if text and #text > 0 then
			promptParts[#promptParts + 1] = text
		end
	end
	local prompt = table.concat(promptParts, "\n\n")

	if not writePath(body, requestMapping.prompt, prompt) then
		return nil, "Request Schema Mapping is missing a `prompt` destination path."
	end
	if requestMapping.model and not writePath(body, requestMapping.model, spec.model) then
		return nil, "Request Schema Mapping has an invalid `model` destination path."
	end
	if requestMapping.system and systemText then
		writePath(body, requestMapping.system, systemText)
	end
	if requestMapping.temperature and spec.temperature ~= nil then
		writePath(body, requestMapping.temperature, spec.temperature)
	end
	if requestMapping.maxOutputTokens and spec.maxOutputTokens then
		writePath(body, requestMapping.maxOutputTokens, spec.maxOutputTokens)
	end
	if requestMapping.stream then
		writePath(body, requestMapping.stream, includeStream and spec.streaming == true)
	end
	if requestMapping.tools and spec.tools and #spec.tools > 0 then
		writePath(body, requestMapping.tools, spec.tools)
	end

	-- Any static fields the user declared verbatim.
	if type(mapping.staticFields) == "table" then
		for path, value in mapping.staticFields do
			writePath(body, path, value)
		end
	end

	local encoded, encodeError = JSONValidator.encode(body)
	if not encoded then
		return nil, "Could not serialise the request: " .. tostring(encodeError)
	end
	return { url = url, body = encoded, jsonBody = body }, nil
end

function Adapter.buildHeaders(profile: any, apiKey: string?, streaming: boolean): { [string]: string }
	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }

	local authHeaders = UniversalProviderRegistry.buildAuthHeaders({
		style = profile.authStyle or "bearer",
		headerName = profile.authHeaderName,
		headerPrefix = profile.authHeaderPrefix,
		queryParam = profile.authQueryParam,
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
	if streaming then
		headers["Accept"] = "text/event-stream"
	end
	return headers
end

--=============================================================================
-- RESPONSE
--=============================================================================

function Adapter.parseResponse(body: string, profile: any?): (AdapterTypes.CompleteResponse?, string?)
	local decoded, err = JSONValidator.decode(body)
	if not decoded or type(decoded) ~= "table" then
		return nil, "Provider returned a body that is not valid JSON: " .. tostring(err)
	end

	local mapping = if profile then profile.schemaMapping else nil
	local responseMapping = if type(mapping) == "table" then mapping.response else nil

	if type(decoded.error) == "table" then
		return nil, tostring(decoded.error.message or "Provider reported an error.")
	end

	if type(responseMapping) ~= "table" then
		return nil,
			"Custom REST providers need a Response Schema Mapping. Add one in Advanced Settings so ForgePilot knows where the reply lives."
	end

	local text = readPath(decoded, responseMapping.text)
	if text == nil then
		return nil, string.format(
			"No text found at the mapped response path `%s`. The provider may have changed its shape.",
			tostring(responseMapping.text)
		)
	end
	if type(text) ~= "string" then
		return nil, string.format("The value at `%s` is a %s, not a string.", tostring(responseMapping.text), type(text))
	end

	local reasoning = readPath(decoded, responseMapping.reasoning)
	if type(reasoning) ~= "string" then
		reasoning = nil
	end

	local finishReason = readPath(decoded, responseMapping.finish)

	local inputTokens: number? = nil
	local outputTokens: number? = nil
	local usageMapping = responseMapping.usage
	if type(usageMapping) == "table" then
		inputTokens = tonumber(readPath(decoded, usageMapping.input))
		outputTokens = tonumber(readPath(decoded, usageMapping.output))
	end

	return {
		text = text,
		reasoning = reasoning,
		toolCalls = {},
		usage = {
			inputTokens = inputTokens,
			outputTokens = outputTokens,
			source = if inputTokens or outputTokens then "provider" else "none",
		},
		stopReason = if type(finishReason) == "string" then finishReason else nil,
		raw = decoded,
	}, nil
end

--=============================================================================
-- STREAM
--=============================================================================
-- A custom endpoint is non-streaming unless the user declares a chunk path.

function Adapter.newStreamState()
	return { buffer = "" }
end

function Adapter.parseStreamChunk(_state: any, _chunk: string): { AdapterTypes.ResponseChunk }
	-- No streaming contract without an explicit mapping, so nothing is emitted.
	return {}
end

function Adapter.finalizeStream(_state: any): { AdapterTypes.ToolCall }
	return {}
end

function Adapter.streamStateUsage(_state: any): AdapterTypes.Usage?
	return nil
end

return Adapter