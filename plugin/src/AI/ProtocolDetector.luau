--!strict
--[[
	ForgePilot / AI / ProtocolDetector
	Bounded, user-authorised protocol probing.

	THE RULES THIS ENFORCES
	  * A generic HTTP 200 is NOT proof a protocol works. Every candidate response
	    must contain the structure that protocol requires.
	  * HTTP 404 is NOT proof another protocol exists. It only means this path did
	    not answer.
	  * Only the paths ForgePilot would actually use are probed. Nothing else.
	  * Each probe is a real request and may cost money, so the count is bounded,
	    the user is warned first, and cancellation is honoured between probes.

	Detection order matches the spec:
	  known metadata → documented schema → model list → capability probes → manual
]]

local APIEndpointRouter = require(script.Parent.APIEndpointRouter)
local BaseURLResolver = require(script.Parent.BaseURLResolver)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local JSONValidator = require(script.Parent.Parent.Utilities.JSONValidator)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local Time = require(script.Parent.Parent.Utilities.Time)
local UniversalHTTPClient = require(script.Parent.Parent.Utilities.UniversalHTTPClient)
local UniversalProviderRegistry = require(script.Parent.UniversalProviderRegistry)

local ProtocolDetector = {}

--=============================================================================
-- CANDIDATES
--=============================================================================

export type Candidate = {
	protocolId: string,
	label: string,
	confidence: number,
	source: string,
	validated: boolean,
	note: string,
}

-- Probed in this order: chat first (most widely supported), then the rest.
local PROBE_ORDER = {
	"openai_chat",
	"openai_responses",
	"openai_text_completions",
	"anthropic_messages",
	"gemini_native",
	"openrouter",
	"gemini_openai",
	"custom_rest",
}

--=============================================================================
-- RESPONSE VALIDATORS
--=============================================================================
-- A candidate is "validated" only when the body proves the shape.

local function hasChoices(body: string): (boolean, string?)
	local decoded = JSONValidator.decode(body)
	if type(decoded) ~= "table" then
		return false, "Response was not valid JSON."
	end
	if type(decoded.error) == "table" then
		return false, "Provider returned an error object."
	end
	local choices = decoded.choices
	if type(choices) ~= "table" or #choices == 0 then
		return false, "No `choices` array in the response."
	end
	local first = choices[1]
	if type(first) ~= "table" then
		return false, "`choices[0]` was not an object."
	end
	-- Chat Completions put content under message; legacy puts it under text.
	if type(first.message) == "table" or type(first.text) == "string" or type(first.delta) == "table" then
		return true, nil
	end
	return false, "`choices[0]` had neither `message` nor `text`."
end

local function hasLegacyCompletionText(body: string): (boolean, string?)
	local decoded = JSONValidator.decode(body)
	if type(decoded) ~= "table" or type(decoded.choices) ~= "table" or #decoded.choices == 0 then
		return false, "No `choices` array."
	end
	local first = decoded.choices[1]
	if type(first) ~= "table" or type(first.text) ~= "string" then
		return false, "`choices[0].text` was absent — this is not a Text Completions response."
	end
	return true, nil
end

local function hasResponsesOutput(body: string): (boolean, string?)
	local decoded = JSONValidator.decode(body)
	if type(decoded) ~= "table" then
		return false, "Response was not valid JSON."
	end
	if type(decoded.error) == "table" then
		return false, "Provider returned an error object."
	end
	if decoded.output == nil and decoded.output_text == nil then
		return false, "No `output` field — this is not a Responses API result."
	end
	return true, nil
end

local function hasAnthropicContent(body: string): (boolean, string?)
	local decoded = JSONValidator.decode(body)
	if type(decoded) ~= "table" then
		return false, "Response was not valid JSON."
	end
	if type(decoded.error) == "table" then
		return false, "Provider returned an error object."
	end
	if decoded.type ~= "message" and decoded.content == nil then
		return false, "No `content` block array — this is not an Anthropic Messages result."
	end
	local content = decoded.content
	if type(content) ~= "table" then
		return false, "`content` was not an array."
	end
	for _, block in content do
		if type(block) == "table" and (block.type == "text" or block.type == "tool_use") then
			return true, nil
		end
	end
	return false, "`content` had no text or tool_use block."
end

local function hasGeminiCandidates(body: string): (boolean, string?)
	local decoded = JSONValidator.decode(body)
	if type(decoded) ~= "table" then
		return false, "Response was not valid JSON."
	end
	if type(decoded.error) == "table" then
		return false, "Provider returned an error object."
	end
	local candidates = decoded.candidates
	if type(candidates) ~= "table" or #candidates == 0 then
		if type(decoded.promptFeedback) == "table" then
			return false, "Prompt was blocked (promptFeedback), so no candidates were produced."
		end
		return false, "No `candidates` array — this is not a Gemini generateContent result."
	end
	local first = candidates[1]
	if type(first) ~= "table" or type(first.content) ~= "table" then
		return false, "`candidates[0].content` was absent."
	end
	return true, nil
