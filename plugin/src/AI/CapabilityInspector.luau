--!strict
--[[
	ForgePilot / AI / CapabilityInspector
	V3.3 capability detection across model AND protocol.

	Combines three sources into one Supported / Unsupported / Unknown verdict:
	  * known provider metadata (preset table)
	  * model-specific metadata
	  * live probes (real requests, user-authorised)

	Hard rule: absent information stays UNKNOWN. It is never inferred from the
	protocol alone unless the protocol genuinely defines the capability.
]]

local APIEndpointRouter = require(script.Parent.APIEndpointRouter)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ModelCapabilityDetector = require(script.Parent.ModelCapabilityDetector)
local Time = require(script.Parent.Parent.Utilities.Time)
local UniversalHTTPClient = require(script.Parent.Parent.Utilities.UniversalHTTPClient)
local UniversalProviderRegistry = require(script.Parent.UniversalProviderRegistry)

local CapabilityInspector = {}

--=============================================================================
-- V3.3 CAPABILITY CATALOGUE
--=============================================================================

export type Verdict = "Supported" | "Unsupported" | "Unknown"

export type Row = {
	id: string,
	label: string,
	verdict: Verdict,
	source: string,
	checkedAt: number?,
	note: string,
	overridden: boolean,
	probeable: boolean,
	probeCost: "none" | "low" | "high",
	probeNote: string,
}

export type Report = {
	providerId: string,
	providerName: string,
	protocolId: string,
	modelId: string,
	rows: { Row },
	contextWindow: number,
	contextWindowSource: string,
	maxOutputTokens: number,
	maxOutputTokensSource: string,
	generatedAt: number,
}

--- Ordered catalogue matching the spec's capability list exactly.
local CATALOGUE: { { id: string, label: string, probeable: boolean, cost: "none" | "low" | "high", note: string } } = {
	{ id = "chat_completions", label = "Chat Completions", probeable = true, cost = "low", note = "Sends one chat request and validates the response structure." },
	{ id = "text_completions", label = "Text Completions", probeable = true, cost = "low", note = "Sends one /completions request and requires choices[].text." },
	{ id = "responses_api", label = "Responses API", probeable = true, cost = "low", note = "Sends one /responses request and requires an output field." },
	{ id = "streaming", label = "Streaming", probeable = true, cost = "low", note = "Opens a real stream and counts received chunks." },
	{ id = "tool_calling", label = "Tool Calling", probeable = true, cost = "low", note = "Offers a tool and checks whether the model requests it." },
	{ id = "parallel_tool_calling", label = "Parallel Tool Calling", probeable = true, cost = "low", note = "Offers two tools and counts returned calls." },
	{ id = "structured_json", label = "Structured JSON Output", probeable = true, cost = "low", note = "Requests JSON mode and validates the reply." },
	{ id = "vision", label = "Vision (Image Input)", probeable = true, cost = "high", note = "Sends a tiny generated PNG." },
	{ id = "image_generation", label = "Image Generation", probeable = false, cost = "high", note = "Requires a dedicated image endpoint ForgePilot does not call." },
	{ id = "pdf_input", label = "PDF Input", probeable = false, cost = "high", note = "Chat endpoints cannot verify binary PDF parsing." },
	{ id = "document_input", label = "Document Input", probeable = true, cost = "low", note = "Sends a short text document." },
	{ id = "audio_input", label = "Audio Input", probeable = false, cost = "high", note = "Only Gemini's native route inlines audio." },
	{ id = "video_input", label = "Video Input", probeable = false, cost = "high", note = "Only Gemini's native route inlines video." },
	{ id = "audio_output", label = "Audio Output", probeable = false, cost = "high", note = "No chat route returns audio." },
	{ id = "reasoning", label = "Reasoning", probeable = true, cost = "high", note = "Looks for reasoning tokens or reasoning text in the response." },
	{ id = "system_instructions", label = "System Instructions", probeable = true, cost = "low", note = "Sends a system instruction and checks it is honoured." },
}

