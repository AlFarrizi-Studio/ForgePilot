--!strict
--[[
	ForgePilot / UI / HistoryView
	Conversation list with new/rename/delete plus full-text message search.
]]

local Components = require(script.Parent.Components)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local SessionManager = require(script.Parent.Parent.Core.SessionManager)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local Theme = require(script.Parent.Parent.Utilities.Theme)
local Time = require(script.Parent.Parent.Utilities.Time)

local HistoryView = {}

function HistoryView.build(parent: GuiObject): Frame
	local view = Instance.new("Frame")
	view.Name = "HistoryView"
	view.Size = UDim2.fromScale(1, 1)
	view.BackgroundTransparency = 1
	Theme.passThrough(view)
	view.Parent = parent

	-- Toolbar -------------------------------------------------------------
	local toolbar = Instance.new("Frame")
	toolbar.Name = "Toolbar"
	toolbar.Size = UDim2.new(1, 0, 0, 30)
	toolbar.BackgroundTransparency = 1
	Theme.passThrough(toolbar)
	toolbar.Parent = view

	local newButton = Theme.textButton("New chat", { accent = true })
	newButton.Name = "NewChat"
	newButton.AnchorPoint = Vector2.new(1, 0)
	newButton.Position = UDim2.new(1, 0, 0, 0)
	newButton.Size = UDim2.fromOffset(108, 26)
	newButton.Parent = toolbar
	Icons.setButton(newButton, "Plus", "New chat")

	local searchBox = Theme.input("Search messages…")
	searchBox.Name = "Search"
	searchBox.Size = UDim2.new(1, -116, 0, 26)
	searchBox.Position = UDim2.fromOffset(0, 2)
	searchBox.TextSize = Theme.TextSizes.Small
	searchBox.Parent = toolbar

	-- Body ---------------------------------------------------------------
	local body = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, -40)
	body.Position = UDim2.fromOffset(0, 40)
	body.BackgroundTransparency = 1
	Theme.passThrough(body)
	body.Parent = view
	Theme.padding(2).Parent = body
	Theme.listLayout(4).Parent = body

	local conversationList = Instance.new("Frame")
	conversationList.Name = "Conversations"
	conversationList.Size = UDim2.new(1, 0, 0, 0)
	conversationList.AutomaticSize = Enum.AutomaticSize.Y
	conversationList.BackgroundTransparency = 1
	Theme.passThrough(conversationList)
	conversationList.LayoutOrder = 1
	conversationList.Parent = body
	Theme.listLayout(4).Parent = conversationList

	local searchResults = Instance.new("Frame")
	searchResults.Name = "SearchResults"
	searchResults.Size = UDim2.new(1, 0, 0, 0)
	searchResults.AutomaticSize = Enum.AutomaticSize.Y
	searchResults.BackgroundTransparency = 1
	Theme.passThrough(searchResults)
	searchResults.LayoutOrder = 2
	searchResults.Visible = false
	searchResults.Parent = body
	Theme.listLayout(4).Parent = searchResults

	-- Rows ----------------------------------------------------------------
	local function IconButtonAt(xOffset: number, iconKey: string, parent: Instance, callback: any): TextButton
		local button = Instance.new("TextButton")
		button.Name = "IconButton"
		button.AnchorPoint = Vector2.new(1, 0)
		button.Position = UDim2.new(1, -(if iconKey == "Edit" then 26 else 4), 0, 13)
		button.Size = UDim2.fromOffset(18, 18)
		button.BackgroundTransparency = 1
		Icons.setButton(button, iconKey)
		button.TextColor3 = Theme.Extra.Muted
		button.TextSize = 12
		button.Parent = parent
		button.MouseButton1Click:Connect(callback)
		return button
	end

	local function makeRow(title: string, subtitle: string, order: number, onClick: any, onRename: any?, onDelete: any?)
		local row = Instance.new("TextButton")
		row.Name = "Row"
		row.LayoutOrder = order
		row.Size = UDim2.new(1, 0, 0, 42)
		row.BackgroundColor3 = Theme.Extra.Surface
		row.BorderSizePixel = 0
		row.Text = ""
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.AutoButtonColor = false
		row.Parent = nil
		Theme.corner(Theme.Metrics.RadiusSmall).Parent = row

		local titleLabel = Theme.label(title, {
			size = Theme.TextSizes.Small,
			font = Theme.Fonts.Medium,
			truncate = true,
		})
		titleLabel.Name = "Title"
		titleLabel.Position = UDim2.fromOffset(30, 5)
		titleLabel.Size = UDim2.new(1, -70, 0, 16)
		titleLabel.Parent = row

		local subtitleLabel = Theme.label(subtitle, {
			size = Theme.TextSizes.Caption,
			color = Theme.Extra.Muted,
			truncate = true,
		})
		subtitleLabel.Name = "Subtitle"
		subtitleLabel.Position = UDim2.fromOffset(30, 22)
		subtitleLabel.Size = UDim2.new(1, -70, 0, 14)
		subtitleLabel.Parent = row

		local icon = Icons.glyph("Chat", 13, Theme.Extra.Muted)
		icon.Name = "Icon"
		icon.Size = UDim2.fromOffset(15, 15)
		icon.Position = UDim2.fromOffset(9, 13)
		icon.Parent = row

		if onRename then
			local renameButton = IconButtonAt(1, "Edit", row, onRename)
			renameButton.Name = "Rename"
		end
		if onDelete then
			local deleteButton = IconButtonAt(1, "Trash", row, onDelete)
			deleteButton.Name = "Delete"
		end

		row.MouseButton1Click:Connect(onClick)
		row.MouseEnter:Connect(function()
			Theme.tween(row, { BackgroundColor3 = Theme.Extra.SurfaceHover }, Theme.Motion.Fast):Play()
		end)
		row.MouseLeave:Connect(function()
			Theme.tween(row, { BackgroundColor3 = Theme.Extra.Surface }, Theme.Motion.Fast):Play()
		end)
		return row
	end

	-- Rendering -----------------------------------------------------------
	local function renderConversations()
		for _, child in conversationList:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local conversations = SessionManager.getConversations()
		local activeId = SessionManager.getActiveId()

		if #conversations == 0 then
			local empty = Components.emptyState("History", "No conversations yet", "Start a chat and it will appear here.")
			empty.Parent = conversationList
			return
		end

		for index, conversation in conversations do
			local subtitle = string.format(
				"%d message%s · %s%s",
				#conversation.messages,
				if #conversation.messages == 1 then "" else "s",
				Time.formatDuration(os.time() - conversation.updatedAt) .. " ago",
				if conversation.model then (" · " .. conversation.model) else ""
			)
			local row = makeRow(conversation.title, subtitle, index, function()
				SessionManager.setActive(conversation.id)
			end, function()
				HistoryView.promptRename(view, conversation.id)
			end, function()
				SessionManager.deleteConversation(conversation.id)
				renderConversations()
			end)
			if conversation.id == activeId then
				row.BackgroundColor3 = Theme.withAlpha(Theme.Colors.Highlight, 0.16)
			end
			row.Parent = conversationList
		end
	end

	local function renderSearch(query: string)
		for _, child in searchResults:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local query2 = StringUtil.trim(query)
		if #query2 < 2 then
			searchResults.Visible = false
			conversationList.Visible = true
			return
		end

		searchResults.Visible = true
		conversationList.Visible = false

		local results = SessionManager.search(query2, 60)
		if #results == 0 then
			local empty = Components.emptyState("Search", "No matches", string.format('Nothing matches "%s".', query2))
			empty.Parent = searchResults
			return
		end

		for index, result in results do
			local preview = string.gsub(StringUtil.trim(result.message.content), "%s+", " ")
			preview = string.sub(preview, 1, 110)
			local row = makeRow(
				string.sub(result.conversation.title, 1, 42),
				preview,
				index,
				function()
					SessionManager.setActive(result.conversation.id)
					EventBus.emit(EventBus.Events.Toast, {
						kind = "info",
						message = string.format("Opened \"%s\".", result.conversation.title),
					})
				end
			)
			row.Parent = searchResults
		end
	end

	-- Behaviour -----------------------------------------------------------
	newButton.MouseButton1Click:Connect(function()
		SessionManager.createConversation({ mode = SettingsManager.getValue("defaultMode") })
		EventBus.emit(EventBus.Events.Toast, { kind = "success", message = "New chat created." })
		renderConversations()
	end)

	local debounce: thread? = nil
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		if debounce then
			task.cancel(debounce)
		end
		local snapshot = searchBox.Text
		debounce = task.spawn(function()
			task.wait(0.2)
			renderSearch(snapshot)
		end)
	end)

	local disconnect = EventBus.on(EventBus.Events.ConversationListChanged, function()
		renderConversations()
	end)

	-- Roblox Instances reject new members ("x is not a valid member of Frame"),
	-- so the view's API lives on a plain table returned alongside the frame.
	-- ChatInput, ThinkingIndicator and TokenMeter already use this shape.
	local api: { [string]: any } = {
		render = renderConversations,
		search = renderSearch,
		destroy = function()
			disconnect()
			if debounce then
				task.cancel(debounce)
			end
		end,
	}

	renderConversations()
	return view, api
