--!strict
--[[
	ForgePilot / AI / ProviderRateLimitScheduler
	Sliding-window rate limiting with per-provider cooldowns and a FIFO queue.

	Honest scope: ForgePilot can only account for requests IT sends. Other
	applications using the same provider account are invisible, so learned
	cooldowns are deliberately conservative and always reported as estimates.
]]

local RetryDelayCalculator = require(script.Parent.RetryDelayCalculator)

local ProviderRateLimitScheduler = {}

--=============================================================================
-- TYPES
--=============================================================================

export type Bucket = {
	key: string,
	providerId: string,
	model: string,
	endpoint: string,
	--- os.clock() timestamps of requests this session actually sent.
	requestTimestamps: { number },
	--- Requests allowed per window, once learned from a provider error.
	limit: number?,
	windowMs: number?,
	--- os.clock() at which an established cooldown expires.
	cooldownUntil: number?,
	cooldownReason: string?,
	cooldownEstimated: boolean,
	queue: { QueueItem },
}

export type QueueItem = {
	id: string,
	enqueuedAt: number,
	readyAt: number?,
	resolve: ((waitSeconds: number) -> ())?,
	reject: ((reason: string) -> ())?,
	operationId: string?,
}

--=============================================================================
-- STATE
--=============================================================================

local buckets: { [string]: Bucket } = {}
local enabled = true
local queueEnabled = true

local DEFAULT_WINDOW_MS = 60 * 1000
local MAX_TRACKED_REQUESTS = 64
local FALLBACK_COOLDOWN_SECONDS = 60

--=============================================================================
-- CLOCK
--=============================================================================
-- Injectable so tests can run deterministically without waiting.

local clock: () -> number = function()
	return os.clock()
end

function ProviderRateLimitScheduler.setClock(fn: () -> number)
	clock = if type(fn) == "function" then fn else function()
		return os.clock()
	end
end

function ProviderRateLimitScheduler.resetClock()
	clock = function()
		return os.clock()
	end
end

--=============================================================================
-- CONFIG
--=============================================================================

function ProviderRateLimitScheduler.setEnabled(value: boolean)
	enabled = value
end

function ProviderRateLimitScheduler.isEnabled(): boolean
	return enabled
end

function ProviderRateLimitScheduler.setQueueEnabled(value: boolean)
	queueEnabled = value
end

function ProviderRateLimitScheduler.isQueueEnabled(): boolean
	return queueEnabled
end

--=============================================================================
-- KEYS
--=============================================================================

--- Quota independence between models/endpoints is rarely documented, so the
--- default scope is deliberately shared (provider + key session) rather than
--- per-model. Narrow it only when the provider states the limits are separate.
function ProviderRateLimitScheduler.keyFor(providerId: string, model: string?, endpoint: string?): string
	return string.format("%s|%s|%s", providerId, model or "*", endpoint or "*")
end

function ProviderRateLimitScheduler.getBucket(
	providerId: string,
	model: string?,
	endpoint: string?
): Bucket
	local key = ProviderRateLimitScheduler.keyFor(providerId, model, endpoint)
	local existing = buckets[key]
	if existing then
		return existing
	end

	local bucket: Bucket = {
		key = key,
		providerId = providerId,
		model = model or "*",
		endpoint = endpoint or "*",
		requestTimestamps = {},
		limit = nil,
		windowMs = nil,
		cooldownUntil = nil,
		cooldownReason = nil,
		cooldownEstimated = false,
		queue = {},
	}
	buckets[key] = bucket
	return bucket
end

function ProviderRateLimitScheduler.clearAll()
	buckets = {}
end