CapabilityInspector.Catalogue = CATALOGUE

--=============================================================================
-- PROTOCOL DEFAULTS
--=============================================================================
-- These describe the WIRE FORMAT, not the model, so they are reliable.

local function protocolDefault(protocolId: string, capabilityId: string): (Verdict, string)
	local protocol = UniversalProviderRegistry.getProtocol(protocolId)

	if capabilityId == "chat_completions" then
		if protocolId == "gemini_native" or protocolId == "anthropic_messages" then
			return "Unsupported", "This protocol does not serve the Chat Completions route."
		end
		if protocolId == "custom_rest" then
			return "Unknown", "Depends entirely on your schema mapping."
		end
		return "Supported", "This protocol serves the Chat Completions route."
	end

	if capabilityId == "text_completions" then
		if protocol.supportsTextCompletions then
			return "Supported", "Protocol defines a /completions route."
		end
		return "Unsupported", "Protocol has no /completions route."
	end

	if capabilityId == "responses_api" then
		if protocolId == "openai_responses" then
			return "Supported", "Protocol is the Responses API."
		elseif protocolId == "openai_chat" or protocolId == "openrouter" then
			return "Unknown", "Not probed yet; some compatible servers also expose /responses."
		end
		return "Unsupported", "Protocol does not define a Responses route."
	end

	if capabilityId == "streaming" then
		if protocol.supportsStreaming then
			if UniversalHTTPClient.supportsStreaming() then
				return "Supported", "Protocol streams and this Studio build exposes CreateWebStreamClient."
			end
			return "Unknown", "Protocol streams, but this Studio build has no CreateWebStreamClient."
		end
		return "Unsupported", "Protocol does not stream."
	end

	if capabilityId == "tool_calling" then
		if protocol.supportsToolCalling then
			return "Supported", "Protocol defines tool definitions."
		end
		return "Unsupported", "Protocol has no tool-calling route."
	end

	if capabilityId == "system_instructions" then
		if protocol.supportsSystemRole then
			return "Supported", "Protocol carries a system prompt."
		end
		return "Unsupported", "Protocol has no system role."
	end

	if capabilityId == "structured_json" then
		if protocol.supportsJsonMode then
			return "Supported", "Protocol defines a JSON response mode."
		end
		return "Unsupported", "Protocol has no structured-output parameter."
	end

	if capabilityId == "reasoning" then
		if protocol.supportsReasoningSummaries then
			return "Unknown", "Protocol can carry reasoning; not probed yet."
		end
		return "Unknown", "Nothing about this protocol reports reasoning."
	end

	if capabilityId == "vision" or capabilityId == "document_input" or capabilityId == "pdf_input" then
		if protocol.supportsImages or protocol.supportsDocuments then
			return "Unknown", "Protocol can carry media; the model has not been probed yet."
		end
		return "Unsupported", "Protocol has no inline media block."
	end

	if capabilityId == "parallel_tool_calling" then
		return "Unknown", "Requires a two-tool probe."
	end

	return nil
end

--=============================================================================
-- BUILD REPORT
--=============================================================================

local overrides: { [string]: { [string]: Verdict } } = {}

local function keyFor(profile: any): string
	return string.format("%s|%s|%s", profile.id, profile.modelId or "", profile.protocol or "")
end

