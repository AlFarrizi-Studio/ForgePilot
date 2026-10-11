--!strict
--[[
	ForgePilot / Utilities / Theme
	Central design tokens and UI construction helpers.
	All colours, spacing, radii and motion live here so the interface stays consistent.
]]

local TweenService = game:GetService("TweenService")
local Theme = {}

--=============================================================================
-- COLOUR PALETTE
--=============================================================================

Theme.Colors = {
	Background = Color3.fromHex("#17161C"),
	Secondary = Color3.fromHex("#222027"),
	Accent = Color3.fromHex("#2C2331"),
	Highlight = Color3.fromHex("#9879E8"),
	MainText = Color3.fromHex("#F4F1F8"),
	SecondaryText = Color3.fromHex("#A7A0B2"),
	Success = Color3.fromHex("#49C591"),
	Error = Color3.fromHex("#F16E7A"),
}

-- Derived / supporting tones. Kept explicit so contrast can be tuned in one place.
Theme.Extra = {
	Surface = Color3.fromHex("#1D1B23"),
	SurfaceRaised = Color3.fromHex("#292630"),
	SurfaceHover = Color3.fromHex("#34303D"),
	SurfacePressed = Color3.fromHex("#3E3350"),
	Overlay = Color3.fromHex("#0E0C12"),
	Border = Color3.fromHex("#34303C"),
	BorderStrong = Color3.fromHex("#463B56"),
	HighlightSoft = Color3.fromHex("#3A2F4C"),
	Warning = Color3.fromHex("#E8B661"),
	Info = Color3.fromHex("#6FA8DC"),
	Muted = Color3.fromHex("#9992A4"),
}

Theme.Metrics = {
	RowHeight = 30,
	InputHeight = 30,
	ButtonHeight = 30,
	PrimaryButtonHeight = 34,
	TabHeight = 26,
	SectionTabHeight = 28,
	HeaderHeight = 44,
	NavHeight = 34,
	ToggleWidth = 38,
	ToggleHeight = 20,
	ToggleKnob = 16,
	MinButtonWidth = 64,
	Radius = 8,
	RadiusSmall = 6,
	RadiusLarge = 12,
	Gutter = 10,
	PadX = 12,
	PadY = 10,
	Stroke = 1,
	ScrollThickness = 5,
}

--=============================================================================
-- SPACING SCALE
--=============================================================================
-- A closed scale. Every gap, inset and row height in the interface comes from
-- here, which is what stops "close enough" spacing from drifting apart across
-- five screens built by five different files.

Theme.Space = {
	XS = 4,
	SM = 8,
	MD = 12,
	LG = 16,
	XL = 20,
	XXL = 24,
}

--=============================================================================
-- RESPONSIVE BREAKPOINTS
--=============================================================================
-- The DockWidget can be docked as narrow as 240px and as wide as the whole
-- editor. Widths below these thresholds switch padding, navigation density and
-- field stacking. They are content widths (the window minus its gutter).

Theme.Breakpoints = {
	Compact = 380,
	Medium = 560,
}

export type Bucket = "compact" | "medium" | "wide"

--- Maps a window width to the responsive bucket used by every view.
function Theme.bucketFor(width: number): Bucket
	if width < Theme.Breakpoints.Compact then
		return "compact"
	elseif width < Theme.Breakpoints.Medium then
		return "medium"
	end
	return "wide"
end

--- Horizontal page inset, tightened on narrow windows.
function Theme.gutterFor(width: number): number
	local bucket = Theme.bucketFor(width)
	if bucket == "compact" then
		return Theme.Space.SM
	elseif bucket == "medium" then
		return Theme.Space.MD
	end
	return Theme.Space.LG
end

--- True when a field should stack its control under its label instead of
--- placing it on the right-hand side.
function Theme.shouldStackField(width: number): boolean
	return width < Theme.Breakpoints.Medium
end

Theme.Fonts = {
	Regular = Enum.Font.Gotham,
	Medium = Enum.Font.GothamMedium,
	Bold = Enum.Font.GothamBold,
	Code = Enum.Font.Code,
	Mono = Enum.Font.RobotoMono,
	Icon = Enum.Font.GothamBold,
}

