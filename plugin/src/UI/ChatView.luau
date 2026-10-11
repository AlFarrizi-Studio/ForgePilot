--!strict
local HttpService = game:GetService("HttpService")
local AgentController = require(script.Parent.Parent.AI.AgentController)
local AccessAdvisor = require(script.Parent.Parent.AI.AccessAdvisor)
local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local AttachmentEncoder = require(script.Parent.Parent.AI.AttachmentEncoder)
local ChatInput = require(script.Parent.ChatInput)
local Clipboard = require(script.Parent.Parent.Utilities.Clipboard)
local Components = require(script.Parent.Components)
local ContextManager = require(script.Parent.Parent.AI.ContextManager)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local MessageRenderer = require(script.Parent.MessageRenderer)
local ModelCapabilityDetector = require(script.Parent.Parent.AI.ModelCapabilityDetector)
local QuestionCard = require(script.Parent.QuestionCard)
local RetryStatusUI = require(script.Parent.RetryStatusUI)
local SessionManager = require(script.Parent.Parent.Core.SessionManager)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local StreamingManager = require(script.Parent.Parent.AI.StreamingManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local ThinkingIndicator = require(script.Parent.ThinkingIndicator)
local UniversalProviderRegistry = require(script.Parent.Parent.AI.UniversalProviderRegistry)
local TokenMeter = require(script.Parent.TokenMeter)

local ChatView = {}
function ChatView.build(parent: GuiObject, hooks: any): (Frame, any)
	local view = Instance.new("Frame")
	view.Name = "ChatView"
	view.Size = UDim2.fromScale(1, 1)
	Theme.passThrough(view)
	view.ClipsDescendants = true
	view.Parent = parent
	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.Size = UDim2.fromScale(1, 1)
	Theme.passThrough(stack)
	stack.Parent = view
	Theme.padding4(8, 2, 4, 2).Parent = stack
	Theme.listLayout(6).Parent = stack
	local top = Instance.new("Frame")
	top.Name = "ChatToolbar"
	top.Size = UDim2.new(1, 0, 0, 28)
	top.LayoutOrder = 1
	Theme.passThrough(top)
	top.Parent = stack
	local title = Theme.label("New chat", { size = 12, font = Theme.Fonts.Medium, color = Theme.Colors.SecondaryText })
	title.Name = "ConversationTitle"
	title.Size = UDim2.new(1, -88, 1, 0)
	title.Position = UDim2.fromOffset(8, 0)
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Parent = top
	local newChat = Theme.textButton("+  New chat", { height = 28, width = UDim2.fromOffset(80, 28) })
	newChat.Name = "NewChat"
	newChat.AnchorPoint = Vector2.new(1, 0)
	newChat.Position = UDim2.fromScale(1, 0)
	newChat.BackgroundTransparency = 1
	newChat.TextColor3 = Theme.Colors.SecondaryText
	newChat.TextSize = 11
	newChat.Parent = top
	local accessNotice = Theme.autoText("Local access is disconnected. Web and local files need the bridge. Setup: " .. AccessAdvisor.setupUrl, { size = 11, color = Theme.Extra.Warning })
	accessNotice.Name = "AccessNotice"
	accessNotice.LayoutOrder = 1
	accessNotice.Visible = not BridgeClient.isConnected()
	accessNotice.Parent = stack
	top.LayoutOrder = 0
	local transcript = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	transcript.Name = "Transcript"
	transcript.Size = UDim2.new(1, 0, 0, 0)
	transcript.LayoutOrder = 2
	transcript.Active = true
	transcript.Parent = stack
	Theme.flexItem(transcript, 1, 1)
	Theme.padding4(6, 4, 12, 10).Parent = transcript
	Theme.listLayout(14).Parent = transcript
	local cards = Instance.new("Frame")
	cards.Name = "QuestionCards"
	cards.Size = UDim2.new(1, 0, 0, 0)
	cards.AutomaticSize = Enum.AutomaticSize.Y
	cards.LayoutOrder = 10000
	Theme.passThrough(cards)
	cards.Parent = transcript
	Theme.listLayout(8).Parent = cards
	local latest = Theme.textButton("↓  Latest message", { height = 26 })
	latest.Name = "ScrollToBottom"
	latest.Size = UDim2.new(1, 0, 0, 26)
	latest.LayoutOrder = 3
	latest.Visible = false
	latest.TextSize = 11
	latest.Parent = stack
	local thinkingFrame, thinking = ThinkingIndicator.build()
	thinkingFrame.LayoutOrder = 4
	thinkingFrame.Parent = stack
	local editRow = Instance.new("Frame")
	editRow.Name = "Editing"
	editRow.Size = UDim2.new(1, 0, 0, 24)
	editRow.LayoutOrder = 5
	editRow.Visible = false
	Theme.passThrough(editRow)
	editRow.Parent = stack
	local editLabel = Theme.label("Editing message", { size = 11, color = Theme.Colors.Highlight })
	editLabel.Size = UDim2.new(1, -66, 1, 0)
	editLabel.Parent = editRow
	local cancelEdit = Theme.textButton("Cancel", { height = 24, width = UDim2.fromOffset(60, 24) })
	cancelEdit.Name = "CancelEdit"
	cancelEdit.BackgroundTransparency = 1
	cancelEdit.TextSize = 11
	cancelEdit.AnchorPoint = Vector2.new(1, 0)
	cancelEdit.Position = UDim2.fromScale(1, 0)
	cancelEdit.Parent = editRow

	local mode = SettingsManager.getValue("defaultMode") or "build"
	local input: any = nil
	local reconcile: (boolean?) -> () = nil :: any
	local rendered: { [string]: any } = {}
	local questionCards: { [string]: Frame } = {}
	local activeId: string? = nil
	local editingId: string? = nil
	local running = false
	local destroyed = false
	local follow = true
	local retryApi: any = nil
	local approvalCard: Frame? = nil
	local landing: Frame? = nil
	local function toast(kind: string, message: string)
		EventBus.emit(EventBus.Events.Toast, { kind = kind, message = message })
	end
	local function openSettings()
		if hooks.onNavigate then hooks.onNavigate("settings") end
		EventBus.emit(EventBus.Events.Navigate, { section = "settings", tab = "AI & Provider" })
	end
	local function idle(): boolean
		if running or StateManager.isBusy() then
			toast("info", "Stop the current task and wait for it to finish first.")
			return false
		end
		return true
	end
	local function configured(): any?
		local profile = SettingsManager.getActiveProvider()
		if not profile then toast("warning", "Choose an AI provider in Settings to start chatting."); openSettings(); return nil end
		if StringUtil.trim(profile.modelId or "") == "" then toast("warning", "Enter a model ID in your provider settings."); openSettings(); return nil end
		if profile.authStyle ~= "none" and not profile.viaRouter and not CredentialStore.has(profile.id) then
			toast("warning", "Enter this provider's API key in Settings."); openSettings(); return nil
		end
		return profile
	end
	local function maxScroll(): number
		return math.max(0, transcript.AbsoluteCanvasSize.Y - transcript.AbsoluteWindowSize.Y)
	end
	local function scrollBottom()
		if destroyed then return end
		follow = true
		transcript.CanvasPosition = Vector2.new(0, maxScroll())
		latest.Visible = false
	end
	local function removeRetry()
		if retryApi then retryApi.destroy(); retryApi = nil end
	end
	local function clearEditing()
		editingId = nil
		editRow.Visible = false
		input.setPlaceholder("Ask ForgePilot anything about your place…")
	end
	local function run(conversation: any)
		running = true
		input.setBusy(true)
		thinking.show()
		removeRetry()
		follow = true
		task.defer(scrollBottom)
		task.spawn(function()
			local ok, result = pcall(function()
				return AgentController.runTask({
					userText = "", mode = mode, conversation = conversation,
					onRetryWait = function(seconds: number, decision: any, attempt: number)
						if destroyed then return end
						if not retryApi then
							local profile = SettingsManager.getActiveProvider()
							local card
							card, retryApi = RetryStatusUI.build({
								operationId = StateManager.getTaskId() or conversation.id, providerName = profile and profile.displayName or "Provider",
								model = profile and profile.modelId or "", category = decision.category or "RATE_LIMITED",
								reason = decision.reason or "The provider is temporarily unavailable.",
								maxRetries = SettingsManager.get().smartRetry.maxRetries,
								providerId = profile and profile.id, endpoint = profile and profile.baseUrl,
								attempt = attempt, delaySeconds = seconds, paused = false,
								onCancel = function()
									StateManager.cancel()
									StreamingManager.cancelAll()
									thinking.setActivity("Stopping…")
								end,
							})
							card.LayoutOrder = 9900
							card.Parent = cards
							follow = true
						end
						retryApi.setAttempt(attempt, seconds)
					end,
					onRetryError = function(normalised: any)
						if retryApi then retryApi.setCategory(normalised.category, normalised.message) end
					end,
				})
			end)
			if destroyed then return end
			running = false
			input.setBusy(false)
			thinking.stop()
			removeRetry()
			if approvalCard then approvalCard:Destroy(); approvalCard = nil end
			if not ok then
				StateManager.transition("FAILED", { force = true })
				toast("error", "The task stopped: " .. tostring(result))
			elseif result and not result.ok and result.message ~= "Cancelled" and result.message ~= "Provider failure" then
				toast("error", result.message or "The task could not finish.")
			end
			reconcile()
		end)
	end

	local inputFrame
	inputFrame, input = ChatInput.build({
		onSend = function(text: string): boolean
			if not idle() then return false end
			local profile = configured()
			if not profile then return false end
			local notice = AccessAdvisor.notice(text, ModelCapabilityDetector.getOrBuildReport(profile))
			if notice then toast("warning", notice) end
			local conversation = SessionManager.ensureConversation()
			SessionManager.setConversationMeta(conversation.id, { mode = mode, providerId = profile.id, model = profile.modelId })
			if editingId then
				SessionManager.truncateAfter(editingId)
				SessionManager.updateMessage(editingId, { content = text, attachments = AttachmentEncoder.manifest() })
			else
				SessionManager.addMessage("user", text, { attachments = AttachmentEncoder.manifest() })
			end
			clearEditing()
			-- Fresh editor context stays separate from the summarised chat history.
			conversation.editorContext = AgentController.gatherContext(mode)
			run(conversation)
			return true
		end,
		onStop = function()
			StateManager.cancel()
			StreamingManager.cancelAll()
			thinking.setActivity("Stopping…")
		end,
		onModeChange = function(value: string)
			mode = value
			local conversation = SessionManager.getActive()
			if conversation then SessionManager.setConversationMeta(conversation.id, { mode = mode }) end
		end,
		onPickFiles = function()
			local profile = SettingsManager.getActiveProvider()
			local report = if profile then ModelCapabilityDetector.getOrBuildReport(profile) else nil
			local files = AttachmentEncoder.pickFiles(true)
			if #files == 0 then return end
			local result = AttachmentEncoder.load(files, report, profile and profile.protocol)
			for _, rejected in result.rejected do toast("warning", rejected.name .. ": " .. rejected.reason) end
		end,
		onOpenSettings = openSettings,
	})
	inputFrame.Name = "Composer"
	inputFrame.LayoutOrder = 6
	inputFrame.Parent = stack
	input.setMode(mode)
	local tokenFrame, tokenMeter = TokenMeter.build()
	tokenFrame.LayoutOrder = 7
	tokenFrame.Parent = stack

	local function rerun(messageId: string)
		if not idle() or not configured() then return end
		local conversation = SessionManager.getActive()
		if not conversation then return end
		local index: number? = nil
		for position, message in conversation.messages do if message.id == messageId then index = position; break end end
		if not index then return end
		for position = index - 1, 1, -1 do
			if conversation.messages[position].role == "user" then
				SessionManager.truncateAfter(conversation.messages[position].id)
				clearEditing()
				run(conversation)
				return
			end
		end
	end
	local rendererOptions: MessageRenderer.RenderOptions = {
		onCopy = function(text: string)
			local copied, reason, presented = Clipboard.copy(text)
			if presented then return end
			toast(if copied then "success" else "warning", if copied then "Copied." else reason or "Clipboard unavailable.")
		end,
		onRegenerate = rerun, onRetry = rerun,
		onEdit = function(id: string)
			if not idle() then return end
			local message = SessionManager.findMessage(id)
			if not message then return end
			editingId = id
			editRow.Visible = true
			input.setText(message.content)
			input.setPlaceholder("Edit your message…")
			input.focus()
		end,
		onSwitchToBuild = function()
			if not idle() then return end
			mode = "build"
			input.setMode(mode)
			input.setText("Build the plan above in this place.")
			input.focus()
		end,
		onPlanAction = function(_, action: string)
			if action == "revise" and idle() then input.setPlaceholder("Describe what to change in the plan…"); input.focus() end
		end,
	}
	local function signature(message: any): string
		local ok, extras = pcall(function() return HttpService:JSONEncode({ message.usage, message.toolCalls, message.attachments, message.plan }) end)
		return table.concat({ message.content or "", tostring(message.streaming), message.reasoning or "", message.error or "", tostring(message.elapsedMs), if ok then extras else "" }, "\0")
	end
	local function upsert(message: any, index: number)
		if message.internal then return end
		local mark = signature(message)
		local previous = rendered[message.id]
		if previous and previous.signature == mark then previous.frame.LayoutOrder = index; return end
		if previous then previous.api.destroy(); previous.frame:Destroy() end
		message.plan = message.plan or (message.role == "assistant" and (message.content or ""):find("PLAN_READY", 1, true) ~= nil)
		local frame, api = MessageRenderer.render(message, rendererOptions)
		frame.LayoutOrder = index
		frame.Parent = transcript
		rendered[message.id] = { frame = frame, api = api, signature = signature(message) }
	end
	local function buildLanding()
		local frame = Instance.new("Frame")
		frame.Name = "Welcome"
		frame.Size = UDim2.new(1, 0, 0, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		Theme.passThrough(frame)
		Theme.padding4(18, 12, 16, 12).Parent = frame
		Theme.listLayout(12).Parent = frame
		local mark = Icons.brandMark(32)
		mark.LayoutOrder = 1
		mark.Parent = frame
		local heading = Theme.autoText("What would you like to create?", { size = 22, font = Theme.Fonts.Bold, color = Theme.Colors.MainText })
		heading.LayoutOrder = 2
		heading.Parent = frame
		local note = Theme.autoText("Plan an idea, understand your scripts, or build something in Roblox Studio.", { size = 13 })
		note.LayoutOrder = 3
		note.Parent = frame
		local suggestions = {
			{ "Plan a game", "Help me plan a Roblox game with a clear gameplay loop." },
			{ "Review my selection", "Explain the objects and scripts I have selected, and suggest improvements." },
			{ "Improve my UI", "Review the UI in this place and suggest a cleaner layout." },
		}
		for index, suggestion in suggestions do
			local button = Theme.textButton(suggestion[1] .. "  →", { height = 38 })
			button.Name = "Suggestion_" .. index
			button.TextXAlignment = Enum.TextXAlignment.Left
			button.TextSize = 12
			button.LayoutOrder = 3 + index
			Theme.padding4(0, 12, 0, 12).Parent = button
			button.Parent = frame
			button.MouseButton1Click:Connect(function() input.setText(suggestion[2]); input.focus() end)
		end
		if not SettingsManager.getActiveProvider() then
			local button = Components.textButton("Connect your AI provider", { accent = true, order = 9 })
			button.Parent = frame
			button.MouseButton1Click:Connect(openSettings)
		end
		frame.Parent = transcript
		return frame
	end
	reconcile = function(forceBottom: boolean?)
		if destroyed then return end
		local conversation = SessionManager.getActive()
		local id = conversation and conversation.id
		if id ~= activeId then
			for _, entry in rendered do entry.api.destroy(); entry.frame:Destroy() end
			rendered = {}
			for _, child in cards:GetChildren() do if child:IsA("GuiObject") then child:Destroy() end end
			questionCards = {}
			activeId = id
			clearEditing()
			mode = conversation and conversation.mode or SettingsManager.getValue("defaultMode") or "build"
			input.setMode(mode)
			follow = true
		end
		title.Text = conversation and conversation.title or "New chat"
		if not conversation or #conversation.messages == 0 then
			if not landing then landing = buildLanding() end
		else
			if landing then landing:Destroy(); landing = nil end
			local keep: { [string]: boolean } = {}
			for index, message in conversation.messages do keep[message.id] = true; upsert(message, index) end
			for key, entry in rendered do
				if not keep[key] then entry.api.destroy(); entry.frame:Destroy(); rendered[key] = nil end
			end
		end
		if forceBottom then follow = true end
		if follow then task.defer(scrollBottom) end
	end
	local function refreshProvider()
		local profile = SettingsManager.getActiveProvider()
		input.setProvider(if profile then profile.modelId or profile.displayName else "Set up AI", if profile then Theme.Colors.SecondaryText else Theme.Colors.Highlight, if profile then profile.iconId or (UniversalProviderRegistry.getPreset(profile.presetId) or {}).iconId else nil)
		if landing then landing:Destroy(); landing = nil; reconcile() end
	end
	local unsubs = {}
	unsubs[#unsubs + 1] = EventBus.on("BridgeChanged", function() accessNotice.Visible = not BridgeClient.isConnected() end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.MessageStarted, function(payload)
		if payload.conversationId == nil or payload.conversationId == SessionManager.getActiveId() then reconcile() end
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.MessageUpdated, function(payload)
		if payload.conversationId == SessionManager.getActiveId() then reconcile() end
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.MessageDelta, function(payload)
		local entry = rendered[payload.messageId]
		if entry then entry.api.appendDelta(payload.delta, payload.channel) end
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ConversationChanged, function() reconcile(true) end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ConversationRenamed, function() reconcile() end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ModeChanged, function(payload)
		if not running then mode = payload.mode; input.setMode(mode) end
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ProvidersChanged, refreshProvider)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ActiveProviderChanged, refreshProvider)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.QuestionAsked, function(payload)
		local frame = QuestionCard.build(payload.question)
		frame.LayoutOrder = 9000
		frame.Parent = cards
		questionCards[payload.question.id] = frame
		follow = true
		task.defer(scrollBottom)
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.QuestionAnswered, function(payload)
		local card = questionCards[payload.questionId]
		if card then QuestionCard.markAnswered(card, payload.answer) end
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.QuestionCancelled, function(payload)
		local card = questionCards[payload.questionId]
		if card then card:Destroy(); questionCards[payload.questionId] = nil end
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ApprovalRequested, function(payload)
		if approvalCard then approvalCard:Destroy() end
		local card, body = Components.section(payload.summary or "Approve action", { subtitle = "Review this change before it runs." })
		approvalCard = card
		card.LayoutOrder = 9100
		card.Parent = cards
		local row, add = Components.buttonRow({ columns = 2 })
		row.Parent = body
		local answered = false
		local function answer(value: boolean)
			if answered then return end
			answered = true
			AgentController.resolveApproval(value)
			card:Destroy()
			approvalCard = nil
		end
		add("Approve", { accent = true, order = 1 }).MouseButton1Click:Connect(function() answer(true) end)
		add("Decline", { order = 2 }).MouseButton1Click:Connect(function() answer(false) end)
		follow = true
		task.defer(scrollBottom)
	end)
	unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.Toast, function(payload) Components.toast(view, payload.kind, payload.message) end)
	transcript:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		follow = maxScroll() - transcript.CanvasPosition.Y < 48
		latest.Visible = not follow
	end)
	transcript:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
		if follow then task.defer(scrollBottom) else latest.Visible = true end
	end)
	latest.MouseButton1Click:Connect(scrollBottom)
	newChat.MouseButton1Click:Connect(function()
		if not idle() then return end
		AttachmentEncoder.clear()
		input.setText("")
		SessionManager.createConversation({ mode = mode })
	end)
	cancelEdit.MouseButton1Click:Connect(function() clearEditing(); input.setText("") end)
	local function resize()
		input.setMaxHeight(math.clamp(view.AbsoluteSize.Y * 0.22, 48, 110))
		tokenFrame.Visible = view.AbsoluteSize.Y >= 290
	end
	view:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	refreshProvider()
	reconcile()
	resize()
	return view, {
		destroy = function()
			destroyed = true
			removeRetry()
			for _, unsubscribe in unsubs do unsubscribe() end
			for _, entry in rendered do entry.api.destroy() end
			input.destroy(); thinking.destroy(); tokenMeter.destroy()
		end,
		input = input, transcript = transcript,
	}
end
return ChatView