function ProviderRateLimitScheduler.clearProvider(providerId: string)
	local prefix = providerId .. "|"
	for key, bucket in buckets do
		if string.sub(key, 1, #prefix) == prefix then
			-- Release anyone still waiting so cancellation cannot strand them.
			for _, item in bucket.queue do
				if item.reject then
					item.reject("Provider bucket was cleared.")
				end
			end
			buckets[key] = nil
		end
	end
end

--=============================================================================
-- RECORDING
--=============================================================================

--- Records that ForgePilot just sent a request.
function ProviderRateLimitScheduler.recordRequest(
	providerId: string,
	model: string?,
	endpoint: string?,
	now: number?
)
	if not enabled then
		return
	end
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)
	local stamp = now or clock()
	table.insert(bucket.requestTimestamps, stamp)
	while #bucket.requestTimestamps > MAX_TRACKED_REQUESTS do
		table.remove(bucket.requestTimestamps, 1)
	end
end

--- How many requests ForgePilot has sent inside the current window.
function ProviderRateLimitScheduler.countInWindow(bucket: Bucket, now: number): number
	local windowMs = bucket.windowMs or DEFAULT_WINDOW_MS
	local cutoff = now - windowMs / 1000
	local count = 0
	for _, stamp in bucket.requestTimestamps do
		if stamp > cutoff then
			count += 1
		end
	end
	return count
end

--=============================================================================
-- COOLDOWN
--=============================================================================

export type CooldownResult = {
	active: boolean,
	remainingSeconds: number,
	reason: string?,
	estimated: boolean,
}

function ProviderRateLimitScheduler.getCooldown(
	providerId: string,
	model: string?,
	endpoint: string?,
	now: number?
): CooldownResult
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)
	local stamp = now or clock()
	if bucket.cooldownUntil and bucket.cooldownUntil > stamp then
		return {
			active = true,
			remainingSeconds = bucket.cooldownUntil - stamp,
			reason = bucket.cooldownReason,
			estimated = bucket.cooldownEstimated,
		}
	end
	if bucket.cooldownUntil then
		bucket.cooldownUntil = nil
		bucket.cooldownReason = nil
	end
	return { active = false, remainingSeconds = 0, reason = nil, estimated = false }
end

--- Establishes a provider cooldown. Returns the cooldown state afterwards.
function ProviderRateLimitScheduler.setCooldown(
	providerId: string,
	model: string?,
	endpoint: string?,
	seconds: number,
	reason: string?,
	estimated: boolean,
	now: number?
): CooldownResult
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)
	local stamp = now or clock()
	local expiresAt = stamp + math.max(0, seconds)

	-- Never shorten an existing, longer cooldown.
	if bucket.cooldownUntil and bucket.cooldownUntil > expiresAt then
		return ProviderRateLimitScheduler.getCooldown(providerId, model, endpoint, stamp)
	end

	bucket.cooldownUntil = expiresAt
	bucket.cooldownReason = reason or "Provider cooldown"
	bucket.cooldownEstimated = estimated == true
	return {
		active = true,
		remainingSeconds = seconds,
		reason = bucket.cooldownReason,
		estimated = bucket.cooldownEstimated,
	}
end

function ProviderRateLimitScheduler.clearCooldown(
	providerId: string,
	model: string?,
	endpoint: string?
)
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)
	bucket.cooldownUntil = nil
	bucket.cooldownReason = nil
	bucket.cooldownEstimated = false
end

--=============================================================================
-- LEARNING
--=============================================================================

