--!strict
--[[
	ForgePilot / Roblox / ToolValidator
	The allowlist.

	No AI text reaches the DataModel except through a tool declared here, with
	arguments validated against an explicit schema, a mode gate (read-only vs
	write), and a permission check. Anything else is rejected.
]]

local JSONValidator = require(script.Parent.Parent.Utilities.JSONValidator)

local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local ExternalTools = require(script.Parent.ExternalTools)
local ToolValidator = {}

export type Mode = "plan" | "build"

export type Tool = {
	name: string,
	mode: Mode,
	category: string,
	description: string,
	destructive: boolean,
	confirmation: boolean,
	external: boolean?,
	parameters: JSONValidator.Schema,
	--- Human-readable summary shown before approval.
	summarise: ((arguments: { [string]: any }) -> string)?,
}

--=============================================================================
-- SHARED RULES
--=============================================================================

local function v3(): JSONValidator.Rule
	return { typeName = "any", validate = function(value)
		if type(value) == "table" then
			return JSONValidator.isNumber(value.X or value.x)
				and JSONValidator.isNumber(value.Y or value.y)
				and JSONValidator.isNumber(value.Z or value.z), "must contain numeric x, y and z components."
		end
		if type(value) == "string" and string.match(value, "^%s*[%-%d%.]+%s*,%s*[%-%d%.]+%s*,%s*[%-%d%.]+%s*$") then
			return true
		end
		return false, "must be a Vector3 such as {x=0, y=10, z=0}."
	end }
end

local function colour(): JSONValidator.Rule
	return { typeName = "any", validate = function(value)
		if type(value) == "table" and (value.R or value.r) then
			return true
		end
		if type(value) == "string" and string.match(value, "^#?%x%x%x%x%x%x$") then
			return true
		end
		return false, "must be a Color3 {r,g,b} (0-1) or a hex string like #9879E8."
	end }
end

local function countKeys(t: any): number
	if type(t) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

local function pathRule(required: boolean?): JSONValidator.Rule
	return {
		typeName = "string",
		required = required ~= false,
		min = 1,
		max = 200,
		description = "Instance path such as Workspace.MyModel, or a full path like game.Workspace.X.",
	}
end

--=============================================================================
-- READ-ONLY TOOLS (Planning mode)
--=============================================================================

local READ_TOOLS: { Tool } = {
	{
		name = "inspect_place",
		mode = "plan",
		category = "Inspect",
		description = "Returns the place name, id, genre and a top-level Workspace outline.",
		destructive = false,
		confirmation = false,
		parameters = {
			includeClassCounts = { typeName = "boolean", default = true },
		},
		summarise = function()
			return "Read place metadata"
		end,
	},
	{
		name = "inspect_tree",
		mode = "plan",
		category = "Inspect",
		description = "Returns a bounded outline of an instance and its descendants.",
		destructive = false,
		confirmation = false,
		parameters = {
			path = pathRule(),
			maxDepth = { typeName = "number", min = 1, max = 5, default = 3 },
		},
		summarise = function(args)
			return string.format("Read the instance tree at `%s`", tostring(args.path))
		end,
	},
	{
		name = "inspect_selection",
		mode = "plan",
		category = "Inspect",
		description = "Returns the objects currently selected in Studio, with safe properties.",
		destructive = false,
		confirmation = false,
		parameters = {},
		summarise = function()
			return "Read the current Studio selection"
		end,
	},
	{
		name = "inspect_properties",
		mode = "plan",
		category = "Inspect",
		description = "Reads an allowlisted set of properties from one instance.",
		destructive = false,
		confirmation = false,
		parameters = {
			path = pathRule(),
		},
		summarise = function(args)
			return string.format("Read properties of `%s`", tostring(args.path))
		end,
	},
	{
		name = "inspect_script",
		mode = "plan",
		category = "Inspect",
		description = "Reads the source of a LocalScript, Script or ModuleScript.",
		destructive = false,
		confirmation = false,
		parameters = {
			path = pathRule(),
		},
		summarise = function(args)
			return string.format("Read the source of `%s`", tostring(args.path))
		end,
	},
	{
		name = "inspect_lighting",
		mode = "plan",
		category = "Inspect",
		description = "Reads Lighting settings and the list of post effects.",
		destructive = false,
		confirmation = false,
		parameters = {},
		summarise = function()
			return "Read Lighting settings"
		end,
	},
	{
		name = "inspect_ui",
		mode = "plan",
		category = "Inspect",
		description = "Lists ScreenGuis and GUI elements known to the place.",
		destructive = false,
		confirmation = false,
		parameters = {},
		summarise = function()
			return "List game UI"
		end,
	},
	{
		name = "inspect_place_stats",
		mode = "plan",
		category = "Inspect",
		description = "Returns instance counts and total descendant count for the place.",
		destructive = false,
		confirmation = false,
		parameters = {},
		summarise = function()
			return "Read place statistics"
		end,
	},
}