end

local VALIDATORS: { [string]: (body: string) -> (boolean, string?) } = {
	openai_chat = hasChoices,
	openrouter = hasChoices,
	gemini_openai = hasChoices,
	openai_text_completions = hasLegacyCompletionText,
	openai_responses = hasResponsesOutput,
	anthropic_messages = hasAnthropicContent,
	gemini_native = hasGeminiCandidates,
}

--=============================================================================
-- METADATA FIRST
--=============================================================================

--- A provider whose preset already states the protocol does not need probing.
function ProtocolDetector.fromMetadata(profile: any): Candidate?
	if type(profile) ~= "table" then
		return nil
	end
	if type(profile.presetId) == "string" and profile.presetId ~= "custom" and profile.presetId ~= "rest" then
		local preset = UniversalProviderRegistry.getPreset(profile.presetId)
		if preset and preset.baseUrl ~= "" then
			return {
				protocolId = preset.protocol,
				label = UniversalProviderRegistry.getProtocol(preset.protocol).label,
				confidence = 0.99,
				source = "known_provider_metadata",
				validated = true,
				note = string.format("Preset \"%s\" documents this protocol.", preset.label),
			}
		end
	end
	if type(profile.protocol) == "string" and #profile.protocol > 0 and profile.protocol ~= "openai_compatible" then
		return {
			protocolId = profile.protocol,
			label = UniversalProviderRegistry.getProtocol(profile.protocol).label,
			confidence = 0.8,
			source = "manual_configuration",
			validated = false,
			note = "Protocol was chosen manually. Not verified against a live response.",
		}
	end
	return nil
end

--=============================================================================
-- PROBING
--=============================================================================

export type ProbeOptions = {
	--- Maximum candidate protocols to send a real request to.
	maxProbes: number?,
	onProgress: ((candidates: { Candidate }, note: string) -> ())?,
	shouldCancel: (() -> boolean)?,
}

export type DetectionReport = {
	candidates: { Candidate },
	best: Candidate?,
	probesRun: number,
	probesSkipped: number,
	cancelled: boolean,
	startedAt: number,
	elapsedMs: number,
}

--- Builds the minimal request body a protocol needs for a connectivity probe.
local function probeBody(profile: any, protocolId: string): { [string]: any }
	local model = (profile.modelId and #profile.modelId > 0) and profile.modelId or "probe"
	local prompt = "Reply with the single word: ok"

	if protocolId == "openai_text_completions" then
		return { model = model, prompt = prompt, max_tokens = 8 }
	elseif protocolId == "openai_responses" then
		return { model = model, input = prompt, max_output_tokens = 16 }
	elseif protocolId == "anthropic_messages" then
		return { model = model, max_tokens = 16, messages = { { role = "user", content = prompt } } }
	elseif protocolId == "gemini_native" then
		return { contents = { { role = "user", parts = { { text = prompt } } } } }
	end
	return { model = model, messages = { { role = "user", content = prompt } }, max_tokens = 16 }
end

local function buildHeaders(profile: any, apiKey: string?): { [string]: string }
	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }
	local auth = UniversalProviderRegistry.buildAuthHeaders({
		style = profile.authStyle,
		headerName = profile.authHeaderName,
		headerPrefix = profile.authHeaderPrefix,
		queryParam = profile.authQueryParam,
	}, apiKey)
	for key, value in auth do
		headers[key] = value
	end
	for key, value in (profile.defaultHeaders or {}) do
		headers[key] = value
	end
	for key, value in (profile.extraHeaders or {}) do
		headers[key] = value
	end
	return headers
end

