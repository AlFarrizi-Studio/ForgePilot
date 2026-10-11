--!strict
--[[
	ForgePilot / AI / Adapters / OpenAICompletionAdapter
	The legacy Text Completions protocol (POST /completions).

	Differences from Chat Completions that this adapter handles:
	  * the request field is `prompt`, not `messages`
	  * no system role — the system prompt is prefixed to the prompt text
	  * the reply is `choices[].text`, not `choices[].message.content`
	  * streamed deltas arrive under `choices[].text`, not `choices[].delta.content`
	  * no tool calling at all

	Newer chat models generally do NOT serve this route; the capability report
	keeps that distinction visible instead of assuming it works.
]]

local JSONValidator = require(script.Parent.Parent.Parent.Utilities.JSONValidator)
local StringUtil = require(script.Parent.Parent.Parent.Utilities.StringUtil)

local UniversalProviderRegistry = require(script.Parent.Parent.UniversalProviderRegistry)

local Adapter = {}

local AdapterTypes = require(script.Parent.Parent.AdapterTypes)

--=============================================================================
-- REQUEST
--=============================================================================

--- Flattens chat messages into a single prompt string.
local function flatten(messages: { AdapterTypes.ChatMessage }, system: string?): string
	local parts: { string } = {}
	if system and #StringUtil.trim(system) > 0 then
		parts[#parts + 1] = system
	end

	for _, message in messages do
		if message.content and #StringUtil.trim(message.content) > 0 then
			if message.role == "system" then
				parts[#parts + 1] = message.content
			elseif message.role == "assistant" then
				parts[#parts + 1] = "Assistant: " .. message.content
			else
				parts[#parts + 1] = "User: " .. message.content
			end
		elseif message.parts then
			local textParts = {}
			for _, part in message.parts do
				if part.kind == "text" then
					textParts[#textParts + 1] = part.text
				end
			end
			if #textParts > 0 then
				parts[#parts + 1] = table.concat(textParts, "\n")
			end
		end
	end

	return table.concat(parts, "\n\n")
end

function Adapter.buildRequest(profile: any, spec: AdapterTypes.RequestSpec, includeStream: boolean): (any?, string?)
	local url, urlError = UniversalProviderRegistry.resolveUrl(profile, { streaming = includeStream })
	if not url then
		return nil, urlError
	end

	local body: { [string]: any } = {
		model = spec.model,
		prompt = flatten(spec.messages, spec.system),
	}

	if spec.temperature ~= nil then
		body.temperature = spec.temperature
	end
	if spec.topP ~= nil then
		body.top_p = spec.topP
	end
	if spec.maxOutputTokens then
		body.max_tokens = spec.maxOutputTokens
	end
	if spec.stopSequences and #spec.stopSequences > 0 then
		body.stop = spec.stopSequences
	end
	if includeStream and spec.streaming then
		body.stream = true
	end

	-- Text Completions has no tool-calling or JSON-mode concepts.
	local encoded, encodeError = JSONValidator.encode(body)
	if not encoded then
		return nil, "Could not serialise the request: " .. tostring(encodeError)
	end
	return { url = url, body = encoded, jsonBody = body }, nil
end

function Adapter.buildHeaders(profile: any, apiKey: string?, streaming: boolean): { [string]: string }
	local registry = require(script.Parent.Parent.UniversalProviderRegistry)
	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }

	local authHeaders, authQuery = registry.buildAuthHeaders({
		style = profile.authStyle,
		headerName = profile.authHeaderName,
		headerPrefix = profile.authHeaderPrefix,
		queryParam = profile.authQueryParam,
	}, apiKey)
	for key, value in authHeaders do
		headers[key] = value
	end
	_ = authQuery

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

local function parseUsage(raw: any): AdapterTypes.Usage
	if type(raw) ~= "table" then
		return { source = "none" }
	end
	return {
		inputTokens = tonumber(raw.prompt_tokens),
		outputTokens = tonumber(raw.completion_tokens),
		source = "provider",
	}
end

function Adapter.parseResponse(body: string): (AdapterTypes.CompleteResponse?, string?)
	local decoded, err = JSONValidator.decode(body)
	if not decoded or type(decoded) ~= "table" then
		return nil, "Provider returned a body that is not valid JSON: " .. tostring(err)
	end

	if type(decoded.error) == "table" then
		return nil, tostring(decoded.error.message or "Provider reported an error.")
	end

	local choices = decoded.choices
	if type(choices) ~= "table" or #choices == 0 then
		return nil, "Provider response contained no choices."
	end

	local choice = choices[1]
	-- Legacy completions put the reply in `text`. A body with only
	-- `message` is a chat response served at the wrong route, which must not be
	-- silently accepted as a completion.
	if type(choice.text) ~= "string" then
		return nil, "`choices[0].text` was absent — this endpoint served a Chat Completions response, not a Text Completions response."
	end

	return {
		text = choice.text,
		reasoning = nil,
		toolCalls = {},
		usage = parseUsage(decoded.usage),
		stopReason = choice.finish_reason,
		raw = decoded,
	}, nil
end

--=============================================================================
-- STREAM
--=============================================================================

function Adapter.newStreamState()
	return { buffer = "", usage = nil, finishReason = nil }
end

function Adapter.parseStreamChunk(state: any, chunk: string): { AdapterTypes.ResponseChunk }
	local events: { AdapterTypes.ResponseChunk } = {}
	state.buffer = (state.buffer .. chunk):gsub("\r\n", "\n")

	while true do
		local boundary = state.buffer:find("\n\n", 1, true)
		if not boundary then
			break
		end
		local frame = string.sub(state.buffer, 1, boundary - 1)
		state.buffer = string.sub(state.buffer, boundary + 2)

		for line in (frame .. "\n"):gmatch("(.-)\r?\n") do
			local data = string.match(line, "^data:%s?(.*)$")
			if data then
				local trimmed = StringUtil.trim(data)
				if trimmed == "[DONE]" then
					events[#events + 1] = { kind = "done" }
				else
					local decoded = JSONValidator.decode(trimmed)
					if decoded and type(decoded) == "table" then
						if type(decoded.usage) == "table" then
							state.usage = parseUsage(decoded.usage)
						end
						local choices = decoded.choices
						if type(choices) == "table" and #choices > 0 then
							local choice = choices[1]
							if choice.finish_reason then
								state.finishReason = choice.finish_reason
							end
							if type(choice.text) == "string" and #choice.text > 0 then
								events[#events + 1] = { kind = "text", text = choice.text }
							end
						end
					end
				end
			end
		end
	end

	return events
end

function Adapter.finalizeStream(_state: any): { AdapterTypes.ToolCall }
	-- Text Completions has no tool calls by definition.
	return {}
end

function Adapter.streamStateUsage(state: any): AdapterTypes.Usage?
	return state.usage
end

return Adapter