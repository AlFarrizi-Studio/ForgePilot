--!strict
--[[
	ForgePilot / AI / Adapters / OpenAICompatibleAdapter
	Implements the OpenAI Chat Completions wire format.

	Used by: OpenAI, OpenRouter, Groq, Together, DeepSeek, Mistral, vLLM,
	Ollama, LM Studio, llama.cpp server, and any other compatible endpoint.

	STREAMING FORMAT (real, as emitted by these providers):
	    data: {"choices":[{"delta":{"content":"He"}}]}
	    ...
	    data: [DONE]
]]

local StringUtil = require(script.Parent.Parent.Parent.Utilities.StringUtil)

local UniversalProviderRegistry = require(script.Parent.Parent.UniversalProviderRegistry)
local JSONValidator = require(script.Parent.Parent.Parent.Utilities.JSONValidator)
local Base64 = require(script.Parent.Parent.Parent.Utilities.Base64)

local Adapter = {}

local AdapterTypes = require(script.Parent.Parent.Parent.AI.AdapterTypes)
type ChatMessage = AdapterTypes.ChatMessage
type RequestSpec = AdapterTypes.RequestSpec
type CompleteResponse = AdapterTypes.CompleteResponse
type Usage = AdapterTypes.Usage
type ToolCall = AdapterTypes.ToolCall

--=============================================================================
-- REQUEST BODY
--=============================================================================

