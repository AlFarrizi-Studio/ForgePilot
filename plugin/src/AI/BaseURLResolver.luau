--!strict
--[[
	ForgePilot / AI / BaseURLResolver
	Parses, validates and normalises provider base URLs.

	Two URL modes are supported and never guessed between:
	  * BASE      - an API root such as https://host/v1; the endpoint path is
	                appended by APIEndpointRouter.
	  * FULL      - a complete endpoint such as https://host/v1/chat/completions;
	                used verbatim, with no suffix appended.

	Everything here is pure string handling. No network access, no globals beyond
	the standard library, so it is fully testable.
]]

local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local BaseURLResolver = {}

--=============================================================================
-- TYPES
--=============================================================================

export type Mode = "base" | "full" | "auto"

export type ParsedUrl = {
	scheme: string,
	host: string,
	port: number?,
	authority: string,
	path: string,
	query: string?,
	fragment: string?,
}

export type Resolved = {
	ok: boolean,
	--- Normalised URL without credentials (there are none by construction).
	url: string?,
	parsed: ParsedUrl?,
	error: string?,
	--- Which mode was actually applied.
	mode: Mode,
	--- Set when a query string is carried through.
	query: string?,
}

--=============================================================================
-- TRUST
--=============================================================================

--- Domains ForgePilot recognises as established AI providers. Anything else
--- raises the "unrecognised host" warning before a credential is sent.
local TRUSTED_HOSTS: { [string]: boolean } = {
	["api.openai.com"] = true,
	["openrouter.ai"] = true,
	["generativelanguage.googleapis.com"] = true,
	["api.anthropic.com"] = true,
	["api.groq.com"] = true,
	["api.together.xyz"] = true,
	["api.fireworks.ai"] = true,
	["api.deepseek.com"] = true,
	["api.mistral.ai"] = true,
	["api.cohere.ai"] = true,
	["api.cerebras.ai"] = true,
	["open.bigmodel.cn"] = true,
	["dashscope.aliyuncs.com"] = true,
	["api.perplexity.ai"] = true,
	["api.x.ai"] = true,
	["api-inference.huggingface.co"] = true,
	["api.venice.ai"] = true,
}

--=============================================================================
-- PARSING
--=============================================================================

local SCHEME_PATTERN = "^(%a[%w%+%-%.]*)://(.+)$"

--- Splits a URL into its parts. Returns nil plus a reason on malformed input.
function BaseURLResolver.parse(raw: string): (ParsedUrl?, string?)
	if type(raw) ~= "string" then
		return nil, "URL must be a string."
	end

	local trimmed = StringUtil.trim(raw)
	-- Strip surrounding whitespace and any accidental wrapping quotes.
	trimmed = string.gsub(trimmed, '^"(.*)"$', "%1")
	trimmed = string.gsub(trimmed, "^'(.*)'$", "%1")
	trimmed = StringUtil.trim(trimmed)

	if #trimmed == 0 then
		return nil, "URL is empty."
	end
	if #trimmed > 2048 then
		return nil, "URL is too long."
	end

	local scheme, rest = string.match(trimmed, SCHEME_PATTERN)
	if not scheme then
		return nil, "URL must start with a scheme, for example https://."
	end

	scheme = string.lower(scheme)
	if scheme ~= "https" and scheme ~= "http" then
		return nil, string.format("Unsupported URL scheme `%s`. Use https://.", scheme)
	end

	-- Fragment then query.
	local fragment: string? = nil
	local hashPos = string.find(rest, "#", 1, true)
	if hashPos then
		fragment = string.sub(rest, hashPos + 1)
		rest = string.sub(rest, 1, hashPos - 1)
	end

	local query: string? = nil
	local queryPos = string.find(rest, "?", 1, true)
	if queryPos then
		query = string.sub(rest, queryPos + 1)
		rest = string.sub(rest, 1, queryPos - 1)
	end

	local authority, path = string.match(rest, "^([^/]+)(.*)$")
	if not authority or #authority == 0 then
		return nil, "URL has no host."
	end

	-- Credentials embedded in the URL are refused outright.
	if string.find(authority, "@", 1, true) then
		return nil, "URL must not embed credentials. Use the API Key field instead."
	end

	local host, portText = string.match(authority, "^([^:]+):(%d+)$")
	if not host then
		host = authority
		portText = nil
	end

	host = string.lower(host)
	if not string.match(host, "^[%w][%w%-%.]*$") then
		return nil, "URL host contains unsupported characters."
	end
	if string.find(host, "..", 1, true) then
		return nil, "URL host is malformed."
	end

	local port: number? = nil
	if portText then
		port = tonumber(portText)
		if port == nil or port < 1 or port > 65535 then
			return nil, "URL port is out of range."
		end
	end

	return {
		scheme = scheme,
		host = host,
		port = port,
		authority = if portText then string.format("%s:%s", host, portText) else host,
		path = path or "",
		query = query,
		fragment = fragment,
	}, nil
