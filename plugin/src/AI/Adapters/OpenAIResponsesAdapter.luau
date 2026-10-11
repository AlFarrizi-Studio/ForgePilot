--!strict
--[[
	ForgePilot / AI / Adapters / OpenAIResponsesAdapter
	Implements the OpenAI Responses API wire format (POST /responses).

	STREAMING EVENTS (real):
	    event: response.output_text.delta   data: {"delta":"..."}
	    event: response.reasoning_summary_text.delta
	    event: response.output_item.done    data: {"item":{"type":"function_call",...}}
	    event: response.completed           data: {"response":{"usage":{...}}}

	Unlike Chat Completions, the system prompt is a top-level `instructions`
	field and tool calls are top-level output items, not nested in the message.
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

local function buildInputContent(parts: { any }): { { [string]: any } }
	local out = {}
	for _, part in parts do
		if part.kind == "text" then
			out[#out + 1] = { type = "input_text", text = part.text }
		elseif part.kind == "image" then
			out[#out + 1] = {
				type = "input_image",
				image_url = Base64.dataUrl(part.fileName or "image.png", part.data),
			}
		elseif part.kind == "document" then
			if part.mime == "text/plain" or part.mime == "text/markdown" then
				out[#out + 1] = {
					type = "input_text",
					text = string.format("Contents of `%s`:\n\n%s", part.fileName, part.data),
				}
			end
		end
	end
	return out
end

local function buildInputItem(message: AdapterTypes.ChatMessage): { [string]: any }?
	if message.role == "tool" then
		return {
			type = "function_call_output",
			call_id = message.toolCallId,
			output = message.toolResult or message.content or "",
		}
	end

	if message.toolCalls and #message.toolCalls > 0 then
		local items = {}
		for _, call in message.toolCalls do
			items[#items + 1] = {
				type = "function_call",
				call_id = call.id,
				name = call.name,
				arguments = JSONValidator.encodeObject(call.arguments) or "{}",
			}
		end
		return { __multi = true, items = items }
	end

	local item: { [string]: any } = {
		type = "message",
		role = if message.role == "assistant" then "assistant" else "user",
		content = { { type = "input_text", text = "" } },
	}

	if message.parts and #message.parts > 0 then
		item.content = buildInputContent(message.parts)
	else
		item.content = { { type = "input_text", text = message.content or "" } }
	end

	return item
end

function Adapter.buildRequest(profile: any, spec: RequestSpec, includeStream: boolean): (any?, string?)
	local url, urlError = UniversalProviderRegistry.resolveUrl(profile, { streaming = false })
	if not url then
		return nil, urlError
	end

	local body: { [string]: any } = { model = spec.model, input = {} }
	local instructions: { string } = {}

	for _, message in spec.messages do
		if message.role == "system" then
			instructions[#instructions + 1] = message.content or ""
		else
			local item = buildInputItem(message)
			if item then
				if item.__multi then
					for _, sub in item.items :: { any } do
						table.insert(body.input :: { any }, sub)
					end
				else
					table.insert(body.input :: { any }, item)
				end
			end
		end
	end

	if spec.system and #StringUtil.trim(spec.system) > 0 then
		instructions[#instructions + 1] = spec.system
	end
	if #instructions > 0 then
		body.instructions = table.concat(instructions, "\n\n")
	end

	if spec.temperature ~= nil then
		body.temperature = spec.temperature
	end
	if spec.topP ~= nil then
		body.top_p = spec.topP
	end
	if spec.maxOutputTokens then
		body.max_output_tokens = spec.maxOutputTokens
	end
	if spec.stopSequences and #spec.stopSequences > 0 then
		body.stop = spec.stopSequences
	end
	if spec.streaming and includeStream then
		body.stream = true
	end
	if spec.jsonMode then
		body.text = { format = { type = "json_object" } }
	end
	if spec.reasoningEffort and spec.reasoningEffort ~= "" then
		body.reasoning = {
			effort = spec.reasoningEffort,
			summary = if spec.reasoningSummary ~= false then "auto" else nil,
		}
	end

	if spec.tools and #spec.tools > 0 then
		local tools = {}
		for _, tool in spec.tools do
			tools[#tools + 1] = {
				type = "function",
				name = tool.name,
				description = tool.description,
				parameters = JSONValidator.toolParameters(tool.parameters),
			}
		end
		body.tools = tools
		body.tool_choice = if spec.toolChoice == "none"
			then "none"
			elseif spec.toolChoice == "required" then "required" else "auto"
	end

	local encoded, encodeErr = JSONValidator.encode(body)
	if not encoded then
		return nil, "Could not serialise the request: " .. tostring(encodeErr)
	end
	return { url = url, body = encoded, jsonBody = body }, nil
end

function Adapter.buildHeaders(profile: any, apiKey: string?, streaming: boolean): { [string]: string }
	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }
	if apiKey then
		headers["Authorization"] = "Bearer " .. apiKey
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
	local details = raw.output_tokens_details or {}
	return {
		inputTokens = tonumber(raw.input_tokens),
		outputTokens = tonumber(raw.output_tokens),
		reasoningTokens = tonumber(details.reasoning_tokens),
		cachedTokens = tonumber(raw.input_tokens_details and raw.input_tokens_details.cached_tokens),
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
		return nil, tostring(decoded.error.message or "Provider reported an error.")
	end

	local text: { string } = {}
	local reasoning: { string } = {}
	local toolCalls: { ToolCall } = {}

	local output = decoded.output
	if type(output) == "table" then
		for _, item in output do
			if type(item) ~= "table" then
				continue
			end
			if item.type == "message" and type(item.content) == "table" then
				for _, block in item.content do
					if type(block) == "table" and block.type == "output_text" and type(block.text) == "string" then
						text[#text + 1] = block.text
					end
				end
			elseif item.type == "reasoning" then
				-- Reasoning is a sibling item in `output`, not a message block.
				if type(item.summary) == "table" then
					for _, summary in item.summary do
						if type(summary) == "table" and type(summary.text) == "string" then
							reasoning[#reasoning + 1] = summary.text
						end
					end
				end
				if type(item.content) == "table" then
					for _, block in item.content do
						if type(block) == "table" and type(block.text) == "string" then
							reasoning[#reasoning + 1] = block.text
						end
					end
				end
			elseif item.type == "function_call" then
				local rawArguments = tostring(item.arguments or "{}")
				local parsed = JSONValidator.decode(rawArguments)
				table.insert(toolCalls, {
					id = item.call_id or item.id or ("call_" .. tostring(#toolCalls + 1)),
					name = tostring(item.name or ""),
					arguments = if parsed then parsed else {},
					rawArguments = rawArguments,
				})
			end
		end
	end

	if #text == 0 and type(decoded.output_text) == "string" then
		text[1] = decoded.output_text
	end

	return {
		text = table.concat(text),
		reasoning = if #reasoning > 0 then table.concat(reasoning, "\n") else nil,
		toolCalls = toolCalls,
		usage = parseUsage(decoded.usage),
		stopReason = if decoded.status == "incomplete" and decoded.incomplete_details then decoded.incomplete_details.reason else decoded.status,
		raw = decoded,
	}, nil
end

--=============================================================================
-- STREAM
--=============================================================================

function Adapter.newStreamState()
	return { buffer = "", toolArgs = {}, toolName = {}, toolId = {}, usage = nil, status = nil }
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
		local eventName = nil
		for line in (frame .. "\n"):gmatch("(.-)\r?\n") do
			if string.sub(line, 1, 6) == "event: " then
				eventName = StringUtil.trim(string.sub(line, 8))
			elseif string.sub(line, 1, 6) == "data: " then
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

		if decoded.type == "response.output_text.delta" and type(decoded.delta) == "string" then
			events[#events + 1] = { kind = "text", text = decoded.delta }
		elseif decoded.type == "response.reasoning_summary_text.delta" and type(decoded.delta) == "string" then
			events[#events + 1] = { kind = "reasoning", reasoning = decoded.delta }
		elseif decoded.type == "response.output_item.delta" and type(decoded.item) == "table" then
			local item = decoded.item
			if item.type == "function_call" then
				local key = tostring(item.output_index or decoded.output_index or 1)
				state.toolId[key] = item.call_id or item.id
				state.toolName[key] = item.name
				state.toolArgs[key] = (state.toolArgs[key] or "") .. tostring(item.arguments or "")
			end
		elseif decoded.type == "response.output_item.done" and type(decoded.item) == "table" then
			local item = decoded.item
			if item.type == "function_call" then
				local key = tostring(item.output_index or decoded.output_index or 1)
				state.toolId[key] = item.call_id or item.id or state.toolId[key]
				state.toolName[key] = item.name or state.toolName[key]
				state.toolArgs[key] = item.arguments or state.toolArgs[key]
			end
		elseif (decoded.type == "response.completed" or decoded.type == "response.incomplete") and type(decoded.response) == "table" then
			state.usage = parseUsage(decoded.response.usage)
			state.status = if decoded.type == "response.incomplete" and decoded.response.incomplete_details then decoded.response.incomplete_details.reason else decoded.response.status
			events[#events + 1] = { kind = "usage", usage = state.usage }
			events[#events + 1] = { kind = "done" }
		elseif decoded.type == "response.failed" then
			local providerError = decoded.response and decoded.response.error
			events[#events + 1] = { kind = "error", message = tostring(providerError and providerError.message or "Response failed."), body = if providerError then JSONValidator.encode({ error = providerError }) else data }
		elseif decoded.type == "error" then
			events[#events + 1] = {
				kind = "error",
				message = tostring(decoded.message or decoded.code or "Stream error."),
				body = data,
			}
		end
	end

	return events
end

function Adapter.finalizeStream(state: any): { ToolCall }
	local calls: { ToolCall } = {}
	local keys = {}
	for key in pairs(state.toolName) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in keys do
		local rawArguments = state.toolArgs[key] or "{}"
		local parsed = JSONValidator.decode(rawArguments)
		table.insert(calls, {
			id = state.toolId[key] or ("call_" .. tostring(#calls + 1)),
			name = state.toolName[key],
			arguments = if parsed then parsed else {},
			rawArguments = rawArguments,
		})
	end
	return calls
end

function Adapter.streamStateUsage(state: any): Usage?
	return state.usage
end

return Adapter
