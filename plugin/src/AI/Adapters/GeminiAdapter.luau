--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / AI / Adapters / GeminiAdapter
	Implements the Google Gemini native generateContent wire format.

	Auth uses the x-goog-api-key header. The model id is part of the path.
	`contents[].parts[]` is the universal shape. Multimodal data is inline base64
	with a declared mimeType. Function calling uses `functionDeclarations`.
	System instructions live in `systemInstruction`. Usage lives in
	`usageMetadata` with `thoughtsTokenCount` for reasoning models.

	STREAMING (SSE, requires ?alt=sse on the stream URL):
	    data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}],
	           "usageMetadata":{"promptTokenCount":12,...}}
]]

local StringUtil = require(script.Parent.Parent.Parent.Utilities.StringUtil)

local UniversalProviderRegistry = require(script.Parent.Parent.UniversalProviderRegistry)
local JSONValidator = require(script.Parent.Parent.Parent.Utilities.JSONValidator)

local Adapter = {}

local AdapterTypes = require(script.Parent.Parent.AdapterTypes)
type RequestSpec = AdapterTypes.RequestSpec
type CompleteResponse = AdapterTypes.CompleteResponse
type Usage = AdapterTypes.Usage
type ToolCall = AdapterTypes.ToolCall

--=============================================================================
-- REQUEST
--=============================================================================

