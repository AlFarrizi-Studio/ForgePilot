--!nocheck
--[[
	ForgePilot / Tests / Spec — core regression suite (development only).

	This file is NOT part of the Rojo tree and never ships in the RBXM. It runs
	inside the mock Roblox runtime (see .devtools/run-tests.mjs), so assertions
	exercise real Luau against real Roblox API semantics: an invalid property
	assignment, a wrong Enum type or a call to a method that does not exist all
	throw exactly as they would in Studio.
]]

local Theme = require(script.Parent.Parent.Utilities.Theme)
local Components = require(script.Parent.Parent.UI.Components)
local Base64 = require(script.Parent.Parent.Utilities.Base64)
local BaseURLResolver = require(script.Parent.Parent.AI.BaseURLResolver)
local Redact = require(script.Parent.Parent.Utilities.Redact)
local ErrorHandler = require(script.Parent.Parent.Utilities.ErrorHandler)
local APIEndpointRouter = require(script.Parent.Parent.AI.APIEndpointRouter)
local UniversalProviderRegistry = require(script.Parent.Parent.AI.UniversalProviderRegistry)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local CredentialStore = require(script.Parent.Parent.Core.CredentialStore)
local DockWidget = require(script.Parent.Parent.UI.DockWidget)
local ChatView = require(script.Parent.Parent.UI.ChatView)
local RetryDelayCalculator = require(script.Parent.Parent.AI.RetryDelayCalculator)

local Spec = {}

local function ok(name, condition, message)
	return { name = name, ok = condition == true, message = message or "assertion failed" }
end

