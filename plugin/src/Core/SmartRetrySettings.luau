--!strict
--[[
	ForgePilot / Core / SmartRetrySettings
	Thin, validated accessor over the persisted `smartRetry` settings block.

	The Settings tab writes through here so every value is clamped on the way in
	and a provider override can never weaken the global safety limits.
]]

local SettingsManager = require(script.Parent.SettingsManager)
local EventBus = require(script.Parent.EventBus)

local SmartRetry = {}

--=============================================================================
-- NUMERIC FIELDS
--=============================================================================

local LIMITS: { [string]: { min: number, max: number, integer: boolean? } } = {
	maxRetries = { min = 0, max = 20, integer = true },
	initialDelaySeconds = { min = 0.25, max = 120 },
	multiplier = { min = 1, max = 10 },
	linearStepSeconds = { min = 1, max = 60 },
	maxDelaySeconds = { min = 1, max = 3600 },
	maxAutoWaitSeconds = { min = 5, max = 3600 },
	jitterPercent = { min = 0, max = 100 },
}

--=============================================================================
-- ACCESSORS
--=============================================================================

local function block(): any
	local settings = SettingsManager.get()
	if type(settings.smartRetry) ~= "table" then
		settings.smartRetry = {}
	end
	return settings.smartRetry
end

--- Reads a retry setting.
function SmartRetry.get(key: string?): any
	return if key == nil then block() else block()[key]
end

--- Writes a retry setting, clamping numeric values and validating enums.
function SmartRetry.set(key: string, value: any)
	local limits = LIMITS[key]
	local coerced = value

	if limits then
		local numberValue = tonumber(value)
		if numberValue == nil then
			return false
		end
		numberValue = math.clamp(numberValue, limits.min, limits.max)
		coerced = if limits.integer then math.floor(numberValue) else numberValue
	elseif key == "enabled"
		or key == "respectRetryAfter"
		or key == "dynamicCooldown"
		or key == "rateLimitScheduler"
		or key == "multilingualErrors"
		or key == "showCountdown"
		or key == "showRetryLogs"
	then
		coerced = value == true
	elseif key == "strategy" then
		local valid = { opencode = true, adaptive = true, exponential = true, linear = true, custom = true }
		if not valid[value] then
			return false
		end
	elseif key == "customSequence" then
		if type(value) ~= "table" then
			coerced = nil
		else
			local sequence: { number } = {}
			for _, entry in value do
				local numberValue = tonumber(entry)
				if numberValue then
					sequence[#sequence + 1] = math.clamp(numberValue, 0, 3600)
				end
				if #sequence >= 20 then
					break
				end
			end
			coerced = if #sequence > 0 then sequence else nil
		end
	end

	block()[key] = coerced
	SettingsManager.persist()
	EventBus.emit(EventBus.Events.RetrySettingsChanged, { key = key })
	return true
end

--- The shipped defaults, written explicitly so a reset is exact rather than
--- dependent on the settings template being re-seeded.
local DEFAULTS: { [string]: any } = {
	enabled = true,
	strategy = "opencode",
	maxRetries = 5,
	initialDelaySeconds = 2,
	multiplier = 2,
	linearStepSeconds = 3,
	maxDelaySeconds = 120,
	maxAutoWaitSeconds = 120,
	jitterPercent = 25,
	respectRetryAfter = true,
	dynamicCooldown = true,
	rateLimitScheduler = true,
	multilingualErrors = true,
	showCountdown = true,
	showRetryLogs = true,
	customSequence = nil,
	providerOverrides = {},
}

--- Resets the whole block to the shipped defaults.
function SmartRetry.resetDefaults()
	local settings = SettingsManager.get()
	local fresh = {}
	for key, value in DEFAULTS do
		fresh[key] = if type(value) == "table" then table.clone(value) else value
	end
	settings.smartRetry = fresh
	SettingsManager.persist()
	EventBus.emit(EventBus.Events.RetrySettingsChanged, { reset = true })
	return true
end

--=============================================================================
-- PROVIDER OVERRIDES
--=============================================================================

function SmartRetry.getProviderOverride(providerId: string): { [string]: any }
	local overrides = block().providerOverrides
	if type(overrides) ~= "table" then
		return {}
	end
	local entry = overrides[providerId]
	return type(entry) == "table" and entry or {}
end

--- Sets (or clears) a per-provider override. nil clears it.
function SmartRetry.setProviderOverride(providerId: string, patch: { [string]: any }?)
	local overrides = block().providerOverrides
	if type(overrides) ~= "table" then
		overrides = {}
		block().providerOverrides = overrides
	end

	if patch == nil then
		overrides[providerId] = nil
	else
		local clamped: { [string]: any } = {}
		for key, value in patch do
			local limits = LIMITS[key]
			if limits then
				local numberValue = tonumber(value)
				if numberValue then
					clamped[key] = if limits.integer
						then math.floor(math.clamp(numberValue, limits.min, limits.max))
						else math.clamp(numberValue, limits.min, limits.max)
				end
			else
				clamped[key] = value
			end
		end
		overrides[providerId] = clamped
	end

	SettingsManager.persist()
	EventBus.emit(EventBus.Events.RetrySettingsChanged, { providerId = providerId })
	return true
end

--=============================================================================
-- DESCRIPTION
--=============================================================================

local function human(seconds: number): string
	if seconds >= 60 then
		return string.format("%.0fm", seconds / 60)
	end
	return string.format("%.0fs", seconds)
end

--- A one-line human description of the current schedule.
function SmartRetry.describe(): string
	local strategy = block().strategy or "opencode"
	local maxRetries = block().maxRetries or 5
	local initial = block().initialDelaySeconds or 2
	local multiplier = block().multiplier or 2

	if not block().enabled then
		return "Automatic retry is disabled."
	end
	if strategy == "opencode" then
		return string.format("OpenCode: 2s base, x2, up to 25%% extra jitter, 30s fallback cap; up to %d retries. Provider cooldowns are respected.", maxRetries)
	end

	if strategy == "linear" then
		local step = block().linearStepSeconds or 3
		return string.format(
			"Linear: %s, %s, %s, %s … (up to %d retries)",
			human(step),
			human(step * 2),
			human(step * 3),
			human(step * 4),
			maxRetries
		)
	end

	return string.format(
		"Exponential from %s, x%s, up to %d retries.",
		human(initial),
		tostring(multiplier),
		maxRetries
	)
end

return SmartRetry