local function buildParts(parts: { any }): { { [string]: any } }
	local out = {}
	for _, part in parts do
		if part.kind == "text" then
			out[#out + 1] = { text = part.text }
		elseif part.kind == "image" or part.kind == "document" or part.kind == "audio" or part.kind == "video" then
			-- Gemini is the one protocol here where images, documents, audio and
			-- video all use the same inlineData shape.
			out[#out + 1] = {
				inlineData = { mimeType = part.mime, data = part.data },
			}
		end
	end
	return out
end

local function buildContent(message: AdapterTypes.ChatMessage): { [string]: any }?
	if message.role == "tool" then
		return {
			role = "user",
			parts = {
				{
					functionResponse = {
						name = message.toolCallId,
						response = { result = message.toolResult or message.content or "" },
					},
				},
			},
		}
	end

	local parts: { { [string]: any } } = {}

	for _, call in (message.toolCalls or {}) do
		parts[#parts + 1] = {
			functionCall = { name = call.name, args = JSONValidator.object(call.arguments or {}) },
		}
	end

	if message.parts and #message.parts > 0 then
		for _, block in buildParts(message.parts) do
			parts[#parts + 1] = block
		end
	elseif message.content and #message.content > 0 then
		parts[#parts + 1] = { text = message.content }
	end

	if #parts == 0 then
		return nil
	end

	return {
		role = if message.role == "assistant" then "model" else "user",
		parts = parts,
	}
end

--- `#t` is only meaningful for sequences, so emptiness is counted explicitly.
local function countKeys(t: any): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

function Adapter.buildRequest(profile: any, spec: RequestSpec, includeStream: boolean): (any?, string?)
	local url, urlError = UniversalProviderRegistry.resolveUrl(profile, { streaming = includeStream == true })
	if not url then
		return nil, urlError
	end

	local body: { [string]: any } = { contents = {} }
	local systemParts: { { [string]: any } } = {}

	for _, message in spec.messages do
		if message.role == "system" then
			systemParts[#systemParts + 1] = { text = message.content or "" }
		else
			local content = buildContent(message)
			if content then
				table.insert(body.contents :: { any }, content)
			end
		end
	end

	if spec.system and #StringUtil.trim(spec.system) > 0 then
		systemParts[#systemParts + 1] = { text = spec.system }
	end
	if #systemParts > 0 then
		body.systemInstruction = { parts = systemParts }
	end

	local generationConfig: { [string]: any } = {}
	if spec.maxOutputTokens then
		generationConfig.maxOutputTokens = spec.maxOutputTokens
	end
	if spec.temperature ~= nil then
		generationConfig.temperature = spec.temperature
	end
	if spec.topP ~= nil then
		generationConfig.topP = spec.topP
	end
	if spec.stopSequences and #spec.stopSequences > 0 then
		generationConfig.stopSequences = spec.stopSequences
	end
	if spec.jsonMode then
		generationConfig.responseMimeType = "application/json"
	end
	if countKeys(generationConfig) > 0 then
		body.generationConfig = generationConfig
	end

	if spec.tools and #spec.tools > 0 then
		local declarations = {}
		for _, tool in spec.tools do
			declarations[#declarations + 1] = {
				name = tool.name,
				description = tool.description,
				parameters = JSONValidator.toolParameters(tool.parameters),
			}
		end
		body.tools = { { functionDeclarations = declarations } }
		if spec.toolChoice == "none" then
			body.toolConfig = { functionCallingConfig = { mode = "NONE" } }
		elseif spec.toolChoice == "required" then
			body.toolConfig = { functionCallingConfig = { mode = "ANY" } }
		end
	end

	if spec.safetySettings then
		body.safetySettings = spec.safetySettings
	end

	local encoded, encodeErr = JSONValidator.encode(body)
	if not encoded then
		return nil, "Could not serialise the request: " .. tostring(encodeErr)
	end

	-- Streaming requires the alt=sse query parameter on the native endpoint.
	if includeStream and spec.streaming then
		url ..= "?alt=sse"
	end

	return { url = url, body = encoded, jsonBody = body }, nil
end

function Adapter.buildHeaders(profile: any, apiKey: string?, streaming: boolean): { [string]: string }
	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }
	if apiKey then
		headers["x-goog-api-key"] = apiKey
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
		inputTokens = tonumber(raw.promptTokenCount),
		outputTokens = tonumber(raw.candidatesTokenCount),
		reasoningTokens = tonumber(raw.thoughtsTokenCount),
		cachedTokens = tonumber(raw.cachedContentTokenCount),
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
		return nil, tostring(decoded.error.message or "Gemini reported an error.")
	end

	local candidates = decoded.candidates
	if type(candidates) ~= "table" or #candidates == 0 then
		local blocked = decoded.promptFeedback
		if type(blocked) == "table" and type(blocked.blockReason) == "string" then
			return nil, "Prompt was blocked: " .. blocked.blockReason
		end
		return nil, "Gemini response contained no candidates."
	end

	local candidate = candidates[1]
	local text: { string } = {}
	local thoughtText: { string } = {}
	local toolCalls: { ToolCall } = {}

	if type(candidate.content) == "table" and type(candidate.content.parts) == "table" then
		for _, part in candidate.content.parts do
			if type(part) ~= "table" then
				continue
			end
			if type(part.text) == "string" then
				if part.thought == true then
					thoughtText[#thoughtText + 1] = part.text
				else
					text[#text + 1] = part.text
				end
			end
			if type(part.functionCall) == "table" then
				local call = part.functionCall
				table.insert(toolCalls, {
					id = call.id or ("call_" .. tostring(#toolCalls + 1)),
					name = tostring(call.name or ""),
					arguments = type(call.args) == "table" and call.args or {},
				})
			end
		end
	end

	return {
		text = table.concat(text),
		reasoning = if #thoughtText > 0 then table.concat(thoughtText, "\n") else nil,
		toolCalls = toolCalls,
		usage = parseUsage(decoded.usageMetadata),
		stopReason = candidate.finishReason,
		raw = decoded,
	}, nil
end

--=============================================================================
-- STREAM
--=============================================================================

function Adapter.newStreamState()
	return { buffer = "", tools = {}, usage = nil, finishReason = nil }
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

		if type(decoded.usageMetadata) == "table" then
			state.usage = parseUsage(decoded.usageMetadata)
		end

		local candidates = decoded.candidates
		if type(candidates) == "table" and #candidates > 0 then
			local candidate = candidates[1]
			if candidate.finishReason then
				state.finishReason = candidate.finishReason
			end
			if type(candidate.content) == "table" and type(candidate.content.parts) == "table" then
				for _, part in candidate.content.parts do
					if type(part) ~= "table" then
						continue
					end
					if type(part.text) == "string" and #part.text > 0 then
						if part.thought == true then
							events[#events + 1] = { kind = "reasoning", reasoning = part.text }
						else
							events[#events + 1] = { kind = "text", text = part.text }
						end
					end
					if type(part.functionCall) == "table" then
						local call = part.functionCall
						table.insert(state.tools, {
							id = call.id or ("call_" .. tostring(#state.tools + 1)),
							name = call.name,
							arguments = call.args,
						})
					end
				end
			end
		end

		if type(decoded.error) == "table" then
			events[#events + 1] = { kind = "error", message = tostring(decoded.error.message or "Gemini stream error.") }
		end
	end

	return events
end

function Adapter.finalizeStream(state: any): { ToolCall }
	local calls: { ToolCall } = {}
	for _, slot in state.tools do
		table.insert(calls, {
			id = slot.id,
			name = slot.name,
			arguments = if type(slot.arguments) == "table" then slot.arguments else {},
		})
	end
	return calls
end

function Adapter.streamStateUsage(state: any): Usage?
	return state.usage
end

--=============================================================================
-- MODEL LIST
--=============================================================================

--- Gemini exposes a real model list endpoint. Returns model id strings.
function Adapter.listModels(url: string, apiKey: string?): (string?, string?)
	local headers: { [string]: string } = {}
	if apiKey then
		headers["x-goog-api-key"] = apiKey
	end
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url .. "/v1beta/models",
			Method = "GET",
			Headers = headers,
		})
	end)
	if not ok then
		return nil, tostring(response)
	end
	local code = tonumber(response.StatusCode)
	if code == nil or code < 200 or code >= 300 then
		return nil, string.format("Model list failed (HTTP %s).", tostring(code))
	end
	local decoded = JSONValidator.decode(response.Body)
	if not decoded or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
		return nil, "Model list response was not in the expected shape."
	end
	local ids = {}
	for _, model in decoded.models do
		if type(model) == "table" and type(model.name) == "string" then
			-- Gemini returns "models/gemini-2.0-flash"; strip the prefix.
			ids[#ids + 1] = (string.gsub(model.name, "^models/", ""))
		end
	end
	return ids, nil
end

return Adapter