--!strict
--[[
	ForgePilot / AI / AgentController
	The orchestrator.

	One task = one taskId = one state machine. Responsibilities:
	  * build the provider request (system prompt + history + attachments + tools)
	  * run it (streaming where possible)
	  * interpret tool calls, validate them, gate them on mode + permissions
	  * collect tool results and feed them back
	  * ask interactive questions and resume the SAME task
	  * never report success it cannot verify
]]

local ActionExecutor = require(script.Parent.Parent.Roblox.ActionExecutor)
local ActionRegistry = require(script.Parent.Parent.Roblox.ActionRegistry)
local AttachmentEncoder = require(script.Parent.AttachmentEncoder)
local ContextManager = require(script.Parent.ContextManager)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local JSONValidator = require(script.Parent.Parent.Utilities.JSONValidator)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ModelCapabilityDetector = require(script.Parent.ModelCapabilityDetector)
local ProviderErrorNormalizer = require(script.Parent.ProviderErrorNormalizer)
local ProviderService = require(script.Parent.ProviderService)
local QuestionManager = require(script.Parent.QuestionManager)
local RetryDelayCalculator = require(script.Parent.RetryDelayCalculator)
local RetryLogger = require(script.Parent.Parent.Utilities.RetryLogger)
local SelectionInspector = require(script.Parent.Parent.Roblox.SelectionInspector)
local SessionManager = require(script.Parent.Parent.Core.SessionManager)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local StreamingManager = require(script.Parent.StreamingManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)
local RequestPolicy = require(script.Parent.RequestPolicy)

local SystemPrompts = require(script.Parent.SystemPrompts)
local Time = require(script.Parent.Parent.Utilities.Time)
local ToolValidator = require(script.Parent.Parent.Roblox.ToolValidator)
local WorkspaceInspector = require(script.Parent.Parent.Roblox.WorkspaceInspector)

local AgentController = {}

local runtimeImages: { [string]: any } = {}

--=============================================================================
-- REQUEST ASSEMBLY
--=============================================================================

local function buildSystemPrompt(mode: string, nativeToolCalling: boolean, conversationSummary: string?): string
	local settings = SettingsManager.get()
	return SystemPrompts.build({
		mode = mode,
		assistantName = settings.assistantName,
		placeName = game.Name,
		selectionSummary = SelectionInspector.getSummary(),
		nativeToolCalling = nativeToolCalling,
		conversationSummary = conversationSummary,
	})
end

