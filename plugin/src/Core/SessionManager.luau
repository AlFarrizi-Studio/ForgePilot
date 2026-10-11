--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Core / SessionManager
	Conversation list, message storage, and per-session token accounting.

	Messages are persisted to Plugin:SetSetting under a dedicated key so history
	survives a Studio restart. Every message passes through Redact on the way in,
	so a pasted API key can never be written to disk.
]]

local EventBus = require(script.Parent.EventBus)
local StateManager = require(script.Parent.StateManager)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local Time = require(script.Parent.Parent.Utilities.Time)

local SessionManager = {}

local HISTORY_KEY = "ForgePilot.Conversations.v1"
local MAX_CONVERSATIONS = 60
local MAX_MESSAGES_PER_CONVERSATION = 400

export type Role = "system" | "user" | "assistant" | "tool"

export type Message = {
	internal: boolean?,
	policyBlocked: boolean?,
	id: string,
	role: Role,
	content: string,
	at: number,
	taskId: string?,
	toolCallId: string?,
	attachments: { { name: string, mime: string, sizeBytes: number } }?,
	reasoning: string?,
	toolCalls: { { id: string, name: string, args: any, result: string?, state: string } }?,
	question: any?,
	plan: any?,
	streaming: boolean?,
	elapsedMs: number?,
	usage: { input: number?, output: number?, reasoning: number?, total: number? }?,
	model: string?,
	error: string?,
}

export type Conversation = {
	id: string,
	title: string,
	createdAt: number,
	updatedAt: number,
	mode: string,
	providerId: string?,
	model: string?,
	messages: { Message },
	summary: string?,
	editorContext: string?,
	summarisedUpTo: number,
	totalInput: number,
	totalOutput: number,
	totalReasoning: number,
}

local conversations: { Conversation } = {}
local activeConversationId: string? = nil
local pluginRef: Plugin? = nil

--=============================================================================
-- LIFECYCLE
--=============================================================================

local function serialisable(message: Message): any
	return {
		internal = message.internal,
		policyBlocked = message.policyBlocked,
		id = message.id,
		role = message.role,
		content = Redact.scrubText(message.content),
		at = message.at,
		taskId = message.taskId,
		toolCallId = message.toolCallId,
		attachments = message.attachments,
		reasoning = if message.reasoning then Redact.scrubText(message.reasoning) else nil,
		toolCalls = message.toolCalls,
		question = message.question,
		plan = message.plan,
		elapsedMs = message.elapsedMs,
		usage = message.usage,
		model = message.model,
		error = if message.error then Redact.scrubText(message.error) else nil,
	}
end

local function deserialisable(raw: any): Message?
	if type(raw) ~= "table" or type(raw.id) ~= "string" then
		return nil
	end
	return {
		internal = raw.internal == true,
		policyBlocked = raw.policyBlocked == true,
		id = raw.id,
		role = (raw.role or "user") :: Role,
		content = tostring(raw.content or ""),
		at = tonumber(raw.at) or os.time(),
		taskId = raw.taskId,
		toolCallId = raw.toolCallId,
		attachments = raw.attachments,
		reasoning = raw.reasoning,
		toolCalls = raw.toolCalls,
		question = raw.question,
		plan = raw.plan,
		elapsedMs = raw.elapsedMs,
		usage = raw.usage,
		model = raw.model,
		error = raw.error,
	}
end

function SessionManager.init(plugin: Plugin)
	pluginRef = plugin
	SessionManager.load()
end

