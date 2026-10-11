--!strict
--[[
	ForgePilot / AI / Adapters / GeminiOpenAIAdapter
	Gemini's OpenAI-compatible surface.

	Path: /v1beta/openai/chat/completions, Bearer auth.
	Requests and responses use the Chat Completions schema, but the auth model and
	usage reporting differ enough from the generic case that it gets its own file
	rather than a preset-only alias.
]]

local JSONValidator = require(script.Parent.Parent.Parent.Utilities.JSONValidator)
local StringUtil = require(script.Parent.Parent.Parent.Utilities.StringUtil)

local UniversalProviderRegistry = require(script.Parent.Parent.UniversalProviderRegistry)

local Adapter = {}

local AdapterTypes = require(script.Parent.Parent.AdapterTypes)

--=============================================================================
-- REQUEST
--=============================================================================

function Adapter.buildRequest(profile: any, spec: AdapterTypes.RequestSpec, includeStream: boolean): (any?, string?)
	local url, urlError = UniversalProviderRegistry.resolveUrl(profile, { streaming = includeStream })
	if not url then
		return nil, urlError
	end

	local body: { [string]: any } = { model = spec.model, messages = {} }

	for _, message in spec.messages do
		local entry: { [string]: any } = { role = message.role, content = message.content or "" }
		if message.parts and #message.parts > 0 then
			local parts = {}
			for _, part in message.parts do
				if part.kind == "text" then
					parts[#parts + 1] = { type = "text", text = part.text }
				elseif part.kind == "image" then
					local Base64 = require(script.Parent.Parent.Parent.Utilities.Base64)
					parts[#parts + 1] = {
						type = "image_url",
						image_url = { url = Base64.dataUrl(part.fileName or "image.png", part.data) },
					}
				end
			end
			entry.content = parts
		end
		if message.toolCalls and #message.toolCalls > 0 then
			local calls = {}
			for _, call in message.toolCalls do
				calls[#calls + 1] = {
					id = call.id,
					type = "function",
					["function"] = { name = call.name, arguments = JSONValidator.encodeObject(call.arguments) or "{}" },
				}
			end
			entry.tool_calls = calls
		end
		table.insert(body.messages, entry)
	end

	if spec.system and #StringUtil.trim(spec.system) > 0 then
		table.insert(body.messages, 1, { role = "system", content = spec.system })
	end

	if spec.temperature ~= nil then
		body.temperature = spec.temperature
	end
	if spec.topP ~= nil then
		body.top_p = spec.topP
	end
	if spec.maxOutputTokens then
		-- Gemini's OpenAI surface uses max_tokens for compatibility.
		body.max_tokens = spec.maxOutputTokens
	end
	if spec.streaming and includeStream then
		body.stream = true
	end
	if spec.jsonMode then
		body.response_format = { type = "json_object" }
	end

	if spec.tools and #spec.tools > 0 then
		local tools = {}
		for _, tool in spec.tools do
			tools[#tools + 1] = {
				type = "function",
				["function"] = { name = tool.name, description = tool.description, parameters = JSONValidator.toolParameters(tool.parameters) },
			}
		end
		body.tools = tools
	end

	local encoded, encodeError = JSONValidator.encode(body)
	if not encoded then
		return nil, "Could not serialise the request: " .. tostring(encodeError)
	end
	return { url = url, body = encoded, jsonBody = body }, nil
end

function Adapter.buildHeaders(profile: any, apiKey: string?, streaming: boolean): { [string]: string }
	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }

	-- This surface accepts a normal bearer token.
	local authHeaders = UniversalProviderRegistry.buildAuthHeaders({
		style = profile.authStyle or "bearer",
		headerName = profile.authHeaderName,
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

function Adapter.parseResponse(body: string): (AdapterTypes.CompleteResponse?, string?)
	local decoded, err = JSONValidator.decode(body)
	if not decoded or type(decoded) ~= "table" then
		return nil, "Provider returned a body that is not valid JSON: " .. tostring(err)
	end
	if type(decoded.error) == "table" then
		return nil, tostring(decoded.error.message or "Gemini reported an error.")
	end

	local choices = decoded.choices
	if type(choices) ~= "table" or #choices == 0 then
		-- Safety refusals surface as promptFeedback on this surface.
		if type(decoded.promptFeedback) == "table" and type(decoded.promptFeedback.blockReason) == "string" then
			return nil, "Prompt was blocked: " .. decoded.promptFeedback.blockReason
		end
		return nil, "Provider response contained no choices."
	end

	local choice = choices[1]
	local message = choice.message
	if type(message) ~= "table" then
		return nil, "Provider response contained no message object."
	end

	local toolCalls: { AdapterTypes.ToolCall } = {}
	if type(message.tool_calls) == "table" then
		for _, call in message.tool_calls do
			local fn = (call :: any)["function"] or {}
			local rawArguments = fn.arguments or "{}"
			table.insert(toolCalls, {
				id = call.id or ("call_" .. tostring(#toolCalls + 1)),
				name = tostring(fn.name or ""),
				arguments = JSONValidator.decode(rawArguments) or {},
				rawArguments = rawArguments,
			})
		end
	end

	return {
		text = if type(message.content) == "string" then message.content else "",
		reasoning = nil,
		toolCalls = toolCalls,
		usage = {
			inputTokens = tonumber(decoded.usage and decoded.usage.prompt_tokens),
			outputTokens = tonumber(decoded.usage and decoded.usage.completion_tokens),
			source = "provider",
		},
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
							state.usage = {
								inputTokens = tonumber(decoded.usage.prompt_tokens),
								outputTokens = tonumber(decoded.usage.completion_tokens),
								source = "provider",
							}
						end
						local choices = decoded.choices
						if type(choices) == "table" and #choices > 0 then
							local choice = choices[1]
							local delta = choice.delta
							if type(delta) == "table" and type(delta.content) == "string" and #delta.content > 0 then
								events[#events + 1] = { kind = "text", text = delta.content }
							end
							if choice.finish_reason then
								state.finishReason = choice.finish_reason
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
	return {}
end

function Adapter.streamStateUsage(state: any): AdapterTypes.Usage?
	return state.usage
end

return Adapter