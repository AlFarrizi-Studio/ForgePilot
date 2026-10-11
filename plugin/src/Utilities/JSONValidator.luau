--!strict
local StringUtil = require(script.Parent.StringUtil)

local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Utilities / JSONValidator
	Parsing helpers plus structural validation for AI-produced action payloads.

	The plugin never executes text produced by a model. It parses JSON, then runs
	the result through an explicit schema validator before anything touches the
	DataModel.
]]

local JSONValidator = {}
local objectTables: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Empty Luau tables otherwise become JSON arrays. Keep their intended shape.
function JSONValidator.object(value: any?): any
	local object = value or {}
	assert(type(object) == "table", "JSON object must be a table.")
	objectTables[object] = true
	return object
end

--- Copy JSON Schema dictionaries, preserving arrays such as required/anyOf.
function JSONValidator.toolParameters(value: any): any
	local function schema(node: any): any
		if type(node) ~= "table" then return node end
		local out = JSONValidator.object({})
		for key, child in node do
			if key == "properties" or key == "patternProperties" or key == "$defs" or key == "definitions" or key == "dependentSchemas" then
				local map = JSONValidator.object({})
				for name, definition in child do map[name] = schema(definition) end
				out[key] = map
			elseif key == "allOf" or key == "anyOf" or key == "oneOf" or key == "prefixItems" then
				local list = {}
				for index, definition in child do list[index] = schema(definition) end
				out[key] = list
			elseif key == "items" or key == "additionalProperties" or key == "contains" or key == "not" or key == "if" or key == "then" or key == "else" or key == "propertyNames" then
				out[key] = schema(child)
			else
				out[key] = child
			end
		end
		return out
	end
	return schema(value)
end

--=============================================================================
-- PARSING
--=============================================================================

--- Decodes a JSON string. Returns `nil, message` instead of raising.
function JSONValidator.decode(text: string): (any?, string?)
	if type(text) ~= "string" or string.len(text) == 0 then
		return nil, "Empty JSON payload."
	end
	local ok, result = pcall(HttpService.JSONDecode, HttpService, text)
	if not ok then
		return nil, tostring(result)
	end
	return result, nil
end