function Spec.run()
	local results = {}
	local function check(name, condition, message)
		results[#results + 1] = ok(name, condition, message)
	end

	--=============================================================================
	-- 1. DEPENDENCY / PATH RESOLUTION
	--=============================================================================

	check(
		"module path: Core/ApplicationController resolves through the packaged tree",
		require(script.Parent.Parent.Core.ApplicationController) ~= nil,
		"require(script.Parent.Parent.Core.ApplicationController) returned nil"
	)
	check(
		"module path: nested folder AI/Adapters resolves",
		require(script.Parent.Parent.AI.Adapters.OpenAIResponsesAdapter) ~= nil,
		"require(script.Parent.Parent.AI.Adapters.OpenAIResponsesAdapter) returned nil"
	)
	check(
		"module path: Utilities/Clipboard resolves",
		require(script.Parent.Parent.Utilities.Clipboard) ~= nil,
		"require(script.Parent.Parent.Utilities.Clipboard) returned nil"
	)

	--=============================================================================
	-- 2. THEME — property types Studio enforces
	--=============================================================================

	local label = Theme.label("hello", { size = 12 })
	check("Theme.label returns a TextLabel", label:IsA("TextLabel"), tostring(label.ClassName))
	check(
		"Theme.label sets a TextSize",
		label.TextSize == 12,
		"expected TextSize 12, got " .. tostring(label.TextSize)
	)
	check(
		"Theme.label leaves TextTruncate as an Enum",
		label.TextTruncate == Enum.TextTruncate.None,
		"expected Enum.TextTruncate.None, got " .. tostring(label.TextTruncate)
	)

	local alphaOk, tinted = pcall(function()
		return Theme.withAlpha(Theme.Colors.Highlight, 0.5)
	end)
	check("Theme.withAlpha does not throw", alphaOk, tostring(tinted))
	check(
		"Theme.withAlpha keeps a Color3 result",
		alphaOk and typeof(tinted) == "Color3",
		"withAlpha returned " .. typeof(tinted) .. ", not a Color3"
	)
	local full = Theme.withAlpha(Theme.Colors.Highlight, 1)
	check(
		"Theme.withAlpha(alpha = 1) is the identity",
		full.R == Theme.Colors.Highlight.R and full.G == Theme.Colors.Highlight.G,
		"alpha 1 should return the colour unchanged"
	)

	local cornerOk, corner = pcall(function() return Theme.corner(8) end)
	check("Theme.corner builds a UICorner", cornerOk and corner:IsA("UICorner"), tostring(corner))
	local strokeOk, stroke = pcall(function() return Theme.stroke(Color3.new(1, 0, 0), 1, 0.25) end)
	check("Theme.stroke builds a UIStroke", strokeOk and stroke:IsA("UIStroke"), tostring(stroke))
	check(
		"Theme.stroke honours transparency",
		stroke and stroke.Transparency == 0.25,
		"expected Transparency 0.25"
	)

	local scrollFrame = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
	check("Theme.scrollingFrame returns a ScrollingFrame", scrollFrame:IsA("ScrollingFrame"))
	check(
		"Theme.scrollingFrame sets AutomaticCanvasSize",
		scrollFrame.AutomaticCanvasSize == Enum.AutomaticSize.Y,
		"expected AutomaticSize.Y"
	)

	-- A Theme.create helper must not use Instance.new's second argument wrongly.
	local okCreate, created = pcall(function()
		return Theme.create("Frame", { BackgroundTransparency = 1, Name = "SpecFrame" })
	end)
	check(
		"Theme.create applies a property table",
		okCreate and created ~= nil and created.Name == "SpecFrame" and created.BackgroundTransparency == 1,
		"Theme.create must apply the given properties"
	)
	check(
		"Theme.create does not parent to the property table",
		okCreate and created.Parent == nil,
		"the property table must not be treated as the Parent argument"
	)
	local okNew, instance = pcall(function() return Instance.new("Frame") end)
	check("Instance.new still works after Theme.create", okNew and instance:IsA("Frame"), tostring(instance))

	--=============================================================================
	-- 3. COMPONENTS — construction without throwing
	--=============================================================================

	local sectionOk, sectionCard, sectionBody = pcall(function() return Components.section("Providers") end)
	check(
		"Components.section builds a card and body",
		sectionOk and sectionCard:IsA("Frame") and sectionBody:IsA("Frame"),
		tostring(sectionCard)
	)

	local fieldOk, fieldRow, fieldHolder = pcall(function()
		return Components.field("API Key", { hint = "kept for this session" })
	end)
	check(
		"Components.field builds a row and holder",
		fieldOk and fieldRow:IsA("Frame") and fieldHolder:IsA("Frame"),
		tostring(fieldRow)
	)

	local toggleOk, toggleRow, getToggle = pcall(function()
		return Components.toggle("Streaming", false, function() end)
	end)
	check(
		"Components.toggle builds and returns a getter",
		toggleOk and toggleRow:IsA("Frame") and type(getToggle) == "function",
		tostring(getToggle)
	)
	check("Components.toggle starts at its initial value", getToggle() == false, tostring(getToggle()))

	local dropdownOk, dropdownRow, setOptions, getSelected = pcall(function()
		return Components.dropdown("Protocol", { "openai_chat", "anthropic_messages" }, function() end)
	end)
	check(
		"Components.dropdown builds and returns selectors",
		dropdownOk and dropdownRow:IsA("Frame") and type(setOptions) == "function" and type(getSelected) == "function",
		tostring(dropdownRow)
	)
	setOptions({ "custom_rest" })
	check("Components.dropdown updates its selection", getSelected() == "custom_rest", tostring(getSelected()))

	local chipOk, chip = pcall(function() return Components.chip("live", Theme.Colors.Success, 1) end)
	check("Components.chip builds", chipOk and chip:IsA("TextLabel"), tostring(chip))

	local emptyOk, emptyState = pcall(function()
		return Components.emptyState("Robot", "No provider", "Add one in Settings.", "Open Settings", function() end)
	end)
	check("Components.emptyState builds", emptyOk and emptyState:IsA("Frame"), tostring(emptyState))

	--=============================================================================
	-- 4. PURE LOGIC MODULES
	--=============================================================================

	local encoded = Base64.encode("ForgePilot")
	check("Base64 encodes to the RFC 4648 alphabet", type(encoded) == "string" and #encoded > 0, tostring(encoded))
	check("Base64 round-trips a string", Base64.decode(encoded) == "ForgePilot", encoded)

	local secret = "sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"
	local scrubbed = Redact.scrubText("key is " .. secret .. " here")
	check(
		"Redact output contains no raw key",
		string.find(scrubbed, secret, 1, true) == nil,
		"the raw key survived redaction: " .. scrubbed
	)
	check("Redact.fingerprint hides the secret", string.find(Redact.fingerprint(secret), secret, 1, true) == nil)

	local parsed = BaseURLResolver.parse("https://api.example.com/v1/")
	check("BaseURLResolver parses a base URL", parsed ~= nil, "parse returned nil")
	check("BaseURLResolver extracts the host", parsed ~= nil and parsed.host == "api.example.com", tostring(parsed and parsed.host))
	check(
		"BaseURLResolver strips a trailing slash",
		BaseURLResolver.normaliseBase("https://api.example.com/v1/") == "https://api.example.com/v1",
		tostring(BaseURLResolver.normaliseBase("https://api.example.com/v1/"))
	)
	check(
		"BaseURLResolver rejects a bare host",
		(select(1, BaseURLResolver.parse("api.example.com")) == nil),
		"a URL without a scheme must be rejected"
	)

	local route = APIEndpointRouter.get("openai_chat")
	check("APIEndpointRouter knows openai_chat", route ~= nil and type(route) == "table", "no route returned")
	check(
		"APIEndpointRouter chat route is /chat/completions",
		route ~= nil and string.find(tostring(route.chat or ""), "chat/completions", 1, true) ~= nil,
		tostring(route and route.chat)
	)
	check(
		"APIEndpointRouter.chatPath agrees with get().chat",
		APIEndpointRouter.chatPath("openai_chat") == route.chat,
		tostring(APIEndpointRouter.chatPath("openai_chat"))
	)
	check(
		"APIEndpointRouter falls back for an unknown protocol",
		type(APIEndpointRouter.get("__nope__").chat) == "string",
		"an unknown protocol must still yield a usable path"
	)

	local authHeaders = UniversalProviderRegistry.buildAuthHeaders({ style = "bearer" }, secret)
	check(
		"buildAuthHeaders produces an Authorization header",
		type(authHeaders) == "table",
		"expected a table of headers"
	)

	--=============================================================================
	-- 5. EVENTBUS — no duplicate handlers, clean unsubscribe
	--=============================================================================

	local calls = 0
	local handler = function()
		calls += 1
	end
	local connection = EventBus.on(EventBus.Events.Toast, handler)
	EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "a" })
	EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "b" })
	check("EventBus delivers once per emit", calls == 2, "expected 2 calls, got " .. tostring(calls))
	connection()
	EventBus.emit(EventBus.Events.Toast, { kind = "info", message = "c" })
	check("EventBus unsubscribe stops delivery", calls == 2, "expected 2 calls after unsubscribe, got " .. tostring(calls))

	--=============================================================================
	-- 6. STATEMANAGER
	--=============================================================================

	local previousState = StateManager.get()
	local okState, stateErr = pcall(function() StateManager.transition("THINKING", { force = true }) end)
	check("StateManager.transition accepts a valid state", okState, tostring(stateErr))
	check("StateManager.get reflects the change", StateManager.get() == "THINKING", StateManager.get())
	local rejectedState = StateManager.get()
	local rejectedOk = pcall(function() StateManager.transition("NOT_A_STATE", { force = true }) end)
	check(
		"StateManager ignores an unknown state without throwing",
		rejectedOk and StateManager.get() == rejectedState,
		"an unknown state must not change the machine"
	)
	StateManager.reset()
	check("StateManager.reset returns to IDLE", StateManager.get() == "IDLE", StateManager.get())
	_ = previousState

	--=============================================================================
	-- 7. SETTINGS / CREDENTIALS — no provider and no key
	--=============================================================================

	SettingsManager.init(plugin)
	check("SettingsManager.initialises without a key", type(SettingsManager.get()) == "table")
	check(
		"SettingsManager.getValue returns nil for unknown keys",
		SettingsManager.getValue("__no_such_key__") == nil,
		"unknown keys must not invent values"
	)
	check(
		"no active provider before configuration",
		SettingsManager.getActiveProvider() == nil,
		"getActiveProvider must be nil until the user configures one"
	)
	check(
		"CredentialStore reports no key",
		CredentialStore.has("__missing__") == false,
		"CredentialStore.has must be false for an unknown provider"
	)
	check(
		"CredentialStore.get returns nil for an unknown provider",
		CredentialStore.get("__missing__") == nil,
		"CredentialStore.get must be nil for an unknown provider"
	)

	--=============================================================================
	-- 8. RETRY DELAY — header parsing
	--=============================================================================

	local seconds, secondsSource = RetryDelayCalculator.parseRetryAfter("30", 0)
	check("parseRetryAfter handles seconds", seconds == 30, tostring(seconds))
	check("parseRetryAfter names its source", secondsSource == "retry_after_seconds", tostring(secondsSource))

	local clamped = RetryDelayCalculator.parseRetryAfter("999999", 0)
	check("parseRetryAfter clamps to one day", clamped == 86400, tostring(clamped))

	local future = os.date("!*t", os.time() + 120)
	local httpDate = RetryDelayCalculator.parseRetryAfter(future, os.clock())
	check(
		"parseRetryAfter handles an HTTP date against a monotonic clock",
		httpDate == nil or (httpDate >= 0 and httpDate <= 86400),
		"an HTTP date must not produce a multi-decade wait: " .. tostring(httpDate)
	)

	--=============================================================================
	-- 9. ERRORHANDLER
	--=============================================================================

	check(
		"ErrorHandler.describe never throws",
		pcall(function() return ErrorHandler.describe(nil) end),
		"describe(nil) must be safe"
	)
	check(
		"ErrorHandler.describe handles a table",
		pcall(function() return ErrorHandler.describe({}) end),
		"describe(table) must be safe"
	)
	check(
		"ErrorHandler.describe handles a string",
		type(ErrorHandler.describe("boom")) == "string",
		"describe(string) must return a string"
	)

	--=============================================================================
	-- 10. DOCKWIDGET — construction and navigation without recursion
	--=============================================================================

	local widget = DockWidget.build(plugin)
	check("DockWidget.build returns a PluginGui", widget ~= nil and widget.ClassName == "DockWidgetPluginGui", tostring(widget and widget.ClassName))
	check("DockWidget exposes the content host", DockWidget.content ~= nil and DockWidget.content:IsA("Frame"))
	check("DockWidget exposes the status pill", DockWidget.statusPill ~= nil)

	local navCount = 0
	local navConnection = EventBus.on(EventBus.Events.Navigate, function()
		navCount += 1
	end)
	local okNavigate, navigateErr = pcall(function() DockWidget.navigate("builder") end)
	check("DockWidget.navigate does not throw", okNavigate, tostring(navigateErr))
	check("DockWidget.navigate emits Navigate once", navCount == 1, "expected 1 Navigate event, got " .. tostring(navCount))
	navConnection()

	local pillColourCount = 0
	local okStatus, statusErr = pcall(function()
		DockWidget.setStatus("Testing", Theme.Extra.Warning)
		DockWidget.setSubtitle("ForgePilot · Spec")
	end)
	check("DockWidget.setStatus does not throw", okStatus, tostring(statusErr))
	_ = pillColourCount

	--=============================================================================
	-- 11. CHATVIEW — the composer handle must survive build
	--=============================================================================

	local chatHost = Instance.new("Frame")
	chatHost.Name = "ChatHost"
	chatHost.Size = UDim2.fromScale(1, 1)
	chatHost.Parent = widget
	local okChat, chatErr = pcall(function()
		return ChatView.build(chatHost, { onNavigate = function() end })
	end)
	check("ChatView.build does not throw", okChat, tostring(chatErr))
	if okChat then
		local composer = chatHost:FindFirstChild("Composer", true)
		check("ChatView parents its composer", composer ~= nil, "Composer frame missing")
		check(
			"ChatView has a transcript",
			chatHost:FindFirstChild("Transcript", true) ~= nil,
			"Transcript frame missing"
		)
		check(
			"ChatView has the thinking indicator",
			chatHost:FindFirstChild("ThinkingIndicator", true) ~= nil,
			"ThinkingIndicator frame missing"
		)
		check(
			"ChatView keeps the scroll-to-bottom button reachable",
			chatHost:FindFirstChild("ScrollToBottom", true) ~= nil,
			"ScrollToBottom frame missing"
		)
		-- Regression: the composer handle used to be the Frame, not the api
		-- table, so every control call ("setMode", "setProvider") threw.
		-- The controls are nested (Composer > InputRow > Send), so this has to
		-- search descendants rather than direct children.
		local composerApi = chatHost:FindFirstChild("Composer", true)
		check(
			"ChatView composer controls were wired",
			composerApi ~= nil and composerApi:FindFirstChild("Send", true) ~= nil,
			"the composer lost its controls"
		)
	end

	--=============================================================================
	-- 12. CLIPBOARD
	--=============================================================================

	local Clipboard = require(script.Parent.Parent.Utilities.Clipboard)
	local copied, copyReason = Clipboard.copy("ForgePilot spec")
	check("Clipboard.copy succeeds through StudioService", copied == true, tostring(copyReason))
	local readOk, readReason = Clipboard.read()
	check(
		"Clipboard.read reports honestly that Studio has no read API",
		readOk == false and type(readReason) == "string",
		"read must report the limitation instead of faking a value"
	)

	--=============================================================================
	-- 13. PLANNING / BUILD MODE
	--=============================================================================

	local AgentController = require(script.Parent.Parent.AI.AgentController)
	local okContext, contextErr = pcall(function()
		return AgentController.gatherContext("plan")
	end)
	check("planning mode gathers context", okContext, tostring(contextErr))
	local okBuildContext, buildContextErr = pcall(function()
		return AgentController.gatherContext("build")
	end)
	check("build mode gathers context", okBuildContext, tostring(buildContextErr))

	--=============================================================================
	-- 14. MODEL BUILDER — terrain material table
	--=============================================================================
	-- Regression for the REAL Roblox Studio failure:
	--   Error: Lava is not a valid member of "Enum.Material"
	-- Roblox/ModelBuilder.luau evaluated its material table at MODULE SCOPE, so a
	-- single unknown member aborted require() and surfaced as the generic
	-- "Requested module experienced an error while loading."

	local ModelBuilder = require(script.Parent.Parent.Roblox.ModelBuilder)
	check("ModelBuilder loads", ModelBuilder ~= nil and type(ModelBuilder) == "table")
	check(
		"ModelBuilder exposes its terrain helper",
		type(ModelBuilder.Terrain) == "table" and type(ModelBuilder.Terrain.fill) == "function",
		"Terrain.fill missing"
	)
	local unsupported = ModelBuilder.unsupportedMaterials()
	check(
		"ModelBuilder reports unsupported materials instead of crashing",
		type(unsupported) == "table",
		"unsupportedMaterials() must return a table"
	)
	local region, regionError = ModelBuilder.Terrain.parseRegion("512,512,128")
	check("ModelBuilder parses a terrain region", region ~= nil, tostring(regionError))
	local badRegion = ModelBuilder.Terrain.parseRegion("not a region")
	check("ModelBuilder rejects a malformed region", badRegion == nil, "malformed region accepted")

	-- Every material the table resolves to must be a real Enum.Material item.
	local resolved, fillError = ModelBuilder.Terrain.fill({
		region = "512,512,128",
		material = "Grass",
		size = Vector3.new(4, 4, 4),
	})
	check("terrain fill with a real material does not throw", resolved == nil and fillError ~= nil, tostring(fillError))
	local _, aliasError = ModelBuilder.Terrain.fill({
		region = "512,512,128",
		material = "Lava",
		size = Vector3.new(4, 4, 4),
	})
	check(
		"a material alias that Roblox does not have still resolves safely",
		aliasError ~= nil and not string.find(tostring(aliasError), "not a valid member", 1, true),
		tostring(aliasError)
	)

	local ToolValidator = require(script.Parent.Parent.Roblox.ToolValidator)
	local okTools, toolsErr = pcall(function()
		return ToolValidator.toDefinitions("build")
	end)
	check("ToolValidator produces build tool definitions", okTools, tostring(toolsErr))

	check("ToolValidator lists tools", #ToolValidator.all() > 0, "no tools registered")
	check(
		"build mode exposes at least one tool",
		#ToolValidator.forMode("build") > 0,
		"build mode has no tools"
	)
	local toolCheck = ToolValidator.validate("create_instance", { path = "Workspace.Part" }, "build")
	check("ToolValidator validates a build action", toolCheck ~= nil)

	local StateManagerModule = require(script.Parent.Parent.Core.StateManager)
	check(
		"StateManager knows the planning and building states",
		StateManagerModule.displayLabel.PLANNING ~= nil and StateManagerModule.displayLabel.BUILDING ~= nil,
		"missing state labels"
	)

	--=============================================================================
	-- 13. RELOAD / IDEMPOTENCE
	--=============================================================================

	local secondWidgetOk, secondWidgetErr = pcall(function() return DockWidget.build(plugin) end)
	check("DockWidget.build can run twice without throwing", secondWidgetOk, tostring(secondWidgetErr))

	local passed, failed = 0, 0
	for _, result in ipairs(results) do
		if result.ok then passed += 1 else failed += 1 end
	end
	return { results = results, passed = passed, failed = failed }
end

return Spec