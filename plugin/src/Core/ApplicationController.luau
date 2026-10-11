--!strict
--[[
	ForgePilot / Core / ApplicationController
	Wires the plugin object to every subsystem and owns top-level lifecycle.

	Startup is staged and every stage reports its own outcome. Stages the window
	cannot exist without are required; everything else is optional, so a broken
	optional subsystem degrades the interface instead of preventing it from
	opening. `init` never throws: it returns a report the bootstrap can display.
]]

local ActivityLogs = require(script.Parent.Parent.UI.ActivityLogs)
local BuilderView = require(script.Parent.Parent.UI.BuilderView)
local ChatView = require(script.Parent.Parent.UI.ChatView)
local Components = require(script.Parent.Parent.UI.Components)
local ContextManager = require(script.Parent.Parent.AI.ContextManager)
local CredentialStore = require(script.Parent.CredentialStore)
local EventBus = require(script.Parent.EventBus)
local HistoryManager = require(script.Parent.Parent.Roblox.HistoryManager)
local HistoryView = require(script.Parent.Parent.UI.HistoryView)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ModelCapabilityDetector = require(script.Parent.Parent.AI.ModelCapabilityDetector)
local ProviderRateLimitScheduler = require(script.Parent.Parent.AI.ProviderRateLimitScheduler)
local RetryStateManager = require(script.Parent.Parent.AI.RetryStateManager)
local SessionManager = require(script.Parent.SessionManager)
local SettingsManager = require(script.Parent.SettingsManager)
local SettingsView = require(script.Parent.Parent.UI.SettingsView)
local StateManager = require(script.Parent.StateManager)
local StreamingManager = require(script.Parent.Parent.AI.StreamingManager)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local WelcomeDialog = require(script.Parent.Parent.UI.WelcomeDialog)
local DockWidget = require(script.Parent.Parent.UI.DockWidget)

local ApplicationController = {}

export type StageReport = {
	stage: string,
	modulePath: string,
	ok: boolean,
	required: boolean,
	cause: string?,
	trace: string?,
}

export type Report = {
	ok: boolean,
	stages: { StageReport },
	cause: string?,
	trace: string?,
}

local pluginRef: Plugin? = nil
local gui: PluginGui? = nil
local views: { [string]: any } = {}
-- Per-view teardown hooks, kept out of the Instances themselves.
local viewApis: { [string]: any } = {}
local currentSection: string = "chat"
local unsubs: { () -> () } = {}
local lastReport: Report? = nil

--=============================================================================
-- HEADER STATUS
--=============================================================================

local function refreshHeader()
	local settings = SettingsManager.get()
	Theme.motionEnabled = settings.animations ~= false and not settings.reducedMotion
	DockWidget.setSubtitle(string.format("%s · %s", settings.assistantName, game.Name))

	local profile = SettingsManager.getActiveProvider()
	if not profile then
		DockWidget.setStatus("No AI Provider Configured", Theme.Extra.Muted)
		return
	end

	local hasKey = profile.viaRouter or profile.authStyle == "none" or CredentialStore.has(profile.id)
	local modelLabel = if profile.modelId ~= "" then profile.modelId else "(no model set)"

	if not hasKey then
		DockWidget.setStatus(string.format("%s · no key", profile.displayName), Theme.Extra.Warning)
	else
		local stream = StreamingManager.streamingStatus(profile)
		local suffix = if stream.available then "" else " · no stream"
		DockWidget.setStatus(string.format("%s · %s%s", profile.displayName, modelLabel, suffix), Theme.Extra.Muted)
	end
end

--=============================================================================
-- BUILD
--=============================================================================

