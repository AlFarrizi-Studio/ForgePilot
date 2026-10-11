--!strict
--[[
	ForgePilot / Roblox / ScriptManager
	Script creation helpers plus ScriptEditorService integration.

	NOTE ON SECURITY
	----------------
	Generated gameplay scripts are written into the place as ordinary project
	assets. ForgePilot never runs them with plugin privileges, never evaluates
	model-generated Luau inside the plugin, and never bypasses Roblox's scripting
	security rules. The code lives in your place and obeys the normal runtime
	sandbox exactly like anything you type by hand.
]]

local Logger = require(script.Parent.Parent.Utilities.Logger)

local ScriptManager = {}

local editorAvailable = false

--- Probes ScriptEditorService once and caches the result.
function ScriptManager.isEditorAvailable(): boolean
	if editorAvailable then
		return true
	end
	local ok = pcall(function()
		local service = game:GetService("ScriptEditorService")
		-- ScriptEditorService:GetScriptEditor does not exist; the supported way to
		-- put a script in front of the user is OpenScriptDocumentAsync.
		return type(service.OpenScriptDocumentAsync) == "function"
	end)
	editorAvailable = ok
	return ok
end

--- Opens a script in Studio's script editor, if that API is reachable.
function ScriptManager.open(scriptInstance: Instance): boolean
	if not ScriptManager.isEditorAvailable() then
		Logger.warn("Scripts", "ScriptEditorService is not reachable from this plugin context.")
		return false
	end
	if not scriptInstance:IsA("LuaSourceContainer") then
		return false
	end

	local ok, err = pcall(function()
		local service = game:GetService("ScriptEditorService")
		service:OpenScriptDocumentAsync(scriptInstance)
	end)
	if ok then
		Logger.info("Scripts", string.format("Opened %s in the script editor.", scriptInstance:GetFullName()))
		return true
	end

	Logger.warn("Scripts", "The script editor could not be opened.", { detail = tostring(err) })
	return false
end

--- Selects an instance in Studio (used after creating scripts or GUIs).
function ScriptManager.focus(instance: Instance): boolean
	local ok, err = pcall(function()
		game:GetService("Selection"):Set({ instance })
	end)
	if not ok then
		Logger.debug("Scripts", "Selection service is unavailable.", { detail = tostring(err) })
		return false
	end
	return true
end

--- Finds scripts by class for a quick overview.
function ScriptManager.listScripts(): { { path: string, className: string, lines: number, bytes: number } }
	local list = {}
	local roots = {
		game:GetService("ServerScriptService"),
		game:GetService("ReplicatedStorage"),
		game:GetService("StarterPlayer"),
		game:GetService("StarterGui"),
	}

	local budget = 0
	for _, root in roots do
		for _, descendant in root:GetDescendants() do
			budget += 1
			if budget > 2000 then
				break
			end
			if descendant:IsA("LuaSourceContainer") then
				local source = tostring((descendant :: any).Source or "")
				local lines = select(2, string.gsub(source, "\n", "")) + 1
				list[#list + 1] = {
					path = descendant:GetFullName(),
					className = descendant.ClassName,
					lines = lines,
					bytes = #source,
				}
			end
		end
	end
	return list
end

--- Reads a script's source safely, returning nil plus a reason on failure.
function ScriptManager.readSource(scriptInstance: Instance): (string?, string?)
	if not scriptInstance:IsA("LuaSourceContainer") then
		return nil, string.format("`%s` is a %s, not a script.", scriptInstance:GetFullName(), scriptInstance.ClassName)
	end
	local source = (scriptInstance :: any).Source
	if type(source) ~= "string" then
		return nil, "This script's source is not readable."
	end
	return source, nil
end

--- Strips accidental leading markers some models emit.
function ScriptManager.normaliseSource(source: string): string
	local cleaned = source:gsub("\r\n", "\n")
	-- Remove a wrapping markdown fence if the model emitted one.
	cleaned = cleaned:gsub("^%s*```%a*\n", ""):gsub("\n```%s*$", "")
	return cleaned
end

return ScriptManager