--- Runs the bounded protocol probe.
function ProtocolDetector.detect(profile: any, options: ProbeOptions?): DetectionReport
	local opts = options or {}
	local maxProbes = math.clamp(opts.maxProbes or 3, 1, 8)
	local apiKey = CredentialStore.get(profile.id)
	local headers = buildHeaders(profile, apiKey)
	local started = os.clock()

	local report: DetectionReport = {
		candidates = {},
		best = nil,
		probesRun = 0,
		probesSkipped = 0,
		cancelled = false,
		startedAt = started,
		elapsedMs = 0,
	}

	-- 1 & 2. Known metadata or documented schema — no request needed.
	local fromMeta = ProtocolDetector.fromMetadata(profile)
	if fromMeta then
		report.candidates[#report.candidates + 1] = fromMeta
		report.best = fromMeta
	end

	-- 3. Model listing, when the base exposes one.
	local modelsUrl, modelsError = UniversalProviderRegistry.modelListUrl(profile)
	if modelsUrl then
		local response = UniversalHTTPClient.request(modelsUrl, {
			method = "GET",
			headers = headers,
			accept = "application/json",
			timeoutMs = profile.timeoutMs,
			label = "protocol-detect/models",
			shouldCancel = opts.shouldCancel,
		})
		if response.ok then
			local decoded = JSONValidator.decode(response.body)
			local count = if type(decoded) == "table" and type(decoded.data) == "table"
				then #decoded.data
				elseif type(decoded) == "table" and type(decoded.models) == "table" then #decoded.models else 0
			if count > 0 then
				report.candidates[#report.candidates + 1] = {
					protocolId = profile.protocol,
					label = "Model list reachable",
					confidence = 0.6,
					source = "model_list_endpoint",
					validated = true,
					note = string.format("`/models` returned %d model id(s), so the base URL is correct.", count),
				}
			end
		elseif opts.onProgress then
			opts.onProgress(report.candidates, string.format("Model list unavailable: HTTP %s", tostring(response.statusCode)))
		end
	elseif opts.onProgress and modelsError then
		opts.onProgress(report.candidates, modelsError)
	end

	-- 4. Bounded capability probes against candidate protocols.
	local budget = if report.best and report.best.source == "known_provider_metadata" then 1 else maxProbes

	for _, protocolId in PROBE_ORDER do
		if report.probesRun >= budget then
			report.probesSkipped += 1
			continue
		end
		if opts.shouldCancel and opts.shouldCancel() then
			report.cancelled = true
			break
		end
		if protocolId == "custom_rest" then
			-- Never probe a custom mapping; it is the user's to verify.
			continue
		end

		local url, urlError = BaseURLResolver.resolve(profile.baseUrl, {
			endpointPath = APIEndpointRouter.chatPath(protocolId),
			mode = (profile.urlMode or "base") :: any,
			model = profile.modelId,
		})
		if not url then
			continue
		end
		local protocol = UniversalProviderRegistry.getProtocol(protocolId)
		local protocolHeaders = table.clone(headers)
		for key, value in protocol.defaultHeaders do
			protocolHeaders[key] = value
		end
		-- Each protocol declares its own credential header, so a probe for
		-- Anthropic or Gemini native never reuses the previous protocol's style.
		local probeAuth, probeQuery = UniversalProviderRegistry.buildAuthHeaders({
			style = profile.authStyle == "none" and "none" or protocol.authStyle,
			headerName = profile.authHeaderName or protocol.authHeaderName,
			queryParam = profile.authQueryParam or protocol.authQueryParam,
		}, apiKey)
		for key, value in probeAuth do
			protocolHeaders[key] = value
		end
		local requestUrl = url
		if probeQuery then
			requestUrl ..= (if string.find(url, "?", 1, true) then "&" else "?") .. probeQuery
		end

		report.probesRun += 1
		if opts.onProgress then
			opts.onProgress(
				report.candidates,
				string.format("Probing %s (%d/%d)…", protocol.label, report.probesRun, budget)
			)
		end

		local response = UniversalHTTPClient.request(requestUrl, {
			method = "POST",
			headers = protocolHeaders,
			json = probeBody(profile, protocolId),
			accept = "application/json",
			timeoutMs = math.min(profile.timeoutMs or 120000, 30000),
			label = "protocol-detect/" .. protocolId,
			shouldCancel = opts.shouldCancel,
		})
		_ = urlError

		if not response.ok then
			-- 401/403 proves the ENDPOINT exists but the key is wrong. That is
			-- real information, unlike a bare 404.
			if response.statusCode == 401 or response.statusCode == 403 then
				report.candidates[#report.candidates + 1] = {
					protocolId = protocolId,
					label = protocol.label,
					confidence = 0.5,
					source = "http_status",
					validated = false,
					note = string.format(
						"The endpoint answered with HTTP %d, which means this path exists but the key was rejected. Protocol still unproven.",
						response.statusCode
					),
				}
			end
			continue
		end

		local validator = VALIDATORS[protocolId]
		local valid: boolean
		local reason: string?
		if validator then
			valid, reason = validator(response.body)
		else
			valid, reason = false, "No validator for this protocol."
		end
		if valid then
			local candidate: Candidate = {
				protocolId = protocolId,
				label = protocol.label,
				confidence = 0.95,
				source = "live_probe",
				validated = true,
				note = string.format("The response matched the %s response structure.", protocol.label),
			}
			report.candidates[#report.candidates + 1] = candidate
			if report.best == nil or candidate.confidence > report.best.confidence then
				report.best = candidate
			end
			-- A validated match is enough; stop probing to save quota.
			break
		end

		report.candidates[#report.candidates + 1] = {
			protocolId = protocolId,
			label = protocol.label,
			confidence = 0.2,
			source = "live_probe",
			validated = false,
			note = string.format("HTTP 200 but the shape did not match: %s", tostring(reason)),
		}
	end

	report.elapsedMs = (os.clock() - started) * 1000

	Logger.info("AI Provider", "Protocol detection finished.", {
		detail = string.format(
			"%d probe(s) run, %d skipped · best: %s",
			report.probesRun,
			report.probesSkipped,
			if report.best then report.best.protocolId else "none confirmed"
		),
	})

	return report
end

return ProtocolDetector
