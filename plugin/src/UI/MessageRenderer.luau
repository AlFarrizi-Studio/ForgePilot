--!strict
-- A message owns its layout and returns a separate controller table.
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local Components = require(script.Parent.Components)
local Disclosure = require(script.Parent.Disclosure)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local Time = require(script.Parent.Parent.Utilities.Time)

local MessageRenderer = {}
export type Block = { kind: "text" | "code", content: string, language: string? }
export type RenderOptions = {
	onCopy: ((string) -> ())?, onRegenerate: ((string) -> ())?,
	onEdit: ((string) -> ())?, onRetry: ((string) -> ())?,
	onSwitchToBuild: ((string) -> ())?, onPlanAction: ((string, string) -> ())?,
	onToolExpand: ((string) -> ())?,
}

function MessageRenderer.escapeRichText(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function MessageRenderer.formatInline(text: string): string
	local code: { string } = {}
	local escaped = MessageRenderer.escapeRichText(text)
	escaped = escaped:gsub("`([^`]+)`", function(value)
		code[#code + 1] = '<font face="Code" color="#C6B2F5">' .. value .. '</font>'
		return "\1" .. #code .. "\2"
	end)
	escaped = escaped:gsub("%*%*([^*]+)%*%*", "<b>%1</b>"):gsub("%*([^*]+)%*", "<i>%1</i>")
	return (escaped:gsub("\1(%d+)\2", function(index) return code[tonumber(index) :: number] end))
end

function MessageRenderer.parseBlocks(source: string): { Block }
	local blocks: { Block } = {}
	local cursor = 1
	while cursor <= #source do
		local first = source:find("```", cursor, true)
		if not first then
			blocks[#blocks + 1] = { kind = "text", content = source:sub(cursor) }
			break
		end
		if first > cursor then blocks[#blocks + 1] = { kind = "text", content = source:sub(cursor, first - 1) } end
		local newline = source:find("\n", first + 3, true)
		if not newline then
			blocks[#blocks + 1] = { kind = "text", content = source:sub(first) }
			break
		end
		local last = source:find("```", newline + 1, true)
		local language = source:sub(first + 3, newline - 1):gsub("%s", "")
		blocks[#blocks + 1] = {
			kind = "code", language = if language == "" then "text" else language,
			content = source:sub(newline + 1, if last then last - 1 else #source):gsub("\n$", ""),
		}
		cursor = if last then last + 3 else #source + 1
	end
	return blocks
end

local function column(name: string, parent: Instance?, gap: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BorderSizePixel = 0
	Theme.passThrough(frame)
	Theme.listLayout(gap or 8).Parent = frame
	frame.Parent = parent
	return frame
end

local function clear(frame: Frame)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then child:Destroy() end
	end
end

local function codeBlock(parent: Frame, block: Block, opts: RenderOptions, order: number)
	local card = column("CodeBlock", parent, 0)
	card.LayoutOrder = order
	card.BackgroundTransparency = 0
	card.BackgroundColor3 = Theme.Extra.Overlay
	Theme.corner(8).Parent = card
	Theme.stroke(Theme.Extra.Border).Parent = card
	Theme.padding(10).Parent = card
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 28)
	Theme.passThrough(header)
	header.LayoutOrder = 1
	header.Parent = card
	local language = Theme.label(block.language or "code", { size = 11, color = Theme.Extra.Muted, font = Theme.Fonts.Mono })
	language.Size = UDim2.new(1, -58, 1, 0)
	language.TextTruncate = Enum.TextTruncate.AtEnd
	language.Parent = header
	local copy = Theme.textButton("Copy", { height = 24, width = UDim2.fromOffset(50, 24) })
	copy.Name = "CopyCode"
	copy.BackgroundTransparency = 1
	copy.AnchorPoint = Vector2.new(1, 0)
	copy.Position = UDim2.new(1, 0, 0, 0)
	copy.TextSize = 11
	copy.Parent = header
	copy.MouseButton1Click:Connect(function() if opts.onCopy then opts.onCopy(block.content) end end)
	local bounds = TextService:GetTextSize(block.content, 12, Theme.Fonts.Code, Vector2.new(1000000, 1000000))
	local scroll = Theme.scrollingFrame({ scrollingDirection = Enum.ScrollingDirection.XY })
	scroll.Name = "CodeScroll"
	scroll.LayoutOrder = 2
	scroll.Size = UDim2.new(1, 0, 0, math.clamp(bounds.Y + 14, 34, 240))
	scroll.CanvasSize = UDim2.fromOffset(bounds.X + 14, bounds.Y + 14)
	scroll.Active = true
	scroll.Parent = card
	local code = Theme.label(block.content, { size = 12, font = Theme.Fonts.Code, alignY = Enum.TextYAlignment.Top })
	code.Name = "Code"
	code.Size = UDim2.fromOffset(bounds.X + 8, bounds.Y + 8)
	code.Position = UDim2.fromOffset(0, 2)
	code.RichText = false
	code.Parent = scroll
end

local function renderParagraph(content: string): string
	local lines = {}
	for line in (content .. "\n"):gmatch("(.-)\n") do
		local heading = line:match("^#+%s+(.+)")
		local bullet = line:match("^%s*[-*]%s+(.+)")
		lines[#lines + 1] = if heading then "<b>" .. MessageRenderer.formatInline(heading) .. "</b>"
			elseif bullet then "\u{2022}  " .. MessageRenderer.formatInline(bullet)
			else MessageRenderer.formatInline(line)
	end
	return (table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

function MessageRenderer.render(message: any, options: RenderOptions?): (Frame, any)
	local opts = options or {}
	local isUser = message.role == "user"
	local isTool = message.role == "tool"
	local container = column("Message_" .. message.id, nil, 0)
	container.LayoutOrder = message.layoutOrder or 0
	local bubble = column("Bubble", container, 10)
	Theme.padding4(12, 12, 12, 12).Parent = bubble
	if isUser or isTool then
		bubble.BackgroundTransparency = 0
		bubble.BackgroundColor3 = if isUser then Theme.Colors.Accent else Theme.Extra.Surface
		Theme.corner(12).Parent = bubble
	end
	if isTool then
		local toolName = message.toolName or (message.content or ""):match("^%[([^%]]+)%]") or "Tool result"
		local iconKey = if toolName == "web_search" then "Search" elseif toolName == "web_fetch" then "Globe" elseif toolName == "view_image" then "Image" elseif toolName == "run_command" then "Terminal" else "Tool"
		local disclosure = Disclosure.build(bubble, {
			name = "ToolResult", title = "Tool result · " .. toolName, icon = iconKey,
			text = Redact.scrubText(message.content or ""), preview = true,
			onCopy = opts.onCopy, onToggle = function() if opts.onToolExpand then opts.onToolExpand(message.id) end end,
		})
		disclosure.LayoutOrder = 1
		return container, { appendDelta = function() end, destroy = function() end }
	end
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 22)
	Theme.passThrough(header)
	header.LayoutOrder = 1
	header.Parent = bubble
	local role = Theme.label(if isUser then "You" elseif isTool then "Tool result" else SettingsManager.getValue("assistantName") or "ForgePilot", {
		size = 12, font = Theme.Fonts.Bold, color = if isUser then Theme.Colors.SecondaryText else Theme.Colors.MainText,
	})
	role.Name = "Role"
	role.Size = UDim2.new(1, -64, 1, 0)
	role.TextTruncate = Enum.TextTruncate.AtEnd
	role.Parent = header
	local meta = Theme.label(if message.streaming then "Writing…" elseif message.elapsedMs then Time.formatDuration(message.elapsedMs / 1000) else "", {
		size = 11, color = Theme.Extra.Muted, alignX = Enum.TextXAlignment.Right,
	})
	meta.Name = "Meta"
	meta.Size = UDim2.fromOffset(62, 22)
	meta.AnchorPoint = Vector2.new(1, 0)
	meta.Position = UDim2.fromScale(1, 0)
	meta.Parent = header
	if message.attachments and #message.attachments > 0 then
		local chips = column("Attachments", bubble, 4)
		chips.LayoutOrder = 2
		for index, attachment in message.attachments do
			local chip = Theme.label(attachment.name .. " · " .. Time.formatBytes(attachment.sizeBytes or 0), { size = 11, color = Theme.Colors.SecondaryText })
			chip.Name = "Attachment"
			chip.LayoutOrder = index
			chip.Size = UDim2.new(1, 0, 0, 22)
			chip.TextTruncate = Enum.TextTruncate.AtEnd
			chip.Parent = chips
		end
	end
	local body = column("Body", bubble, 10)
	body.LayoutOrder = 3
	local live = Theme.autoText(message.content or "", { size = Theme.TextSizes.Body, color = Theme.Colors.MainText })
	live.Name = "Live"
	live.Visible = message.streaming == true
	live.RichText = false
	live.Parent = body
    local reasoningRow, reasoningDetails = Disclosure.build(bubble, {
        name = "LiveReasoning", title = "Thinking", icon = "Thinking", text = message.reasoning or "",
        textName = "ReasoningText", expanded = message.streaming == true,
        font = Theme.Fonts.Regular, onCopy = opts.onCopy,
    })
    reasoningRow.LayoutOrder = 2
    reasoningRow.Visible = #(message.reasoning or "") > 0
	local source = message.content or ""
    local reasoningSource = message.reasoning or ""
	local streaming = message.streaming == true
	local disposed = false
	local function flush()
		if not disposed then live.Text = source end
	end
	local function renderBody()
		clear(body)
		for index, block in MessageRenderer.parseBlocks(source) do
			if block.kind == "code" then
				codeBlock(body, block, opts, index)
			elseif block.content:match("%S") then
				local label = Theme.autoText(renderParagraph(block.content), { size = Theme.TextSizes.Body, color = Theme.Colors.MainText, rich = true })
				label.Name = "Block"
				label.LayoutOrder = index
				label.Parent = body
			end
		end
	end
	if not streaming then renderBody() end
	if message.toolCalls and #message.toolCalls > 0 then
		local tools = column("ToolCalls", bubble, 6)
		tools.LayoutOrder = 4
		for index, call in message.toolCalls do
			local ok, encoded = pcall(function() return HttpService:JSONEncode(call.arguments or {}) end)
			local text = Redact.scrubText((if ok then encoded else "{}") .. (if call.result then "\n" .. tostring(call.result) else ""))
			local row = Disclosure.build(tools, {
				name = "ToolCall", title = tostring(call.name or "Tool") .. " · " .. tostring(call.state or "requested"),
				icon = if call.name == "web_search" then "Search" elseif call.name == "web_fetch" then "Globe" else "Tool",
				text = text, textSize = 11, onCopy = opts.onCopy,
				onToggle = function() if opts.onToolExpand then opts.onToolExpand(message.id) end end,
			})
			row.LayoutOrder = index
		end
	end
	if message.error then
		local label = Theme.autoText(message.error, { color = Theme.Colors.Error, size = 12 })
		label.Name = "Error"
		label.LayoutOrder = 5
		label.Parent = bubble
	end
	local details = column("Details", bubble, 6)
	details.LayoutOrder = 7
	details.Visible = false
	local facts = {}
	if message.model then facts[#facts + 1] = "Model · " .. message.model end
	if message.usage then
		facts[#facts + 1] = string.format("Tokens · %s in / %s out", tostring(message.usage.input or "~"), tostring(message.usage.output or "~"))
	end
	if #facts > 0 then
		local info = Theme.autoText(table.concat(facts, "\n"), { size = 11 })
		info.LayoutOrder = 1
		info.Parent = details
	end
	if message.reasoning and #message.reasoning > 0 then
		local reasoning = Theme.autoText(message.reasoning, { size = 12 })
		reasoning.Name = "Reasoning"
		reasoning.LayoutOrder = 2
		reasoning.Parent = details
	end
	if not isTool then
		local actions = Instance.new("Frame")
		actions.Name = "Actions"
		actions.Size = UDim2.new(1, 0, 0, 24)
		Theme.passThrough(actions)
		actions.LayoutOrder = 6
		actions.Visible = not streaming
		actions.Parent = bubble
		local layout = Theme.listLayout(8, Enum.FillDirection.Horizontal)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Parent = actions
		local function action(text: string, order: number, callback: () -> ())
			local button = Theme.textButton(text, { height = 24, width = UDim2.fromOffset(68, 24) })
			button.Name = "Action_" .. text
			button.BackgroundTransparency = 1
			button.TextColor3 = Theme.Extra.Muted
			button.TextSize = 11
			button.LayoutOrder = order
			button.Parent = actions
			button.MouseButton1Click:Connect(callback)
		end
		action("Copy", 1, function() if opts.onCopy then opts.onCopy(message.content or source) end end)
		if isUser then
			action("Edit", 2, function() if opts.onEdit then opts.onEdit(message.id) end end)
		elseif message.error then
			action("Retry", 2, function() if opts.onRetry then opts.onRetry(message.id) end end)
		else
			action("Regenerate", 2, function() if opts.onRegenerate then opts.onRegenerate(message.id) end end)
		end
		if #facts > 0 or message.reasoning then action("Details", 3, function() details.Visible = not details.Visible end) end
		if message.plan and not streaming then
			local row, add = Components.buttonRow({ columns = 2, order = 8, padding = 6 })
			row.Name = "PlanActions"
			row.Parent = bubble
			add("Build this plan", { accent = true, order = 1 }).MouseButton1Click:Connect(function()
				if opts.onSwitchToBuild then opts.onSwitchToBuild(message.id) end
			end)
			add("Revise plan", { order = 2 }).MouseButton1Click:Connect(function()
				if opts.onPlanAction then opts.onPlanAction(message.id, "revise") end
			end)
		end
	end
	container.Destroying:Connect(function() disposed = true end)
	return container, {
		appendDelta = function(delta: string, channel: string?)
			if disposed or not streaming then return end
            if channel == "reasoning" then
                reasoningSource ..= delta; reasoningDetails.setText(reasoningSource); reasoningRow.Visible = true; meta.Text = "Thinking…"
            else
			    source ..= delta
			    flush(); meta.Text = "Writing…"
            end
		end,
		destroy = function() disposed = true end,
	}
end

return MessageRenderer
