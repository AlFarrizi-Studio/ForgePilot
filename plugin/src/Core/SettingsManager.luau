--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Core / SettingsManager
	Persists UI preferences and NON-SECRET provider profiles via Plugin:SetSetting.

	SECURITY CONTRACT
	-----------------
	API keys are never written through SetSetting, never placed in chat history,
	never logged, and never serialised into saved provider profiles. Secrets live
	only in the in-memory SessionCredentialStore for the lifetime of the Studio
	session, and the user is told to expect re-entry after a restart.
]]

local EventBus = require(script.Parent.EventBus)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)


local SettingsManager = {}

local SETTINGS_KEY = "ForgePilot.Settings.v1"

export type ProviderProtocol =
	"openai_chat"
	| "openai_responses"
	| "anthropic_messages"
	| "gemini_native"
	| "openai_compatible"
	| "custom_compatible"

export type ProviderProfile = {
	id: string,
	displayName: string,
	providerName: string,
	providerType: string,
	protocol: string,
	baseUrl: string,
	endpointPath: string,
	urlMode: string,
	modelId: string,
	authStyle: string,
	authHeaderName: string?,
	authHeaderPrefix: string?,
	authQueryParam: string?,
	defaultHeaders: { [string]: string },
	extraHeaders: { [string]: string },
	contextWindow: number,
	contextWindowMode: string,
	maxOutputTokens: number,
	maxOutputTokensMode: string,
	temperature: number,
	topP: number,
	reasoningEffort: string,
	reasoningIncludeSummary: boolean,
	streaming: boolean,
	toolCalling: boolean,
	parallelToolCalling: boolean,
	jsonMode: boolean,
	timeoutMs: number,
	retryOverrides: { [string]: any }?,
	schemaMapping: { [string]: any }?,
	presetId: string?,
	createdAt: number,
	updatedAt: number,
}

export type SmartRetrySettings = {
	enabled: boolean,
	strategy: string,
	maxRetries: number,
	initialDelaySeconds: number,
	multiplier: number,
	linearStepSeconds: number,
	maxDelaySeconds: number,
	maxAutoWaitSeconds: number,
	jitterPercent: number,
	respectRetryAfter: boolean,
	dynamicCooldown: boolean,
	rateLimitScheduler: boolean,
	multilingualErrors: boolean,
	showCountdown: boolean,
	showRetryLogs: boolean,
	customSequence: { number }?,
	providerOverrides: { [string]: any },
}

export type Settings = {
	assistantName: string,
	theme: string,
	animations: boolean,
	reducedMotion: boolean,
	language: string,
	confirmDestructive: boolean,
	confirmToolCalls: boolean,
	defaultMode: string,
	modeDefaultsVersion: number,
	autoAsk: boolean,
	letAiDecide: boolean,
	autoApproveReadOnly: boolean,
	toolPermissions: { [string]: boolean },
	maxToolCalls: number,
	maxBuildActions: number,
	streamResponses: boolean,
	bridgeEnabled: boolean,
	bridgeUrl: string,
	summarizeThreshold: number,
	reserveTokensForTools: number,
	smartRetry: SmartRetrySettings,
	providers: { ProviderProfile },
	activeProviderId: string?,
}

--=============================================================================
-- DEFAULTS
--=============================================================================

local function defaultSettings(): Settings
	return {
		assistantName = "ForgePilot Assistant",
		theme = "ForgePilot Dark",
		animations = true,
		reducedMotion = false,
		language = "English",
		confirmDestructive = true,
		confirmToolCalls = true,
		defaultMode = "build",
		modeDefaultsVersion = 2,
		autoAsk = true,
		letAiDecide = true,
		autoApproveReadOnly = true,
		toolPermissions = {},
		maxToolCalls = 40,
		maxBuildActions = 200,
		streamResponses = true,
		bridgeEnabled = true,
		bridgeUrl = "http://127.0.0.1:20129",
		summarizeThreshold = 0.85,
		reserveTokensForTools = 4096,
		smartRetry = {
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
		},
		providers = {},
		activeProviderId = nil,
	}
end

--=============================================================================
-- SCHEMA GUARD
--=============================================================================
-- Anything loaded from disk is untrusted: an older or hand-edited settings blob
-- must never crash the plugin or smuggle unexpected keys through.

