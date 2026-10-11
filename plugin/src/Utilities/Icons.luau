--!strict
--[[
	ForgePilot / Utilities / Icons
	Icon definitions and builder helpers.

	Every displayed icon uses native line segments. No font glyphs or external
	assets are required; the brand mark also uses native Roblox primitives.

	Every non-ASCII codepoint is written as a \u{...} escape on purpose: the file
	is UTF-8, but escapes keep the glyph table readable and immune to any editor
	or console that would mangle the literal characters.
]]

local Theme = require(script.Parent.Parent.Utilities.Theme)
local TextService = game:GetService("TextService")

local Icons = {}

--=============================================================================
-- GLYPH MAP
--=============================================================================
-- Legacy text candidates for plain-text compatibility. Displayed controls use
-- the native builders below; resolve only selects an ASCII fallback.

Icons.Glyphs = {
	Chat = { "\u{1F4AC}", "\u{1F4AC}", "[#]", "#" },
	Builder = { "\u{1F9F1}", "\u{1F6E0}", "[+]", "+" },
	History = { "\u{1F504}", "\u{1F504}", "[~]", "~" },
	Logs = { "\u{1F4C4}", "\u{25A4}", "[=]", "=" },
	Settings = { "\u{2699}", "\u{2699}", "[*]", "*" },
	Send = { "\u{27A4}", "\u{25B6}", "\u{25B6}", ">" },
	Stop = { "\u{25A0}", "\u{25A0}", "[#]", "#" },
	Play = { "\u{25B6}", "\u{25B6}", "[>]", ">" },
	Plus = { "+", "+", "+", "+" },
	Close = { "\u{2715}", "\u{2715}", "[x]", "x" },
	Search = { "\u{1F50D}", "\u{1F50D}", "[/]", "/" },
	Check = { "\u{2713}", "\u{2713}", "[v]", "v" },
	Warning = { "\u{26A0}", "\u{26A0}", "[!]", "!" },
	Error = { "\u{2716}", "\u{2716}", "[x]", "x" },
	Info = { "\u{24D8}", "i", "[i]", "i" },
	ChevronDown = { "\u{25BE}", "\u{25BE}", "[v]", "v" },
	ChevronRight = { "\u{25B8}", "\u{25B8}", "[>]", ">" },
	Spinner = { "\u{25D0}", "\u{25D0}", "~", "~" },
	Copy = { "\u{29C9}", "\u{29C9}", "[c]", "c" },
	Refresh = { "\u{27F3}", "\u{27F3}", "[r]", "r" },
	Trash = { "\u{1F5D1}", "\u{1F5D1}", "[x]", "x" },
	Edit = { "\u{270E}", "\u{270E}", "[e]", "e" },
	Lock = { "\u{1F512}", "\u{26BF}", "[L]", "L" },
	Unlock = { "\u{1F513}", "\u{26BF}", "[U]", "U" },
	Eye = { "\u{1F441}", "\u{25CE}", "[o]", "o" },
	EyeOff = { "\u{1F576}", "\u{25CF}", "[x]", "x" },
	Attach = { "\u{1F4CE}", "\u{1F4CE}", "[f]", "f" },
	Image = { "\u{1F5BC}", "\u{25A8}", "[i]", "i" },
	Doc = { "\u{1F4C4}", "\u{25A4}", "[d]", "d" },
	Code = { "{ }", "{}", "<>", "<>" },
	Lightbulb = { "\u{1F4A1}", "\u{25C7}", "[i]", "i" },
	Shield = { "\u{1F6E1}", "\u{25C6}", "[s]", "s" },
	Sparkle = { "\u{2728}", "\u{2728}", "*", "*" },
	Robot = { "\u{1F916}", "\u{25CE}", "[a]", "a" },
	Thinking = { "[t]" }, ProviderCustom = { "[p]" }, Tool = { "[+]" },
	Globe = { "[w]" }, Terminal = { ">_" }, ChevronUp = { "^" },
}

--=============================================================================
-- RESOLUTION
--=============================================================================

