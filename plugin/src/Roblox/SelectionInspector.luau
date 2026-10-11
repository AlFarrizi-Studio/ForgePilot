--!strict
--[[
	ForgePilot / Roblox / SelectionInspector
	Read-only view of the Studio selection, used by Planning mode and by the
	"inspect selected objects" tool.
]]

local WorkspaceInspector = require(script.Parent.WorkspaceInspector)

local SelectionInspector = {}

local MAX_SELECTION = 30

function SelectionInspector.isAvailable(): boolean
	return typeof(game:GetService("Selection")) == "Instance"
end

--- Returns the current Studio selection as structured data.
function SelectionInspector.get(): { { name: string, className: string, path: string, properties: { [string]: string } } }
	local result = {}
	if not SelectionInspector.isAvailable() then
		return result
	end

	local service = game:GetService("Selection")
	local selection = service:Get()

	for index = 1, math.min(#selection, MAX_SELECTION) do
		local instance = selection[index]
		result[index] = {
			name = instance.Name,
			className = instance.ClassName,
			path = instance:GetFullName(),
			properties = WorkspaceInspector.readProperties(instance),
			childCount = #instance:GetChildren(),
		}
	end

	return result
end

function SelectionInspector.getSummary(): string
	local selection = SelectionInspector.get()
	if #selection == 0 then
		return "Nothing is selected in Studio."
	end

	local lines: { string } = {
		string.format("%d object%s selected:", #selection, if #selection == 1 then "" else "s"),
	}
	for index, entry in selection do
		if index > MAX_SELECTION then
			break
		end
		local detail: { string } = {}
		local count = 0
		for key, value in entry.properties do
			if count >= 8 then
				break
			end
			detail[#detail + 1] = string.format("%s=%s", key, value)
			count += 1
		end
		table.sort(detail)
		lines[#lines + 1] = string.format("- %s [%s] %s", entry.name, entry.className, table.concat(detail, ", "))
	end
	if #selection > MAX_SELECTION then
		lines[#lines + 1] = string.format("… and %d more.", #selection - MAX_SELECTION)
	end
	return table.concat(lines, "\n")
end

function SelectionInspector.getPaths(): { string }
	local paths = {}
	for _, entry in SelectionInspector.get() do
		paths[#paths + 1] = entry.path
	end
	return paths
end

return SelectionInspector