--- Encodes a value, returning `nil, message` on failure (non-finite numbers).
function JSONValidator.encode(value: any): (string?, string?)
	local active: { [any]: boolean } = {}
	local function encode(node: any, depth: number): string
		assert(depth <= 64, "JSON nesting exceeds 64 levels.")
		local kind = type(node)
		if kind ~= "table" then
			if node == nil then return "null" end
			assert(kind == "string" or kind == "number" or kind == "boolean", "Unsupported JSON value.")
			if kind == "number" then assert(node == node and math.abs(node) ~= math.huge, "Non-finite JSON number.") end
			local primitive = HttpService:JSONEncode(node)
			assert(type(primitive) == "string" and primitive ~= "", "Could not encode JSON value.")
			return primitive
		end
		assert(not active[node], "Cyclic JSON table.")
		active[node] = true
		local count, array = 0, not objectTables[node]
		for key in node do
			count += 1
			if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false end
		end
		if array then assert(count == #node, "JSON array must have contiguous indexes.") end
		local parts = {}
		if array then
			for index = 1, #node do parts[#parts + 1] = encode(node[index], depth + 1) end
		else
			local keys = {}
			for key in node do assert(type(key) == "string", "JSON object keys must be strings."); keys[#keys + 1] = key end
			table.sort(keys)
			for _, key in keys do parts[#parts + 1] = encode(key, depth + 1) .. ":" .. encode(node[key], depth + 1) end
		end
		active[node] = nil
		return (if array then "[" else "{") .. table.concat(parts, ",") .. (if array then "]" else "}")
	end
	local ok, result = pcall(encode, value, 0)
	if not ok then
		return nil, tostring(result)
	end
	return result, nil
end

function JSONValidator.encodeObject(value: any): (string?, string?)
	if type(value) ~= "table" then return nil, "JSON object must be a table." end
	return JSONValidator.encode(JSONValidator.object(value))
end

--- Extracts the first balanced JSON object from free-form model output.
--- Handles ```json fenced blocks and stray prose around the payload.
function JSONValidator.extractObject(text: string): (any?, string?)
	if type(text) ~= "string" then
		return nil, "No text to parse."
	end

	-- Prefer a fenced code block when present.
	for fence in text:gmatch("```[%a]*\n(.-)```") do
		local decoded = JSONValidator.decode(fence)
		if decoded and type(decoded) == "table" then
			return decoded, nil
		end
	end

	local decoded = JSONValidator.decode(text)
	if decoded and type(decoded) == "table" then
		return decoded, nil
	end

	-- Balanced brace scan, ignoring braces inside strings.
	-- `}` must be escaped inside a character set as `%}`.
	local start = text:find("[{%}]")
	if not start then
		return nil, "No JSON object found in model output."
	end

	local openChar = string.sub(text, start, start)
	local closeChar = if openChar == "{" then "}" else "]"
	local depth = 0
	local inString = false
	local escaped = false

	for index = start, #text do
		local char = string.sub(text, index, index)
		if inString then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				inString = false
			end
		elseif char == '"' then
			inString = true
		elseif char == openChar then
			depth += 1
		elseif char == closeChar then
			depth -= 1
			if depth == 0 then
				return JSONValidator.decode(string.sub(text, start, index))
			end
		end
	end

	return nil, "JSON object was not balanced."
end

--=============================================================================
-- TYPE CHECKS
--=============================================================================

function JSONValidator.isString(value: any): boolean
	return type(value) == "string"
end

function JSONValidator.isNonEmptyString(value: any): boolean
	return type(value) == "string" and string.len(StringUtil.trim(value)) > 0
end

function JSONValidator.isNumber(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

function JSONValidator.isBoolean(value: any): boolean
	return type(value) == "boolean"
end

function JSONValidator.isArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
end

--=============================================================================
-- SCHEMA VALIDATION
--=============================================================================

export type Rule = {
	name: string,
	typeName: string?,
	required: boolean?,
	min: number?,
	max: number?,
	pattern: string?,
	oneOf: { any }?,
	default: any?,
	description: string?,
	items: { [string]: any }?,
	validate: ((value: any) -> (boolean, string?))?,
}

export type Schema = { [string]: Rule }

export type Result = {
	ok: boolean,
	value: { [string]: any },
	errors: { string },
}

local function matchesType(value: any, typeName: string): boolean
	if typeName == "string" then
		return type(value) == "string"
	elseif typeName == "number" then
		return JSONValidator.isNumber(value)
	elseif typeName == "boolean" then
		return type(value) == "boolean"
	elseif typeName == "table" then
		return type(value) == "table"
	elseif typeName == "array" then
		return JSONValidator.isArray(value)
	elseif typeName == "any" then
		return true
	end
	return false
end

--- Validates `payload` against `schema`.
--- Unknown keys are preserved so free-form tool arguments survive round-trips,
--- but every documented rule is enforced before the caller uses the value.
function JSONValidator.validate(payload: any, schema: Schema): Result
	local errors: { string } = {}
	local out: { [string]: any } = {}

	if type(payload) ~= "table" then
		return { ok = false, value = {}, errors = { "Payload must be a JSON object." } }
	end

	for key, rule in schema do
		local label = rule.name or key
		local raw = (payload :: any)[key]
		local value = if raw == nil then rule.default else raw

		if value == nil then
			if rule.required then
				errors[#errors + 1] = string.format("`%s` is required.", label)
			end
			continue
		end

		if rule.typeName and not matchesType(value, rule.typeName) then
			errors[#errors + 1] = string.format("`%s` must be %s.", label, rule.typeName)
			continue
		end

		if rule.oneOf then
			local found = false
			for _, allowed in rule.oneOf do
				if allowed == value then
					found = true
					break
				end
			end
			if not found then
				local names = {}
				for _, allowed in rule.oneOf do
					names[#names + 1] = tostring(allowed)
				end
				errors[#errors + 1] =
					string.format("`%s` must be one of: %s.", label, table.concat(names, ", "))
				continue
			end
		end

		-- min/max mean "value range" for numbers and "character count" for strings.
		if rule.typeName == "string" then
			local length = #value
			if rule.min and length < rule.min then
				errors[#errors + 1] = string.format("`%s` must be at least %d characters.", label, rule.min)
				continue
			end
			if rule.max and length > rule.max then
				errors[#errors + 1] = string.format("`%s` must be at most %d characters.", label, rule.max)
				continue
			end
		elseif rule.min and value < rule.min then
			errors[#errors + 1] = string.format("`%s` must be >= %s.", label, tostring(rule.min))
			continue
		elseif rule.max and value > rule.max then
			errors[#errors + 1] = string.format("`%s` must be <= %s.", label, tostring(rule.max))
			continue
		end

		if rule.pattern and type(value) == "string" then
			local matched = string.match(value, rule.pattern) ~= nil
			if not matched then
				errors[#errors + 1] = string.format("`%s` has an invalid format.", label)
				continue
			end
		end

		if rule.validate then
			local valid, message = rule.validate(value)
			if not valid then
				errors[#errors + 1] = string.format("`%s` %s", label, message or "is invalid.")
				continue
			end
		end

		out[key] = value
	end

	return { ok = #errors == 0, value = out, errors = errors }
end

return JSONValidator