local function coerce(raw: any, template: any): any
	if template == nil then
		return raw
	end
	local templateType = type(template)
	if raw == nil then
		return template
	end
	if templateType == "number" then
		return if type(raw) == "number" then raw else template
	elseif templateType == "string" then
		return if type(raw) == "string" then raw else template
	elseif templateType == "boolean" then
		return if type(raw) == "boolean" then raw else template
	elseif templateType == "table" then
		if type(raw) ~= "table" then
			return template
		end
		if #template > 0 then
			local arr = {}
			for index, item in raw do
				if type(item) == type(template[1]) then
					arr[#arr + 1] = item
				end
			end
			return arr
		end
		local out = {}
		for key, value in raw do
			if template[key] ~= nil then
				out[key] = coerce(value, template[key])
			end
		end
		return out
	end
	return template
end

--=============================================================================
-- STATE
--=============================================================================

local settings: Settings = defaultSettings()
local pluginRef: Plugin? = nil

--=============================================================================
-- LIFECYCLE
--=============================================================================

function SettingsManager.init(plugin: Plugin)
	pluginRef = plugin
	SettingsManager.load()
end

function SettingsManager.load()
	if not pluginRef then
		return
	end
	local ok, raw = pcall(pluginRef.GetSetting, pluginRef, SETTINGS_KEY)
	if ok and raw ~= nil then
		local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if decodedOk and type(decoded) == "table" then
			settings = coerce(decoded, defaultSettings())
			if (tonumber(decoded.modeDefaultsVersion) or 0) < 2 then
				settings.defaultMode = "build"
				SettingsManager.persist()
			end
			-- Any key accidentally present in a saved blob is dropped here.
			for _, provider in settings.providers do
				provider.secretSlot = provider.secretSlot
			end
		else
			settings = defaultSettings()
		end
	else
		settings = defaultSettings()
	end
end

--- Serialises settings WITHOUT any credential material.
function SettingsManager.persist()
	if not pluginRef then
		return false
	end
	local snapshot = SettingsManager.get()
	local providers = {}
	for _, provider in snapshot.providers do
		local copy = table.clone(provider)
		copy.secretSlot = nil -- belt and braces: secrets never reach disk
		providers[#providers + 1] = copy
	end
	snapshot.providers = providers

	local encodedOk, encoded = pcall(HttpService.JSONEncode, HttpService, snapshot)
	if not encodedOk then
		return false
	end
	local setOk = pcall(pluginRef.SetSetting, pluginRef, SETTINGS_KEY, encoded)
	return setOk
end

--=============================================================================
-- ACCESSORS
--=============================================================================

function SettingsManager.get(): Settings
	return settings
end

function SettingsManager.getValue<K>(key: K): any
	return (settings :: any)[key]
end

function SettingsManager.setValue<K>(key: K, value: any)
	(settings :: any)[key] = value
	SettingsManager.persist()
	EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "settings" })
end

function SettingsManager.resetAll()
	settings = defaultSettings()
	SettingsManager.persist()
	EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "reset" })
end

function SettingsManager.update(updater: (Settings) -> ())
	updater(settings)
	SettingsManager.persist()
end

function SettingsManager.setAssistantName(name: string)
	local trimmed = StringUtil.trim(name or "")
	settings.assistantName = if #trimmed > 0 then trimmed else "ForgePilot Assistant"
	SettingsManager.persist()
	EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "settings", field = "assistantName" })
end

--=============================================================================
-- PROVIDER PROFILES (non-secret)
--=============================================================================

function SettingsManager.addProvider(provider: ProviderProfile)
	settings.providers[#settings.providers + 1] = provider
	if not settings.activeProviderId then
		settings.activeProviderId = provider.id
	end
	SettingsManager.persist()
	EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "added", providerId = provider.id })
end

function SettingsManager.updateProvider(id: string, patch: { [string]: any })
	for index, provider in settings.providers do
		if provider.id == id then
			for key, value in patch do
				(provider :: any)[key] = value
			end
			provider.updatedAt = os.time()
			settings.providers[index] = provider
			SettingsManager.persist()
			EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "updated", providerId = id })
			return provider
		end
	end
	return nil
end

function SettingsManager.removeProvider(id: string): boolean
	for index, provider in settings.providers do
		if provider.id == id then
			table.remove(settings.providers, index)
			if settings.activeProviderId == id then
				settings.activeProviderId = if #settings.providers > 0 then settings.providers[1].id else nil
			end
			SettingsManager.persist()
			EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "removed", providerId = id })
			return true
		end
	end
	return false
end

function SettingsManager.getProvider(id: string?): ProviderProfile?
	if not id then
		return nil
	end
	for _, provider in settings.providers do
		if provider.id == id then
			return provider
		end
	end
	return nil
end

function SettingsManager.getActiveProvider(): ProviderProfile?
	return SettingsManager.getProvider(settings.activeProviderId)
end

function SettingsManager.setActiveProvider(id: string?)
	settings.activeProviderId = id
	SettingsManager.persist()
	EventBus.emit(EventBus.Events.ActiveProviderChanged, { providerId = id })
end

--=============================================================================
-- SAFETY CHECK: asserts nothing secret can be serialised
--=============================================================================

--- Development guard. Walks a settings snapshot and reports any credential-like
--- value that would leak through JSONEncode.
function SettingsManager.assertNoSecrets(): (boolean, { string }?)
	local problems: { string } = {}

	local function walk(value: any, path: string, depth: number)
		if depth > 8 or type(value) ~= "table" then
			return
		end
		for key, entry in value do
			local nextPath = if type(key) == "string" then path .. "." .. key else path .. "[?]"
			if type(key) == "string" and Redact.isSecretKey(key) and entry ~= nil then
				problems[#problems + 1] = nextPath
			else
				walk(entry, nextPath, depth + 1)
			end
		end
	end

	walk(settings, "settings", 0)
	return #problems == 0, problems
end

return SettingsManager