--- Learns a rate-limit window from a provider error message.
---
--- When the provider told us the window we store it exactly. When it did not,
--- we fall back to a conservative 60s cooldown and mark it an ESTIMATE, because
--- requests made outside ForgePilot are invisible to us.
function ProviderRateLimitScheduler.learnFromError(
	providerId: string,
	model: string?,
	endpoint: string?,
	info: {
		limit: number?,
		windowMs: number?,
		category: string,
		cooldownSeconds: number?,
	},
	now: number?
): { learned: boolean, cooldown: CooldownResult, estimated: boolean, windowMs: number? }
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)

	if info.limit and info.windowMs and info.windowMs > 0 then
		bucket.limit = info.limit
		bucket.windowMs = info.windowMs
		local cooldown = ProviderRateLimitScheduler.setCooldown(
			providerId,
			model,
			endpoint,
			info.windowMs / 1000,
			string.format("Provider limit: %d requests per %.0fs", info.limit, info.windowMs / 1000),
			false,
			now
		)
		return { learned = true, cooldown = cooldown, estimated = false, windowMs = info.windowMs }
	end

	local seconds = info.cooldownSeconds
	local estimated = false
	if type(seconds) ~= "number" or seconds <= 0 then
		seconds = FALLBACK_COOLDOWN_SECONDS
		estimated = true
	end

	local cooldown = ProviderRateLimitScheduler.setCooldown(
		providerId,
		model,
		endpoint,
		seconds,
		if estimated
			then "Conservative estimate: ForgePilot cannot see requests made by other apps on this account."
			else "Provider cooldown",
		estimated,
		now
	)
	return { learned = false, cooldown = cooldown, estimated = estimated, windowMs = nil }
end

--=============================================================================
-- ADMISSION
--=============================================================================

export type Admission = {
	allowed: boolean,
	waitSeconds: number,
	reason: string,
	estimated: boolean,
}

--- Asks whether a request may proceed now.
function ProviderRateLimitScheduler.check(
	providerId: string,
	model: string?,
	endpoint: string?,
	now: number?
): Admission
	if not enabled then
		return { allowed = true, waitSeconds = 0, reason = "Rate limit scheduling disabled.", estimated = false }
	end

	local stamp = now or clock()
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)

	local cooldown = ProviderRateLimitScheduler.getCooldown(providerId, model, endpoint, stamp)
	if cooldown.active then
		return {
			allowed = false,
			waitSeconds = cooldown.remainingSeconds,
			reason = cooldown.reason or "Provider cooldown active.",
			estimated = cooldown.estimated,
		}
	end

	if not bucket.limit or not bucket.windowMs then
		return { allowed = true, waitSeconds = 0, reason = "No learned rate limit for this provider yet.", estimated = false }
	end

	local windowSeconds = bucket.windowMs / 1000
	local used = ProviderRateLimitScheduler.countInWindow(bucket, stamp)
	if used < bucket.limit then
		return {
			allowed = true,
			waitSeconds = 0,
			reason = string.format("Window has capacity (%d/%d).", used, bucket.limit),
			estimated = false,
		}
	end

	-- Window is full: wait until the oldest request leaves the window.
	local oldest = bucket.requestTimestamps[1]
	local wait = if oldest then (oldest + windowSeconds) - stamp else windowSeconds
	wait = math.max(wait, 0)

	return {
		allowed = false,
		waitSeconds = wait,
		reason = string.format(
			"ForgePilot has sent %d of %d requests in this %.0fs window.",
			used,
			bucket.limit,
			windowSeconds
		),
		estimated = false,
	}
end

--=============================================================================
-- QUEUE
--=============================================================================

local queueCounter = 0

--- Queues a request until the window has capacity. Cancels on rejection.
function ProviderRateLimitScheduler.enqueue(
	providerId: string,
	model: string?,
	endpoint: string?,
	cancel: (() -> boolean)?,
	onWait: ((waitSeconds: number) -> ())?
): any
	if not enabled or not queueEnabled then
		local admission = ProviderRateLimitScheduler.check(providerId, model, endpoint)
		if admission.allowed then
			return true
		end
		if not onWait then
			return true
		end
	end

	local promise = promise.create()
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)

	queueCounter += 1
	local item: QueueItem = {
		id = string.format("rq-%d", queueCounter),
		enqueuedAt = clock(),
		resolve = function(waitSeconds)
			promise:resolve(true)
			_ = waitSeconds
		end,
		reject = function(reason)
			promise:reject(reason)
		end,
	}
	table.insert(bucket.queue, item)

	task.spawn(function()
		while true do
			if cancel and cancel() then
				ProviderRateLimitScheduler.removeFromQueue(bucket, item)
				promise:reject("Cancelled while waiting for rate limit capacity.")
				return
			end

			local admission = ProviderRateLimitScheduler.check(providerId, model, endpoint)
			if admission.allowed then
				ProviderRateLimitScheduler.removeFromQueue(bucket, item)
				promise:resolve(true)
				return
			end

			if onWait then
				onWait(admission.waitSeconds)
			end

			-- Wake often enough for the countdown to feel live without spinning.
			task.wait(math.clamp(admission.waitSeconds / 8, 0.05, 1))
		end
	end)

	return promise:await()