end

--=============================================================================
-- HTTPS ENFORCEMENT
--=============================================================================

--- Returns the URL unchanged for https, or nil plus a reason otherwise.
--- Loopback HTTP supports the companion and 9Router. Remote addresses still
--- require HTTPS; the original scheme is preserved when building endpoints.
function BaseURLResolver.enforceHttps(parsed: ParsedUrl): (boolean, string?)
	if parsed.scheme == "https" or (parsed.scheme == "http" and (parsed.host == "127.0.0.1" or parsed.host == "localhost")) then
		return true, nil
	end
	return false,
		"Remote providers must use https://. Plain HTTP is accepted only for 127.0.0.1 or localhost."
end

--=============================================================================
-- NORMALISATION
--=============================================================================

--- Collapses a path: removes duplicate slashes and trailing slashes.
--- Collapses every run of slashes into one.
--- Uses repeated plain finds rather than a `{n,m}` quantifier so the behaviour is
--- identical on every Lua-family engine.
local function collapseSlashes(text: string): string
	local cleaned = text or ""
	while string.find(cleaned, "//", 1, true) do
		cleaned = string.gsub(cleaned, "//", "/", 1)
	end
	return cleaned
end

BaseURLResolver.collapseSlashes = collapseSlashes

function BaseURLResolver.normalisePath(path: string): string
	local cleaned = collapseSlashes(path or "")
	cleaned = string.gsub(cleaned, "/+$", "")
	return cleaned
end

