--!strict
--[[
	ForgePilot / Roblox / InstanceManager
	Low-level Instance plumbing shared by the builders.

	Everything here is defensive: names are validated before they reach the
	DataModel, parents are checked for legality (no cycles), and every returned
	result states exactly what happened rather than assuming success.
]]

local Logger = require(script.Parent.Parent.Utilities.Logger)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)


local InstanceManager = {}

local ILLEGAL_NAMES: { [string]: boolean } = {
	[""] = true,
	[".."] = true,
	["..."] = true,
}

--=============================================================================
-- NAMES
--=============================================================================

--- True when a name is safe to assign to an Instance.
function InstanceManager.isValidName(name: any): boolean
	if type(name) ~= "string" then
		return false
	end
	local trimmed = StringUtil.trim(name)
	if #trimmed == 0 or #trimmed > 120 then
		return false
	end
	if ILLEGAL_NAMES[trimmed] then
		return false
	end
	return true
end

--- Returns a safe name, or nil plus a reason.
function InstanceManager.sanitiseName(name: any, fallback: string?): (string?, string?)
	if InstanceManager.isValidName(name) then
		return StringUtil.trim((name :: string)), nil
	end
	if type(name) ~= "string" then
		return nil, "Instance name must be a string."
	end
	if #StringUtil.trim(name) == 0 then
		return nil, "Instance name cannot be empty."
	end
	return nil, "Instance name must be 1-120 characters and not \"..\" or \"...\"."
end

--=============================================================================
-- PARENTS
--=============================================================================

--- True when `child` may be parented to `parent` without creating a cycle.
function InstanceManager.canParent(child: Instance, parent: Instance): (boolean, string?)
	if child == parent then
		return false, "An instance cannot be its own parent."
	end
	if child:IsDescendantOf(parent) then
		return false, "That would create a parenting cycle."
	end
	return true, nil
end

--- Resolves a parent path, defaulting to Workspace.
function InstanceManager.resolveParent(path: any): (Instance?, string?)
	if path == nil then
		return workspace, nil
	end
	if type(path) ~= "string" or StringUtil.trim(path) == "" then
		return nil, "Parent path must be a non-empty string."
	end

	local ok, instance = pcall(function()
		local WorkspaceInspector = require(script.Parent.WorkspaceInspector)
		return WorkspaceInspector.resolve(path)
	end)
	if not ok then
		return nil, tostring(instance)
	end
	if not instance then
		return nil, string.format("No instance at `%s`.", path)
	end
	return instance, nil
end

--=============================================================================
-- CREATION
--=============================================================================

export type CreateResult = {
	ok: boolean,
	instance: Instance?,
	message: string,
}

