--!strict
local ContextManager = require(script.Parent.Parent.AI.ContextManager)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local Time = require(script.Parent.Parent.Utilities.Time)
local TokenMeter = {}
function TokenMeter.build(): (Frame, any)
	local frame = Instance.new("Frame")
	frame.Name = "TokenMeter"
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	Theme.passThrough(frame)
	Theme.padding4(0, 10, 0, 10).Parent = frame
	Theme.listLayout(4).Parent = frame
	local header = Theme.textButton("", { height = 20 })
	header.Name = "ContextSummary"
	header.Size = UDim2.new(1, 0, 0, 20)
	header.BackgroundTransparency = 1
	header.Text = ""
	header.LayoutOrder = 1
	header.Parent = frame
	local label = Theme.label("Context", { size = 10, color = Theme.Extra.Muted })
	label.Name = "ContextLabel"
	label.Size = UDim2.new(1, -42, 1, 0)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = header
	local usage = Theme.label("", { size = 10, color = Theme.Extra.Muted, alignX = Enum.TextXAlignment.Right })
	usage.Name = "Usage"
	usage.Size = UDim2.fromOffset(38, 20)
	usage.AnchorPoint = Vector2.new(1, 0)
	usage.Position = UDim2.fromScale(1, 0)
	usage.Parent = header
	local details = Theme.autoText("", { size = 11 })
	details.Name = "LastRequest"
	details.LayoutOrder = 2
	details.Visible = false
	details.Parent = frame
	header.MouseButton1Click:Connect(function() if details.Text ~= "" then details.Visible = not details.Visible end end)
	local function refresh()
		local snapshot = ContextManager.getSnapshot()
		if snapshot.contextWindow <= 0 then
			label.Text = "Connect an AI provider to begin"
			usage.Text = ""
			details.Text = ""
			details.Visible = false
			return
		end
		label.Text = string.format("Context %s%s / %s", if snapshot.usedIsEstimate then "~" else "", Time.formatNumber(snapshot.used), Time.formatNumber(snapshot.contextWindow))
		usage.Text = string.format("%.0f%%", snapshot.percent)
		usage.TextColor3 = if snapshot.percent >= 85 then Theme.Colors.Error elseif snapshot.percent >= 60 then Theme.Extra.Warning else Theme.Extra.Muted
		local request = snapshot.lastRequest
		if request then
			local prefix = if request.estimated then "~" else ""
			details.Text = string.format("Last request · %s%s in / %s%s out · %.1fs", prefix, Time.formatNumber(request.input), prefix, Time.formatNumber(request.output), request.requestMs / 1000)
			if request.estimatedCost then details.Text ..= "\nEstimated cost · " .. (ContextManager.formatCost(request.estimatedCost) or "—") end
		else
			details.Text = "Token counts are estimated until the provider returns usage."
		end
	end
	local unsubscribe = EventBus.on(EventBus.Events.TokenUsageChanged, refresh)
	refresh()
	return frame, { refresh = refresh, destroy = unsubscribe }
end
return TokenMeter
