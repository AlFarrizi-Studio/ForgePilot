--!nocheck
--[[
	ForgePilot / Tests / SpecV33 — provider recovery, tokens and diagnostics.

	Development only; not part of the Rojo tree and never shipped.
]]

local RetryDelayCalculator = require(script.Parent.Parent.AI.RetryDelayCalculator)
local SmartAutoRetryManager = require(script.Parent.Parent.AI.SmartAutoRetryManager)
local ProviderRateLimitScheduler = require(script.Parent.Parent.AI.ProviderRateLimitScheduler)
local RetryStateManager = require(script.Parent.Parent.AI.RetryStateManager)
local ContextManager = require(script.Parent.Parent.AI.ContextManager)
local TokenMeter = require(script.Parent.Parent.UI.TokenMeter)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local UniversalErrorDetector = require(script.Parent.Parent.Utilities.UniversalErrorDetector)
local UniversalHTTPClient = require(script.Parent.Parent.Utilities.UniversalHTTPClient)
local Redact = require(script.Parent.Parent.Utilities.Redact)

local SpecV33 = {}

local function ok(name, condition, message)
	return { name = name, ok = condition == true, message = message or "assertion failed" }
end

function SpecV33.run()
	local results = {}
	local function check(name, condition, message)
		results[#results + 1] = ok(name, condition, message)
	end

	--=============================================================================
	-- 1. RATE LIMIT SCHEDULER — one bucket key everywhere
	--=============================================================================

	local key = ProviderRateLimitScheduler.keyFor("provider", "model", "api.example.com")
	check("keyFor is stable", key == "provider|model|api.example.com", key)
	local wildcard = ProviderRateLimitScheduler.keyFor("provider", nil, nil)
	check("keyFor tolerates nil parts", wildcard == "provider|*|*", wildcard)

	ProviderRateLimitScheduler.clearAll()
	ProviderRateLimitScheduler.recordRequest("provider", "model", "api.example.com")
	local bucket = ProviderRateLimitScheduler.getBucket("provider", "model", "api.example.com")
	check(
		"recordRequest and getBucket agree on the key",
		bucket ~= nil and ProviderRateLimitScheduler.countInWindow(bucket, os.clock()) >= 1,
		"a request recorded under one key must be visible under the same key"
	)
	ProviderRateLimitScheduler.clearAll()

	--=============================================================================
	-- 2. RETRY DELAY CALCULATOR
	--=============================================================================

	local config = {
		enabled = true,
		strategy = "exponential_backoff",
		maxRetries = 5,
		initialDelaySeconds = 1,
		linearStepSeconds = 5,
		maxDelaySeconds = 60,
		multiplier = 2,
		jitterPercent = 0,
		respectRetryAfter = true,
		dynamicCooldown = true,
		maxAutoWaitSeconds = 86400,
	}

	local base = {
		attempt = 1,
		config = config,
		category = "RATE_LIMITED",
		errorStatus = 429,
		headers = { ["retry-after"] = "5" },
		now = os.clock(),
		random = function() return 0.5 end,
	}
	local decision = RetryDelayCalculator.calculate(base)
	check("RetryDelayCalculator.calculate returns a decision", type(decision) == "table", "no decision")
	check(
		"Retry-After header is honoured",
		decision ~= nil and decision.delaySeconds == 5,
		"expected 5s from retry-after, got " .. tostring(decision and decision.delaySeconds)
	)
	check(
		"decision names its source",
		decision ~= nil and type(decision.source) == "string",
		"expected a source string"
	)

	local capped = RetryDelayCalculator.calculate({
		attempt = 1,
		config = config,
		category = "RATE_LIMITED",
		errorStatus = 429,
		headers = { ["retry-after"] = "99999" },
		now = os.clock(),
		random = function() return 0.5 end,
	})
	check(
		"an absurd Retry-After is capped",
		capped ~= nil and capped.delaySeconds <= 86400,
		"expected a capped delay, got " .. tostring(capped and capped.delaySeconds)
	)

	--=============================================================================
	-- 3. RETRY STATE MACHINE
	--=============================================================================

	RetryStateManager.init()
	check("RetryStateManager starts idle", RetryStateManager.getActive() == nil, tostring(RetryStateManager.getActive()))
	check("RetryStateManager reports it is not retrying", RetryStateManager.isRetrying() == false)
	check("RetryStateManager has no short text when idle", RetryStateManager.shortText() == nil)
	local okClear, clearErr = pcall(function() RetryStateManager.clear() end)
	check("RetryStateManager.clear does not throw", okClear, tostring(clearErr))
	check("RetryStateManager.describe is safe when idle", pcall(function() return RetryStateManager.describe() end))
	local okShutdown, shutdownErr = pcall(function() RetryStateManager.shutdown() end)
	check("RetryStateManager.shutdown does not throw", okShutdown, tostring(shutdownErr))

	--=============================================================================
	-- 4. CONTEXT / TOKEN BUDGET
	--=============================================================================

	ContextManager.reset()
	local okEstimate, estimateErr = pcall(function()
		ContextManager.setPendingEstimate("Hello there, this is a short message.")
	end)
	check("ContextManager accepts a pending estimate", okEstimate, tostring(estimateErr))
	local snapshot = ContextManager.getSnapshot()
	check("ContextManager publishes a snapshot", type(snapshot) == "table")
	check(
		"ContextManager snapshot exposes the fields the token meter reads",
		snapshot ~= nil and snapshot.contextWindow ~= nil and snapshot.reservedForTools ~= nil,
		"missing context window / reserved token fields"
	)
	local usage = {
		input = 1234, output = 56, reasoning = 0, cached = 0,
		estimated = false, source = "spec", requestMs = 120,
		estimatedCost = nil, currency = "USD",
	}
	check(
		"ContextManager formatUsageLabel formats a usage record",
		type(ContextManager.formatUsageLabel(usage)) == "string"
			and string.find(ContextManager.formatUsageLabel(usage), "1", 1, true) ~= nil,
		"formatUsageLabel produced nothing readable"
	)
	ContextManager.reset()
	check("ContextManager.reset clears the snapshot", type(ContextManager.getSnapshot()) == "table")

	--=============================================================================
	-- 5. TOKEN METER UI
	--=============================================================================

	local okMeter, meterErr = pcall(function() return TokenMeter.build() end)
	check("TokenMeter.build does not throw", okMeter, tostring(meterErr))

	--=============================================================================
	-- 6. ERROR DETECTION — multilingual provider errors
	--=============================================================================

	local classification = UniversalErrorDetector.classify({
		statusCode = 429,
		body = "rate limit exceeded",
		transportError = nil,
	})
	check("429 is classified", classification ~= nil, "no classification")
	check(
		"429 maps to RATE_LIMITED",
		classification ~= nil and classification.category == "RATE_LIMITED",
		tostring(classification and classification.category)
	)
	check(
		"a rate limit is retryable",
		classification ~= nil and UniversalErrorDetector.isRetryable(classification.category) == true,
		"RATE_LIMITED must be retryable"
	)

	-- The detection tables cover English, Simplified and Traditional Chinese,
	-- Japanese, Korean, Indonesian and Spanish.
	for _, sample in ipairs({
		{ name = "Spanish", text = "excede el límite de solicitudes" },
		{ name = "Simplified Chinese", text = "请求过于频繁" },
		{ name = "Traditional Chinese", text = "請求過於頻繁" },
		{ name = "Japanese", text = "レート制限が発生しました" },
		{ name = "Korean", text = "요청 한도에 도달했습니다" },
	}) do
		local detected = UniversalErrorDetector.classify({ statusCode = 429, body = sample.text })
		check(
			sample.name .. " rate-limit text is detected",
			detected ~= nil and detected.category == "RATE_LIMITED",
			"expected RATE_LIMITED, got " .. tostring(detected and detected.category)
		)
	end
	check(
		"a JSON error envelope is recognised even with a 200",
		UniversalErrorDetector.bodyIsError('{"error":{"message":"nope"}}') == true,
		"JSON error envelope not detected"
	)
	check(
		"a success envelope is not an error",
		UniversalErrorDetector.bodyIsError('{"choices":[]}') == false,
		"a normal completion body was misread as an error"
	)

	check(
		"an ordinary reply is not an error",
		UniversalErrorDetector.bodyIsError("Here is the model you asked about.") == false,
		"normal assistant text was misread as an error"
	)

	--=============================================================================
	-- 7. TRANSPORT
	--=============================================================================

	local failure = UniversalHTTPClient.request("not-a-url", { method = "POST" })
	check("a malformed URL produces a failure response", failure ~= nil and failure.ok == false, "expected ok=false")
	check("a failure response carries a reason", type(failure.transportError) == "string" and #failure.transportError > 0)

	local streamed, streamError = UniversalHTTPClient.stream({
		url = "https://api.example.com/v1/chat/completions",
		headers = { ["Authorization"] = "Bearer sk-test" },
		body = "{}",
		timeoutMs = 1000,
		label = "Spec",
	}, {})
	check(
		"stream() reports why it cannot stream instead of failing silently",
		streamed ~= nil or (type(streamError) == "string" and #streamError > 0),
		"stream returned neither a handle nor a reason: " .. tostring(streamError)
	)
	if streamed then
		check("a stream handle can be cancelled", pcall(function() streamed.cancel() end))
		check("a cancelled stream reports itself done", streamed.isDone())
	end

	--=============================================================================
	-- 8. SECRETS
	--=============================================================================

	local leaked = Redact.scrubText('{"authorization":"Bearer sk-secret-1234567890abcdef"}')
	check(
		"JSON credentials are redacted",
		string.find(leaked, "sk-secret-1234567890abcdef", 1, true) == nil,
		leaked
	)

	local passed, failed = 0, 0
	for _, result in ipairs(results) do
		if result.ok then passed += 1 else failed += 1 end
	end
	return { results = results, passed = passed, failed = failed }
end

return SpecV33