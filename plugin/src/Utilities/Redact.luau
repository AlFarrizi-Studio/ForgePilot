--!strict
--[[
	ForgePilot / Utilities / Redact
	Secret and sensitive-content scrubbing used before anything is logged,
	rendered into the chat transcript, or written to disk.
]]

local Redact = {}

local PLACEHOLDER = "«redacted»"

-- Field names whose values must never be displayed or persisted.
local SECRET_FIELDS: { [string]: true } = {
	apikey = true,
	api_key = true,
	authorization = true,
	auth = true,
	token = true,
	access_token = true,
	refreshtoken = true,
	refresh_token = true,
	id_token = true,
	secret = true,
	client_secret = true,
	password = true,
	bearer = true,
	x_api_key = true,
	["x-goog-api-key"] = true,
	["proxy-authorization"] = true,
	cookie = true,
	["set-cookie"] = true,
}

local SECRET_PATTERNS = {
	-- Bearer / Basic tokens in free text
	{"%f[%w]Bearer%s+[%w%.%-_]+", PLACEHOLDER},
	-- OpenAI style keys
	{"sk%-[%w%-_]+", PLACEHOLDER},
	{"sk-ant%-[%w%-_]+", PLACEHOLDER},
	-- Google keys
	{"AIza[%w%-_]+", PLACEHOLDER},
	-- AWS style
	{"AKIA[%w]+", PLACEHOLDER},
	-- Generic long hex secrets, handled by a callback rather than a `{n,m}`
	-- quantifier so the rule behaves identically on every Lua engine.
	{
		"%f[%w]%x+",
		function(match: string)
			return if #match >= 40 then PLACEHOLDER else match
		end,
	},
	-- JSON style key:value pairs inside strings
	{'"apikey"%s*:%s*"[^"]*"', '"apiKey":"' .. PLACEHOLDER .. '"'},
	{'"api_key"%s*:%s*"[^"]*"', '"api_key":"' .. PLACEHOLDER .. '"'},
}

--- True when a table key should have its value scrubbed.
function Redact.isSecretKey(key: string): boolean
	local lowered = string.lower(key)
	return SECRET_FIELDS[lowered] == true
end

--- Recursively scrubs secret-bearing fields out of an arbitrary table.
--- Returns a new table; the input is not mutated.
function Redact.scrub(value: any, depth: number?): any
	local level = depth or 0
	if level > 8 then
		return "«depth-limit»"
	end

	if type(value) == "string" then
		return Redact.scrubText(value)
	elseif type(value) ~= "table" then
		return value
	end

	local out = {}
	for key, entry in value do
		if type(key) == "string" and Redact.isSecretKey(key) then
			if type(entry) == "string" and #entry > 0 then
				out[key] = PLACEHOLDER
			elseif entry ~= nil then
				out[key] = "«redacted»"
			end
		else
			out[key] = Redact.scrub(entry, level + 1)
		end
	end
	return out
end

--- Scrubs known secret patterns out of arbitrary text.
function Redact.scrubText(text: string): string
	if type(text) ~= "string" or #text == 0 then
		return text
	end
	local result = text
	for _, entry in SECRET_PATTERNS do
		result = string.gsub(result, entry[1], entry[2])
	end
	return result
end

--- Returns a short, non-reversible fingerprint of a secret.
--- Used to show "key loaded (sha 1a2b3c)" without revealing the value.
function Redact.fingerprint(secret: string): string
	if type(secret) ~= "string" or #secret == 0 then
		return "none"
	end
	local sum = 0
	for index = 1, #secret do
		sum = (sum * 31 + string.byte(secret, index)) % 0xFFFFFFFF
	end
	return string.format("%08x", sum)
end

--- Masks a secret for display: keeps a short prefix/suffix only.
function Redact.mask(secret: string?): string
	if type(secret) ~= "string" or #secret == 0 then
		return ""
	end
	if #secret <= 10 then
		return string.rep("*", #secret)
	end
	local head = string.sub(secret, 1, 4)
	local tail = string.sub(secret, -3)
	return head .. string.rep("*", math.min(16, #secret - 7)) .. tail
end

return Redact