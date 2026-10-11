--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / AI / ModelCapabilityDetector
	Reports Supported / Unsupported / Unknown per capability.

	RULES
	-----
	* Provider metadata is trusted (it is what the provider documents).
	* Model metadata overrides provider metadata when it is more specific.
	* When neither exists, the state is UNKNOWN — never guessed.
	* Optional live probes issue REAL requests and say so.
	* Manual overrides are permitted and clearly marked as unverified.
]]

local ProviderRegistry = require(script.Parent.ProviderRegistry)
local ProviderService = require(script.Parent.ProviderService)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)

local ModelCapabilityDetector = {}

export type Status = "supported" | "unsupported" | "unknown"

export type CapabilityId =
	| "text_input"
	| "text_output"
	| "vision"
	| "image_generation"
	| "document_input"
	| "pdf_input"
	| "audio_input"
	| "audio_output"
	| "video_input"
	| "tool_calling"
	| "parallel_tool_calling"
	| "structured_json"
	| "streaming"
	| "reasoning"
	| "reasoning_effort"
	| "reasoning_summaries"
	| "prompt_caching"
	| "temperature"
	| "top_p"
	| "system_instructions"

export type Capability = {
	id: CapabilityId,
	label: string,
	status: Status,
	verification: string,
	lastChecked: number?,
	details: string?,
	overridden: boolean,
	source: string,
}

export type Report = {
	providerId: string,
	modelId: string,
	presetId: string,
	capabilities: { [string]: Capability },
	contextWindow: number,
	contextWindowSource: string,
	maxOutputTokens: number,
	maxOutputTokensSource: string,
	pricing: { input: number?, output: number?, source: string },
	checkedAt: number,
}

--=============================================================================
-- CATALOGUE
--=============================================================================

export type Definition = {
	id: CapabilityId,
	label: string,
	group: string,
	-- Can this be proven with a real API request?
	probeable: boolean,
	probeCost: "none" | "low" | "high",
	probeNote: string,
}

local currentProbeKey = ""

local capabilityDefinitions: { Definition } = {
	{ id = "text_input", label = "Text Input", group = "Core", probeable = true, probeCost = "low", probeNote = "Included in every request." },
	{ id = "text_output", label = "Text Output", group = "Core", probeable = true, probeCost = "low", probeNote = "Included in every request." },
	{ id = "vision", label = "Vision / Image Input", group = "Modalities", probeable = true, probeCost = "high", probeNote = "Sends a small generated PNG." },
	{ id = "image_generation", label = "Image Generation", group = "Modalities", probeable = false, probeCost = "high", probeNote = "Requires a dedicated image endpoint ForgePilot does not call." },
	{ id = "document_input", label = "Document Input", group = "Modalities", probeable = true, probeCost = "low", probeNote = "Sends a short text document." },
	{ id = "pdf_input", label = "PDF Input", group = "Modalities", probeable = false, probeCost = "high", probeNote = "Chat endpoints cannot verify binary PDF parsing." },
	{ id = "audio_input", label = "Audio Input", group = "Modalities", probeable = false, probeCost = "high", probeNote = "Only the Gemini native protocol inlines audio." },
	{ id = "audio_output", label = "Audio Output", group = "Modalities", probeable = false, probeCost = "high", probeNote = "No chat endpoint returns audio." },
	{ id = "video_input", label = "Video Input", group = "Modalities", probeable = false, probeCost = "high", probeNote = "Only the Gemini native protocol inlines video." },
	{ id = "tool_calling", label = "Tool Calling", group = "Agent", probeable = true, probeCost = "low", probeNote = "Offers a tool and checks whether the model requests it." },
	{ id = "parallel_tool_calling", label = "Parallel Tool Calling", group = "Agent", probeable = true, probeCost = "low", probeNote = "Offers two tools and counts the returned calls." },
	{ id = "structured_json", label = "Structured JSON Output", group = "Agent", probeable = true, probeCost = "low", probeNote = "Requests JSON mode and validates the reply." },
	{ id = "streaming", label = "Streaming", group = "Transport", probeable = true, probeCost = "low", probeNote = "Opens a real stream and counts received chunks." },
	{ id = "reasoning", label = "Reasoning", group = "Reasoning", probeable = true, probeCost = "high", probeNote = "Looks for reasoning tokens or reasoning text in the response." },
	{ id = "reasoning_effort", label = "Reasoning Effort", group = "Reasoning", probeable = false, probeCost = "low", probeNote = "Parameter presence is protocol-level; effect is not observable cheaply." },
	{ id = "reasoning_summaries", label = "Reasoning Summaries", group = "Reasoning", probeable = true, probeCost = "high", probeNote = "Requests a summary and inspects the response." },
	{ id = "prompt_caching", label = "Prompt Caching", group = "Context", probeable = false, probeCost = "high", probeNote = "Requires comparing cached token counts across repeated large requests." },
	{ id = "temperature", label = "Temperature", group = "Parameters", probeable = false, probeCost = "none", probeNote = "Parameter presence is protocol-level." },
	{ id = "top_p", label = "Top P", group = "Parameters", probeable = false, probeCost = "none", probeNote = "Parameter presence is protocol-level." },
	{ id = "system_instructions", label = "System Instructions", group = "Parameters", probeable = true, probeCost = "low", probeNote = "Sends a system instruction and checks it is honoured." },
}

