--!strict
--[[
	ForgePilot / AI / QuestionManager
	Interactive questions inside the chat.

	The model can pause a task and ask the user for input. Questions are rendered
	as functional cards. Answering resumes the SAME task from its existing state;
	the conversation is never restarted.

	"L et AI Decide" is resolved by a real follow-up provider call that sees the
	game context and the user's original request, so the decision is grounded
	rather than hard-coded.
]]

local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local Time = require(script.Parent.Parent.Utilities.Time)

local QuestionManager = {}

export type QuestionKind = "single" | "multiple" | "text" | "number" | "boolean" | "confirm"

export type Option = {
	id: string,
	label: string,
	description: string?,
}

export type Question = {
	id: string,
	taskId: string,
	kind: QuestionKind,
	prompt: string,
	detail: string?,
	options: { Option }?,
	allowCustom: boolean,
	allowAiDecide: boolean,
	placeholder: string?,
	required: boolean,
	createdAt: number,
	answered: boolean,
	answer: any?,
	answeredAt: number?,
	-- Optional task the model wanted answered, used to build the resume prompt.
	context: string?,
}

local pending: Question? = nil
local resolver: ((answer: any) -> ())? = nil
local rejecter: ((reason: string) -> ())? = nil

--=============================================================================
-- CONSTRUCTION
--=============================================================================

local function normaliseKind(kind: any, hasOptions: boolean): QuestionKind
	if kind == "single" or kind == "multiple" or kind == "text" or kind == "number" or kind == "boolean" or kind == "confirm" then
		return kind
	end
	if hasOptions then
		return "single"
	end
	return "text"
end

