--!strict
-- Local checks: no provider request, persistent settings or Workspace edits.
local Theme = require(script.Parent.Theme)
local Components = require(script.Parent.Parent.UI.Components)
local Renderer = require(script.Parent.Parent.UI.MessageRenderer)

local UIHealthCheck = {}

function UIHealthCheck.run(): { passed: number, total: number, errors: { string } }
	local report = { passed = 0, total = 0, errors = {} :: { string } }
	local owned: { Instance } = {}
	local function keep<T>(object: T): T
		owned[#owned + 1] = object :: any
		return object
	end
	local function check(name: string, operation: () -> boolean)
		report.total += 1
		local ok, result = pcall(operation)
		if ok and result == true then report.passed += 1
		else report.errors[#report.errors + 1] = name .. ": " .. tostring(result) end
	end
	check("Rich text", function()
		return Renderer.formatInline("<Part> & **bold**") == "&lt;Part&gt; &amp; <b>bold</b>"
	end)
	check("Code blocks", function()
		local blocks = Renderer.parseBlocks("Example\n```lua\nprint(1)\n```\nDone")
		return #blocks == 3 and blocks[2].kind == "code" and blocks[2].content == "print(1)"
	end)
	check("Input sizing", function()
		local input = keep(Theme.input("Message"))
		return input.Size.Y.Scale == 0 and input.Size.Y.Offset == Theme.Metrics.InputHeight
	end)
	check("Flex reuse", function()
		local frame = keep(Instance.new("Frame"))
		Theme.flexItem(frame, 1, 1)
		local flex = Theme.flexItem(frame, 0, 0)
		return #frame:GetChildren() == 1 and flex.FlexMode == Enum.UIFlexMode.Custom and flex.GrowRatio == 0
	end)
	check("Scrolling input", function()
		local scroll = keep(Instance.new("ScrollingFrame"))
		Theme.passThrough(scroll)
		return scroll.Active
	end)
	check("Dropdown selection", function()
		local row, _, selected, setSelected = Components.dropdown("Mode", { "Chat", "Plan" }, function() end)
		keep(row)
		setSelected("Plan")
		return selected() == "Plan"
	end)
	check("Button grid", function()
		local row, add = Components.buttonRow({ columns = 2 })
		keep(row)
		add("One"); add("Two"); add("Three")
		return row.Size.Y.Offset >= Theme.Metrics.ButtonHeight * 2
	end)
	check("Message controller", function()
		local frame, controller = Renderer.render({ id = "ui-check", role = "assistant", content = "", streaming = true }, {})
		keep(frame)
		return typeof(frame) == "Instance" and type(controller) == "table" and type(controller.appendDelta) == "function"
	end)
	for _, object in owned do object:Destroy() end
	return report
end

return UIHealthCheck