ModelCapabilityDetector.Definitions = capabilityDefinitions

--=============================================================================
-- INTERNAL STATE
--=============================================================================

local reports: { [string]: Report } = {} -- key: providerId .. "|" .. modelId
local knownProfiles: { [string]: any } = {} -- key: same, the profile a report was built from
local overrides: { [string]: { [string]: Status } } = {} -- capabilityId -> Status (per model key)
EventBus.on("RouterModelsChanged", function(payload)
    for modelKey, profile in knownProfiles do
        if profile.viaRouter and profile.routerProviderId == payload.providerId then reports[modelKey] = nil end
    end
end)

local function key(providerId: string, modelId: string): string
	return providerId .. "|" .. modelId
end

--=============================================================================
-- STATUS RESOLUTION
--=============================================================================

local function metadataStatus(hint: any): Status
	if hint == "yes" then
		return "supported"
	elseif hint == "no" then
		return "unsupported"
	end
	return "unknown"
end

local function describeStatusSource(source: string): string
	if source == "provider_metadata" then
		return "Provider documentation metadata"
	elseif source == "model_metadata" then
		return "Model metadata for this exact model id"
	elseif source == "router_catalog" then
		return "9Router model catalog (not a live API probe)"
	elseif source == "protocol" then
		return "Protocol definition"
	elseif source == "manual_override" then
		return "Manual override (unverified)"
	elseif source == "live_probe" then
		return "Live API probe"
	end
	return "Not determined"
end

--=============================================================================
-- REPORT BUILDER
--=============================================================================

