--!plugin
--!strict
--[[
	ForgePilot — AI-Powered Roblox Studio Assistant
	Plugin entry point.

	Contract enforced here:
	  * The toolbar and its button exist before anything else can fail.
	  * Loading ApplicationController is never fatal to the toolbar.
	  * Module paths are resolved by walking real child Instances with '/'
	    separators — never by splitting on '.'.
	  * A failure is reported with the stage, the module, the real Roblox error
	    and a sanitised traceback. Messages are REPLACED, never appended, so the
	    diagnostic window cannot accumulate duplicates or recurse.
	  * Initialisation runs at most once, and a Retry is an explicit user action.
]]

print("[ForgePilot] Bootstrap started")

local STARTUP_STAGES = {
	"Plugin Bootstrap",
	"Module Resolution",
	"Module Initialization",
	"Application Controller",
}

local startup = {
	stage = STARTUP_STAGES[1] :: string,
	modulePath = "" :: string,
	cause = "" :: string,
	trace = "" :: string,
	ok = false,
	attempt = 0,
}

local lastReportedSignature = ""

--=============================================================================
-- TOOLBAR
--=============================================================================

-- A local plugin is already running inside a Plugin instance: never assign
-- `plugin.Enabled`. PluginToolbarButton exposes Click (not MouseButton1Click).
local toolbar = plugin:CreateToolbar("ForgePilot")
local button = toolbar:CreateButton(
	"ForgePilot",
	"Open the ForgePilot AI assistant",
	"rbxthumb://type=Asset&id=82058489576798&w=150&h=150"
)
button.ClickableWhenViewportHidden = true
print("[ForgePilot] Toolbar button created")

--=============================================================================
-- MODULE PATH RESOLUTION
--=============================================================================

--- Resolves a slash-separated path such as "AI/APIEndpointRouter" against the
--- packaged Instance tree. Each segment must exist as a Folder or ModuleScript.
--- Dot-splitting is never used: a module name may legally contain a '.' and the
--- tree is the only authority on what exists.
local function resolveModulePath(relativePath: string): (ModuleScript?, string?)
	local node: Instance? = script
	local walked = 0
	local total = 0
	for _ in string.gmatch(relativePath, "[^/]+") do
		total += 1
	end

	for segment in string.gmatch(relativePath, "([^/]+)") do
		if node == nil then
			break
		end
		if segment == "" or segment == ".." or segment == "." then
			return nil, string.format("Invalid path segment %q in %q.", segment, relativePath)
		end
		local child = node:FindFirstChild(segment)
		if child == nil then
			return nil,
				string.format(
					"%q does not exist. Resolved %d of %d segments under %s.",
					relativePath,
					walked,
					total,
					(node and node:GetFullName()) or "<none>"
				)
		end
		if not (child:IsA("Folder") or child:IsA("ModuleScript")) then
			return nil,
				string.format(
					"%q is a %s, not a Folder or ModuleScript.",
					child:GetFullName(),
					child.ClassName
				)
		end
		walked += 1
		node = child
	end

	if node == nil or not node:IsA("ModuleScript") then
		return nil, string.format("%q does not name a ModuleScript.", relativePath)
	end
	return node :: ModuleScript, nil
end

--- Loads a module, recording the stage/module/cause on failure.
local function requireModule(relativePath: string): any?
	startup.stage = "Module Resolution"
	startup.modulePath = relativePath
	local moduleScript, resolveError = resolveModulePath(relativePath)
	if not moduleScript then
		startup.cause = resolveError or ("Could not resolve " .. relativePath)
		startup.trace = ""
		warn("[ForgePilot] " .. startup.cause)
		return nil
	end

	startup.stage = "Module Initialization"
	local ok, result = xpcall(function()
		return require(moduleScript)
	end, function(message)
		return debug.traceback(tostring(message), 2)
	end)
	if not ok then
		startup.cause = tostring(result)
		startup.trace = tostring(result)
		warn("[ForgePilot][MODULE ERROR] " .. relativePath .. ": " .. startup.cause)
		return nil
	end
	startup.modulePath = relativePath
	startup.cause = ""
	startup.trace = ""
	return result
end

--=============================================================================
-- FAILING-MODULE ISOLATION
--=============================================================================