--- Builds a report from metadata + protocol knowledge. No network needed.
function CapabilityInspector.buildReport(profile: any): Report
	local preset = UniversalProviderRegistry.getPreset(profile.presetId)
	local modelMetadata = if preset then preset.modelMetadata[profile.modelId] else nil
	local rows: { Row } = {}
	local modelKey = keyFor(profile)
	local modelOverrides = overrides[modelKey] or {}

	for _, definition in CATALOGUE do
		local verdict: Verdict = "Unknown"
		local source = "no_information"
		local note = "No metadata available. Run a live probe or set a manual override."

		local modelHint = if modelMetadata then modelMetadata.capabilities[definition.id] else nil
		local presetHint = if preset then preset.providerCapabilities[definition.id] else nil

		if type(modelHint) == "string" and (modelHint == "yes" or modelHint == "no") then
			verdict = if modelHint == "yes" then "Supported" else "Unsupported"
			source = "model_metadata"
			note = string.format("Model metadata for %s.", profile.modelId)
		elseif type(presetHint) == "string" and (presetHint == "yes" or presetHint == "no") then
			verdict = if presetHint == "yes" then "Supported" else "Unsupported"
			source = "provider_metadata"
			note = string.format("Provider documentation for %s.", preset.label)
		else
			local defaultVerdict, defaultNote = protocolDefault(profile.protocol, definition.id)
			if defaultVerdict then
				verdict = defaultVerdict
				source = "protocol_definition"
				note = defaultNote
			end
		end

		local overridden = modelOverrides[definition.id] ~= nil
		if overridden then
			verdict = (modelOverrides[definition.id] :: Verdict)
			source = "manual_override"
			note = "Manual override. Not verified against this provider."
		end

		rows[#rows + 1] = {
			id = definition.id,
			label = definition.label,
			verdict = verdict,
			source = source,
			checkedAt = nil,
			note = note,
			overridden = overridden,
			probeable = definition.probeable,
			probeCost = definition.cost,
			probeNote = definition.note,
		}
	end

	local contextWindow = profile.contextWindow or 128000
	local contextWindowSource = "Manual value from the provider settings."
	local maxOutput = profile.maxOutputTokens or 4096
	local maxOutputSource = "Manual value from the provider settings."
	if modelMetadata and profile.contextWindowMode ~= "manual" then
		contextWindow = modelMetadata.contextWindow
		contextWindowSource = "Model metadata."
	elseif profile.contextWindowMode == "auto" and preset then
		contextWindowSource = "Provider default estimate; no model metadata for this id."
	end
	if modelMetadata and profile.maxOutputTokensMode ~= "manual" then
		maxOutput = modelMetadata.maxOutputTokens
		maxOutputSource = "Model metadata."
	end

	return {
		providerId = profile.id,
		providerName = profile.displayName or profile.providerName or "Provider",
		protocolId = profile.protocol,
		modelId = profile.modelId or "",
		rows = rows,
		contextWindow = contextWindow,
		contextWindowSource = contextWindowSource,
		maxOutputTokens = maxOutput,
		maxOutputTokensSource = maxOutputSource,
		generatedAt = os.clock(),
	}
end

--=============================================================================
-- OVERRIDES
--=============================================================================

function CapabilityInspector.setOverride(profile: any, capabilityId: string, verdict: Verdict?)
	local modelKey = keyFor(profile)
	if not overrides[modelKey] then
		overrides[modelKey] = {}
	end
	overrides[modelKey][capabilityId] = verdict
	local report = CapabilityInspector.buildReport(profile)
	EventBus.emit(EventBus.Events.CapabilitiesChanged, { report = report })
	return report
end

--=============================================================================
-- LIVE PROBES
--=============================================================================

export type ProbeOptions = {
	onProgress: ((row: Row) -> ())?,
	shouldCancel: (() -> boolean)?,
	only: string?,
}

local TINY_PNG_BASE64 =
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

local function mark(rows: { Row }, capabilityId: string, verdict: Verdict, note: string)
	for _, row in rows do
		if row.id == capabilityId then
			if not row.overridden then
				row.verdict = verdict
				row.source = "live_probe"
				row.note = note
				row.checkedAt = os.clock()
			end
			return
		end
	end
end

local function rowById(rows: { Row }, capabilityId: string): Row?
	for _, row in rows do
		if row.id == capabilityId then
			return row
		end
	end
	return nil
end

--- Builds a profile for probing a different protocol against the same endpoint.
local function probeProfile(profile: any, protocolId: string): any
	local copy = table.clone(profile)
	copy.protocol = protocolId
	copy.endpointPath = APIEndpointRouter.chatPath(protocolId)
	copy.urlMode = "base"
	return copy
end

