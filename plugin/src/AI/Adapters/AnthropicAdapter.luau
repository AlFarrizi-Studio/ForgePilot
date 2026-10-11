--!strict
--[[
	ForgePilot / AI / Adapters / AnthropicAdapter
	Implements the Anthropic Messages API wire format (POST /v1/messages).

	Auth differs from OpenAI: the key goes in `x-api-key`, and `anthropic-version`
	is mandatory. The system prompt is a top-level `system` field (not a message).
	Content is a block array. Tool results are `tool_result` blocks inside a
	user message, not standalone messages.

	STREAMING EVENTS (real):
	    event: content_block_delta
	    data: {"type":"content_block_delta","index":0,
	           "delta":{"type":"text_delta","text":"Hi"}}
	    event: content_block_delta  (thinking -> delta.thinking)
	    event: content_block_start   (tool_use -> {"content_block":{"type":"tool_use",...}})
	    event: content_block_delta   (input_json_delta -> {"delta":{"partial_json":"{\""}})
	    event: message_delta / message_stop
]]

local StringUtil = require(script.Parent.Parent.Parent.Utilities.StringUtil)

local UniversalProviderRegistry = require(script.Parent.Parent.UniversalProviderRegistry)
local JSONValidator = require(script.Parent.Parent.Parent.Utilities.JSONValidator)
local Base64 = require(script.Parent.Parent.Parent.Utilities.Base64)

local Adapter = {}

local AdapterTypes = require(script.Parent.Parent.AdapterTypes)
type RequestSpec = AdapterTypes.RequestSpec
type CompleteResponse = AdapterTypes.CompleteResponse
type Usage = AdapterTypes.Usage
type ToolCall = AdapterTypes.ToolCall

--=============================================================================
-- REQUEST
--=============================================================================

