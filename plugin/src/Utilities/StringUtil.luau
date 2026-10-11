--!strict
--[[
	Utilities/StringUtil

	Roblox ships `string.split` but NOT `string.trim`, and the `string` table is
	locked in the plugin sandbox, so it cannot be polyfilled:

	    Unable to assign property trim.

	ForgePilot trims user input, HTTP headers and streamed SSE payloads in 60+
	places, so the helper lives here instead and is required explicitly.
]]
local StringUtil = {}

--- Removes leading and trailing whitespace.
---
--- Non-string input is coerced with tostring so callers can pass any value
--- without a nil check at every call site.
function StringUtil.trim(value: any): string
	local text = tostring(value)
	local withoutLead = string.gsub(text, "^%s+", "")
	return (string.gsub(withoutLead, "%s+$", ""))
end

return StringUtil