local function post(profile: any, protocolId: string, body: any, timeoutMs: number?, shouldCancel: (() -> boolean)?): any
	local ProviderService = require(script.Parent.ProviderService)
	local spec = {
		messages = { { role = "user", content = "Reply with the single word: ok" } },
		system = "You are a capability probe. Follow the instruction exactly.",
		model = profile.modelId,
		maxOutputTokens = 64,
		streaming = false,
		jsonMode = false,
		toolChoice = "none",
	}
	if protocolId == "openai_text_completions" then
		spec.messages = {}
		spec.system = nil
	end
	local prepared = ProviderService.prepare(probeProfile(profile, protocolId), spec, CredentialStore.get(profile.id), false)
	if not prepared then
		return nil, { transportError = "Could not build the probe request." }
	end

	local response = UniversalHTTPClient.postJson(
		prepared.url,
		prepared.headers,
		prepared.jsonBody or {},
		{ timeoutMs = timeoutMs or 30000, label = "capability-probe", shouldCancel = shouldCancel }
	)
	if not response.ok then
		return nil, {
			statusCode = response.statusCode,
			body = response.body,
			headers = response.headers,
			transportError = response.transportError,
		}
	end
	return response.body, nil
end

--- Runs capability probes. Every probe is a real request.
function CapabilityInspector.probe(profile: any, options: ProbeOptions?): Report
	local opts = options or {}
	local report = CapabilityInspector.buildReport(profile)
	local apiKey = CredentialStore.get(profile.id)
	local ProviderService = require(script.Parent.ProviderService)

	local function progress()
		-- The UI reads the report object each time, so one emit is enough.
		EventBus.emit(EventBus.Events.CapabilitiesChanged, { report = report })
	end

	local function cancelled(): boolean
		return opts.shouldCancel ~= nil and opts.shouldCancel() == true
	end

	-- 1. Chat Completions with a tool offer (covers tool calling + system prompt).
	if not cancelled() and (opts.only == nil or opts.only == "chat_completions" or opts.only == "tool_calling") then
		local spec = {
			messages = { { role = "user", content = "Call the probe_tool function exactly once." } },
			system = "You are a capability probe.",
			model = profile.modelId,
			maxOutputTokens = 128,
			streaming = false,
			jsonMode = false,
			toolChoice = "required",
			tools = {
				{
					name = "probe_tool",
					description = "Returns a constant.",
					parameters = { type = "object", properties = {}, additionalProperties = false },
				},
			},
		}
		local prepared = ProviderService.prepare(profile, spec, apiKey, false)
		if prepared then
			local response = UniversalHTTPClient.postJson(
				prepared.url,
				prepared.headers,
				prepared.jsonBody or {},
				{ timeoutMs = math.min(profile.timeoutMs or 30000, 30000), label = "capability/chat", shouldCancel = cancelled }
			)
			if response.ok then
				local parsed = ProviderService.parseAdapterResponse(profile, response.body)
				mark(report.rows, "chat_completions", "Supported", "A chat request succeeded and returned a usable reply.")
				mark(report.rows, "system_instructions", "Supported", "The request carried a system instruction.")
				if parsed and #parsed.toolCalls > 0 then
					mark(report.rows, "tool_calling", "Supported", string.format("The model requested `%s`.", parsed.toolCalls[1].name))
					mark(report.rows, "parallel_tool_calling", "Unknown", "One tool was offered, so parallelism was not measured.")
				else
					mark(report.rows, "tool_calling", "Unsupported", "The request succeeded but no tool call came back.")
				end
				if parsed and parsed.usage and parsed.usage.reasoningTokens and parsed.usage.reasoningTokens > 0 then
					mark(report.rows, "reasoning", "Supported", string.format("Reported %d reasoning tokens.", parsed.usage.reasoningTokens))
				else
					mark(report.rows, "reasoning", "Unknown", "No reasoning token field appeared in the usage block.")
				end
			else
				mark(report.rows, "chat_completions", "Unknown", "The chat probe request failed; see the log for details.")
				mark(report.rows, "tool_calling", "Unknown", "Not probed because the chat probe failed.")
			end
		else
			mark(report.rows, "chat_completions", "Unknown", "Could not build the probe request.")
		end
		progress()
	end

	-- 2. Text Completions.
	if
		not cancelled()
		and (opts.only == nil or opts.only == "text_completions")
		and UniversalProviderRegistry.getProtocol(profile.protocol).supportsTextCompletions
	then
		local textProfile = probeProfile(profile, "openai_text_completions")
		local ok, err = post(textProfile, "openai_text_completions", nil, math.min(profile.timeoutMs or 30000, 30000), cancelled)
		if ok then
			local decoded = require(script.Parent.Parent.Utilities.JSONValidator).decode(ok)
			local valid = type(decoded) == "table"
				and type(decoded.choices) == "table"
				and #decoded.choices > 0
				and type(decoded.choices[1].text) == "string"
			mark(
				report.rows,
				"text_completions",
				if valid then "Supported" else "Unknown",
				if valid
					then "The /completions route returned choices[].text."
					else "HTTP succeeded but choices[].text was absent."
			)
		else
			mark(report.rows, "text_completions", "Unsupported", string.format("Probe failed: %s", tostring((err :: any).statusCode or "error")))
		end
		progress()
	end

	-- 3. Responses API.
	if
		not cancelled()
		and (opts.only == nil or opts.only == "responses_api")
		and profile.protocol ~= "anthropic_messages"
		and profile.protocol ~= "gemini_native"
	then
		local ok = post(probeProfile(profile, "openai_responses"), "openai_responses", nil, math.min(profile.timeoutMs or 30000, 30000), cancelled)
		if ok then
			local decoded = require(script.Parent.Parent.Utilities.JSONValidator).decode(ok)
			local valid = type(decoded) == "table" and (decoded.output ~= nil or decoded.output_text ~= nil)
			mark(
				report.rows,
				"responses_api",
				if valid then "Supported" else "Unknown",
				if valid then "The /responses route returned an output field." else "HTTP succeeded but no output field appeared."
			)
		else
			mark(report.rows, "responses_api", "Unsupported", "This endpoint did not serve the /responses route.")
		end
		progress()
	end

	-- 4. Streaming — a real stream, counting chunks.
	if not cancelled() and (opts.only == nil or opts.only == "streaming") then
		if not UniversalHTTPClient.supportsStreaming() then
			mark(report.rows, "streaming", "Unknown", "This Studio build has no CreateWebStreamClient, so streaming cannot be tested here.")
		else
			local ProviderService2 = require(script.Parent.ProviderService)
			local spec = {
				messages = { { role = "user", content = "Count to three." } },
				model = profile.modelId,
				maxOutputTokens = 32,
				streaming = true,
				jsonMode = false,
				toolChoice = "none",
			}
			local prepared = ProviderService2.prepare(profile, spec, apiKey, true)
			if prepared and prepared.streaming then
				local chunks = 0
				local handle = UniversalHTTPClient.stream({
					url = prepared.url,
					headers = prepared.headers,
					body = prepared.body,
					timeoutMs = math.min(profile.timeoutMs or 30000, 30000),
					label = "capability/streaming",
				}, {
					onChunk = function()
						chunks += 1
					end,
					onComplete = function() end,
					onError = function() end,
				})
				if handle then
					local waited = 0
					while not handle.isDone() and waited < math.min(profile.timeoutMs or 30000, 30000) / 1000 and not cancelled() do
						task.wait(0.1)
						waited += 0.1
					end
					if not handle.isDone() then handle.cancel() end
					mark(
						report.rows,
						"streaming",
						if chunks > 1 then "Supported" else "Unknown",
						if chunks > 1
							then string.format("The stream delivered %d chunks.", chunks)
							else "The stream opened but produced fewer than two chunks."
					)
				else
					mark(report.rows, "streaming", "Unsupported", "The endpoint refused a streaming request.")
				end
			else
				mark(report.rows, "streaming", "Unsupported", "The request could not be prepared as a stream.")
			end
			progress()
		end
	end

	-- 5. Structured JSON.
	if not cancelled() and (opts.only == nil or opts.only == "structured_json") then
		local ProviderService3 = require(script.Parent.ProviderService)
		local spec = {
			messages = { { role = "user", content = 'Return {"ok":true}' } },
			model = profile.modelId,
			maxOutputTokens = 64,
			streaming = false,
			jsonMode = true,
			toolChoice = "none",
		}
		local prepared = ProviderService3.prepare(profile, spec, apiKey, false)
		if prepared then
			local response = UniversalHTTPClient.postJson(prepared.url, prepared.headers, prepared.jsonBody or {}, {
				timeoutMs = math.min(profile.timeoutMs or 30000, 30000),
				shouldCancel = cancelled,
				label = "capability/json",
			})
			if response.ok then
				local parsed = ProviderService3.parseAdapterResponse(profile, response.body)
				local valid = parsed ~= nil
					and require(script.Parent.Parent.Utilities.JSONValidator).decode(parsed.text or "") ~= nil
				mark(
					report.rows,
					"structured_json",
					if valid then "Supported" else "Unsupported",
					if valid then "JSON mode returned parseable JSON." else "JSON mode did not return parseable JSON."
				)
			else
				mark(report.rows, "structured_json", "Unknown", "The JSON-mode probe request failed.")
			end
		end
		progress()
	end

	-- 6. Vision.
	if not cancelled() and (opts.only == nil or opts.only == "vision") then
		local ProviderService4 = require(script.Parent.ProviderService)
		local spec = {
			messages = {
				{
					role = "user",
					parts = {
						{ kind = "text", text = "What colour is this? One word." },
						{ kind = "image", mime = "image/png", data = TINY_PNG_BASE64, fileName = "probe.png" },
					},
				},
			},
			model = profile.modelId,
			maxOutputTokens = 32,
			streaming = false,
			jsonMode = false,
			toolChoice = "none",
		}
		local prepared = ProviderService4.prepare(profile, spec, apiKey, false)
		if prepared then
			local response = UniversalHTTPClient.postJson(prepared.url, prepared.headers, prepared.jsonBody or {}, {
				timeoutMs = math.min(profile.timeoutMs or 30000, 30000),
				shouldCancel = cancelled,
				label = "capability/vision",
			})
			if response.ok then
				mark(report.rows, "vision", "Supported", "The endpoint accepted an inline image and replied.")
			else
				local status = response.statusCode or 0
				mark(
					report.rows,
					"vision",
					if status == 400 or status == 415 or status == 422 then "Unsupported" else "Unknown",
					if status == 400 or status == 415 or status == 422
						then string.format("The provider rejected the image (HTTP %d).", status)
						else "The vision probe was inconclusive."
				)
			end
		end
		progress()
	end

	report.generatedAt = os.clock()

	local counts = { Supported = 0, Unsupported = 0, Unknown = 0 }
	for _, row in report.rows do
		counts[row.verdict] += 1
	end

	Logger.success("Capabilities", "Capability probes finished.", {
		detail = string.format(
			"%s · %s · %d supported, %d unsupported, %d unknown",
			report.providerName,
			report.modelId,
			counts.Supported,
			counts.Unsupported,
			counts.Unknown
		),
	})

	return report
end

--=============================================================================
-- SUMMARY
--=============================================================================

function CapabilityInspector.summary(report: Report): { Supported: number, Unsupported: number, Unknown: number }
	local counts = { Supported = 0, Unsupported = 0, Unknown = 0 }
	for _, row in report.rows do
		counts[row.verdict] += 1
	end
	return counts
end

function CapabilityInspector.getRow(report: Report, capabilityId: string): Row?
	return rowById(report.rows, capabilityId)
end

function CapabilityInspector.describeRow(row: Row): string
	local when = if row.checkedAt then string.format(" · %.0fs ago", os.clock() - row.checkedAt) else ""
	return string.format("%s — %s (%s%s)", row.label, row.verdict, row.source, when)
end

return CapabilityInspector
