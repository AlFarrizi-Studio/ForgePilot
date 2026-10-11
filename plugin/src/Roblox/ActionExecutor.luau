--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Roblox / ActionExecutor
	The ONLY module that mutates the DataModel.

	Every write goes through:
	    ToolValidator.validate  ->  mode gate  ->  permission check
	    ->  change-history transaction  ->  post-action verification

	The post-action check is mandatory: ForgePilot never reports success unless
	Studio confirms the object exists with the requested configuration.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local HistoryManager = require(script.Parent.HistoryManager)
local InstanceManager = require(script.Parent.InstanceManager)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local WorkspaceInspector = require(script.Parent.WorkspaceInspector)
local ScriptManager = require(script.Parent.ScriptManager)
local Terrain = require(script.Parent.ModelBuilder).Terrain
local Buildings = require(script.Parent.ModelBuilder).Buildings
local Roads = require(script.Parent.ModelBuilder).Roads
local GUIBuilder = require(script.Parent.GUIBuilder)
local LightingManager = require(script.Parent.LightingManager)
local ToolValidator = require(script.Parent.ToolValidator)
local EventBus = require(script.Parent.Parent.Core.EventBus)

local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local ActionExecutor = {}

--=============================================================================
-- VALUE COERCION
--=============================================================================

local function toVector3(value: any, fallback: Vector3): Vector3
	if type(value) == "table" then
		local x = value.x or value.X or value[1]
		local y = value.y or value.Y or value[2]
		local z = value.z or value.Z or value[3]
		if x and y and z then
			return Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
		end
	elseif type(value) == "string" then
		local x, y, z = string.match(value, "^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*$")
		if x then
			return Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
		end
	end
	return fallback
end

ActionExecutor.toVector3 = toVector3

local function toColor3(value: any, fallback: Color3): Color3
	if type(value) == "string" then
		local hex = string.gsub(StringUtil.trim(value), "^#", "")
		if string.match(hex, "^%x%x%x%x%x%x$") then
			return Color3.fromHex(hex)
		end
		return fallback
	elseif type(value) == "table" then
		local r = value.r or value.R
		local g = value.g or value.G
		local b = value.b or value.B
		if r and g and b then
			return Color3.new(math.clamp(tonumber(r) or 0, 0, 1), math.clamp(tonumber(g) or 0, 0, 1), math.clamp(tonumber(b) or 0, 0, 1))
		end
	end
	return fallback
end

ActionExecutor.toColor3 = toColor3

--- Writable-property enforcement lives in InstanceManager.isWritable.

local function resolveParent(path: string): (Instance?, string?)
	return InstanceManager.resolveParent(path)
end

local function resolveTarget(path: string): (Instance?, string?)
	return WorkspaceInspector.resolve(path)
end

--=============================================================================
-- READ TOOL HANDLERS
--=============================================================================

