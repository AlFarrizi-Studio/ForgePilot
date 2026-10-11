--!strict
--[[
	ForgePilot / Core / EventBus
	Typed signal hub shared by the AI, Roblox and UI layers.

	Modules never hold references to each other directly; they publish and
	subscribe here. This keeps the plugin's dependency graph acyclic.
]]

export type Payload = { [string]: any }

local EventBus = {}

-- Canonical event names. Referencing these constants avoids string typos.
EventBus.Events = {
	-- Session / chat
	MessageStarted = "message:started",
	MessageDelta = "message:delta",
	MessageUpdated = "message:updated",
	MessageCompleted = "message:completed",
	MessageFailed = "message:failed",
	ConversationChanged = "conversation:changed",
	ConversationListChanged = "conversation:list",
	ConversationRenamed = "conversation:renamed",
	ConversationDeleted = "conversation:deleted",
	ConversationSearchResults = "conversation:search",

	-- Agent lifecycle
	StateChanged = "agent:stateChanged",
	ModeChanged = "agent:modeChanged",
	ActivityChanged = "agent:activity",
	ThinkingStarted = "agent:thinkingStarted",
	ThinkingEnded = "agent:thinkingEnded",

	-- Providers
	ProvidersChanged = "provider:changed",
	ActiveProviderChanged = "provider:activeChanged",
	ConnectionTestResult = "provider:testResult",
	CapabilitiesChanged = "provider:capabilities",
	ModelListChanged = "provider:models",

	-- Context
	TokenUsageChanged = "context:tokens",
	ContextChanged = "context:changed",

	-- Attachments
	AttachmentsChanged = "attachment:changed",

	-- Questions
	QuestionAsked = "question:asked",
	QuestionAnswered = "question:answered",
	QuestionCancelled = "question:cancelled",

	-- Tools
	ToolCallStarted = "tool:started",
	ToolCallFinished = "tool:finished",
	ToolCallFailed = "tool:failed",
	ApprovalRequested = "tool:approval",
	ApprovalResolved = "tool:approvalResolved",
	BuildProgress = "tool:progress",

	-- UI
	Navigate = "ui:navigate",
	Toast = "ui:toast",
	FloatingSizeChanged = "ui:floatingSize",
	StreamEvent = "ui:streamEvent",
}

type Handler = (payload: Payload) -> ()

local handlers: { [string]: { { id: number, callback: Handler } } } = {}
local nextHandlerId = 1

--=============================================================================
-- SUBSCRIBE
--=============================================================================

--- Subscribes to an event. Returns a function that unsubscribes.
function EventBus.on(eventName: string, callback: Handler): () -> ()
	local bucket = handlers[eventName]
	if not bucket then
		bucket = {}
		handlers[eventName] = bucket
	end
	local id = nextHandlerId
	nextHandlerId += 1
	table.insert(bucket, { id = id, callback = callback })

	return function()
		local current = handlers[eventName]
		if not current then
			return
		end
		for index, entry in current do
			if entry.id == id then
				table.remove(current, index)
				return
			end
		end
	end
end

--- Subscribes for a single delivery.
function EventBus.once(eventName: string, callback: Handler): () -> ()
	local disconnect: () -> ()
	disconnect = EventBus.on(eventName, function(payload)
		disconnect()
		callback(payload)
	end)
	return disconnect
end

--=============================================================================
-- PUBLISH
--=============================================================================

function EventBus.emit(eventName: string, payload: Payload?)
	local bucket = handlers[eventName]
	if not bucket then
		return
	end
	-- Copy so handlers may subscribe/unsubscribe during dispatch.
	local snapshot = table.clone(bucket)
	local body = payload or {}
	for _, entry in snapshot do
		local ok, err = pcall(entry.callback, body)
		if not ok then
			warn(string.format("[ForgePilot] handler error for '%s': %s", eventName, tostring(err)))
		end
	end
end

function EventBus.clear(eventName: string?)
	if eventName then
		handlers[eventName] = nil
	else
		table.clear(handlers)
	end
end

function EventBus.listenerCount(eventName: string): number
	local bucket = handlers[eventName]
	return bucket and #bucket or 0
end

return EventBus