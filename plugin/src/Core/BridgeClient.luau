--!strict
-- Local companion transport. The pairing token is session-only and is never
-- sent in prompts, saved with plugin preferences, or forwarded to providers.
local HttpService = game:GetService("HttpService")
local SettingsManager = require(script.Parent.SettingsManager)
local EventBus = require(script.Parent.EventBus)
local BridgeClient = {}
local token = ""
local health: any = nil
local endpointGeneration = 0
local modelMetadata: { [string]: any } = {}

local function endpoint(): string?
    if SettingsManager.getValue("bridgeEnabled") == false then return nil end
    local url = SettingsManager.getValue("bridgeUrl") or "http://127.0.0.1:20129"
    if not string.match(url, "^http://127%.0%.0%.1:%d+/?$") and not string.match(url, "^http://localhost:%d+/?$") then return nil end
    return string.gsub(url, "/$", "")
end
function BridgeClient.setToken(value: string)
    token = string.gsub(value or "", "^%s*(.-)%s*$", "%1")
    health = nil
    endpointGeneration += 1
end
function BridgeClient.reset()
    health = nil
    endpointGeneration += 1
end
function BridgeClient.isConnected(): boolean
    return health ~= nil and endpoint() ~= nil and #token >= 24
end
function BridgeClient.getHealth(): any return health end
function BridgeClient.canTool(name: string): boolean
    return BridgeClient.isConnected() and (name ~= "run_command" or health.fullAccess == true)
end
function BridgeClient.request(route: string, body: any?, method: string?, timeout: number?, shouldCancel: (() -> boolean)?): (any?, string?)
    local base = endpoint()
    if not base or #token < 24 then return nil, "Start-ForgePilot-Bridge and connect it in Settings > Agent Access. Setup: https://github.com/AlFarrizi-Studio/ForgePilot" end
    local current = endpointGeneration
    local done = false
    local response: any = nil
    local failure: string? = nil
    local worker = task.spawn(function()
        local ok, value = pcall(function()
            local request: any = { Url = base .. route, Method = method or (if body then "POST" else "GET"), Headers = { Authorization = "Bearer " .. token } }
            if body then request.Headers["Content-Type"] = "application/json"; request.Body = HttpService:JSONEncode(body) end
            return HttpService:RequestAsync(request)
        end)
        if done or current ~= endpointGeneration then return end
        if ok then response = value else failure = "Local bridge request failed. Check that its terminal is still open and HTTP access is allowed." end
        done = true
    end)
    local started = os.clock()
    while not done do
        if current ~= endpointGeneration or (shouldCancel and shouldCancel()) then done = true; pcall(task.cancel, worker); return nil, "Cancelled." end
        if os.clock() - started > (timeout or 15) then done = true; pcall(task.cancel, worker); return nil, "Local bridge request timed out." end
        task.wait()
    end
    if failure then health = nil; return nil, failure end
    if type(response) ~= "table" or type(response.Body) ~= "string" or type(response.StatusCode) ~= "number" then return nil, "Bridge returned an invalid HTTP response." end
    local ok, value = pcall(HttpService.JSONDecode, HttpService, response.Body)
    if not ok or type(value) ~= "table" then return nil, "Bridge returned an invalid response." end
    if response.StatusCode < 200 or response.StatusCode >= 300 then return nil, tostring(value.message or "Bridge rejected the request.") end
    return value, nil
end
function BridgeClient.connect(): (any?, string?)
    local current = endpointGeneration
    local value, err = BridgeClient.request("/health")
    if value and value.ok and type(value.capabilities) == "table" and (value.capabilities.toolJobs ~= true or value.capabilities.streamIdleTimeout ~= true) then
        value = nil
        err = "The bridge is from an older package. Stop its terminal and run the new Start-ForgePilot-Bridge before reconnecting."
    end
    if current == endpointGeneration then
        health = if value and value.ok and type(value.capabilities) == "table" then value else nil
        EventBus.emit("BridgeChanged", { connected = health ~= nil })
    end
    return health, err
end
function BridgeClient.capabilityText(): string
    if not BridgeClient.isConnected() then return "Local bridge is disconnected. Web search, URL fetching, local files, downloads, terminal commands and file-based image tools are unavailable. Tell the user plainly when their request needs one of these features and show https://github.com/AlFarrizi-Studio/ForgePilot for setup, then Settings > Agent Access. Roblox inspection/build tools are still available. User-selected image/document attachments depend separately on the selected model and adapter; do not promise vision until supported input was supplied." end
    return string.format("Local bridge connected. Workspace: %s. File scope: %s. Web search, fetching URLs, reading/searching files and viewing supported images are available. Build also permits file editing and downloads%s. The operating system's permissions still apply. Image interpretation depends on the selected model's vision capability.", tostring(health.workspace), if health.fullAccess then "full computer access" else "workspace only", if health.fullAccess then " and terminal commands" else "")
