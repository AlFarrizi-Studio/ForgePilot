--!strict
--[[
	ForgePilot / AI / ContextManager
	Context window accounting, trimming, and summarisation.

	TOKEN HONESTY
	-------------
	When a provider returns usage, those numbers are used verbatim and labelled
	"provider". When it does not, ForgePilot computes an ESTIMATE with a clearly
	labelled heuristic and marks it "estimated". Character counts are never
	presented as exact token counts.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)


local ContextManager = {}

--=============================================================================
-- ESTIMATION
--=============================================================================

--- Conservative token estimate.
--- Calibration: English prose averages ~4 chars/token; code and JSON are denser,
--- so they are charged a higher chars-per-token ratio. Numbers are rounded up so
--- the estimate errs on the safe side.
local function estimateTokens(text: string): number
	if type(text) ~= "string" or #text == 0 then
		return 0
	end
	local codeChars = 0
	local total = #text

	-- Count characters that belong to code-ish content.
	for line in text:gmatch("([^\n]*)\n?") do
		if
			string.find(line, "{", 1, true)
			or string.find(line, "}", 1, true)
			or string.find(line, "function", 1, true)
			or string.find(line, "local ", 1, true)
			or string.find(line, "=", 1, true)
			or string.find(line, ";", 1, true)
		then
			codeChars += #line
		end
	end

	local proseChars = total - codeChars
	local tokens = proseChars / 4.0 + codeChars / 3.0
	return math.ceil(tokens)
end

ContextManager.estimateTokens = estimateTokens

--- Estimates the token cost of base64 payloads without decoding them.
local function estimateBinaryTokens(base64Length: number): number
	return math.ceil(base64Length / 4 / 3 * 4 / 3 * 1.1)
end

--=============================================================================
-- USAGE RECORD
--=============================================================================

export type Usage = {
	input: number,
	output: number,
	reasoning: number,
	cached: number,
	estimated: boolean,
	source: string,
	requestMs: number,
	estimatedCost: number?,
	currency: string,
}

export type Snapshot = {
	contextWindow: number,
	contextWindowSource: string,
	used: number,
	usedIsEstimate: boolean,
	remaining: number,
	percent: number,
	reservedForTools: number,
	availableForMessages: number,
	maxOutputTokens: number,
	lastRequest: Usage?,
	totalInput: number,
	totalOutput: number,
	totalReasoning: number,
	estimatedCost: number,
	pricingKnown: boolean,
	messageCount: number,
}

local snapshot: Snapshot = {
	contextWindow = 128000,
	contextWindowSource = "Default estimate",
	used = 0,
	usedIsEstimate = true,
	remaining = 128000,
	percent = 0,
	reservedForTools = 4096,
	availableForMessages = 123904,
	maxOutputTokens = 4096,
	lastRequest = nil,
	totalInput = 0,
	totalOutput = 0,
	totalReasoning = 0,
	estimatedCost = 0,
	pricingKnown = false,
	messageCount = 0,
}

function ContextManager.getSnapshot(): Snapshot
	return table.clone(snapshot)
end

--=============================================================================
-- CONFIGURATION
--=============================================================================

--- Syncs limits from the active provider and its capability report.
function ContextManager.configure(profile: any?, report: any?)
	local settings = require(script.Parent.Parent.Core.SettingsManager).get()
	local reserved = settings.reserveTokensForTools or 4096
	snapshot.reservedForTools = reserved

	if not profile then
		snapshot.contextWindow = 0
		snapshot.contextWindowSource = "No AI provider configured."
		snapshot.maxOutputTokens = 0
		snapshot.availableForMessages = 0
		snapshot.pricingKnown = false
		ContextManager.recompute()
		ContextManager.publish()
		return
	end

	if report then
		snapshot.contextWindow = report.contextWindow
		snapshot.contextWindowSource = report.contextWindowSource
		snapshot.maxOutputTokens = report.maxOutputTokens
		local pricing = if type(report.pricing) == "table" then report.pricing else {}
		snapshot.pricingKnown = pricing.input ~= nil and pricing.output ~= nil
	else
		snapshot.contextWindow = profile.contextWindow or 128000
		snapshot.contextWindowSource = "Manual value from provider settings."
		snapshot.maxOutputTokens = profile.maxOutputTokens or 4096
		snapshot.pricingKnown = false
	end

	snapshot.availableForMessages = math.max(0, snapshot.contextWindow - reserved - snapshot.maxOutputTokens)
	ContextManager.recompute()
	ContextManager.publish()
end

--=============================================================================
-- RECOMPUTE
--=============================================================================

function ContextManager.recompute()
	snapshot.remaining = math.max(0, snapshot.contextWindow - snapshot.used)
	snapshot.percent = if snapshot.contextWindow > 0
		then math.clamp(snapshot.used / snapshot.contextWindow * 100, 0, 100)
		else 0
end

function ContextManager.publish()
	EventBus.emit(EventBus.Events.TokenUsageChanged, { snapshot = ContextManager.getSnapshot() })
	EventBus.emit(EventBus.Events.ContextChanged, { snapshot = ContextManager.getSnapshot() })
end

--=============================================================================
-- MESSAGE ACCOUNTING
--=============================================================================

--- Recomputes context usage from a message list (used on load / after trimming).
function ContextManager.recomputeFromMessages(messages: { any })
	local total = 0
	for _, message in messages do
		total += estimateTokens(message.content or "")
		if message.reasoning then
			total += estimateTokens(message.reasoning)
		end
		for _, attachment in (message.attachments or {}) do
			if attachment.tokens then
				total += attachment.tokens
			end
		end
	end
	snapshot.used = total
	snapshot.usedIsEstimate = true
	snapshot.messageCount = #messages
	ContextManager.recompute()
	ContextManager.publish()
end

--=============================================================================
-- REQUEST RECORDING
--=============================================================================

--- Records the outcome of a real provider request.
function ContextManager.recordRequest(providerUsage: any?, requestMs: number, pricing: any?)
	local settings = require(script.Parent.Parent.Core.SettingsManager).get()

	local input: number
	local output: number
	local reasoning: number
	local cached = 0
	local isEstimate = false
	local source = "provider"

	if type(providerUsage) == "table" and providerUsage.source == "provider" then
		input = providerUsage.inputTokens or 0
		output = providerUsage.outputTokens or 0
		reasoning = providerUsage.reasoningTokens or 0
		cached = providerUsage.cachedTokens or 0
		if input == 0 and output == 0 then
			source = "none"
		end
	else
		isEstimate = true
		source = "estimated"
		input = snapshot.lastEstimatedInput or 0
		output = snapshot.lastEstimatedOutput or 0
		reasoning = 0
	end

	local cost: number? = nil
	if pricing and pricing.input and pricing.output then
		cost = (input / 1_000_000) * pricing.input + (output / 1_000_000) * pricing.output
	end

	local usage: Usage = {
		input = input,
		output = output,
		reasoning = reasoning,
		cached = cached,
		estimated = isEstimate,
		source = source,
		requestMs = requestMs,
		estimatedCost = cost,
		currency = "USD",
	}

	snapshot.lastRequest = usage
	snapshot.totalInput += input
	snapshot.totalOutput += output
	snapshot.totalReasoning += reasoning
	if cost then
		snapshot.estimatedCost += cost
	end

	-- Rolling context estimate: prompt tokens for this turn plus retained history.
	local newUsed = math.max(snapshot.used, input) + output
	snapshot.used = newUsed
	snapshot.usedIsEstimate = not (source == "provider")

	ContextManager.recompute()
	ContextManager.publish()

	Logger.info("Token Usage", string.format(
		"input %s · output %s%s",
		tostring(input),
		tostring(output),
		if isEstimate then " (estimated)" else ""
	), { durationMs = requestMs })

	return usage
end

--- Called before a request so the input side can be estimated if the provider
--- returns no usage.
function ContextManager.setPendingEstimate(text: string)
	snapshot.lastEstimatedInput = estimateTokens(text)
	snapshot.lastEstimatedOutput = 0
end

function ContextManager.setPendingOutputEstimate(text: string)
	snapshot.lastEstimatedOutput = estimateTokens(text)
end

--=============================================================================
-- TRIMMING
--=============================================================================

export type TrimPlan = {
	shouldTrim: boolean,
	removeFromIndex: number?,
	keepCount: number,
	estimatedSaved: number,
	ratio: number,
	reason: string,
}

--- Decides whether history must be trimmed before the next request.
function ContextManager.planTrim(messages: { any }, settings: any): TrimPlan
	local ratio = snapshot.availableForMessages > 0
		and (snapshot.used / snapshot.availableForMessages)
		or 0

	local threshold = settings.summarizeThreshold or 0.85

	if ratio < threshold then
		return {
			shouldTrim = false,
			removeFromIndex = nil,
			keepCount = #messages,
			estimatedSaved = 0,
			ratio = ratio,
			reason = string.format("Context is at %.0f%% of the available window.", ratio * 100),
		}
	end

	-- Keep the system prompt (index 1) and the most recent turns.
	local keepRecent = 6
	local removeFrom = math.max(2, #messages - keepRecent + 1)
	local saved = 0
	for index = removeFrom, #messages do
		saved += estimateTokens(messages[index].content or "")
	end

	return {
		shouldTrim = true,
		removeFromIndex = removeFrom,
		keepCount = #messages - removeFrom + 1,
		estimatedSaved = saved,
		ratio = ratio,
		reason = string.format(
			"Context reached %.0f%% of the available window; older messages will be summarised.",
			ratio * 100
		),
	}
end

--- Returns the message list actually sent to the provider, plus the summary
--- text that should replace anything dropped.
function ContextManager.buildSendWindow(messages: { any }, summary: string?): ({ any }, string?, string?)
	local systemCount = 0
	for _, message in messages do
		if message.role == "system" then
			systemCount += 1
		else
			break
		end
	end

	local out: { any } = {}
	for index = 1, systemCount do
		out[#out + 1] = messages[index]
	end
	for index = systemCount + 1, #messages do
		out[#out + 1] = messages[index]
	end

	if summary and #StringUtil.trim(summary) > 0 then
		return out, summary, string.format("%d earlier messages were summarised.", #out - systemCount)
	end
	return out, nil, nil
end

--=============================================================================
-- MANUAL CONTROLS
--=============================================================================

function ContextManager.reset()
	snapshot.used = 0
	snapshot.usedIsEstimate = true
	snapshot.totalInput = 0
	snapshot.totalOutput = 0
	snapshot.totalReasoning = 0
	snapshot.estimatedCost = 0
	snapshot.messageCount = 0
	snapshot.lastRequest = nil
	ContextManager.recompute()
	ContextManager.publish()
	Logger.info("Token Usage", "Context counters reset.")
end

function ContextManager.setReservedTokens(tokens: number)
	snapshot.reservedForTools = math.max(0, tokens)
	snapshot.availableForMessages =
		math.max(0, snapshot.contextWindow - snapshot.reservedForTools - snapshot.maxOutputTokens)
	ContextManager.recompute()
	ContextManager.publish()
end

--=============================================================================
-- DISPLAY HELPERS
--=============================================================================

local function compact(value: number): string
	if value >= 1_000_000 then
		return string.format("%.1fM", value / 1_000_000)
	elseif value >= 1000 then
		return string.format("%.1fk", value / 1000)
	end
	return tostring(math.floor(value + 0.5))
end

ContextManager.compact = compact

function ContextManager.formatUsageLabel(usage: Usage): string
	local prefix = if usage.estimated then "~" else ""
	local parts = {
		string.format("%sin %s", prefix, compact(usage.input)),
		string.format("%sout %s", prefix, compact(usage.output)),
	}
	if usage.reasoning > 0 then
		parts[#parts + 1] = string.format("%sthink %s", prefix, compact(usage.reasoning))
	end
	if usage.cached > 0 then
		parts[#parts + 1] = string.format("cache %s", compact(usage.cached))
	end
	parts[#parts + 1] = string.format("%.0fms", usage.requestMs)
	return table.concat(parts, " · ")
end

function ContextManager.formatCost(cost: number?): string?
	if cost == nil then
		return nil
	end
	if cost < 0.01 then
		return string.format("$%.4f", cost)
	end
	return string.format("$%.2f", cost)
end

return ContextManager
