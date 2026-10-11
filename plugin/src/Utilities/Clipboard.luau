--!strict
--[[
	ForgePilot / Utilities / Clipboard
	Thin, safe wrapper around the Studio clipboard.

	Tries Studio's privileged copy method, then presents selectable native text
	when the method is unavailable to a local plugin. Clipboard reads are not
	exposed to plugins.
]]

local StudioService = game:GetService("StudioService")

local Clipboard = {}

--- Copies `text` to the Studio clipboard. Returns (ok, reason).
function Clipboard.copy(text: string): (boolean, string?, boolean?)
	local copied, err = pcall(function()
		StudioService:CopyToClipboard(tostring(text))
	end)
	if copied then
		return true
	end
	-- CopyToClipboard is RobloxScriptSecurity on many Studio builds. Local
	-- plugins cannot call it there, so offer a native, selected text box for
	-- Ctrl+C / Cmd+C rather than making every Copy button fail silently.
	local shown = pcall(function()
		local Theme = require(script.Parent.Theme)
		local DockWidget = require(script.Parent.Parent.UI.DockWidget)
		local root = DockWidget.content
		if not root then error("No plugin window") end
		local host = Theme.overlayHost(root)
		local existing = host:FindFirstChild("CopyDialog")
		if existing then existing:Destroy() end
		local modal = Instance.new("TextButton")
		modal.Name = "CopyDialog"
		modal.Size = UDim2.fromScale(1, 1)
		modal.Text = ""
		modal.AutoButtonColor = false
		modal.BackgroundColor3 = Theme.Extra.Overlay
		modal.BackgroundTransparency = 0.2
		modal.ZIndex = Theme.OverlayZIndex + 20
		modal.Parent = host
		local card = Instance.new("Frame")
		card.Name = "Card"
		card.AnchorPoint = Vector2.new(0.5, 0.5)
		card.Position = UDim2.fromScale(0.5, 0.5)
		card.Size = UDim2.new(1, -24, 1, -24)
		card.BackgroundColor3 = Theme.Extra.SurfaceRaised
		card.BorderSizePixel = 0
		card.Active = true
		card.Parent = modal
		Theme.corner(12).Parent = card
		Theme.padding(12).Parent = card
		local title = Theme.label("Copy text", { size = 14, font = Theme.Fonts.Bold })
		title.Size = UDim2.new(1, -30, 0, 24)
		title.Parent = card
		local close = Theme.textButton("×", { height = 24, width = UDim2.fromOffset(26, 24) })
		close.AnchorPoint = Vector2.new(1, 0)
		close.Position = UDim2.fromScale(1, 0)
		close.Parent = card
		close.MouseButton1Click:Connect(function() modal:Destroy() end)
		local box = Theme.input("", { multiLine = true })
		box.Name = "CopyText"
		box.Text = text
		box.TextEditable = false
		box.TextWrapped = false
		box.Font = Theme.Fonts.Code
		box.TextSize = 12
		box.Size = UDim2.new(1, 0, 1, -66)
		box.Position = UDim2.fromOffset(0, 30)
		box.Parent = card
		local hint = Theme.autoText("Press Ctrl+C (Windows) or Cmd+C (Mac) to copy the selected text.", { size = 11 })
		hint.Size = UDim2.new(1, 0, 0, 28)
		hint.AutomaticSize = Enum.AutomaticSize.None
		hint.AnchorPoint = Vector2.new(0, 1)
		hint.Position = UDim2.fromScale(0, 1)
		hint.Parent = card
		modal.MouseButton1Click:Connect(function() modal:Destroy() end)
		task.defer(function()
			if not box.Parent then return end
			box:CaptureFocus()
			box.CursorPosition = 1
			box.SelectionStart = #text + 1
		end)
	end)
	return false, if shown then "Press Ctrl+C / Cmd+C in the selected text." else "Could not open the copy dialog: " .. tostring(err), shown
end

--- Studio has no clipboard read API for plugins.
--- Returns (false, reason) so callers surface an honest message.
function Clipboard.read(): (boolean, string?)
	return false, "Studio does not expose a clipboard read API to plugins."
end

return Clipboard