Theme.TextSizes = {
	Caption = 11,
	Small = 12,
	Body = 14,
	BodyLarge = 15,
	Title = 16,
	Heading = 18,
}

Theme.Motion = {
	Fast = 0.10,
	Normal = 0.18,
	Slow = 0.30,
	Fade = Enum.EasingStyle.Quad,
	Out = Enum.EasingDirection.Out,
	In = Enum.EasingDirection.In,
	OutBack = Enum.EasingDirection.Out,
}

Theme.motionEnabled = true

Theme.LoggerPrefix = "[ForgePilot] "

--=============================================================================
-- COLOUR UTILITIES
--=============================================================================

--- Mixes two colours. `alpha` of 0 returns `a`, 1 returns `b`.
function Theme.mix(a: Color3, b: Color3, alpha: number): Color3
	return a:Lerp(b, math.clamp(alpha, 0, 1))
end

--- Tints `color` toward the window background.
--
-- Roblox's Color3 has no alpha channel, and `Color3.new(r, g, b, alpha)` silently
-- drops the fourth argument. Translucency therefore has to be expressed by
-- pre-mixing the colour against the background it will be drawn over, which is
-- what the interface actually means by "10% highlight" and friends.
-- `alpha` of 0 returns the background, 1 returns `color` unchanged.
function Theme.withAlpha(color: Color3, alpha: number): Color3
	local amount = math.clamp(alpha, 0, 1)
	if amount >= 1 then
		return color
	end
	return color:Lerp(Theme.Colors.Background, 1 - amount)
end

--- Lightens a colour toward white by `amount` (0..1).
function Theme.lighten(color: Color3, amount: number): Color3
	return Theme.mix(color, Color3.new(1, 1, 1), amount)
end

--- Darkens a colour toward black by `amount` (0..1).
function Theme.darken(color: Color3, amount: number): Color3
	return Theme.mix(color, Color3.new(0, 0, 0), amount)
end

--=============================================================================
-- UI CONSTRUCTION HELPERS
--=============================================================================

function Theme.create(className: string, properties: { [string]: any }?): Instance
	local instance = Instance.new(className)
	if properties then
		for key, value in properties do
			(instance :: any)[key] = value
		end
	end
	return instance
end

function Theme.corner(radius: number?): UICorner
	return Theme.create("UICorner", {
		CornerRadius = UDim.new(0, radius or Theme.Metrics.Radius),
	})
end

