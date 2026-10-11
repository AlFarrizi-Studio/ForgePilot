--!strict
--[[
	ForgePilot / AI / UniversalHTTPClient  (compatibility shim)

	The transport now lives in Utilities/UniversalHTTPClient.luau, which the
	provider layer uses directly. This module preserves the original
	`ForgePilot/AI/HTTPClient` surface so existing callers keep working.
]]

local UniversalHTTPClient = require(script.Parent.Parent.Utilities.UniversalHTTPClient)

return {
	postJson = UniversalHTTPClient.postJson,
	get = UniversalHTTPClient.get,
	supportsStreaming = UniversalHTTPClient.supportsStreaming,
	stream = UniversalHTTPClient.stream,
	request = UniversalHTTPClient.request,
	streamSse = UniversalHTTPClient.streamSse,
}