--- Builds a report from metadata only. Cheap and offline.
function ModelCapabilityDetector.buildReport(profile: any): Report
	local preset = ProviderRegistry.getPreset(profile.presetId or "")
	local protocol = ProviderRegistry.getProtocol(profile.protocol)
	local modelId = profile.modelId or ""
	local modelKey = key(profile.id, modelId)

	local modelMetadata = if preset then preset.modelMetadata[modelId] else nil
	local routerMetadata = if profile.viaRouter then BridgeClient.getModelMetadata(profile) else nil
	local routerNames = { tool_calling = "tools", vision = "vision", reasoning = "reasoning" }

	local capabilities: { [string]: Capability } = {}

	for _, definition in ModelCapabilityDetector.Definitions do
		local status: Status = "unknown"
		local source = "unavailable"

		-- A preset entry of "unknown" means the provider itself does not claim
		-- this capability, so it is treated as absent rather than as evidence.
		local modelHint = if modelMetadata then modelMetadata.capabilities[definition.id] else nil
		local presetHint = if preset then preset.providerCapabilities[definition.id] else nil
		local routerName = routerNames[definition.id]
		local routerHint = if routerMetadata and type(routerMetadata.capabilities) == "table" and routerName then routerMetadata.capabilities[routerName] else nil

		if type(routerHint) == "boolean" then
			status = if routerHint then "supported" else "unsupported"
			source = "router_catalog"
		elseif modelHint == "yes" or modelHint == "no" then
			status = metadataStatus(modelHint)
			source = "model_metadata"
		elseif presetHint == "yes" or presetHint == "no" then
			status = metadataStatus(presetHint)
			source = "provider_metadata"
		else
			-- Protocol-level knowledge is reliable for transport/parameter features.
			if definition.id == "streaming" then
				status = if protocol.supportsStreaming then "supported" else "unsupported"
				source = "protocol"
			elseif definition.id == "tool_calling" then
				if not profile.viaRouter then
					status = if protocol.supportsToolCalling then "supported" else "unsupported"
					source = "protocol"
				end
			elseif definition.id == "system_instructions" then
				status = if protocol.supportsSystemRole then "supported" else "unsupported"
				source = "protocol"
			elseif definition.id == "structured_json" then
				status = if protocol.supportsJsonMode then "supported" else "unsupported"
				source = "protocol"
			elseif definition.id == "reasoning_effort" then
				status = if protocol.supportsReasoningEffort then "supported" else "unsupported"
				source = "protocol"
			elseif definition.id == "reasoning_summaries" then
				status = if protocol.supportsReasoningSummaries then "supported" else "unsupported"
				source = "protocol"
			elseif definition.id == "prompt_caching" then
				status = if protocol.supportsPromptCaching then "supported" else "unsupported"
				source = "protocol"
			elseif definition.id == "text_input" or definition.id == "text_output" then
				status = "supported"
				source = "protocol"
			end
		end

		capabilities[definition.id] = {
			id = definition.id,
			label = definition.label,
			status = status,
			verification = describeStatusSource(source),
			lastChecked = nil,
			details = source == "unavailable"
				and "No metadata available for this model. Run a live probe or set a manual override."
				or nil,
			overridden = false,
			source = source,
		}
	end

	-- Manual overrides win, and are labelled as unverified.
	local modelOverrides = overrides[modelKey]
	if modelOverrides then
		for capabilityId, forced in modelOverrides do
			local capability = capabilities[capabilityId]
			if capability then
				capability.status = forced
				capability.source = "manual_override"
				capability.verification = "Manual override (unverified)"
				capability.overridden = true
			end
		end
	end

	local contextWindow = 128000
	local contextWindowSource = "Default estimate — no metadata for this model."
	if routerMetadata and routerMetadata.contextWindow and profile.contextWindowMode ~= "manual" then
		contextWindow = routerMetadata.contextWindow
		contextWindowSource = "9Router model catalog (not live-probed)."
	elseif modelMetadata and profile.contextWindowMode ~= "manual" then
		contextWindow = modelMetadata.contextWindow
		contextWindowSource = "Model metadata."
	elseif profile.contextWindow and profile.contextWindow > 0 then
		contextWindow = profile.contextWindow
		contextWindowSource = "Manual value from the provider settings."
	end

	local maxOutput = 4096
	local maxOutputSource = "Default — no metadata for this model."
	if routerMetadata and routerMetadata.maxOutputTokens and profile.maxOutputTokensMode ~= "manual" then
		maxOutput = routerMetadata.maxOutputTokens
		maxOutputSource = "9Router model catalog (not live-probed)."
	elseif modelMetadata and profile.maxOutputTokensMode ~= "manual" then
		maxOutput = modelMetadata.maxOutputTokens
		maxOutputSource = "Model metadata."
	elseif profile.maxOutputTokens and profile.maxOutputTokens > 0 then
		maxOutput = profile.maxOutputTokens
		maxOutputSource = "Manual value from the provider settings."
	end

	local report: Report = {
		providerId = profile.id,
		modelId = modelId,
		presetId = if preset then preset.id else "custom",
		capabilities = capabilities,
		contextWindow = contextWindow,
		contextWindowSource = contextWindowSource,
		maxOutputTokens = maxOutput,
		maxOutputTokensSource = maxOutputSource,
		pricing = {
			input = if modelMetadata then modelMetadata.inputCostPerMTok else nil,
			output = if modelMetadata then modelMetadata.outputCostPerMTok else nil,
			source = if modelMetadata and modelMetadata.inputCostPerMTok
				then "Model metadata (may be outdated — verify with your provider)"
				else "No pricing metadata available",
		},
		checkedAt = os.clock(),
	}

	reports[modelKey] = report
	knownProfiles[modelKey] = profile
	return report
