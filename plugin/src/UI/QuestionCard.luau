--!strict
--[[
	ForgePilot / UI / QuestionCard
	Renders an interactive question inside the chat.

	Supports single choice, multiple choice, text, number, yes/no and
	confirmation, plus Custom Answer, Let AI Decide, Cancel and Submit.
]]

local Icons = require(script.Parent.Parent.Utilities.Icons)
local QuestionManager = require(script.Parent.Parent.AI.QuestionManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local Theme = require(script.Parent.Parent.Utilities.Theme)

local QuestionCard = {}

local colourFor = {
	single = Theme.Colors.Highlight,
	multiple = Theme.Colors.Highlight,
	text = Theme.Extra.Info,
	number = Theme.Extra.Info,
	boolean = Theme.Extra.Info,
	confirm = Theme.Extra.Warning,
}

--- Live input listeners, keyed by the card that owns them.
---
--- Roblox Instances reject new members ("cleanup is not a valid member of
--- Frame"), so the teardown hook cannot hang off the card itself. A weak table
--- lets `markAnswered` reach it later without threading an api table through
--- every caller.
local liveListeners: { [Frame]: any } = setmetatable({}, { __mode = "k" })

local function releaseListener(card: Frame)
	local listener = liveListeners[card]
	if listener then
		listener:Disconnect()
		liveListeners[card] = nil
	end
end

--- Builds the card. `question` comes from the QuestionAsked event.
function QuestionCard.build(question: any): (Frame, { [string]: any })
	local card = Instance.new("Frame")
	card.Name = "Question_" .. question.id
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Theme.Extra.Surface
	card.BorderSizePixel = 0
	card.LayoutOrder = 20
	card.ClipsDescendants = false
	Theme.corner(Theme.Metrics.Radius).Parent = card

	local accent = colourFor[question.kind] or Theme.Colors.Highlight
	local stroke = Theme.stroke(Theme.withAlpha(accent, 0.45))
	stroke.Parent = card

	Theme.padding(12).Parent = card

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	content.Parent = card
	Theme.listLayout(8).Parent = content

	-- Header -------------------------------------------------------------
	local headerRow = Instance.new("Frame")
	headerRow.Name = "Header"
	headerRow.Size = UDim2.new(1, 0, 0, 18)
	headerRow.BackgroundTransparency = 1
	headerRow.Parent = content

	local icon = Icons.glyph("Lightbulb", 13, accent)
	icon.Name = "Icon"
	icon.Size = UDim2.fromOffset(15, 15)
	icon.Parent = headerRow

	local kindLabel = Theme.label("Question · " .. tostring(question.kind):upper(), {
		size = Theme.TextSizes.Caption,
		font = Theme.Fonts.Bold,
		color = accent,
	})
	kindLabel.Name = "Kind"
	kindLabel.Position = UDim2.fromOffset(20, 0)
	kindLabel.Size = UDim2.new(1, -20, 1, 0)
	kindLabel.Parent = headerRow

	local promptLabel = Theme.label(question.prompt, {
		size = Theme.TextSizes.Body,
		font = Theme.Fonts.Medium,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	promptLabel.Name = "Prompt"
	promptLabel.Size = UDim2.new(1, 0, 0, 0)
	promptLabel.AutomaticSize = Enum.AutomaticSize.Y
	promptLabel.Parent = content

	local detailLabel: TextLabel? = nil
	if question.detail and #question.detail > 0 then
		detailLabel = Theme.label(question.detail, {
			size = Theme.TextSizes.Small,
			color = Theme.Colors.SecondaryText,
			alignY = Enum.TextYAlignment.Top,
			wrap = true,
		})
		detailLabel.Name = "Detail"
		detailLabel.Size = UDim2.new(1, 0, 0, 0)
		detailLabel.AutomaticSize = Enum.AutomaticSize.Y
		detailLabel.Parent = content
	end

	-- Selection state -----------------------------------------------------
	local selected: { [string]: boolean } = {}
	local optionButtons: { [string]: TextButton } = {}
	local customInput: TextBox? = nil
	local numberInput: TextBox? = nil
	local textInput: TextBox? = nil
	local submitted = false

	local function lock()
		if submitted then
			return
		end
		submitted = true
		card.BackgroundTransparency = 0.45
		for _, child in content:GetDescendants() do
			if child:IsA("TextButton") then
				child.Active = false
				child.AutoButtonColor = false
				child.BackgroundTransparency = 1
			elseif child:IsA("TextBox") then
				child.TextEditable = false
				child.BackgroundTransparency = 1
			end
		end
	end

	local function pill(text: string, isPrimary: boolean, order: number, callback: any): TextButton
		local button = Instance.new("TextButton")
		button.Name = text:gsub("%s+", "")
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(0, 28)
		button.AutomaticSize = Enum.AutomaticSize.X
		button.BackgroundColor3 = if isPrimary then Theme.Colors.Highlight else Theme.Extra.SurfaceRaised
		button.BorderSizePixel = 0
		button.Text = text
		button.TextColor3 = if isPrimary then Theme.Colors.Background else Theme.Colors.MainText
		button.TextSize = Theme.TextSizes.Small
		button.Font = if isPrimary then Theme.Fonts.Bold else Theme.Fonts.Medium
		button.Parent = content
		Theme.corner(Theme.Metrics.RadiusSmall).Parent = button
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 14)
		pad.PaddingRight = UDim.new(0, 14)
		pad.Parent = button

		local base = button.BackgroundColor3
		local hover = Theme.lighten(base, 0.12)
		button.MouseEnter:Connect(function()
			Theme.tween(button, { BackgroundColor3 = hover }, Theme.Motion.Fast):Play()
		end)
		button.MouseLeave:Connect(function()
			Theme.tween(button, { BackgroundColor3 = base }, Theme.Motion.Fast):Play()
		end)
		button.MouseButton1Click:Connect(callback)
		return button
	end

	-- Option list ---------------------------------------------------------
	if question.kind == "single" or question.kind == "multiple" then
		local list = Instance.new("Frame")
		list.Name = "Options"
		list.Size = UDim2.new(1, 0, 0, 0)
		list.AutomaticSize = Enum.AutomaticSize.Y
		list.BackgroundTransparency = 1
		list.Parent = content
		Theme.listLayout(5).Parent = list

		for index, option in (question.options or {}) do
			local optionButton = Instance.new("TextButton")
			optionButton.Name = "Option_" .. option.id
			optionButton.LayoutOrder = index
			optionButton.Size = UDim2.new(1, 0, 0, 0)
			optionButton.AutomaticSize = Enum.AutomaticSize.Y
			optionButton.BackgroundColor3 = Theme.Extra.SurfaceRaised
			optionButton.BorderSizePixel = 0
			optionButton.Text = ""
			optionButton.TextXAlignment = Enum.TextXAlignment.Left
			optionButton.Parent = list
			Theme.corner(Theme.Metrics.RadiusSmall).Parent = optionButton
			local optStroke = Theme.stroke(Theme.Extra.Border)
			optStroke.Parent = optionButton
			Theme.padding(9).Parent = optionButton

			local marker = Theme.label(question.kind == "multiple" and "☐" or "○", {
				size = Theme.TextSizes.Body,
				color = Theme.Extra.Muted,
			})
			marker.Name = "Marker"
			marker.Size = UDim2.fromOffset(16, 16)
			marker.Position = UDim2.fromOffset(9, 8)
			marker.Parent = optionButton

			local label = Theme.label(option.label, {
				size = Theme.TextSizes.Small,
				alignY = Enum.TextYAlignment.Top,
				wrap = true,
			})
			label.Name = "Label"
			label.Position = UDim2.fromOffset(30, 7)
			label.Size = UDim2.new(1, -40, 0, 0)
			label.AutomaticSize = Enum.AutomaticSize.Y
			label.Parent = optionButton

			if option.description and #option.description > 0 then
				local desc = Theme.label(option.description, {
					size = Theme.TextSizes.Caption,
					color = Theme.Extra.Muted,
					alignY = Enum.TextYAlignment.Top,
					wrap = true,
				})
				desc.Name = "Description"
				desc.Position = UDim2.fromOffset(30, 23)
				desc.Size = UDim2.new(1, -40, 0, 0)
				desc.AutomaticSize = Enum.AutomaticSize.Y
				desc.Parent = optionButton
			end

			optionButtons[option.id] = optionButton

			optionButton.MouseButton1Click:Connect(function()
				if question.kind == "single" then
					selected = {}
					for id, other in optionButtons do
						local otherMarker = other:FindFirstChild("Marker") :: TextLabel?
						if otherMarker then
							otherMarker.Text = if id == option.id then "●" else "○"
							otherMarker.TextColor3 = if id == option.id then accent else Theme.Extra.Muted
						end
						Theme.tween(other, {
							BackgroundColor3 = if id == option.id then Theme.withAlpha(accent, 0.16) else Theme.Extra.SurfaceRaised,
						}, Theme.Motion.Fast):Play()
					end
				else
					selected[option.id] = not (selected[option.id] or false)
					marker.Text = if selected[option.id] then "☑" else "☐"
					marker.TextColor3 = if selected[option.id] then accent else Theme.Extra.Muted
					Theme.tween(optionButton, {
						BackgroundColor3 = if selected[option.id] then Theme.withAlpha(accent, 0.16) else Theme.Extra.SurfaceRaised,
					}, Theme.Motion.Fast):Play()
				end
			end)

			optionButton.MouseEnter:Connect(function()
				Theme.tween(optionButton, { BackgroundColor3 = Theme.Extra.SurfaceHover }, Theme.Motion.Fast):Play()
			end)
			optionButton.MouseLeave:Connect(function()
				if question.kind == "single" then
					local isPicked = false
					for id in pairs(optionButtons) do
						if id == option.id and next(selected) ~= nil then
							-- fall through; the marker already reflects state
						end
					end
					_ = isPicked
				end
				Theme.tween(optionButton, {
					BackgroundColor3 = Theme.Extra.SurfaceRaised,
				}, Theme.Motion.Fast):Play()
			end)
		end
	end

	-- Free-text inputs ----------------------------------------------------
	local function makeInput(placeholder: string, numeric: boolean?): TextBox
		local box = Theme.input(placeholder, { multiLine = not numeric })
		box.Name = "Input"
		box.Size = UDim2.new(1, 0, 0, if numeric then Theme.Metrics.InputHeight else 64)
		box.AutomaticSize = if numeric then Enum.AutomaticSize.None else Enum.AutomaticSize.None
		box.TextYAlignment = if numeric then Enum.TextYAlignment.Center else Enum.TextYAlignment.Top
		box.Parent = content
		return box
	end

	if question.kind == "text" then
		textInput = makeInput(question.placeholder or "Type your answer")
	elseif question.kind == "number" then
		numberInput = makeInput("Enter a number", true)
	elseif question.kind == "boolean" or question.kind == "confirm" then
		local row = Instance.new("Frame")
		row.Name = "YesNo"
		row.Size = UDim2.new(1, 0, 0, 30)
		row.BackgroundTransparency = 1
		row.Parent = content
		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Padding = UDim.new(0, 8)
		rowLayout.Parent = row

		local yesButton = pill("Yes", true, 1, function()
			selected = { yes = true }
			lock()
			QuestionManager.submit(true)
		end)
		yesButton.Parent = row

		local noButton = pill("No", false, 2, function()
			selected = { yes = false }
			lock()
			QuestionManager.submit(false)
		end)
		noButton.Parent = row
	end

	-- Custom answer -------------------------------------------------------
	if question.allowCustom and question.kind ~= "text" and question.kind ~= "number" then
		local toggle = Instance.new("TextButton")
		toggle.Name = "CustomToggle"
		toggle.Size = UDim2.new(1, 0, 0, 24)
		toggle.BackgroundTransparency = 1
		Icons.setButton(toggle, "Edit", "Custom answer")
		toggle.TextXAlignment = Enum.TextXAlignment.Left
		toggle.TextColor3 = Theme.Extra.Muted
		toggle.TextSize = Theme.TextSizes.Caption
		toggle.Font = Theme.Fonts.Medium
		toggle.Parent = content

		toggle.MouseButton1Click:Connect(function()
			if customInput then
				customInput:Destroy()
				customInput = nil
				Icons.setButton(toggle, "Edit", "Custom answer")
				return
			end
			local box = Theme.input("Type your own answer", { multiLine = true })
			box.Name = "CustomInput"
			box.Size = UDim2.new(1, 0, 0, 56)
			box.LayoutOrder = 99
			box.Parent = content
			customInput = box
			Icons.setButton(toggle, "Close", "Cancel custom answer")
			box:CaptureFocus()
		end)
	end

	-- Action row ----------------------------------------------------------
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.Size = UDim2.new(1, 0, 0, 28)
	actions.BackgroundTransparency = 1
	actions.Parent = content

	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection = Enum.FillDirection.Horizontal
	actionLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionLayout.Padding = UDim.new(0, 6)
	actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	actionLayout.Parent = actions

	local function submitCurrent()
		local value: any = nil

		if customInput and #StringUtil.trim(customInput.Text) > 0 then
			value = "__custom__"
		elseif question.kind == "text" then
			value = textInput and textInput.Text or ""
		elseif question.kind == "number" then
			value = numberInput and tonumber(numberInput.Text) or ""
		elseif question.kind == "multiple" then
			local chosen = {}
			for id, isSelected in selected do
				if isSelected then
					chosen[#chosen + 1] = id
				end
			end
			value = chosen
		else
			for id in pairs(selected) do
				value = id
				break
			end
		end

		-- Custom free text replaces the sentinel the validator expects.
		if value == "__custom__" and customInput then
			value = "__custom__"
		end

		local cleaned = QuestionManager.validate(question, value)
		if cleaned == nil then
			local hint = Instance.new("TextLabel")
			hint.Name = "ValidationHint"
			hint.Size = UDim2.new(1, 0, 0, 18)
			hint.BackgroundTransparency = 1
			hint.TextColor3 = Theme.Colors.Error
			hint.TextSize = Theme.TextSizes.Caption
			hint.Text = question.required and "Choose or enter an answer first." or "That value is not valid."
			hint.Parent = actions
			hint.LayoutOrder = 90
			task.delay(3, function()
				if hint.Parent then
					hint:Destroy()
				end
			end)
			return
		end

		-- Free-form custom text is carried through explicitly.
		if question.kind == "single" and value == "__custom__" and customInput then
			cleaned = StringUtil.trim(customInput.Text)
		elseif question.kind == "multiple" and customInput and #StringUtil.trim(customInput.Text) > 0 then
			cleaned = { StringUtil.trim(customInput.Text) }
		end

		lock()
		QuestionManager.submit(cleaned)
	end

	local order = 0
	order += 1
	local submitButton = pill("Submit answer", true, order, submitCurrent)
	submitButton.Parent = actions

	if question.kind ~= "boolean" and question.kind ~= "confirm" then
		order += 1
		local cancelButton = pill("Cancel", false, order, function()
			lock()
			QuestionManager.cancel("The user cancelled the question.")
		end)
		cancelButton.Parent = actions
	end

	if question.allowAiDecide then
		order += 1
		local decideButton = pill("Let AI decide", false, order, function()
			lock()
			QuestionManager.letAiDecide()
		end)
		decideButton.Parent = actions
	end

	-- Enter submits for text/number questions.
	local listener
	if textInput then
		listener = textInput.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				submitCurrent()
			end
		end)
	elseif numberInput then
		listener = numberInput.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				submitCurrent()
			end
		end)
	end

	liveListeners[card] = listener

	return card, {
		cleanup = function()
			releaseListener(card)
		end,
	}
end

--- Renders the answered state into an existing card.
function QuestionCard.markAnswered(card: Frame, answer: any)
	-- The card is no longer editable, so drop its input listener first.
	releaseListener(card)

	local promptLabel = card:FindFirstChild("Content") and (card.Content:FindFirstChild("Prompt") :: TextLabel?)
	if not promptLabel then
		return
	end
	promptLabel.Text ..= string.format("\n\nAnswer: %s", QuestionManager.formatAnswer(answer))

	local actions = card.Content:FindFirstChild("Actions")
	if actions then
		for _, child in actions:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
	end

	local options = card.Content:FindFirstChild("Options")
	if options then
		options.Visible = false
	end

	card.BackgroundTransparency = 0.4
end

return QuestionCard