end
function BridgeClient.execute(name: string, args: any, mode: string, shouldCancel: (() -> boolean)?): (any?, string?)
    local id = HttpService:GenerateGUID(false)
    local function cancelJob()
        task.spawn(function() BridgeClient.request("/cancel", { operationId = id }, "POST", 5) end)
    end
    local job, err = BridgeClient.request("/tools/start", { name = name, arguments = args, mode = mode, operationId = id }, "POST", 15, shouldCancel)
    if not job then cancelJob(); return nil, err end
    local deadline = os.clock() + 320
    while true do
        if (shouldCancel and shouldCancel()) or os.clock() >= deadline then
            cancelJob()
            return nil, if os.clock() >= deadline then "Local tool timed out." else "Cancelled."
        end
        local value, problem = BridgeClient.request("/tools/" .. id, nil, "GET", 15, shouldCancel)
        if not value then cancelJob(); return nil, problem end
        if value.done then return value.result, value.error end
        -- Yield even if an immediate localhost response contains no result.
        task.wait()
    end
end
function BridgeClient.stream(request: any, callbacks: any): (any?, string?)
    local current = endpointGeneration
    local job, err = BridgeClient.request("/stream", request, "POST", 15)
    if not job then return nil, err end
    if type(job.id) ~= "string" then return nil, "Bridge returned an invalid stream id." end
    local cancelled = false
    local done = false
    local released = false
    local cursor = 0
    local started = os.clock()
    local idleSeconds = math.clamp((request.timeoutMs or 120000) / 1000, 1, 600)
    local lastActivity = started
    local activitySequence: number? = nil
    local collected = {}
    local function release()
        if released then return end
        released = true
        task.spawn(function() BridgeClient.request("/stream/" .. job.id, nil, "DELETE", 5) end)
    end
    local function reportError(message: string)
        done = true
        release()
        if callbacks.onError then pcall(callbacks.onError, message) end
    end
    local function cancel()
        if done then return end
        cancelled = true; done = true; release()
    end
    task.spawn(function()
        -- A parser/UI callback exception must still settle the transport handle.
        local ok = pcall(function()
            while not done do
                if current ~= endpointGeneration then cancel(); break end
                if os.clock() - lastActivity >= idleSeconds then reportError("Provider stream timed out: no upstream data within the configured idle timeout."); break end
                local value, problem = BridgeClient.request("/stream/" .. job.id .. "?cursor=" .. tostring(cursor), nil, "GET", math.min(15, math.max(1, idleSeconds - (os.clock() - lastActivity))), function() return cancelled end)
                if cancelled or done then break end
                if not value then reportError(problem or "Bridge stream failed."); break end
                if type(value.activitySequence) == "number" and value.activitySequence ~= activitySequence then
                    activitySequence = value.activitySequence
                    lastActivity = os.clock()
                    if callbacks.onActivity then callbacks.onActivity() end
                end
                for _, event in (value.events or {}) do
                    if type(event.cursor) ~= "number" or type(event.chunk) ~= "string" then error("Invalid bridge stream event.") end
                    if event.cursor > cursor then
                        lastActivity = os.clock()
                        if callbacks.onActivity then callbacks.onActivity() end
                        collected[#collected + 1] = event.chunk
                        cursor = event.cursor
                        if callbacks.onChunk then callbacks.onChunk(event.chunk) end
                    end
                end
                if value.done then
                    done = true
                    release()
                    if value.error then
                        if callbacks.onError then pcall(callbacks.onError, value.error) end
                    elseif callbacks.onComplete then
                        callbacks.onComplete(table.concat(collected), (os.clock() - started) * 1000, value.statusCode)
                    end
                else
                    task.wait()
                end
            end
        end)
        if not ok then reportError("Stream processing failed. Check Logs, then retry the request.") end
    end)
    return { cancel = cancel, isCancelled = function() return cancelled end, isDone = function() return done end, frames = collected }, nil
end
function BridgeClient.openProvider(providerId: string): (any?, string?)
    return BridgeClient.request("/providers/open", { providerId = providerId })
end
function BridgeClient.providerStatus(providerId: string): (any?, string?)
    return BridgeClient.request("/providers/status", { providerId = providerId })
end
function BridgeClient.signInRouter(password: string): (any?, string?)
    return BridgeClient.request("/router/login", { password = password })
end
function BridgeClient.listModels(profile: any, apiKey: string?, shouldCancel: (() -> boolean)?): ({ string }?, string?)
    local value, err = BridgeClient.request("/router/models", { providerId = profile.routerProviderId, apiKey = apiKey }, "POST", 15, shouldCancel)
    if not value then return nil, err end
    local metadata = if type(value.metadata) == "table" then value.metadata else {}
    modelMetadata[profile.routerProviderId] = metadata
    EventBus.emit("RouterModelsChanged", { providerId = profile.routerProviderId })
    return value.models or {}, nil
end
function BridgeClient.getModelMetadata(profile: any): any
    local bucket = modelMetadata[profile.routerProviderId]
    if not bucket then return nil end
    local model = profile.modelId or ""
    return bucket[model] or bucket[(profile.routerAlias or "") .. "/" .. model]
end
return BridgeClient