function Theme.stroke(color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Theme.create("UIStroke", {
		Color = color or Theme.Extra.Border,
		Thickness = thickness or Theme.Metrics.Stroke,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

--- Creates a gradient used for panel headers and the brand strip.
function Theme.gradient(c1: Color3, c2: Color3, rotation: number?): UIGradient
	return Theme.create("UIGradient", {
		Color = ColorSequence.new(c1, c2),
		Rotation = rotation or 90,
	})
end

--- Applies a background + rounded corners + optional stroke in one call.
function Theme.surface(guiObject: GuiObject, options: { color: Color3?, radius: number?, stroke: Color3? }?)
	local opts = options or {}
	guiObject.BackgroundColor3 = opts.color or Theme.Extra.Surface
	guiObject.BorderSizePixel = 0
	guiObject.ClipsDescendants = true
	local corner = Theme.corner(opts.radius or Theme.Metrics.Radius)
	corner.Parent = guiObject
	if opts.stroke then
		local s = Theme.stroke(opts.stroke)
		s.Parent = guiObject
	end
	return guiObject
end

--=============================================================================
-- TYPOGRAPHY HELPERS
--=============================================================================

function Theme.label(text: string, options: {
	size: number?,
	color: Color3?,
	font: Enum.Font?,
	alignX: Enum.TextXAlignment?,
	alignY: Enum.TextYAlignment?,
	wrap: boolean?,
	textX: Enum.TextXAlignment?,
	truncate: boolean?,
	rich: boolean?,
	width: UDim2?,
	height: UDim2?,
}?): TextLabel
	local o = options or {}
	local textWrapped = if o.wrap ~= nil then o.wrap else false
	local label = Theme.create("TextLabel", {
		BackgroundTransparency = 1,
		Size = o.width or UDim2.new(1, 0, 0, 18),
		Text = text,
		TextSize = o.size or Theme.TextSizes.Body,
		TextColor3 = o.color or Theme.Colors.MainText,
		Font = o.font or Theme.Fonts.Regular,
		TextXAlignment = o.alignX or Enum.TextXAlignment.Left,
		TextYAlignment = o.alignY or Enum.TextYAlignment.Center,
		TextTruncate = if o.truncate then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None,
		TextWrapped = textWrapped,
		RichText = o.rich == true,
	})
	if o.height then
		label.Size = UDim2.new(label.Size.X.Scale, label.Size.X.Offset, o.height.Y.Scale, o.height.Y.Offset)
	end
	return label
end

--- A label that owns its own height.
---
--- Every description, hint and paragraph in ForgePilot goes through this: it
--- measures itself and grows, so a three-line hint can never be painted over
--- the control below it. A TextLabel with a fixed height and TextWrapped is the
--- single most common source of overlapping text in a Roblox GUI, so the
--- design system simply does not expose one.
function Theme.autoText(text: string, options: {
	size: number?,
	color: Color3?,
	font: Enum.Font?,
	alignX: Enum.TextXAlignment?,
	alignY: Enum.TextYAlignment?,
	rich: boolean?,
	minHeight: number?,
	width: UDim2?,
}?): TextLabel
	local o = options or {}
	local fontSize = o.size or Theme.TextSizes.Small
	local label = Theme.label(text, {
		size = fontSize,
		color = o.color or Theme.Colors.SecondaryText,
		font = o.font or Theme.Fonts.Regular,
		alignX = o.alignX,
		alignY = o.alignY or Enum.TextYAlignment.Top,
		rich = o.rich,
		width = o.width or UDim2.new(1, 0, 0, 0),
	})
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.TextWrapped = true
	label.TextTruncate = Enum.TextTruncate.None
	label.Name = "AutoText"
	-- Guarantee the box is at least one full line tall. Roblox clips a
	-- GuiObject's own contents to its rectangle, so a label whose measured
	-- height lands a couple of pixels under its line box loses its descenders.
	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(0, o.minHeight or math.ceil(fontSize * 1.3))
	constraint.Parent = label
	return label
end

function Theme.textButton(text: string, options: {
	size: number?,
	color: Color3?,
	hoverColor: Color3?,
	pressedColor: Color3?,
	font: Enum.Font?,
	height: number?,
	width: UDim2?,
	textColor: Color3?,
	autoButtonColor: boolean?,
	alignX: Enum.TextXAlignment?,
	truncate: boolean?,
	radius: number?,
}?): TextButton
	local o = options or {}
	local baseColor = o.color or Theme.Extra.SurfaceRaised
	local button = Theme.create("TextButton", {
		BackgroundColor3 = baseColor,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = text,
		TextSize = o.size or Theme.TextSizes.Body,
		TextColor3 = o.textColor or Theme.Colors.MainText,
		Font = o.font or Theme.Fonts.Medium,
		TextXAlignment = o.alignX or Enum.TextXAlignment.Center,
		TextWrapped = false,
		TextTruncate = if o.truncate then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None,
		Size = o.width or UDim2.new(1, 0, 0, o.height or Theme.Metrics.ButtonHeight),
	})
	-- Clipped so a long label can never paint over the control next to it.
	button.ClipsDescendants = true
	local c = Theme.corner(o.radius or Theme.Metrics.RadiusSmall)
	c.Parent = button
	Theme.stroke(nil, 1, 0.25).Parent = button

	button.MouseEnter:Connect(function()
		TweenService:Create(
			button,
			TweenInfo.new(Theme.Motion.Fast, Theme.Motion.Fade, Theme.Motion.Out),
			{ BackgroundColor3 = o.hoverColor or Theme.Extra.SurfaceHover }
		):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(
			button,
			TweenInfo.new(Theme.Motion.Fast, Theme.Motion.Fade, Theme.Motion.Out),
			{ BackgroundColor3 = baseColor }
		):Play()
	end)
	return button
end

--- Lets a child of a horizontal UIListLayout give up width when the row would
--- otherwise overflow its parent. This is the anti-overflow rule: a row of
--- buttons shrinks instead of running past the edge of a 320px window.
function Theme.flexItem(guiObject: GuiObject, growRatio: number?, shrinkRatio: number?): UIFlexItem
	local item = guiObject:FindFirstChildOfClass("UIFlexItem")
	if not item then
		item = Instance.new("UIFlexItem")
		item.Parent = guiObject
	end
	-- Custom is the only mode that honours both ratios. Fill ignores them,
	-- which made fixed buttons grow and the transcript lose its available space.
	item.FlexMode = Enum.UIFlexMode.Custom
	item.GrowRatio = if growRatio ~= nil then math.max(0, growRatio) else 1
	item.ShrinkRatio = if shrinkRatio ~= nil then math.max(0, shrinkRatio) else 1
	return item :: UIFlexItem
end

function Theme.minSize(guiObject: GuiObject, minimum: Vector2): UISizeConstraint
	local constraint = guiObject:FindFirstChildOfClass("UISizeConstraint")
	if not constraint then
		constraint = Instance.new("UISizeConstraint")
		constraint.Parent = guiObject
	end
	constraint.MinSize = minimum
	return constraint :: UISizeConstraint
end

--- Marks a frame as a pure layout container.
---
--- Roblox makes ANY Active GuiObject hit-testable, including a fully
--- transparent full-width Frame. Layout containers therefore silently swallow
--- clicks meant for whatever sits behind them — the chat composer covering the
--- empty-state button was exactly this bug. Every structural frame ForgePilot
--- creates for layout calls this.
---
--- It also clears the background. Roblox gives every GuiObject a visible light
--- gray (#B7B5B8) and an Active hitbox by default, so a structural frame left
--- alone both repaints the theme away and covers the controls underneath it.
--- The Builder's full-height stack rendering the whole page white and the
--- Settings stack doing the same were both this bug.
function Theme.passThrough(guiObject: GuiObject)
	-- Only ever raises transparency; it never sets a colour, so a caller that
	-- wants a visible surface opts back in after calling this.
	if guiObject.BackgroundTransparency < 1 then
		guiObject.BackgroundTransparency = 1
	end
	guiObject.Active = guiObject:IsA("ScrollingFrame")
	guiObject.Selectable = false
	guiObject.BorderSizePixel = 0
	return guiObject
end

function Theme.input(placeholder: string, options: { multiLine: boolean?,
	height: number?,
	alignX: Enum.TextXAlignment?,
}?): TextBox
	local o = options or {}
	local box = Theme.create("TextBox", {
		BackgroundColor3 = Theme.Extra.Surface,
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.Extra.Muted,
		TextColor3 = Theme.Colors.MainText,
		TextSize = Theme.TextSizes.Body,
		Font = Theme.Fonts.Regular,
		ClearTextOnFocus = false,
		TextXAlignment = o.alignX or Enum.TextXAlignment.Left,
		TextYAlignment = if o.multiLine then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		TextWrapped = o.multiLine == true,
		MultiLine = o.multiLine == true,
		Size = UDim2.new(1, 0, 0, o.height or Theme.Metrics.InputHeight),
	})
	Theme.padding4(6, 10, 6, 10).Parent = box
	-- A long Base URL or Model ID must scroll inside the box, never escape it.
	box.ClipsDescendants = true
	Theme.corner(Theme.Metrics.RadiusSmall).Parent = box
	local stroke = Theme.stroke(Theme.Extra.Border)
	stroke.Parent = box
	box.Focused:Connect(function()
		stroke.Color = Theme.Colors.Highlight
	end)
	box.FocusLost:Connect(function()
		stroke.Color = Theme.Extra.Border
	end)
	return box
end

function Theme.padding(all: number?): UIPadding
	return Theme.create("UIPadding", {
		PaddingTop = UDim.new(0, all or Theme.Metrics.PadY),
		PaddingBottom = UDim.new(0, all or Theme.Metrics.PadY),
		PaddingLeft = UDim.new(0, all or Theme.Metrics.PadX),
		PaddingRight = UDim.new(0, all or Theme.Metrics.PadX),
	})
end

--- Asymmetric padding (top, right, bottom, left).
function Theme.padding4(top: number, right: number, bottom: number, left: number): UIPadding
	return Theme.create("UIPadding", {
		PaddingTop = UDim.new(0, top),
		PaddingBottom = UDim.new(0, bottom),
		PaddingLeft = UDim.new(0, left),
		PaddingRight = UDim.new(0, right),
	})
end

--=============================================================================
-- OVERLAY LAYER
--=============================================================================

Theme.OverlayZIndex = 50

--- Returns the shared overlay frame for a view, creating it on first use.
---
--- Dropdown menus, toasts and modals are parented here rather than inside the
--- control that opened them. A menu parented to its own button is clipped by
--- every ScrollingFrame between the button and the window edge, which is why
--- dropdowns used to open half off-screen inside the Settings page.
---
--- An existing layer on any ancestor is reused. Nesting a fresh one inside a
--- control is actively harmful: an auto-sized field holder would see the new
--- full-scale overlay as content, grow to fit it, and the overlay would then
--- grow again -- a feedback loop that inflated whole Settings sections to
--- 100,000px. The window-level layer already spans the content area and is not
--- inside an auto-sized frame, so one per window is both correct and cheaper.
function Theme.overlayHost(parent: GuiObject): Frame
	local cursor: Instance? = parent
	while cursor do
		local existing = cursor:FindFirstChild("OverlayLayer")
		if existing and existing:IsA("Frame") then
			return existing
		end
		cursor = cursor.Parent
	end

	local overlay = Instance.new("Frame")
	overlay.Name = "OverlayLayer"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.ZIndex = Theme.OverlayZIndex
	overlay.Active = false
	overlay.ClipsDescendants = false
	overlay.Parent = parent

	-- Every floating child inherits the overlay's ZIndex band unless it asks for
	-- something higher, so a toast can still sit above a dropdown.
	local function inherit(node: Instance)
		for _, child in ipairs(node:GetChildren()) do
			if child:IsA("GuiObject") then
				child.ZIndex = math.max(child.ZIndex, Theme.OverlayZIndex)
			end
			inherit(child)
		end
	end
	overlay.DescendantAdded:Connect(function(child)
		if child:IsA("GuiObject") then
			child.ZIndex = math.max(child.ZIndex, Theme.OverlayZIndex)
		end
	end)
	inherit(overlay)

	return overlay
end

--- Reparents an existing floating widget into the overlay layer.
function Theme.raise(overlay: Frame, node: GuiObject, offset: number?)
	node.ZIndex = math.max(node.ZIndex, Theme.OverlayZIndex + (offset or 0))
end

function Theme.listLayout(padding: number?, direction: Enum.FillDirection?, sortOrder: Enum.SortOrder?): UIListLayout
	return Theme.create("UIListLayout", {
		Padding = UDim.new(0, padding or 4),
		FillDirection = direction or Enum.FillDirection.Vertical,
		SortOrder = sortOrder or Enum.SortOrder.LayoutOrder,
	})
end

function Theme.separator(): Frame
	local f = Theme.create("Frame", {
		BackgroundColor3 = Theme.Extra.Border,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	})
	return f
end

function Theme.scrollingFrame(options: {
	automaticCanvasSize: Enum.AutomaticSize?,
	layoutOrder: number?,
	scrollingDirection: Enum.ScrollingDirection?,
}?): ScrollingFrame
	local o = options or {}
	return Theme.create("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ScrollBarThickness = Theme.Metrics.ScrollThickness,
		ScrollBarImageColor3 = Theme.Extra.BorderStrong,
		ScrollBarImageTransparency = 0.25,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = o.automaticCanvasSize or Enum.AutomaticSize.None,
		LayoutOrder = o.layoutOrder or 0,
		ScrollingDirection = o.scrollingDirection or Enum.ScrollingDirection.Y,
	})
end

--=============================================================================
-- MOTION
--=============================================================================

function Theme.tween(instance: Instance, goal: { [string]: any }, duration: number?): Tween
	return TweenService:Create(
		instance,
		TweenInfo.new(if Theme.motionEnabled == false then 0 else (duration or Theme.Motion.Normal), Theme.Motion.Fade, Theme.Motion.Out),
		goal
	)
end

function Theme.fadeIn(instance: GuiObject, duration: number?): Tween
	return Theme.tween(instance, { BackgroundTransparency = 1, TextTransparency = 1, ImageTransparency = 1 }, 0)
end

return Theme