--- Converts a plugin content part list into OpenAI content parts.
local function buildContentParts(parts: { any }): { { [string]: any } }
	local out = {}
	for _, part in parts do
		if part.kind == "text" then
			out[#out + 1] = { type = "text", text = part.text }
		elseif part.kind == "image" then
			out[#out + 1] = {
				type = "image_url",
				image_url = { url = Base64.dataUrl(part.fileName or "image.png", part.data) },
			}
		elseif part.kind == "document" then
			-- OpenAI's file input block. Only plain-text documents map cleanly;
			-- binary PDFs need the Files API, which plugins cannot reach.
			if part.mime == "text/plain" or part.mime == "text/markdown" or part.mime == "text/csv" then
				out[#out + 1] = { type = "text", text = string.format("Contents of `%s`:\n\n%s", part.fileName, part.data) }
			end
		end
	end
	return out
end

local function buildMessage(message: ChatMessage, useSystemRole: boolean): { [string]: any }?
	if message.role == "tool" then
		return {
			role = "tool",
			tool_call_id = message.toolCallId,
			content = message.toolResult or message.content or "",
		}
	end

	local role = message.role
	if role == "system" and not useSystemRole then
		role = "user"
	end

	local payload: { [string]: any } = { role = role }

	if message.toolCalls and #message.toolCalls > 0 then
		local calls = {}
		for index, call in message.toolCalls do
			local encoded = JSONValidator.encodeObject(call.arguments)
			calls[#calls + 1] = {
				id = call.id,
				type = "function",
				["function"] = { name = call.name, arguments = encoded or "{}" },
			}
		end
		payload.tool_calls = calls
		payload.content = message.content
		return payload
	end

	if message.parts and #message.parts > 0 then
		local multimodal = false
		for _, part in message.parts do
			if part.kind ~= "text" then
				multimodal = true
				break
			end
		end
		if multimodal then
			payload.content = buildContentParts(message.parts)
		else
			local textParts = {}
			for _, part in message.parts do
				if part.kind == "text" then
					textParts[#textParts + 1] = part.text
				end
			end
			payload.content = table.concat(textParts, "\n")
		end
	else
		payload.content = message.content or ""
	end

	return payload
end

function Adapter.buildRequest(profile: any, spec: RequestSpec, includeStream: boolean): (any?, string?)
	local url, urlError = UniversalProviderRegistry.resolveUrl(profile, { streaming = false })
	if not url then
		return nil, urlError
	end

	local body: { [string]: any } = { model = spec.model }
	local messages = {}
	local systemBlocks: { string } = {}

	for _, message in spec.messages do
		if message.role == "system" then
			systemBlocks[#systemBlocks + 1] = message.content or ""
		else
			local payload = buildMessage(message, true)
			if payload then
				messages[#messages + 1] = payload
			end
		end
	end

	if spec.system and #StringUtil.trim(spec.system) > 0 then
		systemBlocks[#systemBlocks + 1] = spec.system
	end

	if #systemBlocks > 0 then
		table.insert(messages, 1, { role = "system", content = table.concat(systemBlocks, "\n\n") })
	end

	body.messages = messages

	if spec.temperature ~= nil then
		body.temperature = spec.temperature
	end
	if spec.topP ~= nil then
		body.top_p = spec.topP
	end
	if spec.maxOutputTokens then
		body.max_tokens = spec.maxOutputTokens
		if spec.streaming and includeStream then
			body.max_completion_tokens = spec.maxOutputTokens
			body.max_tokens = nil
		end
	end
	if spec.stopSequences and #spec.stopSequences > 0 then
		body.stop = spec.stopSequences
	end
	if spec.streaming and includeStream then
		body.stream = true
	end
	if spec.jsonMode then
		body.response_format = { type = "json_object" }
	end
	if spec.reasoningEffort and spec.reasoningEffort ~= "" then
		local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)
		if protocol.supportsReasoningEffort then
			body.reasoning_effort = spec.reasoningEffort
		end
	end

	if spec.tools and #spec.tools > 0 then
		local tools = {}
		for _, tool in spec.tools do
			tools[#tools + 1] = {
				type = "function",
				["function"] = {
					name = tool.name,
					description = tool.description,
					parameters = JSONValidator.toolParameters(tool.parameters),
				},
			}
		end
		body.tools = tools
		body.tool_choice = spec.toolChoice == "none" and "none" or "auto"
		if spec.toolChoice == "required" then
			body.tool_choice = "required"
		end
		if spec.toolChoice == "auto" and profile.parallelToolCalling == false then
			body.parallel_tool_calls = false
		end
	end

	local encoded, encodeErr = JSONValidator.encode(body)
	if not encoded then
		return nil, "Could not serialise the request: " .. tostring(encodeErr)
	end

	return { url = url, body = encoded, jsonBody = body }, nil
end

--=============================================================================
-- HEADERS
--=============================================================================

function Adapter.buildHeaders(profile: any, apiKey: string?, streaming: boolean): { [string]: string }
	local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)
	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }

	if protocol.authStyle == "bearer" and apiKey then
		headers["Authorization"] = "Bearer " .. apiKey
	elseif protocol.authStyle == "header" and apiKey then
		headers[protocol.authHeaderName or "x-api-key"] = apiKey
	end

	for key, value in (profile.extraHeaders or {}) do
		if type(key) == "string" and type(value) == "string" and #value > 0 then
			headers[key] = value
		end
	end

	if streaming then
		headers["Accept"] = "text/event-stream"
		headers["Cache-Control"] = "no-cache"
		headers["X-Accel-Buffering"] = "no"
	end

	return headers
end

--=============================================================================
-- RESPONSE PARSING
--=============================================================================

local function parseUsage(raw: any): Usage
	if type(raw) ~= "table" then
		return { source = "none" }
	end
	local details = raw.completion_tokens_details or raw.reasoning_tokens and { reasoning_tokens = raw.reasoning_tokens }
	local reasoningTokens = nil
	if type(details) == "table" then
		reasoningTokens = tonumber(details.reasoning_tokens)
	end
	local cached = nil
	if type(raw.prompt_tokens_details) == "table" then
		cached = tonumber(raw.prompt_tokens_details.cached_tokens)
	end
	return {
		inputTokens = tonumber(raw.prompt_tokens),
		outputTokens = tonumber(raw.completion_tokens),
		reasoningTokens = reasoningTokens,
		cachedTokens = cached,
		source = "provider",
	}
end

function Adapter.parseResponse(body: string): (CompleteResponse?, string?)
	local decoded, err = JSONValidator.decode(body)
	if not decoded then
		return nil, "Provider returned a body that is not valid JSON: " .. tostring(err)
	end
	if type(decoded) ~= "table" then
		return nil, "Provider returned an unexpected payload shape."
	end

	if type(decoded.error) == "table" then
		local message = decoded.error.message or "Provider reported an error."
		return nil, tostring(message)
	end

	local choices = decoded.choices
	if type(choices) ~= "table" or #choices == 0 then
		-- Some gateways return a bare text completion.
		if type(decoded.output_text) == "string" then
			return { text = decoded.output_text, toolCalls = {}, usage = parseUsage(decoded.usage), raw = decoded }, nil
		end
		return nil, "Provider response contained no choices."
	end

	local choice = choices[1]
	local message = choice.message or choice.delta
	if type(message) ~= "table" then
		return nil, "Provider response contained no message object."
	end

	local toolCalls: { ToolCall } = {}
	if type(message.tool_calls) == "table" then
		for _, call in message.tool_calls do
			local fn = (call :: any)["function"] or {}
			local rawArguments = fn.arguments or "{}"
			local parsed = JSONValidator.decode(rawArguments)
			table.insert(toolCalls, {
				id = call.id or ("call_" .. tostring(#toolCalls + 1)),
				name = tostring(fn.name or ""),
				arguments = if parsed then parsed else {},
				rawArguments = rawArguments,
			})
		end
	end

	return {
		text = if type(message.content) == "string" then message.content else "",
		reasoning = nil,
		toolCalls = toolCalls,
		usage = parseUsage(decoded.usage),
		stopReason = choice.finish_reason,
		raw = decoded,
	}, nil
end

--=============================================================================
-- STREAM PARSING
--=============================================================================

local StreamState = {
	buffer = "",
	toolCalls = {}, -- index -> { id, name, args }
	finishReason = nil,
	usage = nil :: Usage?,
}

function Adapter.newStreamState()
	return {
		buffer = "",
		toolCalls = {},
		finishReason = nil,
		usage = nil,
	}
end

--- Feeds a raw chunk into the parser, emitting zero or more ResponseChunks.
function Adapter.parseStreamChunk(state: any, chunk: string): { AdapterTypes.ResponseChunk }
	local events: { AdapterTypes.ResponseChunk } = {}
	state.buffer = (state.buffer .. chunk):gsub("\r\n", "\n")

	-- SSE frames are separated by a blank line.
	while true do
		local boundary = state.buffer:find("\n\n", 1, true)
		if not boundary then
			break
		end
		local frame = string.sub(state.buffer, 1, boundary - 1)
		state.buffer = string.sub(state.buffer, boundary + 2)

		local dataLines = {}
		for line in (frame .. "\n"):gmatch("(.-)\r?\n") do
			if string.sub(line, 1, 6) == "data: " then
				dataLines[#dataLines + 1] = string.sub(line, 7)
			elseif string.sub(line, 1, 5) == "data:" then
				dataLines[#dataLines + 1] = StringUtil.trim(string.sub(line, 6))
			end
		end

		for _, data in dataLines do
			if data == "[DONE]" then
				events[#events + 1] = { kind = "done" }
				continue
			end

			local decoded, decodeErr = JSONValidator.decode(data)
			if not decoded then
				events[#events + 1] = { kind = "error", message = "Unreadable stream frame: " .. tostring(decodeErr) }
				continue
			end

			if type(decoded.usage) == "table" then
				state.usage = parseUsage(decoded.usage)
			end

			local choices = decoded.choices
			if type(choices) ~= "table" or #choices == 0 then
				continue
			end

			local choice = choices[1]
			if type(choice.finish_reason) == "string" then state.finishReason = choice.finish_reason end
			local delta = choice.delta
			if type(delta) ~= "table" then
				continue
			end

			if choice.finish_reason then
				state.finishReason = choice.finish_reason
			end

			if type(delta.content) == "string" and #delta.content > 0 then
				events[#events + 1] = { kind = "text", text = delta.content }
			end

			-- Reasoning models stream their thinking under a provider-specific key.
			local reasoning = delta.reasoning_content or delta.reasoning
			if type(reasoning) == "string" and #reasoning > 0 then
				events[#events + 1] = { kind = "reasoning", reasoning = reasoning }
			end

			if type(delta.tool_calls) == "table" then
				for _, call in delta.tool_calls do
					local index = call.index or 1
					local slot = state.toolCalls[index]
					if not slot then
						slot = { id = "", name = "", args = "" }
						state.toolCalls[index] = slot
					end
					if call.id then
						slot.id = call.id
					end
					local callFunction = (call :: any)["function"]
					if callFunction then
						if callFunction.name then
							slot.name = callFunction.name .. slot.name
						end
						if callFunction.arguments then
							slot.args ..= callFunction.arguments
						end
					end
					events[#events + 1] = { kind = "tool_call_delta", toolCall = { id = slot.id, name = slot.name, arguments = nil } }
				end
			end
		end
	end

	return events
end

--- Flushes buffered tool-call arguments at end of stream.
function Adapter.finalizeStream(state: any): { ToolCall }
	local calls: { ToolCall } = {}
	local indices = {}
	for index in pairs(state.toolCalls) do
		indices[#indices + 1] = index
	end
	table.sort(indices)

	for _, index in indices do
		local slot = state.toolCalls[index]
		local parsed = JSONValidator.decode(slot.args)
		table.insert(calls, {
			id = slot.id ~= "" and slot.id or ("call_" .. tostring(#calls + 1)),
			name = slot.name,
			arguments = if parsed then parsed else {},
			rawArguments = slot.args,
		})
	end
	return calls
end

function Adapter.streamStateUsage(state: any): Usage?
	return state.usage
end

return Adapter