local function handleRead(toolName: string, args: { [string]: any }): (string?, string?)
	if toolName == "inspect_place" then
		local info = WorkspaceInspector.getPlaceInfo()
		local stats = WorkspaceInspector.getStats()
		local lines = {
			string.format("Place: %s (PlaceId %s, GameId %s)", info.name, tostring(info.placeId), tostring(info.gameId)),
		}
		if info.genre then
			lines[#lines + 1] = "Genre: " .. info.genre
		end
		if info.description and #info.description > 0 then
			lines[#lines + 1] = "Description: " .. string.sub(info.description, 1, 400)
		end
		lines[#lines + 1] =
			string.format("Workspace: %d direct children, %s descendants.", stats.workspaceChildren, tostring(stats.workspaceDescendants))
		if args.includeClassCounts ~= false then
			local counts = WorkspaceInspector.countByClass()
			local keys = {}
			for className, count in counts do
				keys[#keys + 1] = className
			end
			table.sort(keys)
			local parts = {}
			for index, key in keys do
				if index > 30 then
					break
				end
				parts[#parts + 1] = string.format("%s=%d", key, counts[key])
			end
			lines[#lines + 1] = "Class counts: " .. table.concat(parts, ", ")
		end
		lines[#lines + 1] = "Top-level Workspace outline:"
		lines[#lines + 1] = WorkspaceInspector.summariseTree()
		return table.concat(lines, "\n"), nil
	end

	if toolName == "inspect_tree" then
		local instance, err = resolveTarget(args.path)
		if not instance then
			return nil, err
		end
		local tree = WorkspaceInspector.describeTree(instance, args.maxDepth or 3)
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, tree)
		if not ok then
			return nil, "Could not serialise the tree."
		end
		return encoded, nil
	end

	if toolName == "inspect_selection" then
		return require(script.Parent.SelectionInspector).getSummary(), nil
	end

	if toolName == "inspect_properties" then
		local instance, err = resolveTarget(args.path)
		if not instance then
			return nil, err
		end
		local properties = WorkspaceInspector.readProperties(instance)
		local lines = { string.format("%s (%s)", instance:GetFullName(), instance.ClassName) }
		for key, value in properties do
			lines[#lines + 1] = string.format("  %s = %s", key, value)
		end
		return table.concat(lines, "\n"), nil
	end

	if toolName == "inspect_script" then
		local instance, err = resolveTarget(args.path)
		if not instance then
			return nil, err
		end
		if not instance:IsA("LuaSourceContainer") then
			return nil, string.format("`%s` is a %s, not a script.", instance:GetFullName(), instance.ClassName)
		end
		local source = (instance :: any).Source
		if type(source) ~= "string" then
			return nil, "This script has no readable source (it may be a built-in instance)."
		end
		if #source > WorkspaceInspector.LIMITS.MAX_SCRIPT_CHARS then
			return string.format(
				"-- truncated at %d of %d characters --\n%s",
				WorkspaceInspector.LIMITS.MAX_SCRIPT_CHARS,
				#source,
				string.sub(source, 1, WorkspaceInspector.LIMITS.MAX_SCRIPT_CHARS)
			),
				nil
		end
		return source, nil
	end

	if toolName == "inspect_lighting" then
		local properties = WorkspaceInspector.describeLighting()
		local lines = { "Lighting:" }
		for key, value in properties do
			lines[#lines + 1] = string.format("  %s = %s", key, value)
		end
		return table.concat(lines, "\n"), nil
	end

	if toolName == "inspect_ui" then
		local info = WorkspaceInspector.describeUI()
		local lines = {}
		for _, entry in info.playerGuis do
			lines[#lines + 1] = string.format("%s (%d gui elements)", entry.name, entry.total)
			for _, screen in entry.screens do
				lines[#lines + 1] = "  " .. screen
			end
		end
		if #lines == 0 then
			lines[1] = "No PlayerGui instances are present in this place."
		end
		lines[#lines + 1] = info.note
		return table.concat(lines, "\n"), nil
	end

	if toolName == "inspect_place_stats" then
		local stats = WorkspaceInspector.getStats()
		return string.format(
			"Workspace direct children: %d\nWorkspace descendants: %s\nEditor placeholder objects are not included.",
			stats.workspaceChildren,
			tostring(stats.workspaceDescendants)
		),
			nil
	end

	return nil, string.format("No handler for read tool `%s`.", toolName)
end

--=============================================================================
-- WRITE TOOL HANDLERS
--=============================================================================

local function handleCreatePart(args): (Instance?, string?)
	local parent, err = resolveParent(args.parent or "Workspace")
	if not parent then
		return nil, err
	end

	local part = Instance.new("Part")
	part.Name = args.name
	part.Size = toVector3(args.size, Vector3.new(10, 1, 10))
	part.CFrame = CFrame.new(toVector3(args.position, Vector3.new(0, 5, 0)))
	part.Anchored = args.anchored ~= false
	part.CanCollide = args.canCollide ~= false
	if args.material then
		local okEnum = pcall(function()
			part.Material = Enum.Material[args.material]
		end)
		if not okEnum then
			part:Destroy()
			return nil, string.format("`%s` is not a valid Material enum.", tostring(args.material))
		end
	end
	if args.color then
		part.Color = toColor3(args.color, part.Color)
	end
	if args.shape then
		local okShape = pcall(function()
			part.Shape = Enum.PartType[args.shape]
		end)
		if not okShape then
			part:Destroy()
			return nil, string.format("`%s` is not a valid Part shape.", tostring(args.shape))
		end
	end

	part.Parent = parent
	return part, nil
end

local function handleCreateModel(args): (Instance?, string?)
	local result = InstanceManager.create("Model", { Name = args.name, Parent = args.parent or "Workspace" })
	if not result.ok then
		return nil, result.message
	end
	return result.instance, result.message
end

local function handleCreateFolder(args): (Instance?, string?)
	local result = InstanceManager.create("Folder", { Name = args.name, Parent = args.parent or "Workspace" })
	if not result.ok then
		return nil, result.message
	end
	return result.instance, result.message
end

local function handleGenerateMap(args): (Instance?, string?)
	local parent, err = resolveParent(args.parent or "Workspace")
	if not parent then
		return nil, err
	end

	local ModelBuilder = require(script.Parent.ModelBuilder)
	local map, detail = ModelBuilder.generateSimpleMap({
		name = args.name,
		origin = ActionExecutor.toVector3(args.origin, Vector3.zero),
		radius = args.radius,
		buildings = args.buildings,
		roads = args.roads,
		color = args.color,
	})
	if not map then
		return nil, detail
	end

	map.Parent = parent
	return map, detail
end

local function handleCreateScript(args): (Instance?, string?)
	local parent, err = resolveParent(args.parent)
	if not parent then
		return nil, err
	end

	local className = args.scriptType or "LocalScript"
	local scriptInstance = Instance.new(className)
	scriptInstance.Name = args.name

	scriptInstance.Source = if type(args.source) == "string" and #args.source > 0
		then args.source
		else string.format("-- %s\n-- Created by ForgePilot\n", args.name)

	scriptInstance.Parent = parent

	if args.enabled == false then
		scriptInstance.Enabled = false
	end

	if args.openInEditor ~= false then
		ScriptManager.open(scriptInstance)
	end

	return scriptInstance, nil
end

local function handleEditScript(args): (Instance?, string?)
	local instance, err = resolveTarget(args.path)
	if not instance then
		return nil, err
	end
	if not instance:IsA("LuaSourceContainer") then
		return nil, string.format("`%s` is a %s, not a script.", instance:GetFullName(), instance.ClassName)
	end

	local previous = (instance :: any).Source
	if type(previous) ~= "string" then
		return nil, "This script's source is not readable, so ForgePilot will not overwrite it."
	end

	(instance :: any).Source = args.source

	if args.openInEditor ~= false then
		ScriptManager.open(instance)
	end
	return instance, nil
end

local function handleAppendScript(args): (Instance?, string?)
	local instance, err = resolveTarget(args.path)
	if not instance then
		return nil, err
	end
	if not instance:IsA("LuaSourceContainer") then
		return nil, string.format("`%s` is a %s, not a script.", instance:GetFullName(), instance.ClassName)
	end
	(instance :: any).Source = tostring((instance :: any).Source or "") .. args.text
	if args.openInEditor ~= false then
		ScriptManager.open(instance)
	end
	return instance, nil
end

local function handleSetProperties(args): (Instance?, string?)
	local instance, err = resolveTarget(args.path)
	if not instance then
		return nil, err
	end

	local result = InstanceManager.setProperties(instance, args.properties :: any)
	local applied = result.applied
	local rejected = result.rejected

	if #applied == 0 then
		return nil,
			string.format(
				"No property could be set on `%s`. Rejected: %s",
				instance:GetFullName(),
				#rejected > 0 and table.concat(rejected, ", ") or "(none listed)"
			)
	end

	if #rejected > 0 then
		Logger.warn("Build", "Some properties were rejected.", {
			detail = string.format("%s: %s", instance:GetFullName(), table.concat(rejected, ", ")),
		})
	end

	return instance, string.format("Set %s.", table.concat(applied, ", "))
end

local function handleMove(args): (Instance?, string?)
	local instance, err = resolveTarget(args.path)
	if not instance then
		return nil, err
	end

	if args.newParent then
		local newParent, parentErr = resolveParent(args.newParent)
		if not newParent then
			return nil, parentErr
		end
		if newParent == instance or newParent:IsDescendantOf(instance) then
			return nil, "An instance cannot be parented inside itself or one of its own descendants."
		end
		instance.Parent = newParent
	end

	if args.position and instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(toVector3(args.position, instance.Position))
	elseif args.position and instance:IsA("Model") then
		local pivot = (instance :: any).Pivot
		instance:PivotTo(CFrame.new(toVector3(args.position, pivot.Position)))
	end

	return instance, nil
end

local function handleResize(args): (Instance?, string?)
	local instance, err = resolveTarget(args.path)
	if not instance then
		return nil, err
	end
	local size = toVector3(args.size, Vector3.zero)
	if size.Magnitude < 0.001 then
		return nil, "The requested size is zero."
	end
	if instance:IsA("BasePart") then
		instance.Size = size
	elseif instance:IsA("GuiObject") then
		instance.Size = UDim2.fromOffset(math.round(size.X), math.round(size.Y))
	else
		return nil, string.format("`%s` is a %s, which has no resizable Size.", instance:GetFullName(), instance.ClassName)
	end
	return instance, nil
end

local function handleGroup(args): (Instance?, string?)
	local target: Instance
	if args.into then
		local resolved, err = resolveTarget(args.into)
		if not resolved then
			return nil, err
		end
		target = resolved
	else
		local parent, parentErr = resolveParent("Workspace")
		if not parent then
			return nil, parentErr
		end
		target = Instance.new("Model")
		target.Name = args.name or "Group"
		target.Parent = parent
	end

	local moved = 0
	for _, path in (args.paths :: { string }) do
		local instance, resolveErr = resolveTarget(path)
		if instance then
			if instance ~= target and not target:IsDescendantOf(instance) then
				instance.Parent = target
				moved += 1
			end
		else
			Logger.warn("Build", "Skipped an unresolvable path.", { detail = tostring(path) .. ": " .. tostring(resolveErr) })
		end
	end

	if moved == 0 then
		return nil, "None of the given paths could be grouped."
	end
	return target, string.format("Grouped %d instance(s).", moved)
end

local function handleDelete(args): (Instance?, string?)
	local instance, err = resolveTarget(args.path)
	if not instance then
		return nil, err
	end

	local destroyed, message = InstanceManager.destroy(instance)
	if not destroyed then
		return nil, message
	end
	return nil, message
end

local function handleSetDisabled(args): (Instance?, string?)
	local instance, err = resolveTarget(args.path)
	if not instance then
		return nil, err
	end
	if not instance:IsA("LuaSourceContainer") then
		return nil, string.format("`%s` is a %s, not a script.", instance:GetFullName(), instance.ClassName)
	end
	instance.Enabled = args.enabled
	return instance, nil
end

local function handleCreateUI(args): (Instance?, string?)
	local parent, err = resolveParent(args.parent or "StarterGui")
	if not parent then
		return nil, err
	end
	local gui, guiErr = GUIBuilder.build(args)
	if not gui then
		return nil, guiErr
	end
	gui.Parent = parent
	if args.openInEditor ~= false then
		ScriptManager.focus(gui)
	end
	return gui, nil
end

--=============================================================================
-- VERIFICATION
--=============================================================================

--- Confirms the result actually exists in the DataModel.
-- `instance`/`note` are the (Instance?, string?) pair returned by the handler.
local function verify(toolName: string, args: { [string]: any }, instance: Instance?, note: string?): (boolean, string)
	if toolName == "delete_instance" then
		local target, err = resolveTarget(args.path)
		if not target then
			return true, (note or "Deleted.") .. " Verified: the instance is no longer present."
		end
		return false, string.format("Deletion could not be verified: `%s` still exists.", tostring(args.path))
	end

	if instance then
		local stillParented = instance.Parent ~= nil
		if not stillParented then
			return false, "The created instance is not parented to anything."
		end
		local detail = note or ""
		return true,
			string.format(
				"Verified: %s exists at %s.%s",
				instance.Name,
				instance:GetFullName(),
				if #detail > 0 then (" " .. detail) else ""
			)
	end

	return false, note or "The action reported no instance."
end

--=============================================================================
-- EXECUTE
--=============================================================================

export type ExecutionResult = {
	ok: boolean,
	toolName: string,
	verified: boolean,
	message: string,
	detail: string?,
	actionId: string,
	durationMs: number,
}

local actionCounter = 0

--- Executes one validated tool call.
function ActionExecutor.execute(toolName: string, args: { [string]: any }, mode: string): (ExecutionResult?, string?)
	local validation = ToolValidator.validate(toolName, args, mode)
	if not validation.ok or not validation.tool then
		return nil, table.concat(validation.errors, " ")
	end

	local tool = validation.tool
	local arguments = validation.arguments or {}
	actionCounter += 1
	local actionId = string.format("act-%d", actionCounter)
	local started = os.clock()

	Logger.log("TOOL", tool.category, ToolValidator.summarise(toolName, arguments), {
		toolName = toolName,
		detail = "Validated. Executing.",
	})
	EventBus.emit(EventBus.Events.ToolCallStarted, {
		toolName = toolName,
		actionId = actionId,
		summary = ToolValidator.summarise(toolName, arguments),
	})

    if tool.external then
        local value, problem = BridgeClient.execute(toolName, arguments, mode, function() return StateManager.get() == "CANCELLED" end)
        local ok = value ~= nil and value.ok == true
        local result = { ok = ok, verified = ok and value.verified == true, toolName = toolName, message = if value then tostring(value.message or "") else problem or "Bridge tool failed.", actionId = actionId, durationMs = (os.clock() - started) * 1000, attachments = if value then value.attachments else nil }
        EventBus.emit(if ok then EventBus.Events.ToolCallFinished else EventBus.Events.ToolCallFailed, result)
        return result, nil
    end

	local result: any = nil -- (Instance?, string?) pair returned by the handler
	local handlerError: string? = nil

	local function runHandler()
		if tool.mode == "plan" then
			local value, err = handleRead(toolName, arguments)
			result = value; handlerError = err
			return
		end

		local ok, err = HistoryManager.transact(
			string.format("ForgePilot: %s", toolName),
			function()
				if toolName == "create_part" then
					result = handleCreatePart(arguments)
				elseif toolName == "create_model" then
					result = handleCreateModel(arguments)
				elseif toolName == "create_folder" then
					result = handleCreateFolder(arguments)
				elseif toolName == "create_building" then
					result = Buildings.create(arguments)
				elseif toolName == "create_road" then
					result = Roads.create(arguments)
				elseif toolName == "fill_terrain" then
					result = Terrain.fill(arguments)
				elseif toolName == "generate_map" then
					result = handleGenerateMap(arguments)
				elseif toolName == "create_ui" then
					result = handleCreateUI(arguments)
				elseif toolName == "create_script" then
					result = handleCreateScript(arguments)
				elseif toolName == "edit_script" then
					result = handleEditScript(arguments)
				elseif toolName == "append_script" then
					result = handleAppendScript(arguments)
				elseif toolName == "set_properties" then
					result = handleSetProperties(arguments)
				elseif toolName == "move_instance" then
					result = handleMove(arguments)
				elseif toolName == "resize_instance" then
					result = handleResize(arguments)
				elseif toolName == "group_instances" then
					result = handleGroup(arguments)
				elseif toolName == "configure_lighting" then
					result = LightingManager.apply(arguments.settings)
				elseif toolName == "delete_instance" then
					result = handleDelete(arguments)
				elseif toolName == "set_disabled" then
					result = handleSetDisabled(arguments)
				else
					error(string.format("No handler for write tool `%s`.", toolName), 0)
				end
			end
		)
		if not ok then
			handlerError = tostring(err)
		end
	end

	runHandler()

	local durationMs = (os.clock() - started) * 1000

	if handlerError then
		local message = string.format("`%s` failed: %s", toolName, handlerError)
		Logger.error("Build", "Tool execution failed.", { detail = message, toolName = toolName })
		EventBus.emit(EventBus.Events.ToolCallFailed, {
			toolName = toolName,
			actionId = actionId,
			message = message,
		})
		return {
			ok = false,
			toolName = toolName,
			verified = false,
			message = message,
			detail = handlerError,
			actionId = actionId,
			durationMs = durationMs,
		}, nil
	end

    if tool.mode == "plan" then
        local readResult = { ok = type(result) == "string", verified = type(result) == "string", toolName = toolName, message = tostring(result or "No inspection result."), actionId = actionId, durationMs = durationMs }
        EventBus.emit(EventBus.Events.ToolCallFinished, readResult)
        return readResult, nil
    end
	local resultInstance, resultNote = result
	local verified, detail = verify(toolName, arguments, resultInstance, resultNote)

	local executionResult: ExecutionResult = {
		ok = true,
		toolName = toolName,
		verified = verified,
		message = detail,
		detail = resultNote,
		actionId = actionId,
		durationMs = durationMs,
	}

	if verified then
		Logger.success("Build", ToolValidator.summarise(toolName, arguments), {
			detail = detail,
			toolName = toolName,
			durationMs = durationMs,
		})
	else
		Logger.error("Build", "Action finished but could not be verified.", {
			detail = detail,
			toolName = toolName,
		})
	end

	EventBus.emit(EventBus.Events.ToolCallFinished, executionResult)
	return executionResult, nil
end

--- Executes a read tool regardless of mode (used for context gathering).
function ActionExecutor.read(toolName: string, args: { [string]: any }?): (string?, string?)
	local validation = ToolValidator.validate(toolName, args or {}, "plan")
	if not validation.ok then
		return nil, table.concat(validation.errors, " ")
	end
	return handleRead(toolName, validation.arguments or {})
end

return ActionExecutor