--=============================================================================
-- WRITE TOOLS (Build mode only)
--=============================================================================

local WRITE_TOOLS: { Tool } = {
	-- Creation ------------------------------------------------------------
	{
		name = "create_part",
		mode = "build",
		category = "Create",
		description = "Creates a Part. Optionally positions, sizes, colours and anchors it.",
		destructive = false,
		confirmation = false,
		parameters = {
			name = { typeName = "string", required = true, min = 1, max = 120 },
			parent = { typeName = "string", default = "Workspace" },
			size = { typeName = "any", default = { x = 10, y = 1, z = 10 } },
			position = { typeName = "any", default = { x = 0, y = 5, z = 0 } },
			color = colour(),
			material = { typeName = "string", default = "Plastic", oneOf = {
				"Plastic", "Wood", "WoodPlanks", "Slate", "Concrete", "Brick", "Pavement", "Rock", "Sand", "Grass",
				"LeafyGrass", "Sandstone", "CorrodedMetal", "DiamondPlate", "Foil", "Glass", "Ice", "Marble", "Metal",
				"Ground", "Asphalt", "Fabric", "Cobblestone", "Air", "Water", "Cardboard", "Carpet", "CeramicTiles",
				"ClayRoofTiles", "RoofShingles", "Leather", "Plaster", "Rubber",
			} },
			anchored = { typeName = "boolean", default = true },
			canCollide = { typeName = "boolean", default = true },
			shape = { typeName = "string", oneOf = { "Block", "Cylinder", "Ball", "Wedge" } },
		},
		summarise = function(args)
			return string.format("Create Part \"%s\"", tostring(args.name))
		end,
	},
	{
		name = "create_model",
		mode = "build",
		category = "Create",
		description = "Creates a Model, optionally parenting it and naming it.",
		destructive = false,
		confirmation = false,
		parameters = {
			name = { typeName = "string", required = true, min = 1, max = 120 },
			parent = { typeName = "string", default = "Workspace" },
		},
		summarise = function(args)
			return string.format("Create Model \"%s\"", tostring(args.name))
		end,
	},
	{
		name = "create_folder",
		mode = "build",
		category = "Create",
		description = "Creates a Folder for organisation.",
		destructive = false,
		confirmation = false,
		parameters = {
			name = { typeName = "string", required = true, min = 1, max = 120 },
			parent = { typeName = "string", default = "Workspace" },
		},
		summarise = function(args)
			return string.format("Create Folder \"%s\"", tostring(args.name))
		end,
	},
	{
		name = "create_building",
		mode = "build",
		category = "Create",
		description = "Creates a building: a wall-less Model with a floor, optional walls and a roof, sized in studs.",
		destructive = false,
		confirmation = false,
		parameters = {
			name = { typeName = "string", required = true, min = 1, max = 120 },
			parent = { typeName = "string", default = "Workspace" },
			position = { typeName = "any", default = { x = 0, y = 0, z = 0 } },
			size = { typeName = "any", default = { x = 20, y = 12, z = 20 } },
			wallThickness = { typeName = "number", min = 0.5, max = 5, default = 1 },
			floor = { typeName = "boolean", default = true },
			ceilings = { typeName = "boolean", default = false },
			color = colour(),
			material = { typeName = "string", default = "Concrete" },
		},
		summarise = function(args)
			return string.format("Create building \"%s\"", tostring(args.name))
		end,
	},
	{
		name = "create_road",
		mode = "build",
		category = "Create",
		description = "Creates a road: a flat Part with optional kerbs and centre line marks.",
		destructive = false,
		confirmation = false,
		parameters = {
			name = { typeName = "string", required = true, min = 1, max = 120 },
			parent = { typeName = "string", default = "Workspace" },
			start = { typeName = "any", required = true },
			["end"] = { typeName = "any", required = true },
			width = { typeName = "number", min = 2, max = 40, default = 12 },
			color = colour(),
			kerbs = { typeName = "boolean", default = true },
			centerLine = { typeName = "boolean", default = true },
		},
		summarise = function(args)
			return string.format("Create road \"%s\"", tostring(args.name))
		end,
	},
	{
		name = "generate_map",
		mode = "build",
		category = "Create",
		description = "Generates a complete map Model: a ground plate, several buildings and a road grid.",
		destructive = false,
		confirmation = true,
		parameters = {
			name = { typeName = "string", default = "GeneratedMap" },
			parent = { typeName = "string", default = "Workspace" },
			origin = { typeName = "any", default = { x = 0, y = 0, z = 0 } },
			radius = { typeName = "number", min = 30, max = 1000, default = 120 },
			buildings = { typeName = "number", min = 1, max = 30, default = 8 },
			roads = { typeName = "number", min = 0, max = 12, default = 4 },
			color = colour(),
		},
		summarise = function(args)
			return string.format(
				"Generate map \"%s\" with %s building(s) and %s road(s) inside a %s stud radius",
				tostring(args.name),
				tostring(args.buildings or 8),
				tostring(args.roads or 4),
				tostring(args.radius or 120)
			)
		end,
	},
	{
		name = "create_ui",
		mode = "build",
		category = "Create",
		description = "Creates a ScreenGui with optional frames, text labels and buttons.",
		destructive = false,
		confirmation = false,
		parameters = {
			name = { typeName = "string", required = true, min = 1, max = 120 },
			parent = { typeName = "string", default = "PlayerGui" },
			enabled = { typeName = "boolean", default = false },
			resetOnSpawn = { typeName = "boolean", default = false },
			elements = {
				typeName = "array",
				items = { type = "object", additionalProperties = true },
				default = {},
				validate = function(value)
					local allowed = { TextLabel = true, TextButton = true, Frame = true, ImageLabel = true, ScrollingFrame = true }
					for index, element in value do
						if type(element) ~= "table" or type(element.className) ~= "string" then
							return false, string.format("element %d must be an object with a `className`.", index)
						end
						if not allowed[element.className] then
							return false, string.format(
								"element %d uses %s. Allowed: TextLabel, TextButton, Frame, ImageLabel, ScrollingFrame.",
								index,
								element.className
							)
						end
					end
					return true
				end,
			},
		},
		summarise = function(args)
			return string.format("Create ScreenGui \"%s\" with %d element(s)", tostring(args.name), #((args.elements :: any) or {}))
		end,
	},
	{
		name = "create_script",
		mode = "build",
		category = "Scripts",
		description = "Creates a LocalScript, Script or ModuleScript with the given source and opens it in the script editor.",
		destructive = false,
		confirmation = true,
		parameters = {
			name = { typeName = "string", required = true, min = 1, max = 120 },
			parent = { typeName = "string", required = true },
			scriptType = { typeName = "string", default = "LocalScript", oneOf = { "LocalScript", "Script", "ModuleScript" } },
			source = { typeName = "string", default = "", max = 60000 },
			enabled = { typeName = "boolean", default = true },
			openInEditor = { typeName = "boolean", default = true },
		},
		summarise = function(args)
			return string.format(
				"Create %s \"%s\" (%d characters of source)",
				tostring(args.scriptType),
				tostring(args.name),
				#tostring(args.source or "")
			)
		end,
	},
	{
		name = "edit_script",
		mode = "build",
		category = "Scripts",
		description = "Writes new source into an existing script. Replaces the whole source.",
		destructive = true,
		confirmation = true,
		parameters = {
			path = pathRule(),
			source = { typeName = "string", required = true, max = 60000 },
			openInEditor = { typeName = "boolean", default = true },
		},
		summarise = function(args)
			return string.format("Replace the source of `%s` (%d characters)", tostring(args.path), #tostring(args.source or ""))
		end,
	},
	{
		name = "append_script",
		mode = "build",
		category = "Scripts",
		description = "Appends text to the end of an existing script without removing anything.",
		destructive = false,
		confirmation = true,
		parameters = {
			path = pathRule(),
			text = { typeName = "string", required = true, max = 60000 },
			openInEditor = { typeName = "boolean", default = true },
		},
		summarise = function(args)
			return string.format("Append %d characters to `%s`", #tostring(args.text or ""), tostring(args.path))
		end,
	},

	-- Modification -------------------------------------------------------
	{
		name = "set_properties",
		mode = "build",
		category = "Modify",
		description = "Sets an allowlisted set of properties on one instance.",
		destructive = false,
		confirmation = false,
		parameters = {
			path = pathRule(),
			properties = {
				typeName = "table",
				required = true,
				validate = function(value)
					if type(value) ~= "table" then
						return false, "must be an object of property name to value."
					end
					local count = 0
					for key in pairs(value) do
						if type(key) ~= "string" then
							return false, "property names must be strings."
						end
						count += 1
						if count > 30 then
							return false, "at most 30 properties may be set in one call."
						end
					end
					return true
				end,
			},
		},
		summarise = function(args)
			local props = args.properties :: any
			local keys = {}
			for key in pairs(props or {}) do
				keys[#keys + 1] = key
			end
			table.sort(keys)
			return string.format("Set on `%s`: %s", tostring(args.path), table.concat(keys, ", "))
		end,
	},
	{
		name = "move_instance",
		mode = "build",
		category = "Modify",
		description = "Moves an instance to a world position or reparents it.",
		destructive = false,
		confirmation = false,
		parameters = {
			path = pathRule(),
			position = v3(),
			newParent = { typeName = "string" },
		},
		summarise = function(args)
			if args.position then
				return string.format("Move `%s`", tostring(args.path))
			end
			return string.format("Reparent `%s`", tostring(args.path))
		end,
	},
	{
		name = "resize_instance",
		mode = "build",
		category = "Modify",
		description = "Resizes a BasePart or Frame.",
		destructive = false,
		confirmation = false,
		parameters = {
			path = pathRule(),
			size = { typeName = "any", required = true },
		},
		summarise = function(args)
			return string.format("Resize `%s`", tostring(args.path))
		end,
	},
	{
		name = "group_instances",
		mode = "build",
		category = "Modify",
		description = "Parents several instances into a new or existing Model.",
		destructive = false,
		confirmation = false,
		parameters = {
			paths = { typeName = "array", required = true, validate = function(value)
				if #value == 0 then
					return false, "must contain at least one instance path."
				end
				if #value > 100 then
					return false, "at most 100 instances per call."
				end
				return true
			end },
			into = { typeName = "string", description = "Existing model path. Created when omitted." },
			name = { typeName = "string", default = "Group" },
		},
		summarise = function(args)
			return string.format("Group %d instances", #(args.paths :: any))
		end,
	},
	{
		name = "configure_lighting",
		mode = "build",
		category = "Modify",
		description = "Applies Lighting settings such as ClockTime, Brightness and Atmosphere density.",
		destructive = false,
		confirmation = false,
		parameters = {
			settings = { typeName = "table", required = true, validate = function(value)
				local allowed = {
					ClockTime = true, Brightness = true, Ambient = true, OutdoorAmbient = true,
					EnvironmentDiffuseScale = true, EnvironmentSpecularScale = true, ExposureCompensation = true,
					GlobalShadows = true, ShadowSoftness = true, Technology = true,
				}
				for key in pairs(value) do
					if allowed[key] == nil then
						return false, string.format("`%s` is not a supported Lighting property.", tostring(key))
					end
				end
				return true
			end },
		},
		summarise = function(args)
			return string.format("Update Lighting (%d setting(s))", countKeys(args.settings))
		end,
	},
	{
		name = "fill_terrain",
		mode = "build",
		category = "Create",
		description = "Fills a terrain region with a material and colour.",
		destructive = false,
		confirmation = true,
		parameters = {
			size = { typeName = "any", required = true },
			material = { typeName = "string", default = "Grass", oneOf = {
				"Grass", "Sand", "Rock", "Snow", "Water", "Mud", "Ground", "Asphalt", "Salt", "Basalt", "Ice", "Lava", "Moss", "MudRock", "Shale", "VolcanicRock",
			} },
			color = colour(),
			region = { typeName = "string", default = "512,512,128" },
			destroyOtherParts = { typeName = "boolean", default = false },
		},
		summarise = function(args)
			return string.format("Fill terrain %s with %s", tostring(args.region), tostring(args.material))
		end,
	},

	-- Destructive --------------------------------------------------------
	{
		name = "delete_instance",
		mode = "build",
		category = "Destructive",
		description = "Deletes an instance permanently (undoable via Studio's Edit menu).",
		destructive = true,
		confirmation = true,
		parameters = {
			path = pathRule(),
		},
		summarise = function(args)
			return string.format("Delete `%s`", tostring(args.path))
		end,
	},
	{
		name = "set_disabled",
		mode = "build",
		category = "Destructive",
		description = "Toggles the Enabled property of a Script or LocalScript.",
		destructive = false,
		confirmation = false,
		parameters = {
			path = pathRule(),
			enabled = { typeName = "boolean", required = true },
		},
		summarise = function(args)
			return string.format("%s `%s`", if args.enabled then "Enable" else "Disable", tostring(args.path))
		end,
	},
}

local function countKeys(t: any): number
	if type(t) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

local function countKeys(t: any): number
	if type(t) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

--=============================================================================
-- REGISTRY
--=============================================================================

local registry: { [string]: Tool } = {}
local ordered: { Tool } = {}

for _, tool in READ_TOOLS do
	registry[tool.name] = tool
	ordered[#ordered + 1] = tool
end
for _, tool in WRITE_TOOLS do
	registry[tool.name] = tool
	ordered[#ordered + 1] = tool
end

for _, tool in ExternalTools.list do
    registry[tool.name] = tool
    ordered[#ordered + 1] = tool
end

ToolValidator.registry = registry
ToolValidator.ordered = ordered

function ToolValidator.get(name: string): Tool?
	return registry[name]
end

function ToolValidator.all(): { Tool }
	return table.clone(ordered)
end

function ToolValidator.forMode(mode: Mode): { Tool }
	local list = {}
	for _, tool in ordered do
		if tool.external and not BridgeClient.canTool(tool.name) then continue end
		if tool.mode == "plan" then
			list[#list + 1] = tool
		elseif mode == "build" then
			list[#list + 1] = tool
		end
	end
	return list
end

--=============================================================================
-- VALIDATION
--=============================================================================

export type ValidationResult = {
	ok: boolean,
	tool: Tool?,
	arguments: { [string]: any }?,
	errors: { string },
	blockedReason: string?,
}

--- Validates a model-issued tool call.
--- `mode` is the plugin's current operating mode; Planning can never call a
--- write tool, regardless of what the model asked for.
function ToolValidator.validate(toolName: string, rawArguments: any, mode: Mode): ValidationResult
	local tool = registry[toolName]
	if not tool then
		local suggestions = {}
		for name in pairs(registry) do
			if string.find(string.lower(name), string.lower(toolName), 1, true) then
				suggestions[#suggestions + 1] = name
			end
		end
		local hint = if #suggestions > 0
			then string.format(" Did you mean: %s?", table.concat(suggestions, ", "))
			else ""
		return {
			ok = false,
			tool = nil,
			arguments = nil,
			errors = { string.format("Unknown tool `%s`.%s", tostring(toolName), hint) },
			blockedReason = "unknown_tool",
		}
	end

	if tool.mode == "build" and mode ~= "build" then
		return {
			ok = false,
			tool = tool,
			arguments = nil,
			errors = {
				string.format(
					"`%s` is a write action. Planning Mode is read-only — it cannot create, modify or delete anything.",
					toolName
				),
			},
			blockedReason = "read_only_mode",
		}
	end

	if tool.external and not BridgeClient.canTool(toolName) then
        return { ok = false, tool = tool, arguments = nil, errors = { "This bridge tool is unavailable. Connect Settings > Agent Access; commands require full access." }, blockedReason = "bridge_unavailable" }
    end

	if type(rawArguments) ~= "table" then
		return {
			ok = false,
			tool = tool,
			arguments = nil,
			errors = { "`arguments` must be a JSON object." },
			blockedReason = "bad_arguments",
		}
	end

	local result = JSONValidator.validate(rawArguments, tool.parameters)
	return {
		ok = result.ok,
		tool = tool,
		arguments = if result.ok then result.value else nil,
		errors = result.errors,
		blockedReason = if result.ok then nil else "bad_arguments",
	}
end

--- Human-readable one-liner for approval dialogs and logs.
function ToolValidator.summarise(toolName: string, arguments: { [string]: any }?): string
	local tool = registry[toolName]
	if not tool then
		return string.format("Run unknown tool `%s`", toolName)
	end
	if tool.summarise and arguments then
		local ok, summary = pcall(tool.summarise, arguments)
		if ok and type(summary) == "string" then
			return summary
		end
	end
	return string.format("Run `%s`", toolName)
end

--=============================================================================
-- TOOL DEFINITIONS FOR THE MODEL
--=============================================================================

--- Converts the registry into provider tool definitions with JSON Schema.
function ToolValidator.toDefinitions(mode: Mode): { { name: string, description: string, parameters: { [string]: any } } }
	local list = {}
	for _, tool in ToolValidator.forMode(mode) do
		local properties: { [string]: any } = {}
		local requiredList: { string } = {}
		local typeMap = {
			string = "string",
			number = "number",
			boolean = "boolean",
			table = "object",
			array = "array",
		}

		for fieldName, rule in tool.parameters do
			local schema: { [string]: any } = {}
			schema.type = typeMap[rule.typeName or "any"]
			if rule.description then
				schema.description = rule.description
			end
			if rule.oneOf then
				schema.enum = rule.oneOf
			end
			if rule.min then
				schema[if rule.typeName == "string" then "minLength" else "minimum"] = rule.min
			end
			if rule.max then
				schema[if rule.typeName == "string" then "maxLength" else "maximum"] = rule.max
			end
			if rule.default ~= nil then
				schema.default = rule.default
			end
			if rule.typeName == "array" then
				schema.items = rule.items or { type = "string", description = "String value." }
			end
			properties[fieldName] = schema
			if rule.required then
				requiredList[#requiredList + 1] = fieldName
			end
		end

		table.insert(list, {
			name = tool.name,
			description = tool.description,
			parameters = {
				type = "object",
				properties = properties,
				required = requiredList,
			},
		})
	end
	return list
end

return ToolValidator