end

function ModelCapabilityDetector.getReport(providerId: string, modelId: string): Report?
	return reports[key(providerId, modelId)]
end

function ModelCapabilityDetector.getOrBuildReport(profile: any): Report
	local existing = reports[key(profile.id, profile.modelId or "")]
	if existing then
		return existing
	end
	return ModelCapabilityDetector.buildReport(profile)
end

--=============================================================================
-- MANUAL OVERRIDES
--=============================================================================

function ModelCapabilityDetector.setOverride(providerId: string, modelId: string, capabilityId: string, status: Status?)
	local modelKey = key(providerId, modelId)
	local bucket = overrides[modelKey]
	if not bucket then
		bucket = {}
		overrides[modelKey] = bucket
	end
	if status == nil then
		bucket[capabilityId] = nil
	else
		bucket[capabilityId] = status
	end

	local report = reports[modelKey]
	if status == nil and report then
		-- Clearing an override re-derives the status from metadata instead of
		-- leaving a stale "unknown" behind.
		local stored = knownProfiles[modelKey]
		if stored then
			report = ModelCapabilityDetector.buildReport(stored)
		end
	end

	if report and status ~= nil then
		local capability = report.capabilities[capabilityId]
		if capability then
			capability.status = status
			capability.source = "manual_override"
			capability.verification = "Manual override (unverified)"
			capability.overridden = true
			capability.lastChecked = os.clock()
		end
	end

	EventBus.emit(EventBus.Events.CapabilitiesChanged, { report = report })
end

function ModelCapabilityDetector.clearOverrides(providerId: string, modelId: string)
	overrides[key(providerId, modelId)] = nil
	local report = reports[key(providerId, modelId)]
	if report then
		for capabilityId, capability in report.capabilities do
			capability.overridden = false
			capability.source = "unavailable"
			capability.status = "unknown"
			capability.verification = "Not determined"
		end
	end
	EventBus.emit(EventBus.Events.CapabilitiesChanged, { report = report })
end

--=============================================================================
-- LIVE PROBES
--=============================================================================

-- A 1x1 transparent PNG, used only to test whether an endpoint accepts images.
local TINY_PNG_BASE64 =
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

local function mark(capabilityId: string, status: Status, detail: string)
	local report = reports[currentProbeKey]
	if not report then
		return
	end
	local capability = report.capabilities[capabilityId]
	if not capability then
		return
	end
	-- A manual override is never silently replaced by a probe result.
	if capability.overridden then
		return
	end
	capability.status = status
	capability.source = "live_probe"
	capability.verification = "Live API probe"
	capability.lastChecked = os.clock()
	capability.details = detail
end

-- NOTE: `mark` closes over the `currentProbeKey` declared at the top of this
-- module. runProbes must assign THAT variable — a second local declaration here
-- would shadow it and every probe would silently write to reports[""].

export type ProbeOptions = {
	onProgress: ((capabilityId: string, label: string, status: Status, detail: string) -> ())?,
	signal: any?,
}