--- Roblox reports a nested ModuleScript load failure as the generic
--- "Requested module experienced an error while loading." This rebuilds the real
--- dependency graph from the packaged sources and loads it depth-first with
--- dependencies before dependants, so the FIRST module that throws is the real
--- culprit. Only modules the failing closure needs are touched, and Roblox caches
--- require() results, so a module that already loaded is never run twice.
local function isolateFailingModule(rootPath: string): (string?, string?, string?)
	local seen: { [string]: boolean } = {}
	local culprit: string? = nil
	local culpritMessage: string? = nil
	local culpritTrace: string? = nil

	--- Converts `script.Parent.Parent.Core.EventBus` seen inside `fromPath` into
	--- an absolute module path such as "Core/EventBus".
	local function absoluteTarget(fromPath: string, chain: string): string?
		local segments = {}
		for segment in string.gmatch(chain, "[^%.]+") do
			table.insert(segments, segment)
		end
		if segments[1] ~= "script" then
			return nil
		end

		local folder: { string } = {}
		for segment in string.gmatch(fromPath, "[^/]+") do
			table.insert(folder, segment)
		end
		table.remove(folder) -- drop the module's own name

		local cursor = 2
		local parents = 0
		while segments[cursor] == "Parent" do
			parents += 1
			cursor += 1
		end
		-- `script.Parent` is the module's own folder, so only the second and later
		-- `.Parent` hops leave the module's folder.
		for _ = 2, parents do
			if #folder == 0 then
				return nil
			end
			table.remove(folder)
		end
		for index = cursor, #segments do
			table.insert(folder, segments[index])
		end
		return table.concat(folder, "/")
	end

	local function load(path: string, depth: number): boolean
		if seen[path] then
			return culprit == nil
		end
		seen[path] = true
		if depth > 8 then
			return true
		end

		local node = resolveModulePath(path)
		if not node then
			return true
		end

		local sourceOk, source = pcall(function()
			return node.Source
		end)
		if sourceOk and type(source) == "string" then
			-- The capture is the argument itself, e.g. "script.Parent.Parent.UI.SettingsView".
			for chain in string.gmatch(source, "require%(%s*(script[^%)]+)%)") do
				local target = absoluteTarget(path, chain)
				if target and not seen[target] then
					load(target, depth + 1)
				end
			end
		end

		local ok, message = xpcall(function()
			return require(node)
		end, function(err)
			return debug.traceback(tostring(err), 2)
		end)
		if not ok and culprit == nil then
			culprit = path
			culpritMessage = tostring(message)
			culpritTrace = tostring(message)
			warn("[ForgePilot][FIRST FAILING MODULE] " .. path .. ": " .. culpritMessage)
		end
		return ok
	end

	if not resolveModulePath(rootPath) then
		return nil, nil, nil
	end
	load(rootPath, 0)
	return culprit, culpritMessage, culpritTrace
end

--=============================================================================
-- DIAGNOSTICS
--=============================================================================

local diagnostics: DockWidgetPluginGui? = nil
local diagnosticsBody: TextLabel? = nil
local diagnosticsRetry: TextButton? = nil

local function reportFailure()
	local stage = startup.stage
	local modulePath = startup.modulePath
	local cause = startup.cause
	if cause == "" then
		cause = "Initialization failed without a reported cause."
	end

	local signature = table.concat({ stage, modulePath, cause, tostring(startup.attempt) }, "\0")
	if signature == lastReportedSignature then
		return
	end
	lastReportedSignature = signature

	local text = table.concat({
		"ForgePilot \2014 Diagnostics",
		"",
		"Initialization failed.",
		"",
		"Stage:",
		stage,
		"",
		"Module:",
		if modulePath ~= "" then modulePath else "(not yet resolved)",
		"",
		"Cause:",
		cause,
		"",
		"Source:",
		if startup.trace ~= "" then startup.trace else cause,
		"",
		"Details:",
		if startup.trace ~= "" then startup.trace else "No further traceback was available.",
		"",
		"Attempt: " .. tostring(startup.attempt),
		"",
		"See Roblox Studio Output [ForgePilot] for the full log.",
	}, "\n")

	print("[ForgePilot] Diagnostics\n" .. text)

	local ok, err = pcall(function()
		if not diagnostics then
			local info = DockWidgetPluginGuiInfo.new(
				Enum.InitialDockState.Float,
				true,
				false,
				520,
				420,
				320,
				220
			)
			diagnostics = plugin:CreateDockWidgetPluginGuiAsync("ForgePilotDiagnostics", info)
			diagnostics.Title = "ForgePilot - Diagnostics"
			diagnostics.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

			local body = Instance.new("TextLabel")
			body.Name = "DiagnosticMessage"
			body.Size = UDim2.new(1, -24, 1, -56)
			body.Position = UDim2.fromOffset(12, 12)
			body.BackgroundTransparency = 1
			body.TextColor3 = Color3.fromRGB(232, 224, 240)
			body.Font = Enum.Font.Code
			body.TextSize = 13
			body.TextWrapped = true
			body.TextXAlignment = Enum.TextXAlignment.Left
			body.TextYAlignment = Enum.TextYAlignment.Top
			body.Text = ""
			body.Parent = diagnostics
			diagnosticsBody = body

			local retry = Instance.new("TextButton")
			retry.Name = "Retry"
			retry.AnchorPoint = Vector2.new(1, 0)
			retry.Position = UDim2.new(1, -12, 1, -44)
			retry.Size = UDim2.fromOffset(140, 32)
			retry.BackgroundColor3 = Color3.fromRGB(152, 121, 232)
			retry.BorderSizePixel = 0
			retry.Text = "Retry Initialization"
			retry.TextColor3 = Color3.fromRGB(23, 21, 28)
			retry.TextSize = 14
			retry.Font = Enum.Font.GothamMedium
			retry.AutoButtonColor = true
			retry.Parent = diagnostics
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 8)
			corner.Parent = retry
			diagnosticsRetry = retry
		end

		if diagnosticsBody then
			-- REPLACE, never append: a Retry must not accumulate messages.
			diagnosticsBody.Text = text
		end
		if diagnostics then
			diagnostics.Enabled = true
		end
	end)
	if not ok then
		warn("[ForgePilot] Diagnostics window failed: " .. tostring(err))
	end