function SessionManager.load()
	conversations = {}
	activeConversationId = nil
	if not pluginRef then
		return
	end
	local ok, raw = pcall(pluginRef.GetSetting, pluginRef, HISTORY_KEY)
	if not ok or type(raw) ~= "string" or #raw == 0 then
		return
	end
	local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not decodeOk or type(decoded) ~= "table" then
		return
	end
	for _, entry in decoded do
		if type(entry) == "table" and type(entry.id) == "string" then
			local messages = {}
			for _, rawMessage in (entry.messages or {}) do
				local message = deserialisable(rawMessage)
				if message then
					messages[#messages + 1] = message
				end
			end
			conversations[#conversations + 1] = {
				id = entry.id,
				title = tostring(entry.title or "New chat"),
				createdAt = tonumber(entry.createdAt) or os.time(),
				updatedAt = tonumber(entry.updatedAt) or os.time(),
				mode = tostring(entry.mode or "plan"),
				providerId = entry.providerId,
				model = entry.model,
				messages = messages,
				summary = entry.summary,
				summarisedUpTo = tonumber(entry.summarisedUpTo) or 0,
				totalInput = tonumber(entry.totalInput) or 0,
				totalOutput = tonumber(entry.totalOutput) or 0,
				totalReasoning = tonumber(entry.totalReasoning) or 0,
			}
		end
	end
	if #conversations > 0 then
		activeConversationId = conversations[1].id
	end
end

function SessionManager.persist()
	if not pluginRef then
		return false
	end
	local payload = {}
	for _, conversation in conversations do
		local messages = {}
		for _, message in conversation.messages do
			messages[#messages + 1] = serialisable(message)
		end
		payload[#payload + 1] = {
			id = conversation.id,
			title = conversation.title,
			createdAt = conversation.createdAt,
			updatedAt = conversation.updatedAt,
			mode = conversation.mode,
			providerId = conversation.providerId,
			model = conversation.model,
			messages = messages,
			summary = conversation.summary,
			summarisedUpTo = conversation.summarisedUpTo,
			totalInput = conversation.totalInput,
			totalOutput = conversation.totalOutput,
			totalReasoning = conversation.totalReasoning,
		}
	end
	local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
	if not encodeOk then
		return false
	end
	local setOk = pcall(pluginRef.SetSetting, pluginRef, HISTORY_KEY, encoded)
	return setOk
end

--=============================================================================
-- CONVERSATIONS
--=============================================================================

function SessionManager.getConversations(): { Conversation }
	return table.clone(conversations)
end

function SessionManager.getConversation(id: string?): Conversation?
	if not id then
		return nil
	end
	for _, conversation in conversations do
		if conversation.id == id then
			return conversation
		end
	end
	return nil
end

function SessionManager.getActive(): Conversation?
	return SessionManager.getConversation(activeConversationId)
end

function SessionManager.getActiveId(): string?
	return activeConversationId
end

function SessionManager.createConversation(options: { title: string?, mode: string?, providerId: string?, model: string? }?): Conversation
	local active = SessionManager.getActive()
	if StateManager.isBusy() and active then
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Wait for the current task to finish before starting a new chat." })
		return active
	end
	local opts = options or {}
	local conversation: Conversation = {
		id = Time.newId("conv"),
		title = opts.title or "New chat",
		createdAt = os.time(),
		updatedAt = os.time(),
		mode = opts.mode or "build",
		providerId = opts.providerId,
		model = opts.model,
		messages = {},
		summary = nil,
		summarisedUpTo = 0,
		totalInput = 0,
		totalOutput = 0,
		totalReasoning = 0,
	}
	table.insert(conversations, 1, conversation)
	while #conversations > MAX_CONVERSATIONS do
		table.remove(conversations)
	end
	activeConversationId = conversation.id
	SessionManager.persist()
	EventBus.emit(EventBus.Events.ConversationChanged, { conversationId = conversation.id })
	EventBus.emit(EventBus.Events.ConversationListChanged, {})
	return conversation
end

--- Ensures a conversation exists; creates one on first use.
function SessionManager.ensureConversation(): Conversation
	local active = SessionManager.getActive()
	if active then
		return active
	end
	return SessionManager.createConversation()
end

function SessionManager.setActive(id: string)
	if StateManager.isBusy() and id ~= activeConversationId then
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Wait for the current task to finish before switching chats." })
		return false
	end
	local conversation = SessionManager.getConversation(id)
	if not conversation then
		return false
	end
	activeConversationId = id
	EventBus.emit(EventBus.Events.ConversationChanged, { conversationId = id })
	return true
end

function SessionManager.renameConversation(id: string, title: string): boolean
	local conversation = SessionManager.getConversation(id)
	if not conversation then
		return false
	end
	local trimmed = StringUtil.trim(title or "")
	if #trimmed == 0 then
		return false
	end
	conversation.title = string.sub(trimmed, 1, 60)
	conversation.updatedAt = os.time()
	SessionManager.persist()
	EventBus.emit(EventBus.Events.ConversationListChanged, {})
	EventBus.emit(EventBus.Events.ConversationRenamed, { conversationId = id, title = conversation.title })
	return true
end

function SessionManager.deleteConversation(id: string): boolean
	if StateManager.isBusy() and id == activeConversationId then
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Finish or stop the task before deleting this chat." })
		return false
	end
	for index, conversation in conversations do
		if conversation.id == id then
			table.remove(conversations, index)
			if activeConversationId == id then
				activeConversationId = if #conversations > 0 then conversations[1].id else nil
			end
			SessionManager.persist()
			EventBus.emit(EventBus.Events.ConversationDeleted, { conversationId = id })
			EventBus.emit(EventBus.Events.ConversationListChanged, {})
			EventBus.emit(EventBus.Events.ConversationChanged, { conversationId = activeConversationId })
			return true
		end
	end
	return false
end

function SessionManager.clearAll()
	if StateManager.isBusy() then
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Finish or stop the task before clearing history." })
		return false
	end
	conversations = {}
	activeConversationId = nil
	SessionManager.persist()
	EventBus.emit(EventBus.Events.ConversationListChanged, {})
	EventBus.emit(EventBus.Events.ConversationChanged, { conversationId = nil })
	return true
end

function SessionManager.setConversationMeta(id: string, patch: { mode: string?, providerId: string?, model: string? })
	local conversation = SessionManager.getConversation(id)
	if not conversation then
		return
	end
	if patch.mode then
		conversation.mode = patch.mode
		EventBus.emit(EventBus.Events.ModeChanged, { mode = patch.mode, conversationId = id })
	end
	if patch.providerId ~= nil then
		conversation.providerId = patch.providerId
	end
	if patch.model ~= nil then
		conversation.model = patch.model
	end
	conversation.updatedAt = os.time()
	SessionManager.persist()
end

--=============================================================================
-- MESSAGES
--=============================================================================

function SessionManager.addMessage(role: Role, content: string, options: {
	internal: boolean?,
	policyBlocked: boolean?,
	taskId: string?,
	toolCallId: string?,
	conversationId: string?,
	streaming: boolean?,
	attachments: { { name: string, mime: string, sizeBytes: number } }?,
	reasoning: string?,
	toolCalls: any?,
	question: any?,
	plan: any?,
	model: string?,
}?): Message
	local opts = options or {}
	local conversation = SessionManager.getConversation(opts.conversationId) or SessionManager.ensureConversation()
	local message: Message = {
		internal = opts.internal,
		policyBlocked = opts.policyBlocked,
		id = Time.newId("msg"),
		role = role,
		content = Redact.scrubText(content or ""),
		at = os.time(),
		taskId = opts.taskId,
		toolCallId = opts.toolCallId,
		streaming = opts.streaming,
		attachments = opts.attachments,
		reasoning = if opts.reasoning then Redact.scrubText(opts.reasoning) else nil,
		toolCalls = opts.toolCalls,
		question = opts.question,
		plan = opts.plan,
		model = opts.model,
	}

	table.insert(conversation.messages, message)
	while #conversation.messages > MAX_MESSAGES_PER_CONVERSATION do
		table.remove(conversation.messages, 1)
		conversation.summarisedUpTo = math.max(0, conversation.summarisedUpTo - 1)
	end
	conversation.updatedAt = os.time()

	-- First user message names the chat.
	if role == "user" and conversation.title == "New chat" and StringUtil.trim(content) ~= "" then
		local derived = string.gsub(StringUtil.trim(content), "%s+", " ")
		conversation.title = string.sub(derived, 1, 48)
		EventBus.emit(EventBus.Events.ConversationListChanged, {})
	end

	SessionManager.persist()
	EventBus.emit(EventBus.Events.MessageStarted, { message = message, conversationId = conversation.id })
	return message
end

function SessionManager.appendToMessage(id: string, chunk: string, channel: string?): Message?
	local conversation = nil
	for _, candidate in conversations do
		for _, entry in candidate.messages do
			if entry.id == id then conversation = candidate; break end
		end
		if conversation then break end
	end
	if not conversation then return nil end
	for index = #conversation.messages, 1, -1 do
		local message = conversation.messages[index]
		if message.id == id then
            if channel == "reasoning" then message.reasoning = (message.reasoning or "") .. chunk else message.content ..= chunk end
			message.streaming = true
			EventBus.emit(EventBus.Events.MessageDelta, { messageId = id, delta = chunk, channel = channel or "text", conversationId = conversation.id })
			return message
		end
	end
	return nil
end

function SessionManager.updateMessage(id: string, patch: { [string]: any }): Message?
	local conversation = nil
	for _, candidate in conversations do
		for _, entry in candidate.messages do
			if entry.id == id then conversation = candidate; break end
		end
		if conversation then break end
	end
	if not conversation then return nil end
	for index = #conversation.messages, 1, -1 do
		local message = conversation.messages[index]
		if message.id == id then
			for key, value in patch do
				(message :: any)[key] = if type(value) == "string" then Redact.scrubText(value) else value
			end
			conversation.updatedAt = os.time()
			SessionManager.persist()
			EventBus.emit(EventBus.Events.MessageUpdated, { message = message, conversationId = conversation.id })
			return message
		end
	end
	return nil
end

function SessionManager.findMessage(id: string): Message?
	for _, conversation in conversations do
		for _, message in conversation.messages do
			if message.id == id then
				return message
			end
		end
	end
	return nil
end

--- Truncates a conversation at a message index (used by "edit previous message").
function SessionManager.truncateAfter(messageId: string): boolean
	local conversation = SessionManager.getActive()
	if not conversation then
		return false
	end
	for index, message in conversation.messages do
		if message.id == messageId then
			for cut = #conversation.messages, index + 1, -1 do
				table.remove(conversation.messages, cut)
			end
			conversation.updatedAt = os.time()
			SessionManager.persist()
			EventBus.emit(EventBus.Events.MessageStarted, { message = message, replaced = true })
			return true
		end
	end
	return false
end

function SessionManager.getMessages(): { Message }
	local conversation = SessionManager.getActive()
	if not conversation then
		return {}
	end
	return conversation.messages
end

--=============================================================================
-- USAGE ACCOUNTING
--=============================================================================

function SessionManager.recordUsage(conversationId: string?, usage: any?)
	local conversation = SessionManager.getConversation(conversationId) or SessionManager.getActive()
	if not conversation or type(usage) ~= "table" then
		return
	end
	conversation.totalInput += tonumber(usage.inputTokens or usage.input) or 0
	conversation.totalOutput += tonumber(usage.outputTokens or usage.output) or 0
	conversation.totalReasoning += tonumber(usage.reasoningTokens or usage.reasoning) or 0
	conversation.updatedAt = os.time()
end

function SessionManager.getTotals(): { input: number, output: number, reasoning: number, total: number }
	local conversation = SessionManager.getActive()
	if not conversation then
		return { input = 0, output = 0, reasoning = 0, total = 0 }
	end
	return {
		input = conversation.totalInput,
		output = conversation.totalOutput,
		reasoning = conversation.totalReasoning,
		-- Reasoning is a breakdown of output tokens, not an extra token bill.
		total = conversation.totalInput + conversation.totalOutput,
	}
end

--=============================================================================
-- SEARCH
--=============================================================================

--- Returns matching messages across all conversations, newest first.
function SessionManager.search(query: string, limit: number?): { { conversation: Conversation, message: Message } }
	local needle = string.lower(StringUtil.trim(query or ""))
	if #needle < 2 then
		return {}
	end
	local results: { { conversation: Conversation, message: Message } } = {}
	local cap = limit or 100

	for conversationIndex = 1, #conversations do
		local conversation = conversations[conversationIndex]
		for messageIndex = #conversation.messages, 1, -1 do
			local message = conversation.messages[messageIndex]
			if string.find(string.lower(message.content), needle, 1, true) then
				results[#results + 1] = { conversation = conversation, message = message }
				if #results >= cap then
					EventBus.emit(EventBus.Events.ConversationSearchResults, { count = #results })
					return results
				end
			end
		end
	end

	EventBus.emit(EventBus.Events.ConversationSearchResults, { count = #results })
	return results
end

return SessionManager
