--!strict
local HttpService = game:GetService("HttpService")
--[[
    ForgePilot / UI / ProviderView
    A searchable provider catalog and a focused editor with Connection, Model,
    Advanced and Tests pages. Save/test controls remain outside the scroll area.
    Profiles contain no secrets; API keys live only in CredentialStore.
]]

local BaseURLResolver = require(script.Parent.Parent.AI.BaseURLResolver)
local CapabilityInspector = require(script.Parent.Parent.AI.CapabilityInspector)
local Components = require(script.Parent.Components)
local ContextManager = require(script.Parent.Parent.AI.ContextManager)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local CustomProviderManager = require(script.Parent.Parent.AI.CustomProviderManager)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Icons = require(script.Parent.Parent.Utilities.Icons)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ProtocolDetector = require(script.Parent.Parent.AI.ProtocolDetector)
local ProviderService = require(script.Parent.Parent.AI.ProviderService)
local RetryDelayCalculator = require(script.Parent.Parent.AI.RetryDelayCalculator)
local RetryLogger = require(script.Parent.Parent.Utilities.RetryLogger)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local SmartRetrySettings = require(script.Parent.Parent.Core.SmartRetrySettings)
local StreamingManager = require(script.Parent.Parent.AI.StreamingManager)
local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

local Theme = require(script.Parent.Parent.Utilities.Theme)
local Time = require(script.Parent.Parent.Utilities.Time)
local UniversalHTTPClient = require(script.Parent.Parent.Utilities.UniversalHTTPClient)
local UniversalProviderRegistry = require(script.Parent.Parent.AI.UniversalProviderRegistry)

local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local ProviderLogo = require(script.Parent.Parent.Utilities.ProviderLogo)
local ProviderView = {}

CustomProviderManager.setCredentialClear(CredentialStore.clear)

--=============================================================================
-- OPTION LISTS
--=============================================================================

local PROVIDER_TYPE_OPTIONS = {
	{ label = "OpenAI", value = "openai" },
	{ label = "OpenRouter", value = "openrouter" },
	{ label = "Anthropic", value = "anthropic" },
	{ label = "Gemini", value = "gemini" },
	{ label = "OpenAI-Compatible", value = "openai_compatible" },
	{ label = "Custom REST", value = "custom_rest" },
}

local PROTOCOL_OPTIONS = {
	{ label = "Chat Completions", value = "openai_chat" },
	{ label = "Text Completions (Legacy)", value = "openai_text_completions" },
	{ label = "Responses API", value = "openai_responses" },
	{ label = "OpenRouter Chat", value = "openrouter" },
	{ label = "Anthropic Messages", value = "anthropic_messages" },
	{ label = "Gemini Native", value = "gemini_native" },
	{ label = "Gemini (OpenAI surface)", value = "gemini_openai" },
	{ label = "Custom REST", value = "custom_rest" },
}

local AUTH_OPTIONS = {
	{ label = "Authorization: Bearer KEY", value = "bearer" },
	{ label = "x-api-key header", value = "header" },
	{ label = "Query parameter", value = "query" },
	{ label = "Custom header", value = "custom" },
	{ label = "No authentication", value = "none" },
}

local function labelsOf(list: { { label: string, value: string } }): { string }
	local out = {}
	for index, entry in list do
		out[index] = entry.label
	end
	return out
end

local function valueOf(list: { { label: string, value: string } }, label: string?): string?
	for _, entry in list do
		if entry.label == label then
			return entry.value
		end
	end
	return nil
end

local function labelOf(list: { { label: string, value: string } }, value: any): string?
	for _, entry in list do
		if entry.value == value then
			return entry.label
		end
	end
	return nil
end

--=============================================================================
-- HELPERS
--=============================================================================

--- A labelled field in a section body, in the order the rows are stacked.
local function field(parent: Instance, label: string, order: number, hint: string?): Frame
	local row, _holder = Components.field(label, { hint = hint, order = order })
	row.Parent = parent
	return row
end

--- A dropdown in a section body. Returns (row, setOptions, getSelected).
---
--- The old code built a field, threw it away except for its value holder, and
--- then parented a SECOND whole field into that holder. That is what stacked a
--- second "Preset" / "Provider Type" / "API Protocol" label on top of the first
--- and pushed unrelated controls over the Settings navigation.
local function dropdownField(
	parent: Instance,
	label: string,
	options: { string },
	onSelect: (string) -> (),
	order: number,
	hint: string?
): (Frame, any, any, any)
	local row, setOptions, getSelected, setSelected =
		Components.dropdown(label, options, onSelect, { hint = hint, order = order })
	row.Parent = parent
	return row, setOptions, getSelected, setSelected
end

--- A full-width text input inside a section body.
local function textField(
	parent: Instance,
	label: string,
	placeholder: string,
	order: number,
	hint: string?,
	height: number?,
	multiline: boolean?
): TextBox
	local row, holder = Components.field(label, { hint = hint, order = order })
	row.Parent = parent
	local box = Theme.input(placeholder, { multiLine = multiline })
	box.Name = "Input"
	box.Size = UDim2.new(1, 0, 0, height or Theme.Metrics.InputHeight)
	box.TextTruncate = Enum.TextTruncate.AtEnd
	if multiline then
		box.TextYAlignment = Enum.TextYAlignment.Top
		box.Font = Theme.Fonts.Code
		box.TextSize = Theme.TextSizes.Small
	end
	box.Parent = holder
	return box
end

--- An input sitting inside an existing field's value holder.
local function smallInput(holder: Instance, placeholder: string, multiLine: boolean?, height: number?): TextBox
	local box = Theme.input(placeholder, { multiLine = multiLine })
	box.Name = "Input"
	box.Size = UDim2.new(1, 0, 0, height or Theme.Metrics.InputHeight)
	box.TextTruncate = Enum.TextTruncate.AtEnd
	-- Field holders are a vertical stack, so the input owns the first slot and
	-- anything the caller adds below it (a warning line) comes after.
	box.LayoutOrder = 1
	box.Parent = holder
	return box
end

--=============================================================================
-- BUILD
--=============================================================================