end

--=============================================================================
-- STARTUP
--=============================================================================

local ApplicationController: any = nil
local starting = false

local function startApplication()
	if starting or startup.ok then
		return
	end
	starting = true
	startup.attempt += 1
	lastReportedSignature = ""

	-- Stage 1 - module resolution / load.
	startup.stage = "Module Resolution"
	local controller = requireModule("Core/ApplicationController")
	if not controller then
		local modulePath, cause, trace = isolateFailingModule("Core/ApplicationController")
		startup.modulePath = modulePath or "Core/ApplicationController"
		startup.cause = cause or startup.cause
		startup.trace = trace or startup.trace
		starting = false
		reportFailure()
		return
	end

	-- Stage 2 - Application Controller init (staged internally).
	startup.stage = "Application Controller"
	startup.modulePath = "Core/ApplicationController"
	local ok, result = xpcall(function()
		return controller.init(plugin)
	end, function(message)
		return debug.traceback(tostring(message), 2)
	end)
	starting = false

	if not ok then
		startup.cause = tostring(result)
		startup.trace = tostring(result)
		reportFailure()
		return
	end

	-- A stage report tells us which optional subsystem, if any, was skipped.
	local report = if type(result) == "table" then result else {}
	if report.ok == false then
		startup.cause = tostring(report.cause or "A required startup stage failed.")
		startup.trace = tostring(report.trace or startup.cause)
		pcall(function() controller.destroy() end)
		reportFailure()
		return
	end
	if report.cause and report.cause ~= "" then
		warn("[ForgePilot] Startup completed with a degraded stage: " .. tostring(report.cause))
	end

	ApplicationController = controller
	startup.ok = true
	startup.stage = "Plugin Bootstrap"
	startup.modulePath = ""
	startup.cause = ""
	startup.trace = ""
	print("[ForgePilot] Initialized successfully")

	if diagnostics then
		pcall(function()
			diagnostics.Enabled = false
		end)
	end
end

startApplication()

--=============================================================================
-- BUTTON
--=============================================================================

local clickConnection
local enabledConnection
if startup.ok and ApplicationController then
	local gui = ApplicationController.getGui()
	if gui then
		button:SetActive(gui.Enabled)
		enabledConnection = gui:GetPropertyChangedSignal("Enabled"):Connect(function() button:SetActive(gui.Enabled) end)
	end
end
clickConnection = button.Click:Connect(function()
	if not startup.ok or not ApplicationController then
		-- Rebuild the report from current state; never append to an old message.
		reportFailure()
		return
	end
	local ok, err = pcall(function()
		local gui = ApplicationController.getGui()
		if not gui then
			error("ApplicationController.getGui() returned nil")
		end
		gui.Enabled = not gui.Enabled
		print("[ForgePilot] Window " .. (if gui.Enabled then "opened" else "closed"))
	end)
	if not ok then
		startup.stage = "Application Controller"
		startup.modulePath = "Core/ApplicationController"
		startup.cause = "Toolbar click failed: " .. tostring(err)
		startup.trace = debug.traceback(tostring(err), 2)
		lastReportedSignature = ""
		reportFailure()
	end
end)

if diagnosticsRetry then
	diagnosticsRetry.MouseButton1Click:Connect(function()
		startApplication()
	end)
end

--=============================================================================
-- UNLOAD
--=============================================================================

plugin.Unloading:Connect(function()
	-- Best effort only: cleanup must never block Studio from closing.
	pcall(function()
		if enabledConnection then enabledConnection:Disconnect() end
		if clickConnection then
			clickConnection:Disconnect()
			clickConnection = nil
		end
		local okStream, StreamingManager = pcall(require, script.AI.StreamingManager)
		if okStream and StreamingManager.cancelAll then
			StreamingManager.cancelAll()
		end
		local okState, StateManager = pcall(require, script.Core.StateManager)
		if okState and StateManager.cancel then
			StateManager.cancel()
		end
		local okHistory, HistoryManager = pcall(require, script.Roblox.HistoryManager)
		if okHistory and HistoryManager.resetOrphan then
			HistoryManager.resetOrphan()
		end
		if ApplicationController and ApplicationController.destroy then
			ApplicationController.destroy()
		end
		if diagnostics then
			diagnostics:Destroy()
			diagnostics = nil
		end
	end)
	print("[ForgePilot] Unloaded")
end)