--- Asks a question and returns the user's answer.
--- Yields until answered, cancelled, or the question times out.
function QuestionManager.ask(spec: {
	taskId: string,
	kind: any?,
	prompt: string,
	detail: string?,
	options: { any }?,
	allowCustom: boolean?,
	allowAiDecide: boolean?,
	placeholder: string?,
	required: boolean?,
	context: string?,
	timeoutSeconds: number?,
}): any
	local settings = SettingsManager.get()

	local options: { Option } = {}
	for index, raw in (spec.options or {}) do
		if type(raw) == "string" then
			options[#options + 1] = { id = raw, label = raw }
		elseif type(raw) == "table" and type(raw.label) == "string" then
			options[#options + 1] = {
				id = type(raw.id) == "string" and raw.id or raw.label,
				label = raw.label,
				description = if type(raw.description) == "string" then raw.description else nil,
			}
		end
		-- Unrecognised option shapes are dropped rather than passed through.
		_ = index
	end

	local question: Question = {
		id = Time.newId("q"),
		taskId = spec.taskId,
		kind = normaliseKind(spec.kind, #options > 0),
		prompt = string.sub(spec.prompt or "Input required", 1, 500),
		detail = if type(spec.detail) == "string" then string.sub(spec.detail, 1, 1000) else nil,
		options = if #options > 0 then options else nil,
		allowCustom = spec.allowCustom ~= false,
		allowAiDecide = spec.allowAiDecide ~= false and settings.letAiDecide,
		placeholder = spec.placeholder or "Type your answer",
		required = spec.required ~= false,
		createdAt = os.clock(),
		answered = false,
		context = spec.context,
	}

	pending = question
	Logger.log("QUESTION", "Question", "Waiting for user response.", {
		detail = question.prompt,
		taskId = question.taskId,
	})

	local timeout = spec.timeoutSeconds or 1800
	local started = os.clock()

	local finished = false
	local answerValue: any = nil
	local failure: string? = nil

	resolver = function(value)
		answerValue = value
		finished = true
	end
	rejecter = function(reason)
		failure = reason
		finished = true
	end

	EventBus.emit(EventBus.Events.QuestionAsked, { question = table.clone(question) })

	while not finished do
		if StateManager.get() == "CANCELLED" then failure = "Task cancelled."; break end
		if os.clock() - started > timeout then
			failure = string.format("The question timed out after %d seconds.", math.floor(timeout))
			break
		end
		task.wait(0.2)
	end

	local questionId = question.id
	pending = nil
	resolver = nil
	rejecter = nil

	if failure then
		Logger.warn("Question", "The question was not answered.", {
			detail = failure,
			taskId = question.taskId,
		})
		EventBus.emit(EventBus.Events.QuestionCancelled, { questionId = questionId, reason = failure })
		return nil
	end

	return answerValue
end

--=============================================================================
-- UI BRIDGE
--=============================================================================

--- Called by the question card when the user submits.
function QuestionManager.submit(value: any, questionId: string?): boolean
	local question = pending
	if not question or question.answered or (questionId and questionId ~= question.id) then
		return false
	end

	local cleaned = QuestionManager.validate(question, value)
	if cleaned == nil then
		EventBus.emit(EventBus.Events.Toast, {
			kind = "error",
			message = "That answer is not valid for this question.",
		})
		return false
	end

	question.answered = true
	question.answer = cleaned
	question.answeredAt = os.clock()

	Logger.success("Question", "Question answered.", {
		detail = string.format("%s → %s", question.prompt, QuestionManager.formatAnswer(cleaned)),
		taskId = question.taskId,
	})

	EventBus.emit(EventBus.Events.QuestionAnswered, {
		questionId = question.id,
		answer = cleaned,
	})

	local callback = resolver
	if callback then
		callback(cleaned)
	end
	return true
end

--- Called when the user cancels the question.
function QuestionManager.cancel(reason: string?, questionId: string?): boolean
	local question = pending
	if not question or question.answered or (questionId and questionId ~= question.id) then
		return false
	end
	question.answered = true
	question.answer = nil

	Logger.warn("Question", "Question cancelled.", {
		detail = reason or "The user cancelled the question.",
		taskId = question.taskId,
	})
	EventBus.emit(EventBus.Events.QuestionCancelled, {
		questionId = question.id,
		reason = reason or "cancelled",
	})

	local callback = rejecter
	if callback then
		callback(reason or "The user cancelled the question.")
	end
	return true
end

--- "Let AI Decide" — asks the model to choose using its own judgement.
function QuestionManager.letAiDecide(questionId: string?): boolean
	local question = pending
	if not question or question.answered or (questionId and questionId ~= question.id) then
		return false
	end
	if not question.allowAiDecide then
		EventBus.emit(EventBus.Events.Toast, {
			kind = "warning",
			message = "\"Let AI Decide\" is disabled in Agent settings.",
		})
		return false
	end

	Logger.info("Question", "Delegating the decision to the AI.", { taskId = question.taskId })
	question.answered = true
	question.answer = { __aiDecide = true }
	EventBus.emit(EventBus.Events.QuestionAnswered, {
		questionId = question.id,
		answer = { __aiDecide = true },
	})

	-- The waiter in ask() is released by `resolver`; without this the agent would
	-- spin until the question timeout (30 minutes by default).
	local callback = resolver
	if callback then
		callback({ __aiDecide = true })
	end
	return true
end

function QuestionManager.getPending(): Question?
	return pending
end

--=============================================================================
-- VALIDATION
--=============================================================================

--- Returns a cleaned answer, or nil when the value does not satisfy the question.
function QuestionManager.validate(question: Question, value: any): any
	if type(value) == "table" and value.__custom == true then
		if not question.allowCustom or type(value.text) ~= "string" then return nil end
		local text = StringUtil.trim(value.text)
		if text == "" then return nil end
		return if question.kind == "multiple" then { text } else text
	end
	if question.kind == "text" then
		if type(value) ~= "string" then
			return nil
		end
		local trimmed = StringUtil.trim(value)
		if question.required and #trimmed == 0 then
			return nil
		end
		return trimmed
	end

	if question.kind == "number" then
		local numberValue = tonumber(value)
		if numberValue == nil then
			return nil
		end
		return numberValue
	end

	if question.kind == "boolean" or question.kind == "confirm" then
		if type(value) == "boolean" then
			return value
		end
		return nil
	end

	if question.kind == "single" then
		if type(value) ~= "string" then
			return nil
		end
		for _, option in (question.options or {}) do
			if option.id == value then
				return option.label
			end
		end
		return nil
	end

	if question.kind == "multiple" then
		if type(value) ~= "table" then
			return nil
		end
		local valid = {}
		local allowed: { [string]: boolean } = {}
		for _, option in (question.options or {}) do
			allowed[option.id] = true
		end
		for _, entry in value do
			if type(entry) ~= "string" or not allowed[entry] then
				return nil
			end
			valid[#valid + 1] = entry
		end
		if question.required and #valid == 0 then
			return nil
		end
		return valid
	end

	return nil
end

function QuestionManager.formatAnswer(answer: any): string
	if type(answer) == "boolean" then
		return answer and "Yes" or "No"
	elseif type(answer) == "string" then
		return answer
	elseif type(answer) == "table" then
		if answer.__aiDecide then
			return "(AI decides)"
		end
		if answer.__custom then
			return "(custom answer)"
		end
		local parts = {}
		for _, entry in answer do
			parts[#parts + 1] = tostring(entry)
		end
		return table.concat(parts, ", ")
	end
	return tostring(answer)
end

--=============================================================================
-- RESUME PROMPT
--=============================================================================

--- Builds the message appended to the conversation after an answer arrives, so
--- the model can continue the SAME task rather than start over.
function QuestionManager.resumePrompt(question: Question, answer: any): string
	local parts = { "The user answered your question." }
	parts[#parts + 1] = string.format('Question: "%s"', question.prompt)
	parts[#parts + 1] = string.format("Answer: %s", QuestionManager.formatAnswer(answer))
	if question.context and #question.context > 0 then
		parts[#parts + 1] = string.format("That was needed for: %s", question.context)
	end
	parts[#parts + 1] = "Continue the task from where you stopped. Do not repeat the analysis you already did."
	return table.concat(parts, "\n")
end

return QuestionManager