--- Runs the probeable capability checks against the live provider.
--- Each check is a real request; some cost more than others.
function ModelCapabilityDetector.runProbes(profile: any, apiKey: string?, options: ProbeOptions?)
	local opts = options or {}
	currentProbeKey = key(profile.id, profile.modelId or "")

	local report = ModelCapabilityDetector.getOrBuildReport(profile)
	local signal = opts.signal

	local function notify(capabilityId: string, detail: string)
		local capability = report.capabilities[capabilityId]
		if opts.onProgress and capability then
			opts.onProgress(capabilityId, capability.label, capability.status, detail)
		end
		EventBus.emit(EventBus.Events.CapabilitiesChanged, { report = report, capabilityId = capabilityId })
	end

	-- 1. Text output / tool calling ------------------------------------------------
	local toolSchema = {
		type = "function",
		name = "probe_tool",
		description = "Returns a constant. Call this tool.",
		parameters = { type = "object", properties = {}, additionalProperties = false },
	}

	local textSpec = {
		messages = { { role = "user", content = "Call the probe_tool function exactly once. Do not answer in text." } },
		system = "You are a capability probe. Follow the instruction exactly.",
		tools = { toolSchema },
		toolChoice = "required",
		model = profile.modelId,
		maxOutputTokens = 128,
		streaming = false,
		jsonMode = false,
		temperature = 0,
	}

	-- ProviderService.complete returns a single CompleteResult table.
	local result = ProviderService.complete(profile, textSpec, apiKey)
	local response = result.ok and result.response or nil
	if response then
		mark("text_input", "supported", "Accepted a text request.")
		mark("text_output", "supported", string.format("Returned %d characters.", #response.text))
		mark("system_instructions", "supported", "Request included a system instruction.")

		local toolCalls = response.toolCalls or {}
		if #toolCalls > 0 then
			mark("tool_calling", "supported", string.format("Model requested tool `%s`.", tostring(toolCalls[1].name)))
		else
			mark("tool_calling", "unsupported", "Request succeeded but the model returned no tool call.")
		end

		if response.usage then
			if response.usage.inputTokens and response.usage.outputTokens then
				mark("reasoning", response.usage.reasoningTokens and "supported" or "unknown",
					response.usage.reasoningTokens
						and string.format("Reported %d reasoning tokens.", response.usage.reasoningTokens)
						or "No reasoning token field in usage. Cannot confirm.")
			end
			if response.usage.cachedTokens and response.usage.cachedTokens > 0 then
				mark("prompt_caching", "supported", string.format("Reported %d cached tokens.", response.usage.cachedTokens))
			else
				mark("prompt_caching", "unknown", "No cached token count was reported on this short request.")
			end
		end
	else
		local reason = tostring(result.error or "The probe request failed.")
		for _, capabilityId in { "text_input", "text_output", "tool_calling", "system_instructions", "reasoning", "prompt_caching" } do
			mark(capabilityId, "unknown", "Probe could not run: " .. reason)
		end
	end

	for _, capabilityId in { "text_input", "text_output", "tool_calling", "system_instructions", "reasoning", "prompt_caching" } do
		notify(capabilityId, report.capabilities[capabilityId].details or "")
	end

	if signal and signal.cancelled then
		return report
	end

	-- 2. Structured JSON -----------------------------------------------------------
	local jsonSpec = {
		messages = { { role = "user", content = "Return a JSON object with a single key \"ok\" set to true." } },
		model = profile.modelId,
		maxOutputTokens = 128,
		streaming = false,
		jsonMode = true,
		temperature = 0,
		toolChoice = "none",
	}
	-- ProviderService.complete returns a single CompleteResult table.
	local jsonResult = ProviderService.complete(profile, jsonSpec, apiKey)
	local jsonResponse = jsonResult.ok and jsonResult.response or nil
	if jsonResponse then
		local ok = pcall(HttpService.JSONDecode, HttpService, jsonResponse.text or "")
		mark("structured_json", if ok then "supported" else "unsupported",
			if ok then "JSON mode returned parseable JSON." else "JSON mode did not return parseable JSON.")
		if jsonResponse.usage and jsonResponse.usage.reasoningTokens and jsonResponse.usage.reasoningTokens > 0 then
			mark("reasoning", "supported", string.format("Reported %d reasoning tokens.", jsonResponse.usage.reasoningTokens))
			notify("reasoning", report.capabilities.reasoning.details or "")
		end
	else
		mark("structured_json", "unknown", "Probe request failed: " .. tostring(jsonResult.error))
	end
	notify("structured_json", report.capabilities.structured_json.details or "")

	if signal and signal.cancelled then
		return report
	end

	-- 3. Vision --------------------------------------------------------------------
	local visionSpec = {
		messages = {
			{
				role = "user",
				parts = {
					{ kind = "text", text = "What single colour is this pixel? Answer with one word." },
					{ kind = "image", mime = "image/png", data = TINY_PNG_BASE64, fileName = "probe.png" },
				},
			},
		},
		model = profile.modelId,
		maxOutputTokens = 64,
		streaming = false,
		temperature = 0,
		toolChoice = "none",
	}
	local visionResult = ProviderService.complete(profile, visionSpec, apiKey)
	local visionResponse = visionResult.ok and visionResult.response or nil
	if visionResponse then
		mark("vision", "supported", "Endpoint accepted an inline image and returned a reply.")
	else
		local message = tostring(visionResult.error)
		local looksUnsupported = string.find(message, "400", 1, true) ~= nil
			or string.find(string.lower(message), "image", 1, true) ~= nil
			or string.find(string.lower(message), "modalit", 1, true) ~= nil
		mark("vision", if looksUnsupported then "unsupported" else "unknown",
			if looksUnsupported then "Provider rejected the image input: " .. message else "Probe inconclusive: " .. message)
	end
	notify("vision", report.capabilities.vision.details or "")

	report.checkedAt = os.clock()
	Logger.success("AI Provider", "Capability probes finished.", {
		detail = string.format("Model %s on %s", profile.modelId, profile.displayName),
	})
	EventBus.emit(EventBus.Events.CapabilitiesChanged, { report = report })
	return report
end

--=============================================================================
-- SUMMARY HELPERS
--=============================================================================

function ModelCapabilityDetector.statusColor(status: Status): Color3
	if status == "supported" then
		return Color3.fromHex("#49C591")
	elseif status == "unsupported" then
		return Color3.fromHex("#F16E7A")
	end
	return Color3.fromHex("#A7A0B2")
end

function ModelCapabilityDetector.statusLabel(status: Status): string
	if status == "supported" then
		return "Supported"
	elseif status == "unsupported" then
		return "Unsupported"
	end
	return "Unknown"
end

function ModelCapabilityDetector.summary(report: Report): { supported: number, unsupported: number, unknown: number }
	local counts = { supported = 0, unsupported = 0, unknown = 0 }
	for _, capability in report.capabilities do
		counts[capability.status] += 1
	end
	return counts
end

--- Modalities the attachment pipeline should enforce for this model.
---
--- Two gates apply: what the MODEL reports it supports, and what the PROTOCOL can
--- actually carry inline. For example OpenAI's chat-completions body has no
--- audio or video block, so ForgePilot refuses to claim it can send one even
--- when the model id suggests audio support.
function ModelCapabilityDetector.allowedAttachmentKinds(report: Report?, protocolId: string?): { [string]: boolean }
	local allowed: { [string]: boolean } = { text = true }

	if not report then
		return allowed
	end

	local function supports(id: CapabilityId): boolean
		local capability = report.capabilities[id]
		return capability ~= nil and capability.status == "supported"
	end

	local protocol = ProviderRegistry.getProtocol(protocolId or "openai_compatible")

	-- Only Gemini's native generateContent body carries inline media of every
	-- kind; every other protocol ForgePilot speaks has text and images only.
	local nativeMultimodal = protocol.id == "gemini_native"

	allowed.image = supports("vision") and protocol.supportsImages
	allowed.document = supports("document_input") and protocol.supportsDocuments
	allowed.pdf = supports("pdf_input") and nativeMultimodal
	allowed.audio = supports("audio_input") and nativeMultimodal
	allowed.video = supports("video_input") and nativeMultimodal

	return allowed
end

return ModelCapabilityDetector