local function buildBlocks(parts: { any }): { { [string]: any } }
	local out = {}
	for _, part in parts do
		if part.kind == "text" then
			out[#out + 1] = { type = "text", text = part.text }
		elseif part.kind == "image" then
			-- Anthropic takes raw base64, never data URLs, and only accepts
			-- image/jpeg, image/png, image/gif, image/webp.
			out[#out + 1] = {
				type = "image",
				source = { type = "base64", media_type = part.mime, data = part.data },
			}
		elseif part.kind == "document" then
			if part.mime == "text/plain" or part.mime == "text/markdown" then
				out[#out + 1] = {
					type = "text",
					text = string.format("Contents of `%s`:\n\n%s", part.fileName, part.data),
				}
			end
		end
	end
	return out
end

local function buildMessage(message: AdapterTypes.ChatMessage): { [string]: any }?
	if message.role == "tool" then
		return {
			role = "user",
			content = {
				{
					type = "tool_result",
					tool_use_id = message.toolCallId,
					content = message.toolResult or message.content or "",
				},
			},
		}
	end

	local content: { { [string]: any } } = {}

	for _, call in (message.toolCalls or {}) do
		content[#content + 1] = {
			type = "tool_use",
			id = call.id,
			name = call.name,
			input = JSONValidator.object(call.arguments or {}),
		}
	end

	if message.parts and #message.parts > 0 then
		for _, block in buildBlocks(message.parts) do
			content[#content + 1] = block
		end
	elseif message.content and #message.content > 0 then
		content[#content + 1] = { type = "text", text = message.content }
	end

	if #content == 0 then
		return nil
	end

	return { role = if message.role == "assistant" then "assistant" else "user", content = content }
end

function Adapter.buildRequest(profile: any, spec: RequestSpec, includeStream: boolean): (any?, string?)
	local url, urlError = UniversalProviderRegistry.resolveUrl(profile, { streaming = false })
	if not url then
		return nil, urlError
	end

	local body: { [string]: any } = {
		model = spec.model,
		messages = {},
		max_tokens = spec.maxOutputTokens or 4096,
	}

	local systemBlocks: { string } = {}
	for _, message in spec.messages do
		if message.role == "system" then
			systemBlocks[#systemBlocks + 1] = message.content or ""
		else
			local payload = buildMessage(message)
			if payload then
				table.insert(body.messages :: { any }, payload)
			end
		end
	end
	if spec.system and #StringUtil.trim(spec.system) > 0 then
		systemBlocks[#systemBlocks + 1] = spec.system
	end
	if #systemBlocks > 0 then
		body.system = table.concat(systemBlocks, "\n\n")
	end

	if spec.temperature ~= nil then
		body.temperature = spec.temperature
	end
	if spec.topP ~= nil then
		body.top_p = spec.topP
	end
	if spec.stopSequences and #spec.stopSequences > 0 then
		body.stop_sequences = spec.stopSequences
	end
	if spec.streaming and includeStream then
		body.stream = true
	end

	if spec.tools and #spec.tools > 0 then
		local tools = {}
		for _, tool in spec.tools do
			tools[#tools + 1] = {
				name = tool.name,
				description = tool.description,
				input_schema = JSONValidator.toolParameters(tool.parameters),
			}
		end
		body.tools = tools
		if spec.toolChoice == "none" then
			body.tool_choice = { type = "none" }
		elseif spec.toolChoice == "required" then
			body.tool_choice = { type = "any" }
		end
	end

	local encoded, encodeErr = JSONValidator.encode(body)
	if not encoded then
		return nil, "Could not serialise the request: " .. tostring(encodeErr)
	end
	return { url = url, body = encoded, jsonBody = body }, nil
end

function Adapter.buildHeaders(profile: any, apiKey: string?, streaming: boolean): { [string]: string }
	local protocol = UniversalProviderRegistry.getProtocol(profile.protocol)
	local headers: { [string]: string } = {
		["Content-Type"] = "application/json",
		["anthropic-version"] = protocol.defaultHeaders["anthropic-version"] or "2023-06-01",
	}
	if apiKey then
		headers["x-api-key"] = apiKey
	end
	for key, value in (profile.extraHeaders or {}) do
		if type(key) == "string" and type(value) == "string" then
			headers[key] = value
		end
	end
	if streaming then
		headers["Accept"] = "text/event-stream"
	end
	return headers
end

--=============================================================================
-- RESPONSE
--=============================================================================

local function parseUsage(raw: any): Usage
	if type(raw) ~= "table" then
		return { source = "none" }
	end
	return {
		inputTokens = tonumber(raw.input_tokens),
		outputTokens = tonumber(raw.output_tokens),
		reasoningTokens = nil,
		cachedTokens = tonumber(raw.cache_read_input_tokens),
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
		return nil, tostring(decoded.error.type or "error") .. ": " .. tostring(decoded.error.message or "Provider error.")
	end

	local text: { string } = {}
	local thinking: { string } = {}
	local toolCalls: { ToolCall } = {}

	local content = decoded.content
	if type(content) ~= "table" then
		return nil, "Anthropic response contained no content blocks."
	end

	for _, block in content do
		if type(block) ~= "table" then
			continue
		end
		if block.type == "text" and type(block.text) == "string" then
			text[#text + 1] = block.text
		elseif block.type == "thinking" and type(block.thinking) == "string" then
			thinking[#thinking + 1] = block.thinking
		elseif block.type == "tool_use" then
			table.insert(toolCalls, {
				id = block.id or ("call_" .. tostring(#toolCalls + 1)),
				name = tostring(block.name or ""),
				arguments = type(block.input) == "table" and block.input or {},
			})
		end
	end

	return {
		text = table.concat(text, "\n"),
		reasoning = if #thinking > 0 then table.concat(thinking, "\n") else nil,
		toolCalls = toolCalls,
		usage = parseUsage(decoded.usage),
		stopReason = decoded.stop_reason,
		raw = decoded,
	}, nil
end

--=============================================================================
-- STREAM
--=============================================================================

function Adapter.newStreamState()
	return { buffer = "", text = {}, thinking = {}, tools = {}, usage = nil, stopReason = nil }
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

		local data = nil
		for line in (frame .. "\n"):gmatch("(.-)\r?\n") do
			if string.sub(line, 1, 6) == "data: " then
				data = (data or "") .. string.sub(line, 7)
			end
		end
		if not data or data == "[DONE]" then
			continue
		end

		local decoded = JSONValidator.decode(data)
		if not decoded or type(decoded) ~= "table" then
			continue
		end

		local eventType = decoded.type

		if eventType == "content_block_start" and type(decoded.content_block) == "table" then
			local block = decoded.content_block
			local index = decoded.index or 0
			if block.type == "tool_use" then
				state.tools[index] = { id = block.id, name = block.name, args = "" }
			end
		elseif eventType == "content_block_delta" and type(decoded.delta) == "table" then
			local delta = decoded.delta
			local index = decoded.index or 0
			if delta.type == "text_delta" and type(delta.text) == "string" then
				state.text[#state.text + 1] = delta.text
				events[#events + 1] = { kind = "text", text = delta.text }
			elseif delta.type == "thinking_delta" and type(delta.thinking) == "string" then
				state.thinking[#state.thinking + 1] = delta.thinking
				events[#events + 1] = { kind = "reasoning", reasoning = delta.thinking }
			elseif delta.type == "input_json_delta" and type(delta.partial_json) == "string" then
				local slot = state.tools[index]
				if slot then
					slot.args ..= delta.partial_json
				end
			end
		elseif eventType == "message_delta" then
			-- Anthropic reports cumulative output tokens in the event's own
			-- `usage` object; only the stop reason lives inside `delta`.
			local delta = decoded.delta
			if type(delta) == "table" and delta.stop_reason then
				state.stopReason = delta.stop_reason
			end
			if type(decoded.usage) == "table" then
				local merged = state.usage or {}
				local incoming = parseUsage(decoded.usage)
				state.usage = {
					inputTokens = incoming.inputTokens or merged.inputTokens,
					outputTokens = incoming.outputTokens or merged.outputTokens,
					cachedTokens = incoming.cachedTokens or merged.cachedTokens,
					source = "provider",
				}
			elseif type(delta) == "table" and type(delta.usage) == "table" then
				state.usage = parseUsage(delta.usage)
			end
		elseif eventType == "message_stop" then
			events[#events + 1] = { kind = "usage", usage = state.usage }
			events[#events + 1] = { kind = "done" }
		elseif eventType == "error" then
			local err = decoded.error or {}
			events[#events + 1] = {
				kind = "error",
				message = tostring(err.message or "Anthropic stream error."),
			}
		end
	end

	return events
end

function Adapter.finalizeStream(state: any): { ToolCall }
	local calls: { ToolCall } = {}
	local indices = {}
	for index in pairs(state.tools) do
		indices[#indices + 1] = index
	end
	table.sort(indices)
	for _, index in indices do
		local slot = state.tools[index]
		local parsed = JSONValidator.decode(slot.args)
		table.insert(calls, {
			id = slot.id or ("call_" .. tostring(#calls + 1)),
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