end

function ProviderRateLimitScheduler.removeFromQueue(bucket: Bucket, item: QueueItem)
	for index, queued in bucket.queue do
		if queued == item then
			table.remove(bucket.queue, index)
			return
		end
	end
end

function ProviderRateLimitScheduler.queueLength(
	providerId: string,
	model: string?,
	endpoint: string?
): number
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)
	return #bucket.queue
end

--- Rejects every queued item. Called when the user cancels or switches provider.
function ProviderRateLimitScheduler.cancelQueue(
	providerId: string,
	model: string?,
	endpoint: string?,
	reason: string?
)
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)
	local queued = bucket.queue
	bucket.queue = {}
	for _, item in queued do
		if item.reject then
			item.reject(reason or "Cancelled.")
		end
	end
end

--=============================================================================
-- REPORT
--=============================================================================

function ProviderRateLimitScheduler.describe(
	providerId: string,
	model: string?,
	endpoint: string?,
	now: number?
): string
	local bucket = ProviderRateLimitScheduler.getBucket(providerId, model, endpoint)
	local stamp = now or clock()
	local used = ProviderRateLimitScheduler.countInWindow(bucket, stamp)
	if bucket.limit and bucket.windowMs then
		return string.format(
			"Tracked %d/%d requests in the current %.0fs window%s.",
			used,
			bucket.limit,
			bucket.windowMs / 1000,
			if bucket.cooldownUntil and bucket.cooldownUntil > stamp then " (cooldown active)" else ""
		)
	end
	local cooldown = ProviderRateLimitScheduler.getCooldown(providerId, model, endpoint, stamp)
	if cooldown.active then
		return string.format(
			"Cooldown active for %.0fs%s (%d requests tracked).",
			cooldown.remainingSeconds,
			if cooldown.estimated then ", estimated" else "",
			used
		)
	end
	return string.format(
		"No rate limit learned yet. %d request(s) tracked this session. ForgePilot can only see requests it sent itself, so usage from other apps on the same account is invisible and learned cooldowns stay conservative.",
		used
	)
end

--- Combines cooldown + window information for the delay calculator.
function ProviderRateLimitScheduler.advisory(
	providerId: string,
	model: string?,
	endpoint: string?,
	now: number?
): { cooldownSeconds: number?, windowWaitSeconds: number?, reason: string?, estimated: boolean }
	local admission = ProviderRateLimitScheduler.check(providerId, model, endpoint, now)
	local cooldown = ProviderRateLimitScheduler.getCooldown(providerId, model, endpoint, now)
	return {
		cooldownSeconds = if cooldown.active then cooldown.remainingSeconds else nil,
		windowWaitSeconds = if admission.allowed then nil else admission.waitSeconds,
		reason = admission.reason,
		estimated = cooldown.estimated or admission.estimated,
	}
end

-- Re-exported so the retry controller and the calculator share one source.
ProviderRateLimitScheduler.DEFAULT_WINDOW_MS = DEFAULT_WINDOW_MS
ProviderRateLimitScheduler.FALLBACK_COOLDOWN_SECONDS = FALLBACK_COOLDOWN_SECONDS
ProviderRateLimitScheduler.RetryDelayCalculator = RetryDelayCalculator

return ProviderRateLimitScheduler