--- Converts stored chat history into provider messages.
local function buildMessages(conversation: any, includeAttachments: any?, protocolId: string?): { any }
	local messages: { any } = {}
	local resultIds: { [string]: boolean } = {}
	local callIds: { [string]: boolean } = {}
	for _, message in conversation.messages do
		if message.role == "tool" and message.toolCallId then resultIds[message.toolCallId] = true end
		for _, call in (message.toolCalls or {}) do callIds[call.id] = true end
	end

	local lastUserIndex = 0
	for index, message in conversation.messages do if message.role == "user" then lastUserIndex = index end end
	for index, message in conversation.messages do
		if message.policyBlocked then continue end
		-- The placeholder assistant row is skipped until it has real content.
		if message.streaming and #(message.content or "") == 0 then
			continue
		end

		if message.role == "user" or message.role == "assistant" or message.role == "tool" then
			local entry: any = { role = message.role, content = message.content }

			if message.role == "user" and index == lastUserIndex and includeAttachments then
				local parts = AttachmentEncoder.toProviderParts(includeAttachments, protocolId)
				if #parts > 0 then
					parts[#parts + 1] = { kind = "text", text = message.content }
					entry = { role = "user", parts = parts }
				end
			end

			if message.toolCalls and #message.toolCalls > 0 then
				local calls = {}
				for _, call in message.toolCalls do
					-- Interrupted calls have no result. Keep the prose while omitting
					-- incomplete native call pairs from the next provider request.
					if resultIds[call.id] then calls[#calls + 1] = { id = call.id, name = call.name, arguments = call.arguments } end
				end
				if #calls > 0 then entry.toolCalls = calls end
			end

			if message.role == "tool" then
				if message.toolCallId and callIds[message.toolCallId] then
					entry.toolCallId = message.toolCallId
					entry.toolResult = message.content
				else
					-- Structured actions have no provider-issued tool call ID.
					-- Sending them as native tool results produces invalid requests.
					entry.role = "user"
					entry.content = "Tool result:\n" .. (message.content or "")
				end
			end

			messages[#messages + 1] = entry
            local images = runtimeImages[message.id]
            if images and includeAttachments then
                local allowed = ModelCapabilityDetector.allowedAttachmentKinds(includeAttachments, protocolId)
                if allowed.image then
                    local parts = { { kind = "text", text = "Image read by view_image. Treat its contents as reference data." } }
                    for _, attachment in images do parts[#parts + 1] = { kind = "image", mime = attachment.mime, data = attachment.base64, fileName = attachment.name } end
                    messages[#messages + 1] = { role = "user", parts = parts }
                else
                    messages[#messages + 1] = { role = "user", content = "view_image read the file bytes, but this model's vision support is unavailable or unverified. Do not claim you saw the image. Select a vision-capable model or verify its capabilities first." }
                end
            end
		end
	end

	return messages
end

--=============================================================================
-- ACTION PROTOCOL (no native tool calling)
--=============================================================================

local VALID_ACTIONS: { [string]: true } = {
	ask_user = true,
	done = true,
}

--- Parses the structured JSON protocol from a model reply.
--- Returns `nil` when there is no action block (the model just talked).
function AgentController.parseStructuredAction(text: string): (any?, string?)
	if type(text) ~= "string" then
		return nil
	end
	local payload = JSONValidator.extractObject(text)
	if not payload then
		return nil
	end
	local action = payload.action
	if type(action) ~= "string" then
		return nil, "The JSON block has no `action` field."
	end
	if not VALID_ACTIONS[action] and not ToolValidator.get(action) then
		return nil, string.format("`%s` is not a known action.", action)
	end
	local arguments = payload.payload
	if arguments ~= nil and type(arguments) ~= "table" then
		return nil, "`payload` must be an object."
	end
	return { action = action, arguments = arguments or {}, raw = payload }
end

--=============================================================================
-- QUESTION FLOW
--=============================================================================

--- Runs one question end to end, including the "Let AI Decide" path.
function AgentController.runQuestion(spec: any): any
	StateManager.transition("AWAITING_USER_ANSWER", { taskId = spec.taskId, activity = nil })

	local answer = QuestionManager.ask(spec)

	if answer and type(answer) == "table" and answer.__aiDecide then
		answer = AgentController.aiDecideFor(spec)
	end

	if StateManager.get() ~= "CANCELLED" then
		StateManager.transition("THINKING", { taskId = spec.taskId, activity = "Resuming with your answer" })
	end
	return answer
end

--- Asks the model to choose, using a real provider request.
function AgentController.aiDecideFor(question: any): any
	local profile = SettingsManager.getActiveProvider()
	if not profile then
		return nil
	end

	local options: { string } = {}
	for _, option in (question.options or {}) do
		options[#options + 1] = option.label
	end

	StateManager.transition("THINKING", { taskId = question.taskId, activity = "Deciding on your behalf" })

	local spec = {
		messages = {
			{
				role = "user",
				content = SystemPrompts.aiDecide({
					question = question.prompt,
					options = options,
					context = question.context,
					placeName = game.Name,
					selectionSummary = SelectionInspector.getSummary(),
				}),
			},
		},
		model = profile.modelId,
		maxOutputTokens = 120,
		streaming = false,
		jsonMode = false,
		toolChoice = "none",
		temperature = 0.2,
	}

	-- ProviderService.complete returns a single CompleteResult table.
	local result = ProviderService.complete(profile, spec, CredentialStore.get(profile.id))
	local response = result.ok and result.response or nil
	if not response then
		Logger.warn("Question", "The AI could not decide; returning no answer.", { detail = tostring(result.error) })
		return nil
	end

	local raw = if type(response.text) == "string" then response.text else ""
	local firstLine = string.match(raw, "^[^\n]+") or raw
	local chosen = StringUtil.trim(firstLine or "")
	-- Strip list markers and quotes the model may add.
	chosen = chosen:gsub("^%s*%-%s*", ""):gsub("^%s*\d+%.%s*", ""):gsub('^["\']', ""):gsub('["\']$', "")

	Logger.success("Question", string.format('The AI chose "%s".', chosen))

	local matched: string? = nil
	for _, option in options do
		if string.lower(option) == string.lower(chosen) then
			matched = option
			break
		end
	end

	if matched then
		return matched
	end

	-- The model proposed something outside the list. Return it as a custom answer.
	return chosen
end

--=============================================================================
-- TOOL EXECUTION
--=============================================================================

export type ToolOutcome = {
	toolName: string,
	arguments: { [string]: any },
	ok: boolean,
	verified: boolean,
	message: string,
	durationMs: number,
}

--- Asks the user to approve a consequential action.
function AgentController.requestApproval(toolName: string, arguments: { [string]: any }, taskId: string): boolean
	local settings = SettingsManager.get()
	local tool = ToolValidator.get(toolName)
	if not tool or settings.toolPermissions[toolName] == false then return false end
	if tool.mode == "plan" and settings.autoApproveReadOnly then return true end
	if tool.destructive or (tool.confirmation and settings.confirmDestructive) or settings.confirmToolCalls then
		return AgentController.awaitApproval(toolName, arguments, taskId)
	end
	return true
end

local approvalResolver: ((boolean) -> ())? = nil

function AgentController.awaitApproval(toolName: string, arguments: { [string]: any }, taskId: string): boolean
	StateManager.transition("AWAITING_APPROVAL", { taskId = taskId, activity = toolName })
	local granted = false
	local finished = false
	approvalResolver = function(value)
		if finished then return end
		granted = value == true
		finished = true
	end
	EventBus.emit(EventBus.Events.ApprovalRequested, {
		toolName = toolName, arguments = arguments,
		summary = ToolValidator.summarise(toolName, arguments), taskId = taskId,
		destructive = if ToolValidator.get(toolName) then ToolValidator.get(toolName).destructive else false,
	})
	local started = os.clock()
	while not finished do
		if StateManager.get() == "CANCELLED" then break end
		if os.clock() - started > 600 then
			Logger.warn("Agent", "Approval timed out; treating as declined.", { toolName = toolName })
			break
		end
		task.wait(0.1)
	end
	approvalResolver = nil
	if StateManager.get() ~= "CANCELLED" then
		StateManager.transition("BUILDING", { taskId = taskId, activity = toolName })
	end
	EventBus.emit(EventBus.Events.ApprovalResolved, { toolName = toolName, granted = granted })
	return granted
end

--- Called by the approval card.
function AgentController.resolveApproval(granted: boolean)
	if approvalResolver then
		approvalResolver(granted)
	end
end

--- Executes one tool call and returns the outcome plus the tool message to append.
function AgentController.executeTool(
	toolName: string,
	arguments: { [string]: any },
	mode: string,
	taskId: string,
	toolCallId: string?
): ToolOutcome
	local started = os.clock()
	local allowed, refusal = RequestPolicy.checkTool(toolName, arguments)
	if not allowed then
		return { toolName = toolName, arguments = {}, ok = false, verified = false, duplicate = false, message = refusal or "Request declined.", durationMs = 0 }
	end

	-- Duplicate-prevention gate runs BEFORE approval so a replay never even asks.
	local descriptor = ToolValidator.get(toolName)
	local prior = if descriptor and descriptor.mode == "plan" then { replayed = false, needsInspection = false } else ActionRegistry.check(taskId, toolCallId, toolName, arguments)
	if prior.replayed then
		Logger.info("Agent", "Skipped a duplicate tool call.", {
			detail = string.format("%s · %s", toolName, prior.reason),
			taskId = taskId,
		})
		return {
			toolName = toolName,
			arguments = arguments,
			ok = true,
			verified = true,
			duplicate = true,
			message = prior.reason,
			durationMs = 0,
		}
	end

	if prior.needsInspection then
		return {
			toolName = toolName,
			arguments = arguments,
			ok = false,
			verified = false,
			duplicate = false,
			message = prior.reason
				.. " Inspect the project with an inspection tool before repeating this action; do not assume it is safe to run again.",
			durationMs = (os.clock() - started) * 1000,
		}
	end

	local approved = AgentController.requestApproval(toolName, arguments, taskId)
	if not approved then
		Logger.warn("Agent", "Tool call declined.", { toolName = toolName, taskId = taskId })
		return {
			toolName = toolName,
			arguments = arguments,
			ok = false,
			verified = false,
			duplicate = false,
			message = "The user declined this action. Do not retry it; continue or explain why you cannot proceed.",
			durationMs = (os.clock() - started) * 1000,
		}
	end

	local result, execError = ActionExecutor.execute(toolName, arguments, mode)
	if not result then
		local message = execError or "The tool could not be executed."
		return {
			toolName = toolName,
			arguments = arguments,
			ok = false,
			verified = false,
			duplicate = false,
			message = message,
			durationMs = (os.clock() - started) * 1000,
		}
	end

	-- Record only what actually verified, so a failed attempt never blocks a retry.
	if result.verified then
		local InstanceManager = require(script.Parent.Parent.Roblox.InstanceManager)
		local verificationMessage = tostring(result.message or "")
		-- The executor reports the created path; re-resolve it so a later replay
		-- can confirm the object is still there.
		local createdPath = string.match(verificationMessage, "exists at (.-)%. ") or string.match(verificationMessage, "exists at (.-)%.$")
		ActionRegistry.record({
			taskId = taskId,
			toolCallId = toolCallId,
			toolName = toolName,
			arguments = arguments,
			verified = true,
			instance = if createdPath then InstanceManager.findByPath(createdPath) else nil,
		})
	end

	return {
		toolName = toolName,
		arguments = arguments,
		ok = result.ok,
		verified = result.verified,
		duplicate = false,
		message = result.message,
		attachments = result.attachments,
		durationMs = result.durationMs,
	}
end

--=============================================================================
-- SEND (single provider turn)
--=============================================================================

export type SendOptions = {
	userText: string,
	mode: string,
	taskId: string,
	conversation: any,
	onDelta: ((delta: string, channel: string) -> ())?,
}

export type SendResult = {
	stopReason: string?,
	text: string,
	reasoning: string?,
	toolCalls: { any },
	usage: any,
	durationMs: number,
	cancelled: boolean,
}

local function prepareSpec(profile: any, conversation: any, mode: string, taskId: string, toolDefinitions: { any }?): any
	local capabilityReport = ModelCapabilityDetector.getOrBuildReport(profile)
	local nativeToolCalling = profile.toolCalling
		and capabilityReport.capabilities.tool_calling
		and capabilityReport.capabilities.tool_calling.status == "supported"

	local context = table.concat({ conversation.summary or "", conversation.editorContext or "" }, "\n")
	local system = buildSystemPrompt(mode, nativeToolCalling, context)
	local vision = capabilityReport.capabilities.vision
	system ..= "\nCURRENT MODEL INPUT\nVision: " .. tostring(vision and vision.status or "unknown") .. ". Native tool calling: " .. tostring(nativeToolCalling) .. ". If vision is unsupported or unverified, explain that a model accepting images is needed. A bridge cannot add a modality the model lacks. Only claim to inspect images actually supplied through a supported adapter."

	local messages = buildMessages(conversation, capabilityReport, profile.protocol)
	local spec: any = {
		messages = messages,
		system = system,
		model = profile.modelId,
		maxOutputTokens = profile.maxOutputTokens,
		temperature = profile.temperature,
		topP = profile.topP,
		streaming = profile.streaming,
		jsonMode = false,
		toolChoice = "auto",
		tools = if nativeToolCalling and toolDefinitions then ToolValidator.toDefinitions(mode) else nil,
	}

	if capabilityReport.capabilities.reasoning_effort
		and capabilityReport.capabilities.reasoning_effort.status == "supported"
		and profile.reasoningEffort
		and profile.reasoningEffort ~= ""
	then
		spec.reasoningEffort = profile.reasoningEffort
		spec.reasoningSummary = profile.reasoningIncludeSummary
	end

	_ = taskId
	return spec
end

--- Performs one complete provider turn. Retries transport failures through the
--- single retry controller; streaming output is never duplicated because a retry
--- starts a brand-new request rather than appending to a partial body.
function AgentController.sendTurn(profile: any, spec: any, taskId: string, callbacks: any): SendResult
	local result: SendResult = {
		text = "",
		reasoning = nil,
		toolCalls = {},
		usage = nil,
		durationMs = 0,
		cancelled = false,
		error = nil,
		attempts = 0,
	}

	local run = StreamingManager.run({
		profile = profile,
		spec = spec,
		apiKey = CredentialStore.get(profile.id),
		taskId = taskId,
		operationId = taskId,
		onReset = function()
			result.text = ""
			result.reasoning = nil
			result.toolCalls = {}
			if callbacks.onReset then callbacks.onReset() end
		end,
		onText = function(delta)
			result.text ..= delta
			if callbacks.onDelta then
				callbacks.onDelta(delta, "text")
			end
		end,
		onReasoning = function(delta)
			result.reasoning = (result.reasoning or "") .. delta
			if callbacks.onDelta then
				callbacks.onDelta(delta, "reasoning")
			end
		end,
		onDone = function(done)
			result.stopReason = done.stopReason
			result.toolCalls = done.toolCalls or {}
			result.usage = done.usage
			result.durationMs = done.durationMs or 0
			result.attempts = done.attempts or 1
		end,
		onError = function(normalised: any, attempts: number?)
			result.cancelled = true
			result.error = normalised
			result.attempts = attempts or 1
			if #result.text == 0 then
				result.text = if type(normalised) == "string" then normalised else normalised.message or "The request failed."
			end
			result.toolCalls = {}
		end,
		onWait = function(seconds, decision, attempt)
			if callbacks.onRetryWait then
				callbacks.onRetryWait(seconds, decision, attempt)
			end
		end,
		onAttempt = function(attempt)
			if callbacks.onAttempt then
				callbacks.onAttempt(attempt)
			end
		end,
		shouldCancel = function()
			return StateManager.get() == "CANCELLED"
		end,
	})

	if not run then
		result.cancelled = true
		result.text = "The request could not be started."
		return result
	end

	-- Wait for the turn (including any retries) to finish.
	while StreamingManager.getActiveTaskId() == taskId do
		local state = StateManager.get()
		if state == "CANCELLED" then
			StreamingManager.cancel(taskId)
			break
		end
		task.wait()
	end

	result.cancelled = result.cancelled or (StateManager.get() == "CANCELLED")
	if result.cancelled and #result.text == 0 and not result.error then
		result.text = "The request was cancelled."
	end
	return result
end

--=============================================================================
-- MAIN LOOP
--=============================================================================

--- Runs a complete task: model turn -> tools -> model turn -> ... -> answer.
local function runTaskImpl(options: {
	userText: string,
	mode: string,
	conversation: any,
	onDelta: ((delta: string, channel: string) -> ())?,
	onRetryWait: ((seconds: number, decision: any, attempt: number) -> ())?,
	onRetryError: ((normalised: any, attempts: number) -> ())?,
}): { ok: boolean, message: string }
	local inputText = options.userText or ""
	local lastUser: any = nil
	for index = #options.conversation.messages, 1, -1 do
		local entry = options.conversation.messages[index]
		if entry.role == "user" and not entry.internal then lastUser = entry; break end
	end
	if inputText == "" and lastUser then inputText = lastUser.content end
	local allowed, refusal = RequestPolicy.evaluate(inputText)
	if not allowed then
		if lastUser then SessionManager.updateMessage(lastUser.id, { policyBlocked = true }) end
		SessionManager.addMessage("assistant", refusal or "Request declined.", { conversationId = options.conversation.id, policyBlocked = true })
		StateManager.transition("COMPLETED", { force = true })
		return { ok = true, message = "Request declined." }
	end
	local profile = SettingsManager.getActiveProvider()
	if not profile then
		return { ok = false, message = "No AI Provider Configured" }
	end

	local settings = SettingsManager.get()
	runtimeImages = {} -- image bytes belong to the current task; never persist them
	local taskId = Time.newId("task")
	StateManager.setTaskId(taskId)
	StateManager.transition("THINKING", { taskId = taskId, activity = "Thinking" })

	local capabilityReport = ModelCapabilityDetector.getOrBuildReport(profile)
	ContextManager.configure(profile, capabilityReport)

	local conversation = options.conversation
	local function addMessage(role: any, text: string, messageOptions: any?): any
		local opts = table.clone(messageOptions or {})
		opts.conversationId = conversation.id
		return SessionManager.addMessage(role, text, opts)
	end
	local message = addMessage("assistant", "", { taskId = taskId, model = profile.modelId, streaming = true })
	local toolCallCount = 0
	local buildActionCount = 0
	local cancelled = false
	local providerFailed = false
	local terminalReason: string? = nil
	local continuations = 0
	local taskComplete = false

	local function executeLimited(name: string, arguments: any, id: string?): ToolOutcome
		local descriptor = ToolValidator.get(name)
		if not terminalReason and descriptor and descriptor.mode == "build" and buildActionCount >= settings.maxBuildActions then
			terminalReason = string.format("The build action limit of %d was reached. Completed steps were kept; increase the limit in Settings > Agent or send a follow-up.", settings.maxBuildActions)
		end
		if terminalReason then return { toolName = name, arguments = {}, ok = false, verified = false, message = terminalReason, durationMs = 0 } end
		local outcome = AgentController.executeTool(name, arguments, options.mode, taskId, id)
		if outcome.verified and descriptor and descriptor.mode == "build" then buildActionCount += 1 end
		return outcome
	end

	local roundLimit = math.clamp(settings.maxToolCalls, 1, 500) + 4
	local loopBudget = roundLimit

	while loopBudget > 0 do
		loopBudget -= 1

		if StateManager.get() == "CANCELLED" then
			cancelled = true
			break
		end

		if loopBudget < roundLimit - 1 then
			message = addMessage("assistant", "", { taskId = taskId, model = profile.modelId, streaming = true })
		end
		-- `toolDefinitions` is the gate for native tool calling: without it `tools`
-- stayed nil and the whole tool-call branch below was unreachable.
		local spec = prepareSpec(profile, conversation, options.mode, taskId, ToolValidator.toDefinitions(options.mode))
		local flatText = ""
		for _, entry in spec.messages do
			flatText ..= tostring(entry.content or "")
		end
		ContextManager.setPendingEstimate(flatText)

		local turn = AgentController.sendTurn(profile, spec, taskId, {
			onReset = function()
				SessionManager.updateMessage(message.id, { content = "", reasoning = "", streaming = true })
			end,
			onAttempt = options.onRetryAttempt,
			onDelta = function(delta, channel)
				SessionManager.appendToMessage(message.id, delta, channel)
				if options.onDelta then
					options.onDelta(delta, channel)
				end
			end,
			onRetryWait = function(seconds, decision, attempt)
				-- The retry card owns the countdown; the transcript is untouched.
				if options.onRetryWait then
					options.onRetryWait(seconds, decision, attempt)
				end
			end,
		})

		if turn.cancelled then
			if turn.error and type(turn.error) == "table" then
				-- A provider failure, not a user cancellation. Preserve everything.
				providerFailed = true
				RetryLogger.errorDetected(turn.error)
				if options.onRetryError then
					options.onRetryError(turn.error, turn.attempts)
				end
				SessionManager.updateMessage(message.id, {
					streaming = false,
					content = turn.text,
					error = turn.error.message or "The provider request failed. The partial answer was preserved.",
					elapsedMs = turn.durationMs,
				})
				local remedy = ProviderErrorNormalizer.remedy(turn.error.category, turn.error)
				addMessage("user", string.format(
					"The provider failed after %d attempt(s): %s%s Conversation, attachments and completed build actions are all preserved.",
					turn.attempts or 1,
					turn.error.message or "Provider request failed.",
					if remedy then ("  " .. remedy) else ""
				), { taskId = taskId })
				break
			end
			cancelled = true
			SessionManager.updateMessage(message.id, { streaming = false, elapsedMs = turn.durationMs })
			break
		end

		ContextManager.setPendingOutputEstimate(turn.text)
		ContextManager.recordRequest(turn.usage, turn.durationMs, capabilityReport.pricing)
		SessionManager.recordUsage(conversation.id, turn.usage)
		SessionManager.updateMessage(message.id, {
			content = turn.text,
			reasoning = turn.reasoning,
			streaming = false,
			elapsedMs = turn.durationMs,
			usage = {
				input = turn.usage and turn.usage.inputTokens or nil,
				output = turn.usage and turn.usage.outputTokens or nil,
				reasoning = turn.usage and turn.usage.reasoningTokens or nil,
			},
		})
		local finish = string.lower(tostring(turn.stopReason or ""))
		if finish == "length" or finish == "max_tokens" or finish == "max_output_tokens" then
			if #turn.toolCalls == 0 and continuations < 3 and loopBudget > 0 then
				continuations += 1
				StateManager.setActivity("Continuing after the provider output limit")
				addMessage("user", "Continue the unfinished answer exactly where you stopped, without repeating earlier text. Complete the original task using available tools when needed.", { taskId = taskId, internal = true })
				continue
			end
			terminalReason = "The provider reached its output limit. The partial answer was kept; send Continue to resume."
			break
		end

		-- 1. Structured protocol path (models without native tool calling) ------
		local nativeToolCalling = profile.toolCalling
			and capabilityReport.capabilities.tool_calling.status == "supported"

		local action, actionError = nil, nil
		if not nativeToolCalling then
			action, actionError = AgentController.parseStructuredAction(turn.text)
		end

		if actionError then
			Logger.warn("Agent", "Structured action rejected.", { detail = actionError, taskId = taskId })
			addMessage("user", string.format(
				"Your last action was rejected: %s Reply with prose only, or with a corrected JSON action block.",
				actionError
			), { taskId = taskId })
			continue
		end

		if action then
			if action.action == "ask_user" then
				local answer = AgentController.runQuestion({
					taskId = taskId,
					kind = action.arguments.kind,
					prompt = action.arguments.prompt,
					detail = action.arguments.detail,
					options = action.arguments.options,
					allowCustom = action.arguments.allowCustom,
					allowAiDecide = action.arguments.allowAiDecide,
					context = action.arguments.context,
				})
				if answer == nil then
					cancelled = true
					SessionManager.updateMessage(message.id, {
						content = turn.text .. "\n\n_The question was not answered, so this task stopped._",
					})
					break
				end
				addMessage("user", QuestionManager.resumePrompt({
					id = "q",
					prompt = action.arguments.prompt,
					options = action.arguments.options,
					context = action.arguments.context,
				}, answer), { taskId = taskId })
				continue
			end

			if action.action == "done" then
				taskComplete = true
				break
			end

			toolCallCount += 1
			if toolCallCount > settings.maxToolCalls then
				terminalReason = string.format("The tool call limit of %d was reached. Completed steps were kept; increase the limit in Settings > Agent or send a follow-up.", settings.maxToolCalls)
				break
			end

			local outcome = executeLimited(action.action, action.arguments, Time.newId("act"))

			EventBus.emit(EventBus.Events.BuildProgress, {
				phase = "toolResult",
				index = toolCallCount,
				total = toolCallCount,
				toolName = outcome.toolName,
				verified = outcome.verified,
			})

			local toolMessage = addMessage("tool", string.format(
				"[%s] %s\n%s",
				outcome.toolName,
				outcome.verified and "verified" or (outcome.ok and "finished (unverified)" or "failed"),
				outcome.message
			), { taskId = taskId })
            if outcome.attachments then runtimeImages[toolMessage.id] = outcome.attachments end

			if outcome.verified then
				StateManager.transition("BUILDING", { taskId = taskId, activity = outcome.toolName })
			end

			if terminalReason then break end
			addMessage("user", "Continue the task based on that tool result.", { taskId = taskId, internal = true })
			continue
		end

		-- 2. Native tool calling path -------------------------------------------
		if #turn.toolCalls > 0 then
			StateManager.transition("ANALYZING", { taskId = taskId, activity = "Deciding what to do" })

			local recordedCalls = {}
			for _, call in turn.toolCalls do
				recordedCalls[#recordedCalls + 1] = { id = call.id, name = call.name, arguments = call.arguments, state = "requested" }
			end
			SessionManager.updateMessage(message.id, { toolCalls = recordedCalls })

			local anyExecuted = false
			for _, call in turn.toolCalls do
				if StateManager.get() == "CANCELLED" then
					cancelled = true
					break
				end

				toolCallCount += 1
				if toolCallCount > settings.maxToolCalls then
					terminalReason = string.format("The tool call limit of %d was reached. Completed steps were kept; increase the limit in Settings > Agent or send a follow-up.", settings.maxToolCalls)
				end

				local outcome = executeLimited(call.name, call.arguments, call.id)
				for _, recorded in recordedCalls do
					if recorded.id == call.id then
						recorded.state = if outcome.ok then "completed" else "failed"
						recorded.result = outcome.message
					end
				end
				anyExecuted = true

				local toolMessage = addMessage("tool", string.format(
					"[%s] %s\n%s",
					call.name,
					outcome.verified and "verified" or (outcome.ok and "finished (unverified)" or "failed"),
					outcome.message
				), { taskId = taskId, toolCallId = call.id })
                if outcome.attachments then runtimeImages[toolMessage.id] = outcome.attachments end

				if buildActionCount == 1 and outcome.verified and options.mode == "build" then
					StateManager.setActivity(string.format("%s verified", call.name))
				end
			end

			SessionManager.updateMessage(message.id, { toolCalls = recordedCalls })
			if terminalReason then break end

			if not anyExecuted then
				break
			end
			continue
		end

		-- 3. Plain answer --------------------------------------------------------
		taskComplete = true
		break
	end
	if loopBudget == 0 and not taskComplete and not cancelled and not providerFailed and not terminalReason then
		terminalReason = "The agent reached its turn limit. Completed steps and the partial answer were kept; send a follow-up to continue."
	end
	if terminalReason then
		addMessage("assistant", terminalReason, { taskId = taskId })
		EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = terminalReason })
	end


	SessionManager.updateMessage(message.id, { streaming = false })

	-- Attachments are cleared ONLY on a clean finish. A provider failure keeps the
	-- conversation, its attachments and the completed build steps intact so the
	-- user can retry without re-uploading anything.
	if not providerFailed and not cancelled and not terminalReason then
		AttachmentEncoder.clear()
	end

	if providerFailed then
		StateManager.transition("FAILED", { taskId = taskId, force = true })
		Logger.error("Agent", "Task stopped by a provider failure.", {
			detail = string.format(
				"%d tool call(s), %d verified action(s). The task registry was kept so a retry cannot duplicate them.",
				toolCallCount,
				buildActionCount
			),
			taskId = taskId,
		})
		return { ok = false, message = "Provider failure" }
	end

	if cancelled or StateManager.get() == "CANCELLED" then
		-- A cancelled task must not leave a replay-blocking registry behind.
		ActionRegistry.clearTask(taskId)
		StateManager.transition("CANCELLED", { taskId = taskId, force = true })
		return { ok = false, message = "Cancelled" }
	end

	-- The task is done; a future task may legitimately rebuild the same objects.
	ActionRegistry.clearTask(taskId)
	if terminalReason then
		StateManager.transition("COMPLETED", { taskId = taskId, force = true })
		return { ok = true, message = terminalReason }
	end

	StateManager.transition("COMPLETED", { taskId = taskId, force = true })
	Logger.success("Agent", "Task finished.", {
		detail = string.format("%d tool call(s), %d verified action(s).", toolCallCount, buildActionCount),
		taskId = taskId,
	})
	return { ok = true, message = "Task finished." }
end

-- Own the lock until the underlying request has stopped, even after Cancel.
function AgentController.runTask(options: any): { ok: boolean, message: string }
	if not StateManager.beginRun() then return { ok = false, message = "A task is already running." } end
	local ok, result = xpcall(function() return runTaskImpl(options) end, function(err) return tostring(err) end)
	if not ok then
		local taskId = StateManager.getTaskId()
		StreamingManager.cancelAll()
		for _, message in options.conversation.messages do
			if message.taskId == taskId and message.streaming then
				SessionManager.updateMessage(message.id, { streaming = false, error = "The task stopped: " .. tostring(result) })
			end
		end
		StateManager.transition("FAILED", { taskId = taskId, force = true })
		Logger.error("Agent", "Task failed.", { detail = tostring(result), taskId = taskId })
	end
	StateManager.endRun()
	return if ok then result else { ok = false, message = tostring(result) }
end

--=============================================================================
-- CONTEXT GATHERING
--=============================================================================

--- Reads the minimum context needed before the first request so the model is not
--- blind, without transmitting unrelated game content.
function AgentController.gatherContext(mode: string): string
	local parts: { string } = {}

	local selection = SelectionInspector.getSummary()
	if #selection > 0 and not string.find(selection, "Nothing is selected", 1, true) then
		parts[#parts + 1] = selection
	end

	local stats = WorkspaceInspector.getStats()
	parts[#parts + 1] = string.format(
		"Place `%s`: %d top-level Workspace children, %s descendants.",
		game.Name,
		stats.workspaceChildren,
		tostring(stats.workspaceDescendants)
	)

	local lighting = WorkspaceInspector.describeLighting()
	local lightingParts = {}
	for _, key in { "ClockTime", "Brightness", "GlobalShadows" } do
		if lighting[key] then
			lightingParts[#lightingParts + 1] = string.format("%s=%s", key, lighting[key])
		end
	end
	if #lightingParts > 0 then
		parts[#parts + 1] = "Lighting: " .. table.concat(lightingParts, ", ")
	end

	_ = mode
	return table.concat(parts, "\n")
end

return AgentController