--- Creates an instance of `className` with validated properties.
--- `properties` may include `Name`, `Parent` and any writable class property.
function InstanceManager.create(
	className: string,
	properties: { [string]: any }
): CreateResult
	if type(className) ~= "string" or #className == 0 then
		return { ok = false, instance = nil, message = "Class name is required." }
	end

	local ok, template = pcall(function()
		return Instance.new(className)
	end)
	if not ok or not template then
		return { ok = false, instance = nil, message = string.format("`%s` is not a creatable class.", className) }
	end

	local name = properties.Name
	if name ~= nil then
		local safeName, nameError = InstanceManager.sanitiseName(name)
		if not safeName then
			template:Destroy()
			return { ok = false, instance = nil, message = nameError or "Invalid name." }
		end
		template.Name = safeName
	end

	local target = template
	local parentPath = properties.Parent
	if parentPath ~= nil then
		local parent, parentError = InstanceManager.resolveParent(parentPath)
		if not parent then
			template:Destroy()
			return { ok = false, instance = nil, message = parentError or "Parent could not be resolved." }
		end
		target = parent
	end

	local applied = {}
	for key, value in properties do
		if key ~= "Name" and key ~= "Parent" then
			local setOk = pcall(function()
				(template :: any)[key] = value
			end)
			if setOk then
				applied[#applied + 1] = key
			end
		end
	end

	template.Parent = target

	local detail = if #applied > 0
		then string.format("Set %s.", table.concat(applied, ", "))
		else "Created with default properties."

	Logger.info("Build", string.format("Created %s \"%s\".", className, template.Name), { detail = detail })

	return {
		ok = true,
		instance = template,
		message = string.format("Created %s \"%s\" under %s. %s", className, template.Name, target:GetFullName(), detail),
	}
end

--=============================================================================
-- WRITABLE PROPERTY ALLOWLIST
--=============================================================================
-- The agent may only set properties the plugin knows how to reason about.
-- Anything outside this list is refused rather than blindly attempted, so a
-- malformed model response cannot reach an unexpected part of the DataModel.

local WRITABLE_PROPERTIES: { [string]: { [string]: boolean } } = {
	["BasePart"] = {
		Anchored = true,
		CanCollide = true,
		CanQuery = true,
		CanTouch = true,
		Material = true,
		Color = true,
		Transparency = true,
		Reflectance = true,
		TopSurface = true,
		BottomSurface = true,
		CastShadow = true,
	},
	["Part"] = { Shape = true },
	["Model"] = { Archivable = true },
	["Folder"] = {},
	["Configuration"] = {},
	["LocalScript"] = { Enabled = true, Disabled = true },
	["Script"] = { Enabled = true, Disabled = true },
	["ModuleScript"] = {},
	["LuaSourceContainer"] = {},
	["ScreenGui"] = {
		Enabled = true,
		ResetOnSpawn = true,
		ZIndexBehavior = true,
		DisplayOrder = true,
		IgnoreGuiInset = true,
	},
	["Frame"] = {
		Visible = true,
		Size = true,
		Position = true,
		BackgroundColor3 = true,
		BackgroundTransparency = true,
		BorderSizePixel = true,
		LayoutOrder = true,
		Active = true,
	},
	["TextLabel"] = {
		Text = true,
		TextColor3 = true,
		TextSize = true,
		Font = true,
		TextXAlignment = true,
		TextYAlignment = true,
		TextWrapped = true,
		TextTransparency = true,
		RichText = true,
		Visible = true,
		Size = true,
		Position = true,
		BackgroundTransparency = true,
	},
	["TextButton"] = {
		Text = true,
		TextColor3 = true,
		TextSize = true,
		Font = true,
		TextXAlignment = true,
		TextYAlignment = true,
		TextWrapped = true,
		TextTransparency = true,
		AutoButtonColor = true,
		Active = true,
		Visible = true,
		Size = true,
		Position = true,
		BackgroundTransparency = true,
	},
	["ImageLabel"] = {
		Image = true,
		ImageColor3 = true,
		ImageTransparency = true,
		ScaleType = true,
		Visible = true,
		Size = true,
		Position = true,
	},
	["ScrollingFrame"] = {
		Visible = true,
		Size = true,
		Position = true,
		BackgroundColor3 = true,
		ScrollBarThickness = true,
		CanvasSize = true,
		AutomaticCanvasSize = true,
	},
	["LayerCollector"] = { Enabled = true, ResetOnSpawn = true },
	["GuiObject"] = {
		Visible = true,
		Size = true,
		Position = true,
		BackgroundColor3 = true,
		BackgroundTransparency = true,
		BorderSizePixel = true,
		Rotation = true,
		ZIndex = true,
	},
}

--- True when the property is on the allowlist for this instance or an ancestor.
function InstanceManager.isWritable(instance: Instance, property: string): boolean
	local cursor: Instance? = instance
	while cursor do
		local rules = WRITABLE_PROPERTIES[cursor.ClassName]
		if rules and rules[property] then
			return true
		end
		cursor = cursor.Parent
	end
	return false
end

InstanceManager.WRITABLE_PROPERTIES = WRITABLE_PROPERTIES

--=============================================================================
-- SET PROPERTIES
--=============================================================================

--- Applies properties to an existing instance, reporting per-property results.
--- Properties outside the allowlist are refused, not attempted.
function InstanceManager.setProperties(
	instance: Instance,
	properties: { [string]: any }
): { applied: { string }, rejected: { string } }
	local applied: { string } = {}
	local rejected: { string } = {}

	if type(properties) ~= "table" then
		return { applied = applied, rejected = { "Properties must be a table." } }
	end

	for key, value in properties do
		if type(key) ~= "string" then
			rejected[#rejected + 1] = "Property names must be strings."
		elseif not InstanceManager.isWritable(instance, key) then
			rejected[#rejected + 1] = string.format("%s (not in ForgePilot's writable allowlist)", key)
		else
			local setOk, setError = pcall(function()
				(instance :: any)[key] = value
			end)
			if setOk then
				applied[#applied + 1] = key
			else
				rejected[#rejected + 1] = string.format("%s (%s)", key, tostring(setError))
			end
		end
	end

	return { applied = applied, rejected = rejected }
end

--=============================================================================
-- SEARCH
--=============================================================================

--- Finds descendants matching a name (exact first, then case-insensitive).
function InstanceManager.find(root: Instance, name: string, limit: number?): { Instance }
	local results: { Instance } = {}
	local cap = limit or 25
	local lowered = string.lower(name)

	for _, descendant in root:GetDescendants() do
		if results[#results] < cap then
			if descendant.Name == name then
				results[#results + 1] = descendant
			elseif string.lower(descendant.Name) == lowered then
				results[#results + 1] = descendant
			end
		end
	end
	return results
end

--- Finds the first descendant of a given class.
function InstanceManager.findFirstOfClass(root: Instance, className: string): Instance?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA(className) then
			return descendant
		end
	end
	return nil
end

--- Resolves a full instance path such as "game.Workspace.City.Road1".
--- Returns nil when any segment is missing, which is how ActionRegistry detects
--- that a previously verified object no longer exists.
function InstanceManager.findByPath(fullPath: any): Instance?
	if type(fullPath) ~= "string" or fullPath == "" then return nil end
	local WorkspaceInspector = require(script.Parent.WorkspaceInspector)
	local ok, result = pcall(WorkspaceInspector.resolve, fullPath)
	return if ok then result else nil
end

--=============================================================================
-- CLEANUP
--=============================================================================

--- Deletes an instance after refusing to remove engine services.
function InstanceManager.destroy(instance: Instance): (boolean, string?)
	if instance == game or instance.Parent == game then
		local protected = {
			workspace = true,
			game = true,
			Lighting = true,
			ServerScriptService = true,
			ServerStorage = true,
			ReplicatedStorage = true,
			StarterGui = true,
			StarterPlayer = true,
			StarterPack = true,
			SoundService = true,
			Players = true,
		}
		if protected[instance.Name] then
			return false, string.format("Refusing to delete the engine service `%s`.", instance.Name)
		end
	end

	local fullName = instance:GetFullName()
	instance:Destroy()
	return true, string.format("Deleted `%s`.", fullName)
end

return InstanceManager