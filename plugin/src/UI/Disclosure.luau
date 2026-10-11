--!strict
local TextService = game:GetService("TextService")
local Icons = require(script.Parent.Parent.Utilities.Icons)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local Disclosure = {}

-- The same controls exist for one-line and long results. Only the expanded
-- viewport scrolls; closing never leaves a hidden, full-height body behind.
function Disclosure.build(parent: Instance, options: any): (Frame, any)
	local frame = Instance.new("Frame")
	frame.Name = options.name or "ActivityDetails"
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	Theme.passThrough(frame)
	frame.Parent = parent
	Theme.listLayout(5).Parent = frame
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 28)
	Theme.passThrough(header)
	header.Parent = frame
	local icon = Icons.glyph(options.icon or "Tool", 16, Theme.Colors.Highlight)
	icon.Name = "ActivityIcon"
	icon.Position = UDim2.fromOffset(0, 6)
	icon.Parent = header
	local toggle = Theme.textButton("", { height = 28 })
	toggle.Name = "Toggle"
	toggle.Position = UDim2.fromOffset(22, 0)
	toggle.Size = UDim2.new(1, -22, 1, 0)
	toggle.BackgroundTransparency = 1
	toggle.TextXAlignment = Enum.TextXAlignment.Left
	toggle.TextSize = 12
	toggle.Parent = header
	local preview = Theme.label("", { size = 11, color = Theme.Extra.Muted })
	preview.Name = "Preview"
	preview.Size = UDim2.new(1, 0, 0, 18)
	preview.LayoutOrder = 1
	preview.TextTruncate = Enum.TextTruncate.AtEnd
	preview.Parent = frame
	local scroll = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	scroll.Name = "Content"
	scroll.Size = UDim2.new(1, 0, 0, 24)
	scroll.LayoutOrder = 2
	scroll.Active = true
	scroll.Parent = frame
	local text = Theme.autoText(options.text or "", { size = options.textSize or 12, color = options.color or Theme.Colors.SecondaryText, font = options.font or Theme.Fonts.Code })
	text.Name = options.textName or "Detail"
	text.RichText = false
	text.Parent = scroll
	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.Size = UDim2.new(1, 0, 0, 24)
	footer.LayoutOrder = 3
	Theme.passThrough(footer)
	Theme.listLayout(8, Enum.FillDirection.Horizontal).Parent = footer
	footer.Parent = frame
	local close = Theme.textButton("", { height = 24, width = UDim2.fromOffset(76, 24) })
	close.Name = "Close"
	close.BackgroundTransparency = 1
	close.TextSize = 11
	Icons.setButton(close, "ChevronUp", "Close")
	close.Parent = footer
	if options.onCopy then
		local copy = Theme.textButton("", { height = 24, width = UDim2.fromOffset(68, 24) })
		copy.Name = "Copy"
		copy.LayoutOrder = 1
		copy.BackgroundTransparency = 1
		copy.TextSize = 11
		Icons.setButton(copy, "Copy", "Copy")
		copy.Parent = footer
		copy.MouseButton1Click:Connect(function() options.onCopy(text.Text) end)
	end
	local expanded = options.expanded == true
	local function resize()
		local bounds = TextService:GetTextSize(text.Text, text.TextSize, text.Font, Vector2.new(math.max(120, scroll.AbsoluteSize.X - 12), 1000000))
		scroll.Size = UDim2.new(1, 0, 0, math.clamp(bounds.Y + 8, 24, options.maxHeight or 260))
	end
	local function refresh()
		scroll.Visible = expanded
		footer.Visible = expanded
		preview.Visible = not expanded and options.preview == true
		preview.Text = text.Text:match("([^\r\n]+)") or ""
		Icons.setButton(toggle, if expanded then "ChevronDown" else "ChevronRight", options.title or "Details")
		resize()
	end
	local function setExpanded(value: boolean)
		expanded = value
		refresh()
		if options.onToggle then options.onToggle(expanded) end
	end
	toggle.MouseButton1Click:Connect(function() setExpanded(not expanded) end)
	close.MouseButton1Click:Connect(function() setExpanded(false) end)
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	refresh()
	return frame, {
		setText = function(value: string) text.Text = value; refresh() end,
		setExpanded = setExpanded,
		isExpanded = function() return expanded end,
	}
end
return Disclosure