end

--- Inline rename using a temporary TextBox over the title.
function HistoryView.promptRename(parent: GuiObject, conversationId: string)
	local conversation = SessionManager.getConversation(conversationId)
	if not conversation then
		return
	end

	local dialog = Instance.new("Frame")
	dialog.Name = "RenameDialog"
	dialog.AnchorPoint = Vector2.new(0.5, 0.5)
	dialog.Position = UDim2.fromScale(0.5, 0.5)
	dialog.Size = UDim2.fromOffset(280, 120)
	dialog.BackgroundColor3 = Theme.Extra.SurfaceRaised
	dialog.BorderSizePixel = 0
	dialog.ZIndex = 80
	dialog.Parent = parent
	Theme.corner(Theme.Metrics.Radius).Parent = dialog
	Theme.stroke(Theme.Extra.BorderStrong).Parent = dialog
	Theme.padding(14).Parent = dialog

	local label = Theme.label("Conversation name", {
		size = Theme.TextSizes.Small,
		color = Theme.Colors.SecondaryText,
	})
	label.Size = UDim2.new(1, 0, 0, 18)
	label.Parent = dialog

	local box = Theme.input(conversation.title)
	box.Name = "Input"
	box.Text = conversation.title
	box.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight)
	box.Position = UDim2.fromOffset(0, 24)
	box.Parent = dialog

	local buttons = Instance.new("Frame")
	buttons.Size = UDim2.new(1, 0, 0, 28)
	buttons.Position = UDim2.fromOffset(0, 66)
	buttons.BackgroundTransparency = 1
	Theme.passThrough(buttons)
	buttons.Parent = dialog
	local buttonsLayout = Instance.new("UIListLayout")
	buttonsLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonsLayout.Padding = UDim.new(0, 8)
	buttonsLayout.Parent = buttons

	local confirmButton = Components.textButton("Rename", { accent = true, order = 1 })
	confirmButton.Parent = buttons
	local cancelButton = Components.textButton("Cancel", { order = 2 })
	cancelButton.Parent = buttons

	local function close()
		dialog:Destroy()
	end

	confirmButton.MouseButton1Click:Connect(function()
		SessionManager.renameConversation(conversationId, box.Text)
		close()
	end)
	cancelButton.MouseButton1Click:Connect(close)
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			SessionManager.renameConversation(conversationId, box.Text)
			close()
		end
	end)

	box:CaptureFocus()
end

return HistoryView
