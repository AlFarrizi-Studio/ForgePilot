--!strict
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local AttachmentEncoder = require(script.Parent.Parent.AI.AttachmentEncoder)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local ProviderLogo = require(script.Parent.Parent.Utilities.ProviderLogo)

local ChatInput = {}
function ChatInput.build(options: any): (Frame, any)
	local frame = Instance.new("Frame")
	frame.Name = "ChatInput"
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = Theme.Colors.Secondary
	frame.BorderSizePixel = 0
	Theme.corner(14).Parent = frame
	local stroke = Theme.stroke(Theme.Extra.BorderStrong)
	stroke.Parent = frame
	Theme.padding(8).Parent = frame
	Theme.listLayout(6).Parent = frame

	local attachments = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	attachments.Name = "Attachments"
	attachments.Size = UDim2.new(1, 0, 0, 28)
	attachments.LayoutOrder = 1
	attachments.Visible = false
	attachments.Active = true
	attachments.Parent = frame
	Theme.listLayout(4).Parent = attachments

	local box = Theme.input("Ask ForgePilot anything about your place…", { multiLine = true, height = 54 })
	box.Name = "Input"
	-- Let Studio submit Return natively, even if its docked window does not
	-- forward InputBegan. Shift+Return inserts a newline explicitly below.
	box.MultiLine = false
	box.BackgroundTransparency = 1
	box.TextSize = Theme.TextSizes.Body
	box.LayoutOrder = 2
	box.Parent = frame
	local innerStroke = box:FindFirstChildOfClass("UIStroke")
	if innerStroke then innerStroke.Transparency = 1 end

	local toolbar = Instance.new("Frame")
	toolbar.Name = "Toolbar"
	toolbar.Size = UDim2.new(1, 0, 0, 32)
	Theme.passThrough(toolbar)
	toolbar.LayoutOrder = 3
	toolbar.Parent = frame
	local layout = Theme.listLayout(4, Enum.FillDirection.Horizontal)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = toolbar
	local function tool(name: string, text: string, width: number, order: number): TextButton
		local button = Theme.textButton(text, { height = 28, width = UDim2.fromOffset(width, 28) })
		button.Name = name
		button.TextSize = 11
		button.BackgroundTransparency = 1
		button.TextColor3 = Theme.Colors.SecondaryText
		button.LayoutOrder = order
		button.Parent = toolbar
		Theme.flexItem(button, 0, 0)
		return button
	end
	local attach = tool("Attach", "", 28, 1)
	Icons.setButton(attach, "Attach")
	attach.TextSize = 22
	local modeButton = tool("Mode", "Plan", 62, 2)
	Icons.setButton(modeButton, "ChevronDown", "Plan")
	modeButton.BackgroundTransparency = 0
	modeButton.BackgroundColor3 = Theme.Extra.SurfaceRaised
	local provider = tool("Provider", "Set up AI", 0, 3)
	provider.TextTruncate = Enum.TextTruncate.AtEnd
	provider.TextXAlignment = Enum.TextXAlignment.Left
	Theme.flexItem(provider, 1, 1)
	Icons.setButton(provider, "ProviderCustom", "Set up AI")
	local action = tool("Send", "", 32, 4)
	Icons.setButton(action, "Send")
	action.Size = UDim2.fromOffset(32, 32)
	action.BackgroundTransparency = 0
	action.TextSize = 21
	Theme.corner(10).Parent = action

	local hint = Theme.label("Enter to send · Shift+Enter for a new line", { size = 10, color = Theme.Extra.Muted })
	hint.Name = "Hint"
	hint.Size = UDim2.new(1, 0, 0, 14)
	hint.LayoutOrder = 4
	hint.Parent = frame

	local mode = "build"
	local submitting = false
	local enabled = true
	local busyOverride = false
	local destroyed = false
	local leftShiftDown, rightShiftDown = false, false
	local maxHeight = 110
	local function busy(): boolean return busyOverride or StateManager.isBusy() end
	local function setMode(value: string)
		mode = if value:lower() == "build" then "build" else "plan"
		Icons.setButton(modeButton, "ChevronDown", if mode == "build" then "Build" else "Plan")
		modeButton.TextColor3 = if mode == "build" then Theme.Extra.Warning else Theme.Colors.SecondaryText
	end
	local function resize()
		local width = math.max(120, box.AbsoluteSize.X - 20)
		local text = if #box.Text > 0 then box.Text else " "
		local bounds = TextService:GetTextSize(text, box.TextSize, box.Font, Vector2.new(width, 100000))
		local height = math.clamp(bounds.Y + 16, 48, maxHeight)
		if box.Size.Y.Offset ~= height then box.Size = UDim2.new(1, 0, 0, height) end
	end
	local function refresh()
		if destroyed then return end
		local working = busy()
		local hasText = StringUtil.trim(box.Text) ~= ""
		action.Name = if working then "Stop" else "Send"
		Icons.setButton(action, if working then "Stop" else "Send")
		action.TextSize = if working then 12 else 21
		action.BackgroundColor3 = if working then Theme.Extra.SurfaceRaised elseif hasText then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised
		action.TextColor3 = if working or not hasText then Theme.Colors.SecondaryText else Theme.Colors.Background
		action.Active = working or (enabled and hasText)
		action.Selectable = action.Active
		attach.Active = enabled and not working
		modeButton.Active = enabled and not working
		provider.Active = enabled and not working
		stroke.Color = if box:IsFocused() then Theme.Colors.Highlight else Theme.Extra.BorderStrong
	end
	local function send(textOverride: string?)
		if destroyed or submitting or busy() or not enabled then return end
		local text = StringUtil.trim(textOverride or box.Text)
		if text == "" then return end
		submitting = true
		local ok, accepted = pcall(options.onSend, text)
		if ok and accepted ~= false then
			box.Text = ""
		elseif not ok then
			EventBus.emit(EventBus.Events.Toast, { kind = "error", message = "Could not send the message. " .. tostring(accepted) })
		end
		submitting = false
		resize()
		refresh()
	end
	local function isShift(): boolean
		return leftShiftDown or rightShiftDown or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end
	local keyboardConnections: { RBXScriptConnection } = {}
	local boundGui: Instance? = nil
	local enterPending = false
	local function enter(newLine: boolean)
		if destroyed or enterPending then return end
		enterPending = true
		local text = box.Text
		local cursor = if box.CursorPosition > 0 then math.clamp(box.CursorPosition, 1, #text + 1) else #text + 1
		local selection = box.SelectionStart
		local first, last = cursor, cursor
		if selection and selection > 0 then
			selection = math.clamp(selection, 1, #text + 1)
			first, last = math.min(cursor, selection), math.max(cursor, selection)
		end
		-- Release before the native text edit, then apply exactly one action.
		-- This also deduplicates TextBox, PluginGui and FocusLost delivery.
		box:ReleaseFocus(false)
		task.defer(function()
			if not destroyed then
				if newLine then
					box.Text = text:sub(1, first - 1) .. "\n" .. text:sub(last)
					box:CaptureFocus()
					box.CursorPosition = first + 1
					box.SelectionStart = -1
				else
					send(text)
				end
			end
			enterPending = false
		end)
	end
	local function inputBegan(key: InputObject)
		if key.KeyCode == Enum.KeyCode.LeftShift then leftShiftDown = true end
		if key.KeyCode == Enum.KeyCode.RightShift then rightShiftDown = true end
		if (key.KeyCode == Enum.KeyCode.Return or key.KeyCode == Enum.KeyCode.KeypadEnter) and box:IsFocused() then
			enter(isShift())
		end
	end
	local function inputEnded(key: InputObject)
		if key.KeyCode == Enum.KeyCode.LeftShift then leftShiftDown = false end
		if key.KeyCode == Enum.KeyCode.RightShift then rightShiftDown = false end
	end
	box.InputBegan:Connect(inputBegan)
	box.InputEnded:Connect(inputEnded)
	keyboardConnections[#keyboardConnections + 1] = UserInputService.InputBegan:Connect(inputBegan)
	keyboardConnections[#keyboardConnections + 1] = UserInputService.InputEnded:Connect(inputEnded)
	local globalKeyboardConnections = keyboardConnections
	keyboardConnections = {}
	local function bindKeyboard()
		local gui = frame:FindFirstAncestorWhichIsA("PluginGui")
		if gui == boundGui then return end
		for _, connection in keyboardConnections do connection:Disconnect() end
		keyboardConnections = {}
		boundGui = gui
		if gui then
			keyboardConnections[#keyboardConnections + 1] = (gui :: any).InputBegan:Connect(inputBegan)
			keyboardConnections[#keyboardConnections + 1] = (gui :: any).InputEnded:Connect(inputEnded)
		end
	end
	frame.AncestryChanged:Connect(bindKeyboard)

	box.FocusLost:Connect(function(enterPressed)
		if enterPressed and not enterPending then enter(isShift()) end
		if not enterPending then leftShiftDown, rightShiftDown = false, false end
		refresh()
	end)
	box.Focused:Connect(refresh)
	box:GetPropertyChangedSignal("Text"):Connect(function() resize(); refresh() end)
	box:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	action.MouseButton1Click:Connect(function()
		if busy() then options.onStop() else send() end
	end)
	attach.MouseButton1Click:Connect(function() if enabled and not busy() then options.onPickFiles() end end)
	provider.MouseButton1Click:Connect(function() if not busy() then options.onOpenSettings() end end)
	modeButton.MouseButton1Click:Connect(function()
		if not enabled or busy() then return end
		setMode(if mode == "plan" then "build" else "plan")
		options.onModeChange(mode)
	end)

	local function renderAttachments()
		for _, child in attachments:GetChildren() do if child:IsA("GuiObject") then child:Destroy() end end
		local count = 0
		for _, attachment in AttachmentEncoder.getAll() do
			if not attachment.accepted then continue end
			count += 1
			local row = Instance.new("Frame")
			row.Name = "Attachment_" .. attachment.id
			row.Size = UDim2.new(1, -6, 0, 24)
			row.LayoutOrder = count
			row.BorderSizePixel = 0
			row.BackgroundColor3 = Theme.Extra.SurfaceRaised
			row.Parent = attachments
			Theme.corner(6).Parent = row
			local label = Theme.label(attachment.name, { size = 11 })
			label.Position = UDim2.fromOffset(8, 0)
			label.Size = UDim2.new(1, -38, 1, 0)
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.Parent = row
			local remove = Theme.textButton("", { height = 22, width = UDim2.fromOffset(24, 22) })
			Icons.setButton(remove, "Close")
			remove.Name = "Remove"
			remove.BackgroundTransparency = 1
			remove.AnchorPoint = Vector2.new(1, 0)
			remove.Position = UDim2.new(1, -2, 0, 1)
			remove.Parent = row
			remove.MouseButton1Click:Connect(function() if not busy() then AttachmentEncoder.remove(attachment.id) end end)
		end
		attachments.Visible = count > 0
		attachments.Size = UDim2.new(1, 0, 0, math.min(80, count * 28 - 4))
	end
	local unsubs = {
		EventBus.on(EventBus.Events.AttachmentsChanged, renderAttachments),
		EventBus.on(EventBus.Events.StateChanged, refresh),
	}
	setMode("build")
	refresh()
	renderAttachments()
	return frame, {
		frame = frame, focus = function() box:CaptureFocus() end,
		setText = function(text: string) box.Text = text end,
		getText = function() return box.Text end, setMode = setMode,
		setBusy = function(value: boolean) busyOverride = value; refresh() end,
		setMaxHeight = function(value: number) maxHeight = math.max(48, value); resize() end,
		setProvider = function(text: string, color: Color3, iconId: string?)
			provider.Text = text; provider.TextColor3 = color
			local content = provider:FindFirstChild("ButtonContent")
			local icon = content and content:FindFirstChild("ButtonIcon")
			if icon then
				local old = icon:FindFirstChild("ProviderMark"); if old then old:Destroy() end
				local drawing = icon:FindFirstChild("Drawing"); if drawing then drawing.Visible = not iconId end
				if iconId then
					local mark = ProviderLogo.build(iconId, 16); mark.Name = "ProviderMark"; mark.Parent = icon
				end
			end
		end,
		setEnabled = function(value: boolean) enabled = value; refresh() end,
		setPlaceholder = function(text: string) box.PlaceholderText = text end,
		refreshAttachments = renderAttachments,
		destroy = function() destroyed = true; for _, unsubscribe in unsubs do unsubscribe() end; for _, connection in keyboardConnections do connection:Disconnect() end; for _, connection in globalKeyboardConnections do connection:Disconnect() end end,
	}
end
return ChatInput