--- ASCII compatibility fallback for callers that need plain text.
function Icons.resolve(key: string): string
 local candidates = Icons.Glyphs[key]
 if candidates then
  for _, candidate in candidates do
   if candidate:match("^[%w%p ]+$") then return candidate end
  end
 end
 return "?"
end

--=============================================================================
-- BUILDERS
--=============================================================================

-- Native line segments keep every icon independent of font glyph coverage.
local function drawLineIcon(label: TextLabel, key: string): boolean
	local paths: { { { number } } } = {}
	local function circle(x: number, y: number, radius: number, first: number?, last: number?): { { number } }
		local points = {}
		for index = 0, 20 do
			local angle = math.rad((first or 0) + ((last or 360) - (first or 0)) * index / 20)
			points[#points + 1] = { x + math.cos(angle) * radius, y + math.sin(angle) * radius }
		end
		return points
	end
	if key == "Chat" then
		paths = { { { .14, .18 }, { .86, .18 }, { .86, .70 }, { .48, .70 }, { .28, .88 }, { .28, .70 }, { .14, .70 }, { .14, .18 } } }
	elseif key == "Builder" or key == "Code" then
		paths = { { { .34, .22 }, { .12, .50 }, { .34, .78 } }, { { .66, .22 }, { .88, .50 }, { .66, .78 } } }
	elseif key == "Logs" or key == "Doc" then
		paths = {
			{ { .20, .10 }, { .68, .10 }, { .82, .25 }, { .82, .90 }, { .20, .90 }, { .20, .10 } },
			{ { .34, .39 }, { .68, .39 } }, { { .34, .55 }, { .68, .55 } }, { { .34, .71 }, { .59, .71 } },
		}
	elseif key == "Sparkle" then
		paths = { { { .5, .08 }, { .62, .38 }, { .92, .5 }, { .62, .62 }, { .5, .92 }, { .38, .62 }, { .08, .5 }, { .38, .38 }, { .5, .08 } } }
	elseif key == "ChevronDown" then
		paths = { { { .22, .38 }, { .5, .66 }, { .78, .38 } } }
	elseif key == "ChevronRight" then
		paths = { { { .38, .22 }, { .66, .5 }, { .38, .78 } } }
	elseif key == "ChevronUp" then
		paths = { { { .22, .62 }, { .5, .34 }, { .78, .62 } } }
	elseif key == "Thinking" then
		paths = { { { .5, .15 }, { .35, .10 }, { .20, .20 }, { .20, .34 }, { .10, .43 }, { .14, .65 }, { .25, .69 }, { .24, .81 }, { .38, .90 }, { .5, .83 }, { .5, .15 } }, { { .5, .15 }, { .65, .10 }, { .80, .20 }, { .80, .34 }, { .90, .43 }, { .86, .65 }, { .75, .69 }, { .76, .81 }, { .62, .90 }, { .5, .83 } }, { { .23, .36 }, { .38, .42 }, { .33, .57 } }, { { .77, .36 }, { .62, .42 }, { .67, .57 } } }
	elseif key == "ProviderCustom" then
		paths = { circle(.27, .26, .11), circle(.76, .5, .11), circle(.27, .76, .11), { { .38, .26 }, { .65, .5 }, { .38, .76 } }, { { .27, .38 }, { .27, .65 } } }
	elseif key == "Tool" then
		paths = { { { .72, .10 }, { .62, .30 }, { .77, .43 }, { .93, .27 }, { .90, .50 }, { .73, .62 }, { .60, .60 }, { .24, .93 }, { .09, .79 }, { .44, .43 }, { .42, .30 }, { .52, .14 }, { .72, .10 } } }
	elseif key == "Globe" then
		paths = { circle(.5, .5, .40), { { .1, .5 }, { .9, .5 } }, { { .5, .1 }, { .32, .32 }, { .28, .5 }, { .32, .68 }, { .5, .9 }, { .68, .68 }, { .72, .5 }, { .68, .32 }, { .5, .1 } } }
	elseif key == "Terminal" then
		paths = { { { .08, .18 }, { .92, .18 }, { .92, .82 }, { .08, .82 }, { .08, .18 } }, { { .23, .35 }, { .40, .5 }, { .23, .65 } }, { { .52, .65 }, { .76, .65 } } }
	elseif key == "Refresh" or key == "History" then
		local arc = {}
		for index = 0, 16 do
			local angle = math.rad(-50 + index * 300 / 16)
			arc[#arc + 1] = { .5 + math.cos(angle) * .34, .5 + math.sin(angle) * .34 }
		end
		paths = { arc, { { .58, .12 }, { .73, .24 }, { .86, .10 } } }
	elseif key == "Settings" then
		local outer, inner = {}, {}
		for index = 0, 24 do
			local angle = index * math.pi / 12
			local radius = if index % 3 == 0 then .42 else .34
			outer[#outer + 1] = { .5 + math.cos(angle) * radius, .5 + math.sin(angle) * radius }
		end
		for index = 0, 12 do
			local angle = index * math.pi / 6
			inner[#inner + 1] = { .5 + math.cos(angle) * .13, .5 + math.sin(angle) * .13 }
		end
		paths = { outer, inner }
	elseif key == "Send" then
		paths = { { { .18, .45 }, { .5, .12 }, { .82, .45 } }, { { .5, .12 }, { .5, .88 } } }
	elseif key == "Stop" then
		paths = { { { .23, .23 }, { .77, .23 }, { .77, .77 }, { .23, .77 }, { .23, .23 } } }
	elseif key == "Play" then
		paths = { { { .28, .17 }, { .82, .5 }, { .28, .83 }, { .28, .17 } } }
	elseif key == "Plus" then
		paths = { { { .18, .5 }, { .82, .5 } }, { { .5, .18 }, { .5, .82 } } }
	elseif key == "Close" or key == "Error" then
		paths = { { { .24, .24 }, { .76, .76 } }, { { .76, .24 }, { .24, .76 } } }
	elseif key == "Search" then
		paths = { circle(.42, .42, .28), { { .63, .63 }, { .87, .87 } } }
	elseif key == "Check" then
		paths = { { { .16, .5 }, { .4, .75 }, { .84, .24 } } }
	elseif key == "Warning" then
		paths = { { { .5, .12 }, { .91, .85 }, { .09, .85 }, { .5, .12 } }, { { .5, .38 }, { .5, .60 } }, { { .5, .71 }, { .5, .73 } } }
	elseif key == "Info" then
		paths = { circle(.5, .5, .4), { { .5, .45 }, { .5, .75 } }, { { .5, .25 }, { .5, .28 } } }
	elseif key == "Spinner" then
		paths = { circle(.5, .5, .34, -70, 220) }
	elseif key == "Copy" then
		paths = { { { .36, .3 }, { .83, .3 }, { .83, .87 }, { .36, .87 }, { .36, .3 } }, { { .64, .3 }, { .64, .12 }, { .17, .12 }, { .17, .70 }, { .36, .70 } } }
	elseif key == "Trash" then
		paths = { { { .15, .25 }, { .85, .25 } }, { { .35, .25 }, { .35, .12 }, { .65, .12 }, { .65, .25 } }, { { .25, .25 }, { .3, .87 }, { .7, .87 }, { .75, .25 } }, { { .43, .4 }, { .43, .7 } }, { { .57, .4 }, { .57, .7 } } }
	elseif key == "Edit" then
		paths = { { { .15, .85 }, { .22, .6 }, { .7, .12 }, { .87, .29 }, { .39, .77 }, { .15, .85 } }, { { .61, .21 }, { .78, .38 } } }
	elseif key == "Lock" or key == "Unlock" then
		paths = { { { .2, .45 }, { .8, .45 }, { .8, .87 }, { .2, .87 }, { .2, .45 } }, circle(.5, .37, .22, -180, 0), { { .5, .6 }, { .5, .72 } } }
		if key == "Unlock" then paths[2] = circle(.68, .37, .22, -180, -20) end
	elseif key == "Eye" or key == "EyeOff" then
		paths = { { { .08, .5 }, { .27, .29 }, { .5, .22 }, { .73, .29 }, { .92, .5 }, { .73, .71 }, { .5, .78 }, { .27, .71 }, { .08, .5 } }, circle(.5, .5, .15) }
		if key == "EyeOff" then paths[#paths + 1] = { { .12, .12 }, { .88, .88 } } end
	elseif key == "Attach" then
		paths = { { { .68, .23 }, { .31, .60 }, { .31, .73 }, { .42, .79 }, { .52, .73 }, { .82, .43 }, { .82, .23 }, { .7, .11 }, { .54, .11 }, { .17, .48 }, { .17, .75 }, { .33, .9 }, { .57, .9 }, { .77, .7 } } }
	elseif key == "Image" then
		paths = { { { .12, .15 }, { .88, .15 }, { .88, .85 }, { .12, .85 }, { .12, .15 } }, { { .15, .74 }, { .4, .49 }, { .57, .66 }, { .71, .52 }, { .86, .68 } }, circle(.67, .35, .08) }
	elseif key == "Lightbulb" then
		paths = { circle(.5, .36, .25, -210, 30), { { .28, .49 }, { .38, .66 }, { .62, .66 }, { .72, .49 } }, { { .38, .76 }, { .62, .76 } }, { { .43, .86 }, { .57, .86 } } }
	elseif key == "Shield" then
		paths = { { { .5, .1 }, { .83, .24 }, { .79, .6 }, { .67, .79 }, { .5, .9 }, { .33, .79 }, { .21, .6 }, { .17, .24 }, { .5, .1 } } }
	elseif key == "Robot" then
		paths = { { { .18, .28 }, { .82, .28 }, { .82, .8 }, { .18, .8 }, { .18, .28 } }, { { .5, .28 }, { .5, .1 } }, { { .3, .46 }, { .34, .46 } }, { { .66, .46 }, { .7, .46 } }, { { .34, .65 }, { .66, .65 } } }
	else
		return false
	end
	label.Text = ""
	local drawing = Instance.new("Frame")
	drawing.Name = "Drawing"
	drawing.AnchorPoint = Vector2.new(.5, .5)
	drawing.Position = UDim2.fromScale(.5, .5)
	drawing.Size = UDim2.fromOffset(label.TextSize, label.TextSize)
	Theme.passThrough(drawing)
	drawing.Parent = label
	for _, path in paths do
		for index = 2, #path do
			local a, b = path[index - 1], path[index]
			local dx, dy = b[1] - a[1], b[2] - a[2]
			local segment = Instance.new("Frame")
			segment.Name = "IconStroke"
			segment.AnchorPoint = Vector2.new(.5, .5)
			segment.Position = UDim2.fromScale((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
			segment.Size = UDim2.new(math.sqrt(dx * dx + dy * dy), 0, 0, 1.4)
			segment.Rotation = math.deg(math.atan2(dy, dx))
			segment.BackgroundColor3 = label.TextColor3
			segment.BorderSizePixel = 0
			segment.Parent = drawing
		end
	end
	return true
end

function Icons.setGlyph(label: TextLabel, key: string)
	if label:GetAttribute("IconKey") == key then return end
	local old = label:FindFirstChild("Drawing")
	if old then old:Destroy() end
	label:SetAttribute("IconKey", key)
	label.Text = ""
	if not drawLineIcon(label, key) then label.Text = "?" end
end

--- Creates a square icon host containing native strokes; no font is needed.
function Icons.glyph(key: string, size: number?, color: Color3?): (TextLabel, string)
	local fontSize = size or Theme.TextSizes.BodyLarge
	local text = ""
	local label = Theme.label("", {
		size = fontSize,
		color = color or Theme.Colors.SecondaryText,
		font = Theme.Fonts.Medium,
		alignX = Enum.TextXAlignment.Center,
	})
	label.Name = key .. "Icon"
	label.TextTransparency = 0
	label.Size = UDim2.fromOffset(fontSize, fontSize)
	Icons.setGlyph(label, key)
	label:GetPropertyChangedSignal("TextColor3"):Connect(function()
		local drawing = label:FindFirstChild("Drawing")
		if drawing then
			for _, segment in drawing:GetChildren() do (segment :: Frame).BackgroundColor3 = label.TextColor3 end
		end
	end)
	return label, text
end

--- Keep icon and caption in one measured row, centred inside the button.
function Icons.setButton(button: TextButton, key: string, caption: string?)
	button.Text = caption or ""
	button.TextTransparency = 1
	local content = button:FindFirstChild("ButtonContent") :: Frame?
	if not content then
		for _, child in button:GetChildren() do if child:IsA("UIPadding") then child:Destroy() end end
		content = Instance.new("Frame")
		content.Name = "ButtonContent"
		content.Size = UDim2.fromScale(1, 1)
		Theme.passThrough(content)
		content.Parent = button
		local layout = Theme.listLayout(6, Enum.FillDirection.Horizontal)
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Parent = content
		local icon = Icons.glyph(key, 14, button.TextColor3)
		icon.Name = "ButtonIcon"
		icon.LayoutOrder = 1
		icon.Parent = content
		local text = Theme.label("", { size = button.TextSize })
		text.Name = "Caption"
		text.LayoutOrder = 2
		text.TextTruncate = Enum.TextTruncate.AtEnd
		text.Parent = content
		local function refresh()
			if not content or not content.Parent then return end
			icon.TextColor3 = button.TextColor3
			text.Text = button.Text
			text.TextSize = button.TextSize
			text.Font = button.Font
			text.TextColor3 = button.TextColor3
			text.Visible = button.Text ~= ""
			layout.Padding = UDim.new(0, if text.Visible then 6 else 0)
			layout.HorizontalAlignment = if button.TextXAlignment == Enum.TextXAlignment.Left then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Center
			local bounds = TextService:GetTextSize(button.Text, button.TextSize, button.Font, Vector2.new(10000, 1000))
			text.Size = UDim2.fromOffset(math.min(bounds.X, math.max(0, button.AbsoluteSize.X - 28)), math.max(16, button.TextSize + 3))
		end
		for _, property in { "Text", "TextColor3", "TextSize", "Font", "TextXAlignment", "AbsoluteSize" } do button:GetPropertyChangedSignal(property):Connect(refresh) end
		refresh()
	end
	Icons.setGlyph(content:FindFirstChild("ButtonIcon") :: TextLabel, key)
end

--=============================================================================
-- BRAND MARK
--=============================================================================
-- A minimalist forge anvil / geometric hammer drawn with primitives so the
-- toolbar and header share one crisp identity.

local BRAND_COLOR = Theme.Colors.Highlight

function Icons.brandMark(size: number): Frame
	local s = size or 24
	local root = Instance.new("Frame")
	root.Name = "ForgePilotMark"
	root.Size = UDim2.fromOffset(s, s)
	root.BackgroundTransparency = 1
	root.ClipsDescendants = false

	local function piece(props: { [string]: any }): Frame
		local f = Theme.create("Frame", {
			BackgroundColor3 = BRAND_COLOR,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
		})
		for k, v in props do
			(f :: any)[k] = v
		end
		Theme.corner(math.max(1, math.floor(s * 0.08))).Parent = f
		f.Parent = root
		return f
	end

	-- Anvil top plate
	piece({
		Position = UDim2.fromScale(0.5, 0.34),
		Size = UDim2.fromScale(0.82, 0.22),
		Rotation = -12,
	})
	-- Anvil waist
	piece({
		Position = UDim2.fromScale(0.46, 0.58),
		Size = UDim2.fromScale(0.30, 0.16),
		Rotation = -12,
	})
	-- Anvil base
	piece({
		Position = UDim2.fromScale(0.5, 0.80),
		Size = UDim2.fromScale(0.66, 0.16),
	})
	-- Spark highlight, offset for depth
	local spark = piece({
		Position = UDim2.fromScale(0.76, 0.20),
		Size = UDim2.fromScale(0.14, 0.14),
		Rotation = 45,
	})
	spark.BackgroundColor3 = BRAND_COLOR:Lerp(Color3.new(1, 1, 1), 0.45)

	return root
end

return Icons
