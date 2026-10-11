--!strict
--[[
	ForgePilot / Roblox / GUIBuilder
	Creates real ScreenGui hierarchies with proper UDim2 layout.

	The builder only constructs elements the tool schema allowed, so a model
	cannot smuggle in an arbitrary class name.
]]

local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local GUIBuilder = {}

local ALLOWED_CLASSES: { [string]: boolean } = {
	Frame = true,
	TextLabel = true,
	TextButton = true,
	ImageLabel = true,
	ScrollingFrame = true,
}

local DEFAULT_COLORS = {
	Frame = Color3.fromHex("#211D28"),
	TextLabel = Color3.fromHex("#F4F1F8"),
	TextButton = Color3.fromHex("#9879E8"),
	ImageLabel = Color3.fromHex("#2C2331"),
	ScrollingFrame = Color3.fromHex("#211D28"),
}

local function resolveColor(value: any, fallback: Color3): Color3
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

local function toSize(value: any, fallback: UDim2): UDim2
	if type(value) == "table" then
		local x = tonumber(value.x or value.X or value[1])
		local y = tonumber(value.y or value.Y or value[2])
		if x and y then
			return UDim2.fromOffset(math.max(1, math.round(x)), math.max(1, math.round(y)))
		end
	elseif type(value) == "string" then
		local x, y = string.match(value, "^(%-?%d+)%s*,%s*(%-?%d+)$")
		if x then
			return UDim2.fromOffset(math.max(1, tonumber(x)), math.max(1, tonumber(y)))
		end
	end
	return fallback
end

local function toPosition(value: any, fallback: UDim2): UDim2
	if type(value) == "table" then
		local x = tonumber(value.x or value.X or value[1])
		local y = tonumber(value.y or value.Y or value[2])
		if x and y then
			return UDim2.fromOffset(math.round(x), math.round(y))
		end
	end
	return fallback
end

--- Builds one GUI element from a plain description.
function GUIBuilder.buildElement(description: any, parent: Instance, layoutOrder: number): (Instance?, string?)
	if type(description) ~= "table" then
		return nil, "Each element must be an object."
	end
	local className = description.className
	if type(className) ~= "string" or not ALLOWED_CLASSES[className] then
		return nil,
			string.format(
				"`%s` is not an allowed GUI class. ForgePilot can create Frame, TextLabel, TextButton, ImageLabel and ScrollingFrame.",
				tostring(className)
			)
	end

	local instance = Instance.new(className)
	instance.Name = type(description.name) == "string" and string.sub(description.name, 1, 80) or className
	instance.LayoutOrder = layoutOrder

	if className == "Frame" or className == "ScrollingFrame" then
		instance.Size = toSize(description.size, UDim2.fromOffset(320, 200))
		instance.Position = toPosition(description.position, UDim2.fromOffset(0, 0))
		instance.BackgroundColor3 = resolveColor(description.color, DEFAULT_COLORS[className])
		instance.BackgroundTransparency = tonumber(description.transparency) or 0
		instance.BorderSizePixel = 0
	elseif className == "TextLabel" or className == "TextButton" then
		instance.Size = toSize(description.size, UDim2.fromOffset(280, 36))
		instance.Position = toPosition(description.position, UDim2.fromOffset(0, 0))
		instance.BackgroundTransparency = if className == "TextLabel" and not description.background then 1 else 0
		instance.BackgroundColor3 = resolveColor(description.color, DEFAULT_COLORS[className])
		instance.Text = type(description.text) == "string" and string.sub(description.text, 1, 500) or "Text"
		instance.TextColor3 = resolveColor(description.textColor, Color3.fromHex("#F4F1F8"))
		instance.TextSize = tonumber(description.textSize) or 16
		instance.Font = Enum.Font.Gotham
		instance.TextXAlignment = Enum.TextXAlignment.Left
		instance.BorderSizePixel = 0
		instance.Active = if className == "TextButton" then true else false
	elseif className == "ImageLabel" then
		instance.Size = toSize(description.size, UDim2.fromOffset(64, 64))
		instance.Position = toPosition(description.position, UDim2.fromOffset(0, 0))
		instance.BackgroundTransparency = 1
		instance.ImageColor3 = resolveColor(description.color, DEFAULT_COLORS.ImageLabel)
		instance.ImageTransparency = tonumber(description.transparency) or 0
		instance.ScaleType = Enum.ScaleType.Fit
	end

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = instance

	instance.Parent = parent

	-- Children
	if type(description.children) == "table" then
		for index, child in description.children do
			if index > 50 then
				break
			end
			local built, childError = GUIBuilder.buildElement(child, instance, index)
			if not built then
				return instance, string.format("Child %d could not be built: %s", index, tostring(childError))
			end
		end
	end

	return instance, nil
end

--- Builds a ScreenGui with its declared children.
function GUIBuilder.build(args: any): (Instance?, string?)
	local gui = Instance.new("ScreenGui")
	gui.Name = args.name
	gui.Enabled = args.enabled == true
	gui.ResetOnSpawn = args.resetOnSpawn == true
	gui.IgnoreGuiInset = args.ignoreGuiInset == true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui:SetAttribute("ForgePilotOrigin", "create_ui")

	local elements = args.elements
	if type(elements) ~= "table" or #elements == 0 then
		local root = Instance.new("Frame")
		root.Name = "Root"
		root.Size = UDim2.new(0, 360, 0, 240)
		root.Position = UDim2.fromOffset(40, 40)
		root.BackgroundColor3 = DEFAULT_COLORS.Frame
		root.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = root
		root.Parent = gui
		return gui, "Created an empty ScreenGui with a Root frame."
	end

	if #elements > 60 then
		return nil, string.format("A single call may create at most 60 elements (received %d).", #elements)
	end

	local warnings: { string } = {}
	for index, description in elements do
		local built, elementError = GUIBuilder.buildElement(description, gui, index)
		if not built then
			return nil, string.format("Element %d: %s", index, tostring(elementError))
		end
		if elementError then
			warnings[#warnings + 1] = elementError
		end
	end

	local detail = string.format("Created %d top-level element(s).", #elements)
	if #warnings > 0 then
		detail ..= " Warnings: " .. table.concat(warnings, "; ")
	end
	return gui, detail
end

return GUIBuilder