--- Splits a path into non-empty segments.
function BaseURLResolver.segments(path: string): { string }
	local out: { string } = {}
	for segment in string.gmatch(path, "[^/]+") do
		out[#out + 1] = segment
	end
	return out
end

--- True when `path` already ends with `suffix` on a segment boundary.
function BaseURLResolver.pathEndsWith(path: string, suffix: string): boolean
	local a = string.sub(BaseURLResolver.normalisePath(path), 1, -(#suffix + 1))
	local b = string.sub(BaseURLResolver.normalisePath(path), -#suffix)
	if a ~= b then
		return false
	end
	-- Must be a whole segment, not a partial name like "mychatcompletions".
	local before = string.sub(BaseURLResolver.normalisePath(path), 1, -(#suffix + 1))
	return before == "" or string.sub(before, -1) == "/"
end

--- Strips `suffix` from the end of `path` when it is already present.
function BaseURLResolver.stripSuffix(path: string, suffix: string): string
	if not BaseURLResolver.pathEndsWith(path, suffix) then
		return BaseURLResolver.normalisePath(path)
	end
	local cleaned = string.sub(BaseURLResolver.normalisePath(path), 1, -(#suffix + 1))
	return BaseURLResolver.normalisePath(cleaned)
end

--- Validates and normalises a base URL. Returns the URL, or nil plus a reason.
--- Trailing slashes are removed; the path prefix (/v1, /v1beta, …) is preserved.
function BaseURLResolver.normaliseBase(raw: string): (string?, string?)
	local parsed, err = BaseURLResolver.parse(raw)
	if not parsed then
		return nil, err
	end
	local secure, secureErr = BaseURLResolver.enforceHttps(parsed)
	if not secure then
		return nil, secureErr
	end
	local path = BaseURLResolver.normalisePath(parsed.path)
	return string.format("%s://%s%s", parsed.scheme, parsed.authority, path), nil
end

--=============================================================================
-- TRUST
--=============================================================================

function BaseURLResolver.isTrustedHost(urlOrHost: string?): boolean
	if type(urlOrHost) ~= "string" then
		return false
	end
	local host = urlOrHost
	if string.find(host, "://", 1, true) then
		local parsed = BaseURLResolver.parse(host)
		if not parsed then
			return false
		end
		host = parsed.host
	end
	host = string.lower(host)
	if host == "127.0.0.1" or host == "localhost" then return true end
	if TRUSTED_HOSTS[host] then
		return true
	end
	for trusted in pairs(TRUSTED_HOSTS) do
		if string.sub(host, -(#trusted + 1)) == "." .. trusted then
			return true
		end
	end
	return false
end

--- Returns the host of a URL, or nil.
function BaseURLResolver.hostOf(url: string?): string?
	if type(url) ~= "string" then
		return nil
	end
	local parsed = BaseURLResolver.parse(url)
	return parsed and parsed.host or nil
end

--- Normalises and de-duplicates a base + endpoint pair.
---
--- When the endpoint template repeats segments already present at the end of the
--- base (e.g. base `/v1` + template `/v1/chat/completions`), the shared prefix is
--- emitted once. This prevents `/v1/v1/chat/completions` and
--- `/chat/completions/chat/completions` while leaving genuinely distinct
--- segments intact.
local function join(basePath: string, template: string): string
	local baseSegments = BaseURLResolver.segments(basePath)
	local templateSegments = BaseURLResolver.segments(template)

	-- Longest overlap between the tail of the base and the head of the template.
	local maxOverlap = math.min(#baseSegments, #templateSegments)
	local overlap = 0
	for size = maxOverlap, 1, -1 do
		local matches = true
		for index = 1, size do
			if baseSegments[#baseSegments - size + index] ~= templateSegments[index] then
				matches = false
				break
			end
		end
		if matches then
			overlap = size
			break
		end
	end

	local combined: { string } = {}
	for _, segment in baseSegments do
		combined[#combined + 1] = segment
	end
	for index = overlap + 1, #templateSegments do
		combined[#combined + 1] = templateSegments[index]
	end

	if #combined == 0 then
		return ""
	end
	return "/" .. table.concat(combined, "/")
end

BaseURLResolver.joinSegments = join

--=============================================================================
-- MODE DETECTION
--=============================================================================

--- Endpoint suffixes that identify a "full endpoint" URL.
local KNOWN_ENDPOINT_SUFFIXES = {
	"/chat/completions",
	"/completions",
	"/responses",
	"/messages",
	"/generatecontent",
	"/streamgeneratecontent",
	"/models",
	"/embeddings",
}

--- Guesses whether a URL is a BASE root or a FULL endpoint.
--- `auto` never changes the user's stored mode; it only informs the preview.
function BaseURLResolver.detectMode(path: string, endpointPath: string?): Mode
	local cleaned = string.lower(BaseURLResolver.normalisePath(path))
	if cleaned == "" or cleaned == "/" then
		return "base"
	end

	-- An exact match against the configured endpoint path is the strongest signal.
	if endpointPath and #endpointPath > 0 then
		local template = BaseURLResolver.normalisePath((endpointPath:gsub("{model}", "___MODEL___")))
		if cleaned:sub(-#template) == string.lower(template) then
			return "full"
		end
	end

	for _, suffix in KNOWN_ENDPOINT_SUFFIXES do
		if string.sub(cleaned, -#suffix) == suffix then
			return "full"
		end
	end

	-- A path that still carries a version segment looks like a base root.
	local segments = BaseURLResolver.segments(cleaned)
	local last = segments[#segments]
	if last and string.match(last, "^v%d+[%w%-%.]*$") then
		return "base"
	end

	return "base"
end

--=============================================================================
-- RESOLUTION
--=============================================================================

--- Builds the final request URL.
---
--- options:
---   endpointPath - the protocol's path template, e.g. "/chat/completions".
---                   May contain "{model}".
---   mode         - "base" | "full" | "auto"
---   streaming    - use the protocol's streaming path when one exists.
function BaseURLResolver.resolve(raw: string, options: {
	endpointPath: string?,
	mode: Mode?,
	streaming: boolean?,
	model: string?,
	overridePath: string?,
}): Resolved
	local parsed, err = BaseURLResolver.parse(raw)
	if not parsed then
		return { ok = false, url = nil, parsed = nil, error = err, mode = "base" }
	end

	local secure, secureErr = BaseURLResolver.enforceHttps(parsed)
	if not secure then
		return { ok = false, url = nil, parsed = parsed, error = secureErr, mode = "base" }
	end

	local requestedMode = options.mode or "base"
	local template = options.overridePath or options.endpointPath or ""

	-- Substitute the model id, escaping Lua pattern characters in the result.
	if options.model then
		local safeModel = (options.model:gsub("([^%w%-%.%_%~])", "%%%1"))
		template = (template:gsub("{model}", safeModel))
	end

	local basePath = BaseURLResolver.normalisePath(parsed.path)
	local mode = requestedMode

	if requestedMode == "auto" then
		mode = BaseURLResolver.detectMode(basePath, template)
	end

	local resolvedPath: string
	if mode == "full" then
		-- The URL's own path wins; the template only strips a duplicate suffix
		-- the user may have pasted on top of a base.
		local cleanTemplate = BaseURLResolver.normalisePath((template:gsub("{model}", "__MODEL__")))
		if #cleanTemplate > 0 and BaseURLResolver.pathEndsWith(basePath, cleanTemplate) then
			resolvedPath = BaseURLResolver.stripSuffix(basePath, cleanTemplate)
		else
			resolvedPath = basePath
		end
	else
		-- BASE mode: append the endpoint, de-duplicating shared segments so we
		-- never produce /v1/v1/chat/completions.
		if #template > 0 then
			local cleanTemplate = BaseURLResolver.normalisePath((template:gsub("{model}", "__MODEL__")))
			resolvedPath = join(basePath, cleanTemplate)
		else
			resolvedPath = basePath
		end
	end

	-- Collapse any accidental double slash introduced by concatenation.
	resolvedPath = collapseSlashes(resolvedPath)

	local url = string.format("%s://%s%s", parsed.scheme, parsed.authority, resolvedPath)
	if parsed.query and #parsed.query > 0 then
		url ..= "?" .. parsed.query
	end

	return {
		ok = true,
		url = url,
		parsed = parsed,
		error = nil,
		mode = mode,
		query = parsed.query,
	}
end

--- The model-list URL for a base. Returns nil plus a reason when unsupported.
function BaseURLResolver.modelListUrl(raw: string, options: { mode: Mode?, overridePath: string? }?): (string?, string?)
	local opts = options or {}
	local path = opts.overridePath or "/models"
	return BaseURLResolver.resolve(raw, {
		endpointPath = path,
		mode = opts.mode or "base",
	}).url
end

--- Strips every query parameter that could carry a credential, for display.
function BaseURLResolver.forDisplay(url: string): string
	if type(url) ~= "string" then
		return ""
	end
	local parsed = BaseURLResolver.parse(url)
	if not parsed then
		-- Never echo an unparseable string that might contain a key.
		return "(unparseable URL)"
	end
	local out = string.format("%s://%s%s", parsed.scheme, parsed.authority, parsed.path)
	if parsed.query and #parsed.query > 0 then
		out ..= "?<query hidden>"
	end
	return out
end

return BaseURLResolver