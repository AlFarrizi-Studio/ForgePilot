--!strict
--[[
	ForgePilot / AI / ProviderRegistry  (compatibility shim)

	The provider registry now lives in UniversalProviderRegistry, which supports
	nine protocols and five authentication styles. This module forwards the V3
	entry points so older adapters keep working against a single implementation.

	New code should require UniversalProviderRegistry directly.
]]

local UniversalProviderRegistry = require(script.Parent.UniversalProviderRegistry)

return {
	getProtocol = UniversalProviderRegistry.getProtocol,
	protocolList = UniversalProviderRegistry.protocolList,
	getPreset = UniversalProviderRegistry.getPreset,
	presetList = UniversalProviderRegistry.presetList,
	presetsForType = UniversalProviderRegistry.presetsForType,
	newProfile = UniversalProviderRegistry.newProfile,
	applyPreset = UniversalProviderRegistry.applyPreset,
	buildAuthHeaders = UniversalProviderRegistry.buildAuthHeaders,
	resolveUrl = UniversalProviderRegistry.resolveUrl,
	modelListUrl = UniversalProviderRegistry.modelListUrl,
	isTrustedHost = UniversalProviderRegistry.isTrustedHost,
	normaliseBaseUrl = UniversalProviderRegistry.normaliseBaseUrl,
	Protocols = UniversalProviderRegistry.Protocols,
	Presets = UniversalProviderRegistry.Presets,
}