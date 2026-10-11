--!strict
local TweenService = game:GetService("TweenService")
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local RetryStateManager = require(script.Parent.Parent.AI.RetryStateManager)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local ThinkingIndicator = {}

function ThinkingIndicator.build(): (Frame, any)
	local frame = Instance.new("Frame")
	frame.Name = "ThinkingIndicator"
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	Theme.passThrough(frame)
	frame.Visible = false
	Theme.padding4(4, 10, 4, 10).Parent = frame
	Theme.listLayout(4).Parent = frame
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.Size = UDim2.new(1, 0, 0, 24)
	Theme.passThrough(row)
	row.LayoutOrder = 1
	row.Parent = frame
	local dot = Icons.glyph("Thinking", 14, Theme.Colors.Highlight)
	dot.Name = "Dot"
	dot.Size = UDim2.fromOffset(18, 24)
	dot.Parent = row
	local label = Theme.label("Thinking…", { size = 12, color = Theme.Colors.SecondaryText })
	label.Name = "Label"
	label.Size = UDim2.new(1, -90, 1, 0)
	label.Position = UDim2.fromOffset(26, 0)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = row
	local timer = Theme.label("0.0s", { size = 11, color = Theme.Extra.Muted, alignX = Enum.TextXAlignment.Right })
	timer.Name = "Timer"
	timer.AnchorPoint = Vector2.new(1, 0)
	timer.Position = UDim2.new(1, -22, 0, 0)
	timer.Size = UDim2.fromOffset(44, 24)
	timer.Parent = row
	local toggle = Theme.textButton("", { height = 24, width = UDim2.fromOffset(18, 24) })
	Icons.setButton(toggle, "ChevronRight")
	toggle.Name = "Toggle"
	toggle.BackgroundTransparency = 1
	toggle.AnchorPoint = Vector2.new(1, 0)
	toggle.Position = UDim2.fromScale(1, 0)
	toggle.Parent = row
	local details = Theme.autoText("", { size = 11 })
	details.Name = "Details"
	details.LayoutOrder = 2
	details.Visible = false
	details.Parent = frame
	toggle.MouseButton1Click:Connect(function() details.Visible = not details.Visible; Icons.setButton(toggle, if details.Visible then "ChevronDown" else "ChevronRight") end)
	local startedAt = 0
	local generation = 0
	local destroyed = false
	local spinner: any = nil
	local activity: string? = nil
	local notes: { string } = {}
	local function refresh()
		if destroyed then return end
		local state = StateManager.get()
		local key = if state == "BUILDING" or state == "ANALYZING" then "Tool" elseif state == "CONNECTING" then "ProviderCustom" else "Thinking"
		Icons.setGlyph(dot, key)
		label.Text = RetryStateManager.shortText() or activity or StateManager.getActivity() or StateManager.displayLabel[state] or "Thinking…"
		timer.Text = string.format("%.1fs", math.max(0, os.clock() - startedAt))
		dot.TextColor3 = if state == "FAILED" then Theme.Colors.Error elseif state == "AWAITING_APPROVAL" or state == "AWAITING_USER_ANSWER" then Theme.Extra.Warning else Theme.Colors.Highlight
		details.Text = table.concat(notes, "\n")
	end
	local unsubs = {
		EventBus.on(EventBus.Events.StateChanged, function() activity = nil; refresh() end),
		EventBus.on(EventBus.Events.ActivityChanged, function(payload) activity = payload.activity; refresh() end),
		EventBus.on(EventBus.Events.MessageDelta, function(payload) activity = if payload.channel == "reasoning" then "Thinking…" else "Writing…"; refresh() end),
		EventBus.on(EventBus.Events.BuildProgress, function(payload)
			if payload.phase == "toolResult" then
				notes[#notes + 1] = tostring(payload.toolName) .. (if payload.verified then " · verified" else " · completed")
				while #notes > 4 do table.remove(notes, 1) end
				refresh()
			end
		end),
	}
	return frame, {
		frame = frame,
		show = function()
			generation += 1
			local current = generation
			startedAt = os.clock()
			activity = nil
			notes = {}
            if spinner then spinner:Cancel(); spinner = nil end
            dot.Rotation = -8
            if Theme.motionEnabled then
                spinner = TweenService:Create(dot, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Rotation = 8 })
                spinner:Play()
            end
			frame.Visible = true
			details.Visible = false
			refresh()
			task.spawn(function()
				while not destroyed and generation == current and frame.Visible do
					refresh()
					task.wait(0.15)
				end
			end)
		end,
		stop = function() generation += 1; frame.Visible = false; if spinner then spinner:Cancel(); spinner = nil end end,
		setActivity = function(value: string?) activity = value; refresh() end,
		addNote = function(value: string) notes[#notes + 1] = value; refresh() end,
		destroy = function() destroyed = true; generation += 1; if spinner then spinner:Cancel(); spinner = nil end; for _, unsubscribe in unsubs do unsubscribe() end end,
	}
end
return ThinkingIndicator
