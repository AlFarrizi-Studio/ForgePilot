--!strict
--[[
	ForgePilot / AI / AdapterTypes
	Shared shapes every protocol adapter produces and consumes.

	Adapters are intentionally pure: they translate between the plugin's internal
	representation and a provider's wire format. They never perform I/O, never
	touch the DataModel, and never log message bodies.
]]

local AdapterTypes = {}

export type ContentPart =
	| { kind: "text", text: string }
	| { kind: "image", mime: string, data: string, fileName: string? }
	| { kind: "document", mime: string, data: string, fileName: string?, kind2: string? }
	| { kind: "audio", mime: string, data: string, fileName: string? }
	| { kind: "video", mime: string, data: string, fileName: string? }

export type ChatMessage = {
	role: "system" | "user" | "assistant" | "tool",
	content: string?,
	parts: { ContentPart }?,
	toolCallId: string?,
	toolCalls: { { id: string, name: string, arguments: any } }?,
	toolResult: string?,
}

export type ToolDefinition = {
	name: string,
	description: string,
	-- JSON Schema object describing `arguments`.
	parameters: { [string]: any },
}

export type RequestSpec = {
	messages: { ChatMessage },
	system: string?,
	tools: { ToolDefinition }?,
	toolChoice: "auto" | "none" | "required",
	model: string,
	temperature: number?,
	topP: number?,
	maxOutputTokens: number?,
	streaming: boolean,
	jsonMode: boolean,
	reasoningEffort: string?,
	reasoningSummary: boolean?,
	responseFormatName: string?,
	stopSequences: { string }?,
	cacheKey: string?,
	safetySettings: { any }?,
}

export type Usage = {
	inputTokens: number?,
	outputTokens: number?,
	reasoningTokens: number?,
	cachedTokens: number?,
	source: "provider" | "estimated" | "none",
}

export type ToolCall = {
	id: string,
	name: string,
	arguments: any,
	rawArguments: string?,
}

export type ResponseChunk = {
	kind: "text" | "reasoning" | "tool_call_delta" | "usage" | "done" | "error" | "raw",
	text: string?,
	reasoning: string?,
	toolCall: ToolCall?,
	usage: Usage?,
	message: string?,
	raw: any?,
}

export type CompleteResponse = {
	text: string,
	reasoning: string?,
	toolCalls: { ToolCall },
	usage: Usage,
	stopReason: string?,
	raw: any?,
}

export type TestOutcome = {
	ok: boolean,
	statusCode: number?,
	message: string,
	latencyMs: number,
	usage: Usage?,
	model: string?,
	body: any?,
}

return AdapterTypes