function ProviderView.build(parent: GuiObject): (Frame, any)
	local view = Instance.new("Frame")
	view.Name = "ProviderView"
	view.Size = UDim2.fromScale(1, 1)
	view.BackgroundTransparency = 1
	Theme.passThrough(view)
	view.Parent = parent

	local draft = table.clone(SettingsManager.getActiveProvider() or UniversalProviderRegistry.newProfile("custom"))
	local busy = false
	local probeBusy = false
	local operation: any = nil
	local destroyed = false
	local editorTab = "Connection"
	local profileActions: { [string]: () -> () } = {}
	local addPreset: (string) -> () = nil :: any
	local showEditor: (any) -> () = nil :: any
	local refreshPreview: () -> () = nil :: any
	local refresh: () -> () = nil :: any
	local syncLimits: () -> () = function() end
	local runCapabilityProbe: () -> () = nil :: any
	local function configureIfActive(report: any?)
		if not StateManager.isBusy() and SettingsManager.getValue("activeProviderId") == draft.id then
			ContextManager.configure(draft, report or CapabilityInspector.buildReport(draft))
		end
	end

	local overview = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	overview.Name = "ProviderOverview"
	overview.BackgroundTransparency = 1
	overview.Parent = view
	Theme.padding4(2, 2, 12, 8).Parent = overview
	Theme.listLayout(12).Parent = overview
	local searchBox = Theme.input("Search providers…")
	searchBox.Name = "ProviderSearch"
	searchBox.LayoutOrder = 0
	searchBox.Parent = overview

	local editor = Instance.new("Frame")
	editor.Name = "ProviderEditor"
	editor.Size = UDim2.fromScale(1, 1)
	Theme.passThrough(editor)
	editor.Visible = false
	editor.ClipsDescendants = true
	editor.Parent = view
	local editorHeader = Instance.new("Frame")
	editorHeader.Name = "EditorHeader"
	editorHeader.Size = UDim2.new(1, 0, 0, 30)
	Theme.passThrough(editorHeader)
	editorHeader.Parent = editor
	local backButton = Components.textButton("← Back")
	backButton.Name = "BackToProviders"
	backButton.Size = UDim2.fromOffset(60, 30)
	backButton.Parent = editorHeader
	local editorTitle = Theme.label("Provider", { size = Theme.TextSizes.Small, font = Theme.Fonts.Medium, truncate = true })
	editorTitle.Name = "ProviderTitle"
	editorTitle.Position = UDim2.fromOffset(70, 0)
	editorTitle.Size = UDim2.new(1, -154, 1, 0)
	editorTitle.Parent = editorHeader
	local menuRow, _, _, setActionLabel = Components.dropdown("Profile actions", {
		"Use for chat", "Duplicate profile", "Disconnect key", "Remove profile",
	}, function(value)
		if not busy and profileActions[value] then profileActions[value]() end
	end, { menuWidth = 194 })
	menuRow.Name = "ProfileActions"
	local menuLabel = menuRow:FindFirstChild("Label")
	if menuLabel then menuLabel:Destroy() end
	menuRow.AutomaticSize = Enum.AutomaticSize.None
	menuRow.Size = UDim2.fromOffset(76, 30)
	menuRow.AnchorPoint = Vector2.new(1, 0)
	menuRow.Position = UDim2.fromScale(1, 0)
	menuRow.Parent = editorHeader
	setActionLabel("More")

	local pages: { [string]: ScrollingFrame } = {}
	for _, name in { "Connection", "Model", "Advanced", "Tests" } do
		local page = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
		page.Name = name .. "Page"
		page.BackgroundTransparency = 1
		page.Visible = name == editorTab
		page.Parent = editor
		Theme.padding4(2, 2, 12, 8).Parent = page
		Theme.listLayout(12).Parent = page
		pages[name] = page
	end
	local tabBar, selectTab = Components.tabBar({ "Connection", "Model", "Advanced", "Tests" }, function(name)
		editorTab = name
		for tab, page in pages do page.Visible = tab == name end
	end)
	tabBar.Name = "ProviderTabs"
	tabBar.Position = UDim2.fromOffset(0, 38)
	tabBar.Parent = editor
	local footer = Instance.new("Frame")
	footer.Name = "ProviderFooter"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, 64)
	Theme.passThrough(footer)
	footer.Parent = editor
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider.BackgroundColor3 = Theme.Extra.Border
	divider.BorderSizePixel = 0
	divider.Parent = footer
	local footerRow, addFooterButton = Components.buttonRow({ padding = 8 })
	footerRow.Name = "FooterActions"
	footerRow.AutomaticSize = Enum.AutomaticSize.None
	footerRow.Position = UDim2.fromOffset(0, 8)
	footerRow.Size = UDim2.new(1, 0, 0, Theme.Metrics.ButtonHeight)
	footerRow.Parent = footer
	local testButton = addFooterButton("Test connection", { order = 1 })
	local saveButton = addFooterButton("Save changes", { accent = true, order = 2 })
	local footerStatus = Theme.label("", { size = Theme.TextSizes.Caption, color = Theme.Extra.Muted, truncate = true })
	footerStatus.Name = "ProviderStatus"
	footerStatus.Position = UDim2.fromOffset(0, 43)
	footerStatus.Size = UDim2.new(1, 0, 0, 18)
	footerStatus.Parent = footer
	local function layoutEditor()
		for _, page in pages do
			page.Position = UDim2.fromOffset(0, 76)
			page.Size = UDim2.new(1, 0, 1, -148)
		end
	end
	layoutEditor()

	local function commit(validateNow: boolean?): (boolean, { any }?)
		if StateManager.isBusy() then
			return false, { { field = "task", message = "Wait for the current task to finish before changing the provider." } }
		end
		if not SettingsManager.getProvider(draft.id) then
			return false, { { field = "profile", message = "Choose or add a provider first." } }
		end
		local ok, errors = CustomProviderManager.save(draft, validateNow ~= true)
		if not ok then
			local first = errors and errors[1]
			EventBus.emit(EventBus.Events.Toast, {
				kind = "error", message = if first then (first.field .. ": " .. first.message) else "The provider could not be saved.",
			})
		end
		return ok, errors
	end
	local function showOverview()
		if busy then return end
		Components.closeMenus()
		editor.Visible = false
		overview.Visible = true
	end
	backButton.MouseButton1Click:Connect(showOverview)

	local listCard, listHolder = Components.section("Your providers", { order = 1 })
	listCard.Name = "SavedProviders"
	listCard.Parent = overview
	local catalogCard, catalogHolder = Components.section("Add a provider", {
		subtitle = "Choose a preset or connect your own API.", order = 2,
	})
	catalogCard.Name = "ProviderCatalog"
	catalogCard.Parent = overview
	local function matches(text: string): boolean
		local query = string.lower(StringUtil.trim(searchBox.Text))
		return query == "" or string.find(string.lower(text), query, 1, true) ~= nil
	end
	local function clearRows(holder: Instance)
		for _, child in holder:GetChildren() do
			if child:IsA("GuiObject") then child:Destroy() end
		end
	end
	local function providerRow(holder: Instance, name: string, detail: string, badge: string, color: Color3, order: number, iconId: string?): TextButton
		local button = Theme.textButton("", { height = 56, color = Theme.Extra.Surface, radius = Theme.Metrics.RadiusSmall })
		button.Size = UDim2.new(1, 0, 0, 56)
		button.Interactable = not busy
		button.LayoutOrder = order
		button.Parent = holder
        local mark = ProviderLogo.build(iconId, 30)
        mark.Name = "ProviderMark"
        mark.Position = UDim2.fromOffset(8, 13)
        mark.Parent = button
		local title = Theme.label(name, { size = Theme.TextSizes.Small, font = Theme.Fonts.Medium, truncate = true })
		title.Name = "Title"
		title.Position = UDim2.fromOffset(48, 8)
		title.Size = UDim2.new(1, -124, 0, 18)
		title.Parent = button
		local subtitle = Theme.label(detail, { size = Theme.TextSizes.Caption, color = Theme.Extra.Muted, truncate = true })
		subtitle.Name = "Subtitle"
		subtitle.Position = UDim2.fromOffset(48, 29)
		subtitle.Size = UDim2.new(1, -60, 0, 16)
		subtitle.Parent = button
		local state = Theme.label(badge, { size = Theme.TextSizes.Caption, color = color, alignX = Enum.TextXAlignment.Right, truncate = true })
		state.Name = "State"
		state.AnchorPoint = Vector2.new(1, 0)
		state.Position = UDim2.new(1, -10, 0, 8)
		state.Size = UDim2.fromOffset(64, 18)
		state.Parent = button
		return button
	end
	local function emptyRow(holder: Instance, text: string)
		local label = Theme.autoText(text, { size = Theme.TextSizes.Small, color = Theme.Extra.Muted })
		label.Name = "Empty"
		label.Parent = holder
	end
	local function renderProfileList()
		clearRows(listHolder)
		local count = 0
		for index, profile in SettingsManager.getValue("providers") do
			if matches((profile.displayName or "") .. " " .. (profile.providerName or "") .. " " .. (profile.modelId or "")) then
				count += 1
				local active = profile.id == SettingsManager.getValue("activeProviderId")
				local ready = profile.viaRouter or profile.authStyle == "none" or CredentialStore.has(profile.id)
				local state = if active then "Active" elseif not ready then "Needs key" else "Saved"
				local button = providerRow(listHolder, profile.displayName, if profile.modelId ~= "" then profile.modelId else "No model selected", state, if active then Theme.Colors.Highlight elseif not ready then Theme.Extra.Warning else Theme.Extra.Muted, index, profile.iconId or (UniversalProviderRegistry.getPreset(profile.presetId) or {}).iconId)
				button.Name = "Profile_" .. profile.id
				button.MouseButton1Click:Connect(function() if not busy then showEditor(profile) end end)
			end
		end
		if count == 0 then emptyRow(listHolder, if #SettingsManager.getValue("providers") == 0 then "No providers yet. Choose one below to get started." else "No matching providers.") end
	end
    local category = "oauth"
    local pageNumber = 1
    local categoryNames = { oauth = "OAuth providers", free = "Free / Free-tier providers", apikey = "API-key providers", direct = "Direct API / Custom" }
    local categories = { "OAuth", "Free / Free tier", "API key", "Direct / Custom" }
    local categoryValues = { ["OAuth"] = "oauth", ["Free / Free tier"] = "free", ["API key"] = "apikey", ["Direct / Custom"] = "direct" }
    local renderCatalog: () -> ()
    local categoryRow = Components.dropdown("Provider category", categories, function(selected)
        category = categoryValues[selected] or "oauth"; pageNumber = 1; renderCatalog()
    end, { order = 0 })
    categoryRow.Parent = overview
    local function renderCatalogImpl()
        clearRows(catalogHolder)
        local entries = {}
        for _, preset in UniversalProviderRegistry.presetList() do
            if matches(preset.label .. " " .. preset.id) and (preset.category == category or StringUtil.trim(searchBox.Text) ~= "") then entries[#entries + 1] = preset end
        end
        local pagesCount = math.max(1, math.ceil(#entries / 9))
        pageNumber = math.clamp(pageNumber, 1, pagesCount)
        local heading = Theme.autoText((if StringUtil.trim(searchBox.Text) == "" then categoryNames[category] else "Search results") .. " · " .. tostring(#entries), { size = 12, color = Theme.Colors.SecondaryText })
        heading.LayoutOrder = 0; heading.Parent = catalogHolder
        for index = (pageNumber - 1) * 9 + 1, math.min(pageNumber * 9, #entries) do
            local preset = entries[index]
            local description = if preset.viaRouter then (if preset.hasOAuth then "Browser sign in · 9Router" elseif preset.noAuth then "No provider key · 9Router" else "Connect account / key in 9Router") else "Direct connection · " .. (labelOf(PROVIDER_TYPE_OPTIONS, preset.providerType) or "Custom API")
            if preset.deprecated then description ..= " · upstream notice" end
            local button = providerRow(catalogHolder, preset.label, description, "Add +", Theme.Extra.Muted, index, preset.iconId)
            button.Name = "AddPreset_" .. preset.id
            button.MouseButton1Click:Connect(function() if not busy then addPreset(preset.id) end end)
        end
        if #entries == 0 then emptyRow(catalogHolder, "No matching presets. Try another provider name.") end
        if pagesCount > 1 then
            local nav = Instance.new("Frame"); nav.Name = "CatalogPages"; nav.Size = UDim2.new(1, 0, 0, 28); nav.LayoutOrder = 999; Theme.passThrough(nav); nav.Parent = catalogHolder
            local previous = Components.textButton("← Previous"); previous.Size = UDim2.new(0.33, -2, 1, 0); previous.Parent = nav; previous.Interactable = pageNumber > 1 and not busy
            local nextPage = Components.textButton("Next →"); nextPage.Size = UDim2.new(0.33, -2, 1, 0); nextPage.Position = UDim2.fromScale(0.67, 0); nextPage.Parent = nav; nextPage.Interactable = pageNumber < pagesCount and not busy
            local label = Theme.label(tostring(pageNumber) .. " / " .. tostring(pagesCount), { size = 11, alignX = Enum.TextXAlignment.Center }); label.Position = UDim2.fromScale(0.34, 0); label.Size = UDim2.new(0.32, 0, 1, 0); label.Parent = nav
            previous.MouseButton1Click:Connect(function() if not busy and pageNumber > 1 then pageNumber -= 1; renderCatalog() end end)
            nextPage.MouseButton1Click:Connect(function() if not busy and pageNumber < pagesCount then pageNumber += 1; renderCatalog() end end)
        end
    end
    renderCatalog = renderCatalogImpl
	searchBox:GetPropertyChangedSignal("Text"):Connect(function() pageNumber = 1; renderProfileList(); renderCatalog() end)

	--=========================================================================
	-- IDENTITY
	--=========================================================================

	local _, identityBody = (function()
		local card, body = Components.section("Connection details", { order = 1 })
		card.Parent = pages.Connection
		return card, body
	end)()

    local routerCard, routerBody = Components.section("9Router account", { order = 0, subtitle = "Sign in or connect a provider key in the local dashboard." })
    routerCard.Name = "RouterAccount"; routerCard.Parent = pages.Connection
    local routerNote = Theme.autoText("", { size = 12, color = Theme.Extra.Muted }); routerNote.LayoutOrder = 0; routerNote.Parent = routerBody
    local login = Components.textButton("Sign in / Log in", { order = 1 }); login.Name = "ProviderSignIn"; login.Size = UDim2.new(1, 0, 0, 30); login.Parent = routerBody
    local statusButton = Components.textButton("Refresh connection", { order = 2 }); statusButton.Name = "RefreshOAuthStatus"; statusButton.Size = UDim2.new(1, 0, 0, 28); statusButton.Parent = routerBody
    local loginGeneration = 0
    local function refreshAccount(providerId: string, profileId: string, current: number)
        local value, err = BridgeClient.providerStatus(providerId)
        if destroyed or current ~= loginGeneration or draft.id ~= profileId then return end
        routerNote.Text = if value then value.message else err or "Connection check failed."
        routerNote.TextColor3 = if value and value.connected then Theme.Colors.Success else Theme.Extra.Muted
        if value and value.connected then login.Text = "Manage account in 9Router" end
    end
    login.MouseButton1Click:Connect(function()
        if busy or StateManager.isBusy() or not draft.viaRouter then return end
        loginGeneration += 1
        local current = loginGeneration; local profileId = draft.id; local providerId = draft.routerProviderId
        login.Interactable = false; statusButton.Interactable = false; routerNote.Text = "Opening local provider sign in…"
        task.spawn(function()
            local value, err = BridgeClient.openProvider(providerId)
            if destroyed or current ~= loginGeneration or draft.id ~= profileId then return end
            login.Interactable = not StateManager.isBusy(); statusButton.Interactable = not StateManager.isBusy()
            routerNote.Text = if value then value.message else err or "Could not open the dashboard."
            if value then
                task.spawn(function()
                    for _ = 1, 45 do
                        if destroyed or current ~= loginGeneration or draft.id ~= profileId then return end
                        local result = BridgeClient.providerStatus(providerId)
                        if result and result.connected then refreshAccount(providerId, profileId, current); return end
                        task.wait(2)
                    end
                end)
            end
        end)
    end)
    statusButton.MouseButton1Click:Connect(function()
        if busy or StateManager.isBusy() then return end
        loginGeneration += 1; local current = loginGeneration; local profileId = draft.id; local providerId = draft.routerProviderId
        statusButton.Interactable = false; statusButton.Text = "Checking…"
        task.spawn(function()
            refreshAccount(providerId, profileId, current)
            if destroyed or current ~= loginGeneration or draft.id ~= profileId then return end
            statusButton.Interactable = not StateManager.isBusy(); statusButton.Text = "Refresh connection"
        end)
    end)
	local displayNameRow = field(identityBody, "Profile name", 0, "Used to identify this connection.")
	local displayNameBox = smallInput(displayNameRow:FindFirstChild("Value") :: Instance, "My Roblox Assistant")
	displayNameBox.Text = draft.displayName
	displayNameBox.FocusLost:Connect(function()
		do
			draft.displayName = displayNameBox.Text
			commit()
		end
	end)

	local providerNameRow = field(identityBody, "Provider Name", 1)
	local providerNameBox = smallInput(providerNameRow:FindFirstChild("Value") :: Instance, "My Custom AI")
	providerNameBox.Text = draft.providerName
	providerNameBox.FocusLost:Connect(function()
		do
			draft.providerName = providerNameBox.Text
			commit()
		end
	end)

	local typeField, _, _, setType = dropdownField(identityBody, "Provider Type", labelsOf(PROVIDER_TYPE_OPTIONS), function(selected)
		local value = valueOf(PROVIDER_TYPE_OPTIONS, selected)
		if not value then
			return
		end
		draft.providerType = value
		-- Adopting a type also adopts its documented protocol and auth style.
		for _, preset in UniversalProviderRegistry.presetList() do
			if preset.providerType == value then
				draft.protocol = preset.protocol
				draft.authStyle = preset.authStyle
				draft.authHeaderName = preset.authHeaderName
				break
			end
		end
		draft.endpointPath = ""
		draft.endpointPathCustom = false
		commit()
		refresh()
	end, 2)

	--=========================================================================
	-- PROTOCOL & ENDPOINT
	--=========================================================================

	local _, endpointBody = (function()
		local card, body = Components.section("API configuration", {
			subtitle = "Requests go directly from Studio to this HTTPS endpoint.",
			order = 4,
		})
		card.Parent = pages.Advanced
		return card, body
	end)()

	local protocolField, _, _, setProtocol = dropdownField(endpointBody, "API Protocol", labelsOf(PROTOCOL_OPTIONS), function(selected)
		local value = valueOf(PROTOCOL_OPTIONS, selected)
		if not value then
			return
		end
		draft.protocol = value
		-- The path follows the new protocol until it is edited by hand.
		draft.endpointPathCustom = false
		commit()
		refresh()
	end, 0)

	local detectHolder = Instance.new("Frame")
	detectHolder.Name = "Detect"
	detectHolder.Size = UDim2.new(1, 0, 0, 0)
	detectHolder.AutomaticSize = Enum.AutomaticSize.Y
	detectHolder.BackgroundTransparency = 1
	Theme.passThrough(detectHolder)
	detectHolder.LayoutOrder = 1
	detectHolder.Parent = endpointBody
	local detectLayout = Instance.new("UIListLayout")
	detectLayout.FillDirection = Enum.FillDirection.Vertical
	detectLayout.SortOrder = Enum.SortOrder.LayoutOrder
	detectLayout.Padding = UDim.new(0, 6)
	detectLayout.Parent = detectHolder

	local detectButton = Components.textButton("Detect API protocol", { order = 1 })
	detectButton.Size = UDim2.fromOffset(150, 26)
	detectButton.LayoutOrder = 1
	detectButton.Parent = detectHolder

	local detectNote = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Warning,
		alignY = Enum.TextYAlignment.Center,
		wrap = true,
	})
	detectNote.Name = "DetectNote"
	detectNote.Size = UDim2.new(1, 0, 0, 0)
	detectNote.AutomaticSize = Enum.AutomaticSize.Y
	detectNote.LayoutOrder = 2
	detectNote.Parent = detectHolder

	local baseUrlRow = field(
		endpointBody,
		"Base URL",
		2,
		"Use the API root, for example https://api.example.com/v1."
	)
	local baseUrlHolder = baseUrlRow:FindFirstChild("Value") :: Instance
	local baseUrlBox = smallInput(baseUrlHolder, "https://api.example.com/v1")
	baseUrlBox.Text = draft.baseUrl

	local urlWarning = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Warning,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	urlWarning.Name = "UrlWarning"
	urlWarning.Size = UDim2.new(1, 0, 0, 0)
	urlWarning.AutomaticSize = Enum.AutomaticSize.Y
	urlWarning.LayoutOrder = 2
	urlWarning.Parent = baseUrlHolder

	baseUrlBox.FocusLost:Connect(function()
				local normalised, err = BaseURLResolver.normaliseBase(baseUrlBox.Text)
		if not normalised then
			urlWarning.TextColor3 = Theme.Colors.Error
			urlWarning.Text = tostring(err)
			baseUrlBox.Text = draft.baseUrl
			return
		end
		draft.baseUrl = normalised
		baseUrlBox.Text = normalised
		if BaseURLResolver.isTrustedHost(normalised) then
			urlWarning.TextColor3 = Theme.Extra.Muted
			urlWarning.Text = "Recognised provider host."
		else
			urlWarning.TextColor3 = Theme.Extra.Warning
			urlWarning.Text =
				"Unfamiliar host. Your API key will be sent to this domain when you make a request. Continue only if you trust it."
		end
		refreshPreview()
		commit()
	end)

	local endpointPathRow = field(
		endpointBody,
		"Endpoint Path",
		3,
		"Generated from the protocol. Edit it if this provider uses a different path."
	)
	local endpointPathBox = smallInput(endpointPathRow:FindFirstChild("Value") :: Instance, "/chat/completions")
	endpointPathBox.Text = draft.endpointPath

	endpointPathBox.FocusLost:Connect(function()
				local trimmed = StringUtil.trim(endpointPathBox.Text)
		if trimmed == "" then
			endpointPathBox.Text = draft.endpointPath
			return
		end
		-- Normalise a pasted full endpoint into a path.
		if string.find(trimmed, "://", 1, true) then
			local parsed = BaseURLResolver.parse(trimmed)
			if parsed then
				draft.baseUrl = string.format("https://%s", parsed.authority)
				baseUrlBox.Text = draft.baseUrl
				trimmed = parsed.path
			end
		end
		draft.endpointPath = trimmed
		draft.endpointPathCustom = true
		endpointPathBox.Text = trimmed
		refreshPreview()
		commit()
	end)

	local modeField, _, _, setURLMode = dropdownField(endpointBody, "URL Mode", { "Base URL", "Full Endpoint URL" }, function(selected)
		draft.urlMode = if selected == "Full Endpoint URL" then "full" else "base"
		refreshPreview()
		commit()
	end, 4, "Base URL appends the endpoint path. Full Endpoint URL uses your path verbatim.")

	-- URL preview ---------------------------------------------------------
	local previewCard, previewBody = Components.section("Request URL", {
		subtitle = "Generated from your connection settings.",
		order = 5,
	})
	previewCard.Parent = pages.Advanced

	local previewLabel = Theme.label("—", {
		size = Theme.TextSizes.Caption,
		color = Theme.Colors.SecondaryText,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	previewLabel.Name = "Preview"
	previewLabel.Size = UDim2.new(1, 0, 0, 0)
	previewLabel.AutomaticSize = Enum.AutomaticSize.Y
	previewLabel.Font = Theme.Fonts.Code
	previewLabel.Parent = previewBody

	local streamingNote = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Muted,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	streamingNote.Name = "StreamingNote"
	streamingNote.Size = UDim2.new(1, 0, 0, 0)
	streamingNote.AutomaticSize = Enum.AutomaticSize.Y
	streamingNote.Parent = previewBody

	local function buildPreview()
		if StringUtil.trim(draft.baseUrl or "") == "" then
			previewLabel.TextColor3 = Theme.Extra.Muted
			previewLabel.Text = "Enter a Base URL in Connection to preview the request."
			streamingNote.Text = ""
			return
		end
		local preview = CustomProviderManager.preview(draft)
		if not preview.ok then
			previewLabel.TextColor3 = Theme.Colors.Error
			previewLabel.Text = "Invalid base URL: " .. tostring(preview.error)
		else
			previewLabel.TextColor3 = Theme.Colors.SecondaryText
			previewLabel.Text = string.format(
				"Request : %s\nStream  : %s\nMode    : %s%s",
				tostring(preview.display),
				if preview.streamingUrl
					then BaseURLResolver.forDisplay(preview.streamingUrl)
					else "(streaming unavailable)",
				preview.mode,
				if preview.note then ("\nNote    : " .. preview.note) else ""
			)
		end

		local status = StreamingManager.streamingStatus(draft)
		streamingNote.TextColor3 = if status.available then Theme.Extra.Muted else Theme.Extra.Warning
		streamingNote.Text = status.reason
	end

	refreshPreview = buildPreview

	--=========================================================================
	-- CREDENTIALS
	--=========================================================================

	local _, credentialBody = (function()
		local card, body = Components.section("Credentials", {
			subtitle = "Authentication options and request headers.",
			order = 6,
		})
		card.Parent = pages.Advanced
		return card, body
	end)()

	local authField, _, _, setAuth = dropdownField(credentialBody, "Authentication", labelsOf(AUTH_OPTIONS), function(selected)
		draft.authStyle = valueOf(AUTH_OPTIONS, selected) or "bearer"
		commit()
		refresh()
	end, 0)

	local headerNameRow = field(credentialBody, "API key header name", 1, "For x-api-key, query or custom header auth.")
	local headerNameBox = smallInput(headerNameRow:FindFirstChild("Value") :: Instance, "x-api-key")
	headerNameBox.Text = draft.authHeaderName or ""
	headerNameBox.FocusLost:Connect(function()
		do
			draft.authHeaderName = headerNameBox.Text
			commit()
		end
	end)

	local headerPrefixRow = field(credentialBody, "API key header prefix", 2)
	local headerPrefixBox = smallInput(headerPrefixRow:FindFirstChild("Value") :: Instance, "Token ")
	headerPrefixBox.FocusLost:Connect(function()
		do
			draft.authHeaderPrefix = headerPrefixBox.Text
			commit()
		end
	end)

	local queryParamRow = field(credentialBody, "API key query parameter", 3)
	local queryParamBox = smallInput(queryParamRow:FindFirstChild("Value") :: Instance, "key")
	queryParamBox.FocusLost:Connect(function()
		do
			draft.authQueryParam = queryParamBox.Text
			commit()
		end
	end)

	local keyRow = field(credentialBody, "API Key", 4, "Session only. Re-enter after restarting Studio.")
	local keyHolder = keyRow:FindFirstChild("Value") :: Instance

	-- The textbox and the reveal button share a row; the status line sits under
	-- it. Parenting all three to the same frame without a layout made them
	-- overlap.
	local keyInputRow = Instance.new("Frame")
	keyInputRow.Name = "InputRow"
	keyInputRow.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight)
	keyInputRow.BackgroundTransparency = 1
	Theme.passThrough(keyInputRow)
	keyInputRow.ClipsDescendants = false
	keyInputRow.LayoutOrder = 1
	keyInputRow.Parent = keyHolder

	local keyInputLayout = Instance.new("UIListLayout")
	keyInputLayout.FillDirection = Enum.FillDirection.Horizontal
	keyInputLayout.SortOrder = Enum.SortOrder.LayoutOrder
	keyInputLayout.Padding = UDim.new(0, Theme.Space.XS)
	keyInputLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	keyInputLayout.Parent = keyInputRow

	local keyBox = Theme.input("Paste your API key")
	keyBox.Name = "ApiKey"
	keyBox.Size = UDim2.new(1, -62, 0, Theme.Metrics.InputHeight)
	keyBox.TextXAlignment = Enum.TextXAlignment.Left
	keyBox.LayoutOrder = 1
	keyBox.Parent = keyInputRow

	local revealButton = Components.textButton("Show", { order = 2 })
	revealButton.Name = "Reveal"
	revealButton.Size = UDim2.fromOffset(56, Theme.Metrics.InputHeight)
	revealButton.Parent = keyInputRow

	local revealed = false
		local keyMask = Theme.label("", { size = Theme.TextSizes.Body })
	keyMask.Name = "KeyMask"
	keyMask.Size = UDim2.fromScale(1, 1)
	keyMask.AutomaticSize = Enum.AutomaticSize.None
	keyMask.TextTruncate = Enum.TextTruncate.AtEnd
	keyMask.Parent = keyBox
	local function refreshKeyMask()
		keyBox.TextTransparency = if revealed then 0 else 1
		keyMask.Visible = not revealed
		keyMask.Text = if #keyBox.Text == 0 then keyBox.PlaceholderText else string.rep("•", math.min(#keyBox.Text, 48))
		keyMask.TextColor3 = if #keyBox.Text == 0 then Theme.Extra.Muted else Theme.Colors.MainText
	end
	keyBox:GetPropertyChangedSignal("Text"):Connect(refreshKeyMask)
	refreshKeyMask()

	local keyStatus = Theme.label("", { size = Theme.TextSizes.Caption, color = Theme.Extra.Muted })
	keyStatus.Name = "KeyStatus"
	keyStatus.Size = UDim2.new(1, 0, 0, 0)
	keyStatus.AutomaticSize = Enum.AutomaticSize.Y
	keyStatus.TextWrapped = true
	keyStatus.TextXAlignment = Enum.TextXAlignment.Left
	keyStatus.LayoutOrder = 2
	keyStatus.Parent = keyHolder

	local function refreshKeyStatus()
		if CredentialStore.has(draft.id) then
			keyStatus.Text = string.format(
				"Key loaded for this session · %s",
				CredentialStore.preview(draft.id)
			)
		else
			keyStatus.Text = "No key loaded for this session."
		end
	end

	keyBox.FocusLost:Connect(function()
		local entered = StringUtil.trim(keyBox.Text)
		if #entered > 0 and not StateManager.isBusy() then
			CredentialStore.set(draft.id, entered)
			keyBox.Text = entered
		end
		refreshKeyStatus()
		renderProfileList()
	end)
	revealButton.MouseButton1Click:Connect(function()
		revealed = not revealed
		revealButton.Text = if revealed then "Hide" else "Show"
		if keyBox.Text == "" then keyBox.Text = CredentialStore.get(draft.id) or "" end
		refreshKeyMask()
	end)

	--=========================================================================
	-- MODEL
	--=========================================================================

	local _, modelBody = (function()
		local card, body = Components.section("Model", {
			subtitle = "Use automatic limits or set your own.",
			order = 7,
		})
		card.Parent = pages.Model
		return card, body
	end)()

	local modelRow = field(modelBody, "Model ID", 0)
	local modelBox = smallInput(modelRow:FindFirstChild("Value") :: Instance, "e.g. gpt-4o-mini")
	modelBox.Text = draft.modelId

	modelBox.FocusLost:Connect(function()
		do
			draft.modelId = StringUtil.trim(modelBox.Text)
			commit()
			CapabilityInspector.buildReport(draft)
			renderProfileList()
		end
	end)

	local contextAutoRow, _, setContextAuto = Components.toggle(
		"Detect context limit",
		draft.contextWindowMode ~= "manual",
		function(value)
			draft.contextWindowMode = if value then "auto" else "manual"
			syncLimits()
			configureIfActive()
			commit()
		end,
		{ hint = "Uses model metadata, with the profile value as a fallback." }
	)
	contextAutoRow.Parent = modelBody

	local contextRow = field(modelBody, "Context Window", 2)
	local contextBox = smallInput(contextRow:FindFirstChild("Value") :: Instance, "128000")
	contextBox.Text = tostring(draft.contextWindow)
	contextBox.FocusLost:Connect(function()
		do
			draft.contextWindow = tonumber(contextBox.Text) or draft.contextWindow
			draft.contextWindowMode = "manual"
			setContextAuto(false)
			syncLimits()
			configureIfActive()
			commit()
		end
	end)

	local outputAutoRow, _, setOutputAuto = Components.toggle(
		"Detect output limit",
		draft.maxOutputTokensMode ~= "manual",
		function(value)
			draft.maxOutputTokensMode = if value then "auto" else "manual"
			syncLimits()
			commit()
		end
	)
	outputAutoRow.Parent = modelBody

	local outputRow = field(modelBody, "Maximum Output Tokens", 4)
	local outputBox = smallInput(outputRow:FindFirstChild("Value") :: Instance, "8192")
	outputBox.Text = tostring(draft.maxOutputTokens)
	outputBox.FocusLost:Connect(function()
		do
			draft.maxOutputTokens = tonumber(outputBox.Text) or draft.maxOutputTokens
			draft.maxOutputTokensMode = "manual"
			setOutputAuto(false)
			syncLimits()
			commit()
		end
	end)

	local refreshModelsButton = Components.textButton("Refresh models", { order = 1 })
	refreshModelsButton.Size = UDim2.fromOffset(120, 26)
	refreshModelsButton.Parent = modelBody

	local modelListHolder = Instance.new("Frame")
	modelListHolder.Name = "ModelList"
	modelListHolder.Size = UDim2.new(1, 0, 0, 0)
	modelListHolder.AutomaticSize = Enum.AutomaticSize.Y
	modelListHolder.BackgroundTransparency = 1
	Theme.passThrough(modelListHolder)
	modelListHolder.LayoutOrder = 5
	modelListHolder.Parent = modelBody

	--=========================================================================
	-- ADVANCED
	--=========================================================================

	local _, advancedBody = (function()
		local card, body = Components.section("Response preferences", { order = 2 })
		card.Parent = pages.Model
		return card, body
	end)()

	local temperatureRow = field(advancedBody, "Temperature", 0)
	local temperatureBox = smallInput(temperatureRow:FindFirstChild("Value") :: Instance, "0.7")
	temperatureBox.Text = tostring(draft.temperature)
	temperatureBox.FocusLost:Connect(function()
		do
			draft.temperature = tonumber(temperatureBox.Text) or draft.temperature
			commit()
		end
	end)

	local topPRow = field(advancedBody, "Top P", 1)
	local topPBox = smallInput(topPRow:FindFirstChild("Value") :: Instance, "1.0")
	topPBox.Text = tostring(draft.topP)
	topPBox.FocusLost:Connect(function()
		do
			draft.topP = tonumber(topPBox.Text) or draft.topP
			commit()
		end
	end)

	local effortField, _, _, setEffort = dropdownField(
		advancedBody,
		"Reasoning Effort",
		{ "(not sent)", "minimal", "low", "medium", "high" },
		function(selected)
			draft.reasoningEffort = if selected == "(not sent)" then "" else selected
			commit()
		end,
		2
	)

	local timeoutRow = field(advancedBody, "Idle / Request Timeout (ms)", 3, "Streaming: maximum time without upstream data. An active response can continue beyond this value. Non-streaming: request timeout.")
	local timeoutBox = smallInput(timeoutRow:FindFirstChild("Value") :: Instance, "120000")
	timeoutBox.Text = tostring(draft.timeoutMs)
	timeoutBox.FocusLost:Connect(function()
		do
			draft.timeoutMs = tonumber(timeoutBox.Text) or draft.timeoutMs
			commit()
		end
	end)

	local streamingRow, _, setStreaming = Components.toggle("Streaming", draft.streaming ~= false, function(value)
		draft.streaming = value
		refreshPreview()
		commit()
	end)
	streamingRow.Parent = advancedBody

	local toolRow, _, setTools = Components.toggle("Tool Calling", draft.toolCalling ~= false, function(value)
		draft.toolCalling = value
		commit()
	end, { hint = "Off makes ForgePilot use a validated JSON action protocol instead." })
	toolRow.Parent = advancedBody

	local jsonRow, _, setJSON = Components.toggle("Structured JSON", draft.jsonMode == true, function(value)
		draft.jsonMode = value
		commit()
	end)
	jsonRow.Parent = advancedBody

	local retryRow = Instance.new("Frame")
	retryRow.Name = "RetryPolicy"
	retryRow.Size = UDim2.new(1, 0, 0, 0)
	retryRow.AutomaticSize = Enum.AutomaticSize.Y
	retryRow.BackgroundTransparency = 1
	Theme.passThrough(retryRow)
	retryRow.Parent = advancedBody
	local retryNote = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Muted,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	retryNote.Name = "RetryNote"
	retryNote.Size = UDim2.new(1, 0, 0, 0)
	retryNote.AutomaticSize = Enum.AutomaticSize.Y
	retryNote.Parent = retryRow

	local function refreshRetryNote()
		retryNote.Text = string.format(
			"Auto Retry: %s · %s\nConfigure the full policy in the Retry tab.",
			if SmartRetrySettings.get("enabled") ~= false then "enabled" else "disabled",
			SmartRetrySettings.describe()
		)
	end

	local headersRow = field(advancedBody, "Custom Headers", 5, "One per line, `Name: value`.")
	local headersBox = Theme.input("HTTP-Referer: https://yourgame.example", { multiLine = true })
	headersBox.Name = "Headers"
	headersBox.Size = UDim2.new(1, 0, 0, 58)
	headersBox.Font = Theme.Fonts.Code
	headersBox.TextSize = Theme.TextSizes.Small
	headersBox.Parent = headersRow:FindFirstChild("Value") :: Instance
	headersBox.FocusLost:Connect(function()
		do
			local headers, problems = CustomProviderManager.parseHeaders(headersBox.Text)
			draft.extraHeaders = headers
			commit()
			if #problems > 0 then
				EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = problems[1] })
			end
		end
	end)

	local schemaCard, schemaBody = Components.section("Request & response schema mapping", {
		subtitle = "Only needed for Custom REST. Dotted paths, e.g. input.text.",
		order = 9,
	})
	schemaCard.Parent = pages.Advanced

	local schemaNote = Theme.label(
		"Without a mapping a Custom REST provider cannot be called. ForgePilot never assumes an arbitrary REST API is OpenAI-compatible.",
		{ size = Theme.TextSizes.Caption, color = Theme.Extra.Warning, alignY = Enum.TextYAlignment.Top, wrap = true }
	)
	schemaNote.Name = "Note"
	schemaNote.Size = UDim2.new(1, 0, 0, 0)
	schemaNote.AutomaticSize = Enum.AutomaticSize.Y
	schemaNote.Parent = schemaBody

	local requestSchemaRow = field(schemaBody, "Request Schema Mapping", 0)
	local requestSchemaBox = Theme.input(
		'{"prompt":"input.text","model":"parameters.model","system":"input.system"}',
		{ multiLine = true }
	)
	requestSchemaBox.Name = "RequestSchema"
	requestSchemaBox.Size = UDim2.new(1, 0, 0, 66)
	requestSchemaBox.Font = Theme.Fonts.Code
	requestSchemaBox.TextSize = Theme.TextSizes.Small
	requestSchemaBox.Parent = requestSchemaRow:FindFirstChild("Value") :: Instance

	local responseSchemaRow = field(schemaBody, "Response Schema Mapping", 1)
	local responseSchemaBox = Theme.input(
		'{"text":"output.answer","reasoning":"output.thoughts","usage":{"input":"usage.prompt","output":"usage.completion"}}',
		{ multiLine = true }
	)
	responseSchemaBox.Name = "ResponseSchema"
	responseSchemaBox.Size = UDim2.new(1, 0, 0, 66)
	responseSchemaBox.Font = Theme.Fonts.Code
	responseSchemaBox.TextSize = Theme.TextSizes.Small
	responseSchemaBox.Parent = responseSchemaRow:FindFirstChild("Value") :: Instance

	local schemaApplyButton = Components.textButton("Apply schema mapping", { accent = true, order = 1 })
	schemaApplyButton.Parent = schemaBody

	schemaApplyButton.MouseButton1Click:Connect(function()
		local requestDecoded = require(script.Parent.Parent.Utilities.JSONValidator).decode(
			requestSchemaBox.Text
		)
		local responseDecoded = require(script.Parent.Parent.Utilities.JSONValidator).decode(
			responseSchemaBox.Text
		)
		if type(requestDecoded) ~= "table" then
			EventBus.emit(EventBus.Events.Toast, { kind = "error", message = "Request mapping is not valid JSON." })
			return
		end
		if type(responseDecoded) ~= "table" then
			EventBus.emit(EventBus.Events.Toast, { kind = "error", message = "Response mapping is not valid JSON." })
			return
		end
		draft.schemaMapping = { request = requestDecoded, response = responseDecoded }
		local ok, errors = commit(true)
		if ok then
			EventBus.emit(EventBus.Events.Toast, { kind = "success", message = "Schema mapping applied." })
		else
			local first = errors and errors[1]
			EventBus.emit(EventBus.Events.Toast, {
				kind = "error",
				message = if first then (first.field .. ": " .. first.message) else "Mapping could not be saved.",
			})
		end
	end)

	--=========================================================================
	-- ACTIONS
	--=========================================================================

	local _, actionsCard2 = (function()
		local card, body = Components.section("Test & detect", {
			subtitle = "Tests send real requests to your provider.",
			order = 10,
		})
		card.Parent = pages.Tests
		return card, body
	end)()

	-- Six actions cannot share one line at 320px without becoming unreadable, so
	-- the row wraps to two columns instead of overflowing or shrinking.
	local testRow, addTestButton = Components.buttonRow({ columns = 2, padding = 6 })
	testRow.Name = "TestRow"
	testRow.Parent = actionsCard2

	-- Connection testing stays available in the persistent footer.
	local testChatButton = addTestButton("Test chat", { order = 2 })
	local testStreamButton = addTestButton("Test streaming", { order = 3 })
	local testToolButton = addTestButton("Test tool calling", { order = 4 })
	local capabilityButton = addTestButton("Detect capabilities", { order = 5 })

	-- Saving stays available without scrolling through diagnostics.

	local testResult = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Colors.SecondaryText,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	testResult.Name = "TestResult"
	testResult.Size = UDim2.new(1, 0, 0, 0)
	testResult.AutomaticSize = Enum.AutomaticSize.Y
	testResult.Parent = actionsCard2

	local function syncFooterStatus()
		if StateManager.isBusy() and not probeBusy then
			footerStatus.Text = "Chat in progress · Settings unlock when the task finishes."
			footerStatus.TextColor3 = Theme.Extra.Warning
		elseif testResult.Text ~= "" then
			footerStatus.Text = string.match(testResult.Text, "[^\n]+") or testResult.Text
			footerStatus.TextColor3 = testResult.TextColor3
		else
			local active = draft.id == SettingsManager.getValue("activeProviderId")
			local key = draft.viaRouter or draft.authStyle == "none" or CredentialStore.has(draft.id)
			footerStatus.Text = (if active then "Active provider" else "Saved profile") .. (if key then " · Ready to test" else " · API key needed")
			footerStatus.TextColor3 = if key then Theme.Extra.Muted else Theme.Extra.Warning
		end
	end
	testResult:GetPropertyChangedSignal("Text"):Connect(syncFooterStatus)
	testResult:GetPropertyChangedSignal("TextColor3"):Connect(syncFooterStatus)

	--=========================================================================
	-- CAPABILITY INSPECTOR
	--=========================================================================

	local _, capabilityBody = (function()
		local card, body = Components.section("Capability inspector", {
			subtitle = "Supported / Unsupported / Unknown, with the source of each verdict.",
			order = 11,
		})
		card.Parent = pages.Tests
		return card, body
	end)()

	local capabilitySummary = Theme.label("", {
		size = Theme.TextSizes.Caption,
		color = Theme.Extra.Muted,
		alignY = Enum.TextYAlignment.Top,
		wrap = true,
	})
	capabilitySummary.Name = "Summary"
	capabilitySummary.Size = UDim2.new(1, 0, 0, 0)
	capabilitySummary.AutomaticSize = Enum.AutomaticSize.Y
	capabilitySummary.Parent = capabilityBody

	local capabilityList = Instance.new("Frame")
	capabilityList.Name = "List"
	capabilityList.Size = UDim2.new(1, 0, 0, 0)
	capabilityList.AutomaticSize = Enum.AutomaticSize.Y
	capabilityList.BackgroundTransparency = 1
	Theme.passThrough(capabilityList)
	capabilityList.Parent = capabilityBody
	Theme.listLayout(3).Parent = capabilityList

	local function verdictColor(verdict: string): Color3
		if verdict == "Supported" then
			return Theme.Colors.Success
		elseif verdict == "Unsupported" then
			return Theme.Colors.Error
		end
		return Theme.Extra.Muted
	end

	local function renderCapabilities(report: any)
		for _, child in capabilityList:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		if not report then
			capabilitySummary.Text = "No provider selected."
			return
		end

		local counts = CapabilityInspector.summary(report)
		capabilitySummary.Text = string.format(
			"Model: %s · Context %s (%s) · Max output %s (%s)\n%d supported · %d unsupported · %d unknown",
			if report.modelId ~= "" then report.modelId else "(not set)",
			Time.formatNumber(report.contextWindow),
			report.contextWindowSource,
			Time.formatNumber(report.maxOutputTokens),
			report.maxOutputTokensSource,
			counts.Supported,
			counts.Unsupported,
			counts.Unknown
		)

		for index, rowData in report.rows do
			local row = Instance.new("Frame")
			row.Name = "Capability_" .. rowData.id
			row.LayoutOrder = index
			row.Size = UDim2.new(1, 0, 0, 0)
			row.AutomaticSize = Enum.AutomaticSize.Y
			row.BackgroundColor3 = Theme.Extra.SurfaceRaised
			row.BorderSizePixel = 0
			row.Parent = capabilityList
			Theme.corner(Theme.Metrics.RadiusSmall).Parent = row

			local inner = Instance.new("Frame")
			inner.Size = UDim2.new(1, -16, 0, 0)
			inner.AutomaticSize = Enum.AutomaticSize.Y
			inner.BackgroundTransparency = 1
			Theme.passThrough(inner)
			inner.Position = UDim2.fromOffset(8, 6)
			inner.Parent = row
			Theme.listLayout(2).Parent = inner

			local top = Instance.new("Frame")
			top.Size = UDim2.new(1, 0, 0, 16)
			top.BackgroundTransparency = 1
			Theme.passThrough(top)
			top.Parent = inner

			-- Name and verdict share the row. Left at their default Position
			-- they both start at x=0 and paint over one another, because a
			-- percentage width does not move the origin.
			local topLayout = Instance.new("UIListLayout")
			topLayout.FillDirection = Enum.FillDirection.Horizontal
			topLayout.SortOrder = Enum.SortOrder.LayoutOrder
			topLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			topLayout.Parent = top

			local nameLabel = Theme.label(rowData.label, {
				size = Theme.TextSizes.Caption,
				font = Theme.Fonts.Medium,
				truncate = true,
			})
			nameLabel.Size = UDim2.new(1, -104, 1, 0)
			nameLabel.LayoutOrder = 1
			nameLabel.Parent = top
			-- The flex item belongs on the LABEL, inside this fixed-height row.
			-- On the row itself it would be a Fill child of an auto-sized
			-- vertical list, which makes it grow to the full canvas height.
			Theme.flexItem(nameLabel, 1)

			local statusLabel = Theme.label(rowData.verdict, {
				size = Theme.TextSizes.Caption,
				color = verdictColor(rowData.verdict),
				font = Theme.Fonts.Bold,
				alignX = Enum.TextXAlignment.Right,
			})
			statusLabel.Size = UDim2.fromOffset(96, 16)
			statusLabel.LayoutOrder = 2
			statusLabel.TextXAlignment = Enum.TextXAlignment.Right
			statusLabel.Parent = top

			local metaLabel = Theme.label(
				string.format(
					"%s%s%s",
					rowData.source,
					if rowData.overridden then " · override" else "",
					if rowData.checkedAt then string.format(" · %.0fs ago", os.clock() - rowData.checkedAt) else ""
				),
				{ size = 10, color = Theme.Extra.Muted, alignY = Enum.TextYAlignment.Top, wrap = true }
			)
			metaLabel.Size = UDim2.new(1, 0, 0, 0)
			metaLabel.AutomaticSize = Enum.AutomaticSize.Y
			metaLabel.Parent = inner

			local noteLabel = Theme.label(rowData.note, {
				size = 10,
				color = Theme.Extra.Muted,
				alignY = Enum.TextYAlignment.Top,
				wrap = true,
			})
			noteLabel.Size = UDim2.new(1, 0, 0, 0)
			noteLabel.AutomaticSize = Enum.AutomaticSize.Y
			noteLabel.Parent = inner

			if rowData.probeable then
				local probeRow = Instance.new("TextButton")
				probeRow.Name = "Probe"
				probeRow.Size = UDim2.new(1, 0, 0, 0)
				probeRow.AutomaticSize = Enum.AutomaticSize.Y
				probeRow.BackgroundTransparency = 1
				Theme.passThrough(probeRow)
				Icons.setButton(probeRow, "Warning", "Test with a real request (may cost tokens)")
				probeRow.TextXAlignment = Enum.TextXAlignment.Left
				probeRow.TextColor3 = Theme.Extra.Muted
				probeRow.TextSize = 10
				probeRow.TextWrapped = true
				probeRow.Font = Theme.Fonts.Medium
				probeRow.Parent = inner
				probeRow.MouseButton1Click:Connect(function()
					if not busy and runCapabilityProbe then runCapabilityProbe() end
				end)
			else
				local note = Theme.label("Not probeable: " .. rowData.probeNote, {
					size = 10,
					color = Theme.Extra.Muted,
					alignY = Enum.TextYAlignment.Top,
					wrap = true,
				})
				note.Size = UDim2.new(1, 0, 0, 0)
				note.AutomaticSize = Enum.AutomaticSize.Y
				note.Parent = inner
			end
		end
	end

	--=========================================================================
	-- BEHAVIOUR
	--=========================================================================

	local function setBusy(value: boolean)
		probeBusy = value or operation ~= nil
		busy = probeBusy or StateManager.isBusy()
		if busy then Components.closeMenus() end
		for _, control in view:GetDescendants() do
			if control:IsA("GuiButton") then control.Interactable = not busy
			elseif control:IsA("TextBox") then control.TextEditable = not busy end
		end
		testButton.Interactable = if probeBusy then not (operation and operation.cancelled) else not busy
		syncFooterStatus()
	end

	local function restoreTestControls()
		testButton.Text = "Test connection"
		testChatButton.Text = "Test chat"
		testStreamButton.Text = "Test streaming"
		testToolButton.Text = "Test tool calling"
		capabilityButton.Text = "Detect capabilities"
		detectButton.Text = "Detect API protocol"
		refreshModelsButton.Text = "Refresh models"
		setBusy(false)
	end

	local function finishStopped(token: any)
		if operation ~= token then return end
		operation = nil
		if destroyed then return end
		restoreTestControls()
		testResult.TextColor3 = Theme.Extra.Warning
		testResult.Text = if token.timedOut then "Test timed out after 60 seconds. Check the URL and provider, then try again." else "Provider test stopped."
	end

	local function stopOperation(timedOut: boolean?)
		local token = operation
		if not token then return end
		token.cancelled = true
		token.timedOut = timedOut == true
		if not destroyed then
			testButton.Text = "Stopping…"
			testButton.Interactable = false
		end
		-- HTTP calls and stream loops poll the token and clean up themselves.
		-- A misbehaving callback cannot hold the settings controls forever.
		task.delay(1, function()
			if operation ~= token then return end
			if token.worker then pcall(task.cancel, token.worker) end
			finishStopped(token)
		end)
	end

	-- Defer work so Studio can draw the busy state before starting requests.
	-- Diagnostics use one attempt, short requests and a whole-operation deadline.
	local function runBackground(work: (any, () -> boolean) -> ())
		local token = { cancelled = false, timedOut = false, deadline = os.clock() + 60, worker = nil :: thread? }
		operation = token
		local profile = table.clone(draft)
		profile.timeoutMs = math.min(profile.timeoutMs or 120000, 15000)
		profile.retryOverrides = { enabled = false, maxRetries = 0, dynamicCooldown = false }
		local function shouldCancel(): boolean
			return destroyed or token.cancelled or operation ~= token or os.clock() >= token.deadline
		end
		testButton.Text = "Stop test"
		testButton.Interactable = true
		token.worker = task.defer(function()
			if shouldCancel() then finishStopped(token); return end
			local ok, cause = pcall(work, profile, shouldCancel)
			if destroyed or operation ~= token then return end
			if shouldCancel() then
				token.timedOut = token.timedOut or os.clock() >= token.deadline
				finishStopped(token)
			else
				operation = nil
				restoreTestControls()
				if not ok then
					testResult.TextColor3 = Theme.Colors.Error
					testResult.Text = "The provider test failed. Check the activity log for details."
					Logger.error("AI Provider", "Provider operation failed.", { detail = tostring(cause) })
				end
			end
		end)
		task.delay(60, function()
			if operation == token then stopOperation(true) end
		end)
	end

	local function requireApiKey(): (string?, string?)
		if busy then return nil, "A task or provider test is already running." end
		if #StringUtil.trim(draft.baseUrl) == 0 then
			return nil, "Set an API Base URL first."
		end
		if #StringUtil.trim(draft.modelId) == 0 then
			return nil, "Set a Model ID first. Any model your provider exposes can be entered manually."
		end
		local ok, errors = commit(true)
		if not ok then
			local first = errors and errors[1]
			return nil, if first then (first.field .. ": " .. first.message) else "The provider is not valid yet."
		end
		local key = CredentialStore.get(draft.id)
		if draft.authStyle ~= "none" and not draft.viaRouter and not key then
			return nil, "Enter an API key in Connection before running a test."
		end
		return key, nil
	end

	addPreset = function(presetId: string)
		local created, err
		if presetId == "custom" or presetId == "rest" then
			created, err = CustomProviderManager.createDraft(presetId)
		else
			created, err = CustomProviderManager.create(presetId)
		end
		if not created then
			EventBus.emit(EventBus.Events.Toast, { kind = "error", message = tostring(err) })
			return
		end
		RetryLogger.providerSelected(created)
		showEditor(created)
	end
	profileActions["Use for chat"] = function()
		if not commit(true) then return end
		SettingsManager.setActiveProvider(draft.id)
		configureIfActive()
		RetryLogger.providerSelected(draft)
		refresh()
		EventBus.emit(EventBus.Events.Toast, { kind = "success", message = "Provider selected for chat." })
	end
	profileActions["Duplicate profile"] = function()
		local copy, err = CustomProviderManager.duplicate(draft.id)
		if not copy then
			EventBus.emit(EventBus.Events.Toast, { kind = "error", message = tostring(err) })
			return
		end
		showEditor(copy)
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Profile duplicated. Enter a new API key for the copy." })
	end
	profileActions["Remove profile"] = function()
		CredentialStore.clear(draft.id)
		CustomProviderManager.remove(draft.id)
		showOverview()
		renderProfileList()
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Provider profile removed." })
	end
	profileActions["Disconnect key"] = function()
		CredentialStore.clear(draft.id)
		CustomProviderManager.disconnect(draft.id)
		refresh()
		ContextManager.configure(SettingsManager.getActiveProvider())
		EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "Session API key removed. The profile is kept." })
	end

	saveButton.MouseButton1Click:Connect(function()
		local ok, errors = commit(true)
		if ok then
			EventBus.emit(EventBus.Events.Toast, { kind = "success", message = "Provider saved." })
			renderProfileList()
		else
			local first = errors and errors[1]
			EventBus.emit(EventBus.Events.Toast, {
				kind = "error",
				message = if first then (first.field .. ": " .. first.message) else "The provider could not be saved.",
			})
		end
	end)

	testButton.MouseButton1Click:Connect(function()
		if probeBusy then stopOperation(); return end
		local _, err = requireApiKey()
		if err then
			EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = err })
			return
		end
		setBusy(true)
		testButton.Text = "Stop test"
		testResult.TextColor3 = Theme.Extra.Muted
		testResult.Text = "Contacting the provider…"

		runBackground(function(profile, shouldCancel)
			local apiKey = CredentialStore.get(draft.id)
			local result = ProviderService.testConnection(profile, apiKey, {
				shouldCancel = shouldCancel,
				onProgress = function(note)
					testResult.Text = note
				end,
			})

			if shouldCancel() then return end
			testButton.Text = "Test connection"
			setBusy(false)

			if result.ok then
				testResult.TextColor3 = Theme.Colors.Success
			else
				testResult.TextColor3 = Theme.Colors.Error
			end
			testResult.Text = string.format(
				"%s in %.0f ms.\n%s",
				if result.ok then "Connected" else "Failed",
				result.latencyMs or 0,
				result.message or ""
			)
			if result.remedy then
				testResult.Text ..= "\n" .. result.remedy
			end
			testResult.Text ..= "\nEndpoint: " .. result.endpoint

			EventBus.emit(EventBus.Events.Toast, {
				kind = if result.ok then "success" else "error",
				message = if result.ok then "Connection succeeded." else result.message,
			})
		end)
	end)

	testChatButton.MouseButton1Click:Connect(function()
		local apiKey, err = requireApiKey()
		if err then
			EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = err })
			return
		end
		setBusy(true)
		testChatButton.Text = "Testing…"
		runBackground(function(profile, shouldCancel)
			local result = ProviderService.complete(profile, {
				messages = { { role = "user", content = "Reply with the single word: ok" } },
				model = draft.modelId,
				maxOutputTokens = 32,
				streaming = false,
				jsonMode = false,
				toolChoice = "none",
			}, apiKey, { operationId = "probe-chat-" .. tostring(os.clock()), shouldCancel = shouldCancel })

			if shouldCancel() then return end
			testChatButton.Text = "Test chat"
			setBusy(false)

			if result.ok and result.response then
				testResult.TextColor3 = Theme.Colors.Success
				testResult.Text = string.format(
					"Chat works. Reply: \"%s\"",
					string.sub(string.gsub(result.response.text or "", "%s+", " "), 1, 80)
				)
			else
				testResult.TextColor3 = Theme.Colors.Error
				testResult.Text = result.error and result.error.message or "Chat test failed."
			end
		end)
	end)

	testStreamButton.MouseButton1Click:Connect(function()
		local apiKey, err = requireApiKey()
		if err then
			EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = err })
			return
		end
		local status = StreamingManager.streamingStatus(draft)
		setBusy(true)
		testStreamButton.Text = "Testing…"
		runBackground(function(profile, shouldCancel)
			local chunks = 0
			local finished = false
			local failure: any = nil

			ProviderService.stream(profile, {
				messages = { { role = "user", content = "Count to three." } },
				model = draft.modelId,
				maxOutputTokens = 32,
				streaming = true,
				jsonMode = false,
				toolChoice = "none",
			}, apiKey, {
				shouldCancel = shouldCancel,
				onText = function()
					if shouldCancel() then return end
					chunks += 1
					testResult.Text = string.format("Receiving… %d chunk(s) so far.", chunks)
				end,
				onDone = function()
					finished = true
				end,
				onError = function(normalised)
					failure = normalised
				end,
			})

			local waited = 0
			while not finished and not failure and waited < 30 and not shouldCancel() do
				task.wait(0.1)
				waited += 0.1
			end

			if shouldCancel() then return end
			testStreamButton.Text = "Test streaming"
			setBusy(false)

			if failure then
				testResult.TextColor3 = Theme.Colors.Error
				testResult.Text = string.format("Streaming failed: %s", failure.message or "unknown error")
			elseif chunks > 1 then
				testResult.TextColor3 = Theme.Colors.Success
				testResult.Text = string.format("Streaming works. %d chunks received.", chunks)
			else
				testResult.TextColor3 = Theme.Extra.Warning
				testResult.Text = "The request completed, but only one chunk arrived. Streaming may be unsupported here."
			end
		end)
	end)

	testToolButton.MouseButton1Click:Connect(function()
		local apiKey, err = requireApiKey()
		if err then
			EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = err })
			return
		end
		setBusy(true)
		testToolButton.Text = "Testing…"
		runBackground(function(profile, shouldCancel)
			local result = ProviderService.complete(profile, {
				messages = { { role = "user", content = "Call the probe_tool function exactly once." } },
				model = draft.modelId,
				maxOutputTokens = 128,
				streaming = false,
				jsonMode = false,
				toolChoice = "required",
				tools = {
					{
						name = "probe_tool",
						description = "Returns a constant.",
						parameters = { type = "object", properties = {}, additionalProperties = false },
					},
				},
			}, apiKey, { operationId = "probe-tool-" .. tostring(os.clock()), shouldCancel = shouldCancel })

			if shouldCancel() then return end
			testToolButton.Text = "Test tool calling"
			setBusy(false)

			local toolCalls = if result.ok and result.response then result.response.toolCalls else nil
			if toolCalls and #toolCalls > 0 then
				testResult.TextColor3 = Theme.Colors.Success
				testResult.Text = string.format("Tool calling works. The model requested `%s`.", toolCalls[1].name)
			elseif result.ok then
				testResult.TextColor3 = Theme.Extra.Warning
				testResult.Text = "The request succeeded but no tool call came back. This model may not support tools."
			else
				testResult.TextColor3 = Theme.Colors.Error
				testResult.Text = result.error and result.error.message or "Tool test failed."
			end
		end)
	end)

	runCapabilityProbe = function()
		local _, err = requireApiKey()
		if err then
			EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = err })
			return
		end
		setBusy(true)
		capabilityButton.Text = "Probing…"
		EventBus.emit(EventBus.Events.Toast, {
			kind = "warning",
			message = "Capability probes send real requests and may cost tokens.",
		})
		runBackground(function(profile, shouldCancel)
			local report = CapabilityInspector.probe(profile, {
				shouldCancel = shouldCancel,
				onProgress = function()
					renderCapabilities(CapabilityInspector.buildReport(draft))
				end,
			})
			if shouldCancel() then return end
			capabilityButton.Text = "Detect capabilities"
			setBusy(false)
			configureIfActive(report)
			renderCapabilities(report)
			EventBus.emit(EventBus.Events.Toast, {
				kind = "success",
				message = "Capability probes finished.",
			})
		end)
	end
	capabilityButton.MouseButton1Click:Connect(runCapabilityProbe)

	detectButton.MouseButton1Click:Connect(function()
		local _, err = requireApiKey()
		if err then
			EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = err })
			return
		end
		setBusy(true)
		detectButton.Text = "Detecting…"
		detectNote.Text = "Probing protocols. These are real, billable requests."
		EventBus.emit(EventBus.Events.Toast, {
			kind = "warning",
			message = "Protocol detection sends real requests and may cost tokens.",
		})

		runBackground(function(profile, shouldCancel)
			local report = ProtocolDetector.detect(profile, {
				shouldCancel = shouldCancel,
				maxProbes = 3,
				onProgress = function(candidates, note)
					detectNote.Text = note
					_ = candidates
				end,
			})

			if shouldCancel() then return end
			detectButton.Text = "Detect API protocol"
			setBusy(false)

			if report.best then
				draft.protocol = report.best.protocolId
				draft.endpointPathCustom = false
				local label = labelOf(PROTOCOL_OPTIONS, report.best.protocolId) or report.best.protocolId
				commit()
				refresh()
				RetryLogger.protocolConfirmed(draft, report.best.protocolId, report.best.source)
				detectNote.Text = string.format(
					"Best match: %s (%s, confidence %.2f). %s",
					label,
					report.best.source,
					report.best.confidence,
					report.best.note
				)
			else
				detectNote.Text = "No protocol could be confirmed. Choose one manually, or check the Base URL."
			end
		end)
	end)

	refreshModelsButton.MouseButton1Click:Connect(function()
		if busy then return end
		local ok, errors = commit(true)
		if not ok then
			local first = errors and errors[1]
			EventBus.emit(EventBus.Events.Toast, {
				kind = "error",
				message = if first then (first.field .. ": " .. first.message) else "Save the provider first.",
			})
			return
		end

		setBusy(true)
		refreshModelsButton.Text = "Loading…"
		runBackground(function(profile, shouldCancel)
			local ids, err = ProviderService.listModels(profile, CredentialStore.get(profile.id), shouldCancel)
			if shouldCancel() then return end
			refreshModelsButton.Text = "Refresh models"
			setBusy(false)

			for _, child in modelListHolder:GetChildren() do
				if child:IsA("GuiObject") and child ~= refreshModelsButton then child:Destroy() end
			end

			if not ids then
				EventBus.emit(EventBus.Events.Toast, { kind = "warning", message = tostring(err) })
				return
			end

			local dropdown = Components.dropdown(
				string.format("Available models (%d)", #ids),
				ids,
				function(selected)
					draft.modelId = selected
					modelBox.Text = selected
					commit()
					CapabilityInspector.buildReport(draft)
					renderProfileList()
				end
			)
			dropdown.LayoutOrder = 1
			dropdown.Parent = modelListHolder

			EventBus.emit(EventBus.Events.Toast, {
				kind = "success",
				message = string.format("%d model ids loaded.", #ids),
			})
		end)
	end)

	providerNameRow.Parent = endpointBody
	providerNameRow.LayoutOrder = 0
	typeField.Parent = endpointBody
	typeField.LayoutOrder = 1
	protocolField.LayoutOrder = 2
	detectHolder.LayoutOrder = 3
	endpointPathRow.LayoutOrder = 4
	modeField.LayoutOrder = 5
	baseUrlRow.Parent = identityBody
	baseUrlRow.LayoutOrder = 4
	displayNameRow.LayoutOrder = 0
	keyRow.Parent = identityBody
	keyRow.LayoutOrder = 1
	keyRow.Visible = draft.authStyle ~= "none"
	modelRow.Parent = identityBody
	modelRow.LayoutOrder = 2
	modelListHolder.Parent = identityBody
	modelListHolder.LayoutOrder = 3
	Theme.listLayout(6).Parent = modelListHolder
	refreshModelsButton.Parent = modelListHolder
	refreshModelsButton.LayoutOrder = 0
	contextAutoRow.LayoutOrder = 0
	contextRow.LayoutOrder = 1
	outputAutoRow.LayoutOrder = 2
	outputRow.LayoutOrder = 3
	timeoutRow.Parent = endpointBody
	timeoutRow.LayoutOrder = 6
	headersRow.Parent = credentialBody
	headersRow.LayoutOrder = 5
	streamingRow.LayoutOrder = 4
	toolRow.LayoutOrder = 5
	jsonRow.LayoutOrder = 6
	retryRow.LayoutOrder = 7
	local limitsSummary = Theme.autoText("", { size = Theme.TextSizes.Caption, color = Theme.Extra.Muted })
	limitsSummary.Name = "LimitsSummary"
	limitsSummary.LayoutOrder = 4
	limitsSummary.Parent = modelBody
	syncLimits = function()
		contextRow.Visible = draft.contextWindowMode == "manual"
		outputRow.Visible = draft.maxOutputTokensMode == "manual"
		local report = CapabilityInspector.buildReport(draft)
		limitsSummary.Text = string.format("Context: %s tokens · Output: %s tokens", Time.formatNumber(report.contextWindow), Time.formatNumber(report.maxOutputTokens))
	end

	--=========================================================================
	-- SYNC
	--=========================================================================

	refresh = function()
		displayNameBox.Text = draft.displayName or ""
		providerNameBox.Text = draft.providerName or ""
		baseUrlBox.Text = draft.baseUrl or ""
		endpointPathBox.Text = if draft.endpointPathCustom then (draft.endpointPath or "") else CustomProviderManager.suggestEndpointPath(draft.protocol)
		modelBox.Text = draft.modelId or ""
		contextBox.Text = tostring(draft.contextWindow or 128000)
		outputBox.Text = tostring(draft.maxOutputTokens or 8192)
		temperatureBox.Text = tostring(draft.temperature or 0.7)
		topPBox.Text = tostring(draft.topP or 1.0)
		timeoutBox.Text = tostring(draft.timeoutMs or 120000)
		headerNameBox.Text = draft.authHeaderName or ""
		headerPrefixBox.Text = draft.authHeaderPrefix or ""
		queryParamBox.Text = draft.authQueryParam or ""
		headersBox.Text = CustomProviderManager.formatHeaders(draft.extraHeaders)
		setType(labelOf(PROVIDER_TYPE_OPTIONS, draft.providerType))
		setProtocol(labelOf(PROTOCOL_OPTIONS, draft.protocol))
		setAuth(labelOf(AUTH_OPTIONS, draft.authStyle))
		setURLMode(if draft.urlMode == "full" then "Full Endpoint URL" else "Base URL")
		setContextAuto(draft.contextWindowMode ~= "manual")
		setOutputAuto(draft.maxOutputTokensMode ~= "manual")
		setStreaming(draft.streaming ~= false)
		setTools(draft.toolCalling ~= false)
		setJSON(draft.jsonMode == true)
		setEffort(if draft.reasoningEffort and #draft.reasoningEffort > 0 then draft.reasoningEffort else "(not sent)")
		revealed = false
		revealButton.Text = "Show"
		keyBox.Text = ""
		refreshKeyMask()
		requestSchemaBox.Text = HttpService:JSONEncode(draft.schemaMapping and draft.schemaMapping.request or {})
		responseSchemaBox.Text = HttpService:JSONEncode(draft.schemaMapping and draft.schemaMapping.response or {})

		keyRow.Visible = draft.authStyle ~= "none"
        local keyLabel = keyRow:FindFirstChild("Label")
        if keyLabel and keyLabel:IsA("TextLabel") then keyLabel.Text = if draft.viaRouter then "9Router API key" else "API Key" end
        keyBox.PlaceholderText = if draft.viaRouter then "9Router client key, if required" else "Enter API key"
        routerCard.Visible = draft.viaRouter == true
        login.Interactable = not busy; statusButton.Interactable = not busy; statusButton.Text = "Refresh connection"
        login.Text = if draft.hasOAuth then "Sign in / Log in" else "Connect in 9Router"
        routerNote.Text = if draft.viaRouter then "Account credentials stay in 9Router. Finish sign in there, refresh connection, then select a model." else ""
		headerNameRow.Visible = draft.authStyle == "header" or draft.authStyle == "custom"
		headerPrefixRow.Visible = draft.authStyle == "custom"
		queryParamRow.Visible = draft.authStyle == "query"
		schemaCard.Visible = draft.protocol == "custom_rest"
		editorTitle.Text = draft.displayName or "Provider"
		setActionLabel("More")
		syncLimits()
		refreshKeyStatus()
		syncFooterStatus()
		refreshRetryNote()
		refreshPreview()
		renderProfileList()
		renderCapabilities(CapabilityInspector.buildReport(draft))
	end

	showEditor = function(profile: any)
		if busy or not profile then return end
		Components.closeMenus()
		loginGeneration += 1
		draft = table.clone(profile)
		editorTab = "Connection"
		selectTab(editorTab)
		for name, page in pages do
			page.Visible = name == editorTab
			page.CanvasPosition = Vector2.new(0, 0)
		end
		for _, child in modelListHolder:GetChildren() do
			if child:IsA("GuiObject") and child ~= refreshModelsButton then child:Destroy() end
		end
		testResult.Text = ""
		overview.Visible = false
		editor.Visible = true
		refresh()
	end
	local unsubscribeProviders = EventBus.on(EventBus.Events.ProvidersChanged, function(payload)
		renderProfileList()
		if payload.reason == "reset" or not SettingsManager.getProvider(draft.id) then showOverview() end
	end)
	local unsubscribeActive = EventBus.on(EventBus.Events.ActiveProviderChanged, function()
		renderProfileList()
		syncFooterStatus()
	end)
	local unsubscribeState = EventBus.on(EventBus.Events.StateChanged, function() setBusy(probeBusy) end)
	setBusy(false)
	local function destroy()
		if destroyed then return end
		destroyed = true
		stopOperation()
		unsubscribeProviders()
		unsubscribeActive()
		unsubscribeState()
		Components.closeMenus()
	end
	view.Destroying:Connect(destroy)
	refresh()
	renderCatalog()
	return view, {
		showOverview = showOverview,
		editProfile = function(id: string) showEditor(SettingsManager.getProvider(id)) end,
		getTab = function() return editorTab end,
		refresh = refresh,
		destroy = destroy,
	}
end

return ProviderView