--- Each view is built independently: one failing view leaves the rest usable and
--- is reported instead of taking the window down with it.
local function buildViews(content: Frame, stages: { StageReport })
	local builders: { [string]: (Frame) -> any } = {
		chat = function(frame)
			return ChatView.build(frame, {
				onNavigate = function(section: string)
					DockWidget.navigate(section)
				end,
			})
		end,
		builder = BuilderView.build,
		history = HistoryView.build,
		logs = ActivityLogs.build,
		settings = SettingsView.build,
	}

	for _, name in ipairs(DockWidget.SectionOrder) do
		local builder = builders[name]
		if builder then
			-- Every view build returns (frame, api). The frame is the GuiObject;
			-- the api is a plain table because Roblox Instances cannot carry
			-- extra members.
			local ok, frame, api = xpcall(function()
				return builder(content)
			end, function(message)
				return debug.traceback(tostring(message), 2)
			end)
			local stage: StageReport = {
				stage = "Initial UI Rendering",
				modulePath = string.format("UI/%s", name),
				ok = ok,
				required = false,
			}
			if ok and frame then
				views[name] = frame
				viewApis[name] = api
				views[name].Visible = name == "chat"
				views[name].Parent = content
			else
				stage.cause = tostring(frame)
				stage.trace = tostring(frame)
				warn("[ForgePilot][VIEW ERROR] UI/" .. name .. ": " .. stage.cause)
			end
			stages[#stages + 1] = stage
		end
	end

	if views.chat then
		views.chat.Visible = true
	end
end

--=============================================================================
-- STAGE RUNNER
--=============================================================================

local function runStage(
	stages: { StageReport },
	name: string,
	modulePath: string,
	required: boolean,
	action: () -> ()
): boolean
	local ok, err = xpcall(action, function(message)
		return debug.traceback(tostring(message), 2)
	end)
	local stage: StageReport = {
		stage = name,
		modulePath = modulePath,
		ok = ok,
		required = required,
	}
	if not ok then
		stage.cause = tostring(err)
		stage.trace = tostring(err)
		warn("[ForgePilot][STAGE ERROR] " .. name .. " (" .. modulePath .. "): " .. stage.cause)
	end
	stages[#stages + 1] = stage
	return ok
end

--=============================================================================
-- INIT
--=============================================================================

--- Starts ForgePilot. Always returns a report; never throws.
function ApplicationController.init(plugin: Plugin): Report
	pluginRef = plugin

	local stages: { StageReport } = {}
	local report: Report = { ok = true, stages = stages }
	lastReport = report

	local function finish(): Report
		for _, stage in ipairs(stages) do
			if not stage.ok and stage.required then
				report.ok = false
				report.cause = stage.cause
				report.trace = stage.trace
				break
			elseif not stage.ok and report.cause == nil then
				report.cause = string.format("%s (%s): %s", stage.stage, stage.modulePath, tostring(stage.cause))
				report.trace = stage.trace
			end
		end
		return report
	end

	-- 1. Core services --------------------------------------------------------
	if not runStage(stages, "Core Services", "Core/SettingsManager", true, function()
		SettingsManager.init(plugin)
		Theme.motionEnabled = SettingsManager.get().animations ~= false and not SettingsManager.get().reducedMotion
		SessionManager.init(plugin)
		HistoryManager.resetOrphan()
	end) then
		return finish()
	end

	-- 2. State ----------------------------------------------------------------
	runStage(stages, "State Manager", "Core/StateManager", true, function()
		RetryStateManager.init()
	end)
	runStage(stages, "State Manager", "AI/ProviderRateLimitScheduler", false, function()
		ProviderRateLimitScheduler.setEnabled(
			SettingsManager.getValue("smartRetry") ~= nil
				and SettingsManager.get().smartRetry.rateLimitScheduler ~= false
		)
	end)

	-- 3. Dock widget ----------------------------------------------------------
	local builtOk = runStage(stages, "DockWidget Creation", "UI/DockWidget", true, function()
		gui = DockWidget.build(plugin)
	end)
	if not builtOk or not gui then
		return finish()
	end

	-- 4. Provider capabilities (optional; never blocks the window) -----------
	runStage(stages, "Context Manager", "AI/ModelCapabilityDetector", false, function()
		local profile = SettingsManager.getActiveProvider()
		if profile then
			ModelCapabilityDetector.buildReport(profile)
			ContextManager.configure(profile, ModelCapabilityDetector.getOrBuildReport(profile))
		end
	end)

	-- 5. Views ----------------------------------------------------------------
	runStage(stages, "UI Components", "UI/*", false, function()
		buildViews(DockWidget.content, stages)
	end)

	-- 6. Event binding --------------------------------------------------------
	runStage(stages, "Event Binding", "Core/EventBus", false, function()
		unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.Navigate, function(payload)
			local section = payload.section :: string
			if not table.find(DockWidget.SectionOrder, section) then return end
			Components.closeMenus()
			currentSection = section
			for name in pairs(views) do
				local view = views[name]
				if view then
					view.Visible = (name == section)
				end
			end
		end)

		unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ProvidersChanged, refreshHeader)
		unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ActiveProviderChanged, refreshHeader)
		local function syncContext()
			local profile = SettingsManager.getActiveProvider()
			ContextManager.configure(profile, if profile then ModelCapabilityDetector.getOrBuildReport(profile) else nil)
		end
		unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ActiveProviderChanged, syncContext)
		unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.ProvidersChanged, syncContext)
		unsubs[#unsubs + 1] = EventBus.on(EventBus.Events.CapabilitiesChanged, syncContext)
	end)

	-- 7. Initial render -------------------------------------------------------
	runStage(stages, "Initial UI Rendering", "UI/DockWidget", false, function()
		refreshHeader()
	end)

	Logger.info("System", "ForgePilot ready.", {
		detail = SettingsManager.getActiveProvider()
				and "A provider profile is selected. Enter an API key in Settings."
			or "No provider configured. ForgePilot is usable offline for editor tools.",
	})

	-- First-run naming prompt (optional, skippable, never blocks the UI).
	task.defer(function()
		local window = gui
		if not window then
			return
		end
		pcall(function()
			window.Enabled = true
		end)
		local ok, result = pcall(function()
			return WelcomeDialog.show(window)
		end)
		if ok and type(result) == "table" and result.named then
			refreshHeader()
		end
	end)

	ApplicationController.views = views
	ApplicationController.gui = gui
	return finish()
end

function ApplicationController.getViews()
	return views
end

function ApplicationController.getGui()
	return gui
end

function ApplicationController.getReport(): Report?
	return lastReport
end

function ApplicationController.destroy()
	for _, name in ipairs(DockWidget.SectionOrder) do
		local api = viewApis[name]
		if api and typeof(api.destroy) == "function" then
			local ok, err = pcall(api.destroy)
			if not ok then
				warn("[ForgePilot] View teardown failed (" .. name .. "): " .. tostring(err))
			end
		end
	end
	for _, unsubscribe in ipairs(unsubs) do
		local ok, err = pcall(unsubscribe)
		if not ok then
			warn("[ForgePilot] Unsubscribe failed during shutdown: " .. tostring(err))
		end
	end
	table.clear(unsubs)
	table.clear(views)
	table.clear(viewApis)
	if gui then gui:Destroy() end
	gui = nil
	pluginRef = nil
	HistoryManager.resetOrphan()
end

return ApplicationController
