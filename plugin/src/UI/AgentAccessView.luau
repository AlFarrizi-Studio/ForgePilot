--!strict
local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local SettingsManager = require(script.Parent.Parent.Core.SettingsManager)
local StateManager = require(script.Parent.Parent.Core.StateManager)
local Components = require(script.Parent.Components)
local Theme = require(script.Parent.Parent.Utilities.Theme)
local AgentAccessView = {}
function AgentAccessView.build(): (ScrollingFrame, any)
    local scroll = Theme.scrollingFrame({ automaticCanvasSize = Enum.AutomaticSize.Y })
    scroll.Name = "AgentAccess"; scroll.BackgroundTransparency = 1
    Theme.padding(6).Parent = scroll; Theme.listLayout(10).Parent = scroll
    local destroyed = false
    local busy = false
    local card, body = Components.section("Local agent access", { order = 1, subtitle = "Connect the companion terminal to use files, web research, downloads and real streaming." })
    card.Parent = scroll
    local enabled = Components.toggle("Enable local bridge", SettingsManager.getValue("bridgeEnabled") ~= false, function(value)
        if StateManager.isBusy() then return end
        SettingsManager.setValue("bridgeEnabled", value); BridgeClient.reset()
    end, { order = 0 })
    enabled.Parent = body
    local urlRow, urlHolder = Components.field("Bridge address", { order = 1 })
    urlRow.Parent = body
    local url = Theme.input("http://127.0.0.1:20129")
    url.Text = SettingsManager.getValue("bridgeUrl") or "http://127.0.0.1:20129"
    url.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight); url.Parent = urlHolder
    url.FocusLost:Connect(function()
        if StateManager.isBusy() then return end
        SettingsManager.setValue("bridgeUrl", url.Text); BridgeClient.reset()
    end)
    local tokenRow, tokenHolder = Components.field("Bridge token", { order = 2, hint = "Copy from the bridge terminal. Kept only for this Studio session." })
    tokenRow.Parent = body
    local key = Theme.input("Paste token from terminal")
    key.Name = "BridgeToken"; key.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight); key.TextTransparency = 1; key.Parent = tokenHolder
    local mask = Theme.label("Paste token from terminal", { size = 12, color = Theme.Extra.Muted })
    mask.Name = "Mask"; mask.Size = UDim2.fromScale(1, 1); mask.TextTruncate = Enum.TextTruncate.AtEnd; mask.Parent = key
    key:GetPropertyChangedSignal("Text"):Connect(function() mask.Text = if #key.Text > 0 then string.rep("•", math.min(48, #key.Text)) else "Paste token from terminal" end)
    key.FocusLost:Connect(function() if not StateManager.isBusy() then BridgeClient.setToken(key.Text) end end)
    local connect = Components.textButton("Connect bridge", { order = 3 })
    connect.Name = "ConnectBridge"; connect.Size = UDim2.new(1, 0, 0, 30); connect.Parent = body
    local status = Theme.autoText("Disconnected. Run Start-ForgePilot-Bridge for your OS, paste the token above, then connect. Setup: https://github.com/AlFarrizi-Studio/ForgePilot", { size = 12, color = Theme.Extra.Muted })
    status.Name = "BridgeStatus"; status.LayoutOrder = 4; status.Parent = body
    local function showHealth()
        local health = BridgeClient.getHealth()
        if health then
            status.TextColor3 = Theme.Colors.Success
            status.Text = "Connected · " .. (if health.fullAccess then "Full computer access" else "Workspace only") .. "\nWorkspace: " .. tostring(health.workspace) .. "\nWeb search, URLs, files, downloads, images and streaming are ready." .. (if health.fullAccess then " Terminal commands are available in Build mode." else "")
        end
    end
    connect.MouseButton1Click:Connect(function()
        if busy or StateManager.isBusy() then return end
        SettingsManager.setValue("bridgeUrl", url.Text)
        if #key.Text > 0 then BridgeClient.setToken(key.Text) end
        busy = true; connect.Text = "Connecting…"; connect.Interactable = false
        task.spawn(function()
            local health, err = BridgeClient.connect()
            if destroyed then return end
            busy = false; connect.Text = "Reconnect bridge"; connect.Interactable = true
            if health then showHealth() else status.TextColor3 = Theme.Colors.Error; status.Text = err or "Bridge connection failed." end
        end)
    end)
    local scopeCard, scopeBody = Components.section("What the agent can use", { order = 2 })
    scopeCard.Parent = scroll
    local capabilities = Theme.autoText("Plan: inspect Roblox, search/read websites, list/read/search local files, and pass images to a vision-capable model.\n\nBuild: edit Roblox and local files, download resources, and run terminal commands when full computer access is enabled. File changes keep backups in the workspace.\n\nThe launcher enables full computer access as requested. To restrict it to one folder, run npm run start:bridge -- --workspace-only. Individual tools and confirmations follow Settings > Agent.", { size = 12 })
    capabilities.Parent = scopeBody
    local routerCard, routerBody = Components.section("Provider login", { order = 3 })
    routerCard.Parent = scroll
    local routerInfo = Theme.autoText("Run Start-9Router and Start-ForgePilot-Bridge for OAuth, free-tier and API-key connections. In AI & Provider, choose a provider, then Sign in / Connect in 9Router. Complete login in the browser and refresh its status. Use Refresh models to select an account model.\n\nIf the router requires a client API key, copy it from its dashboard into the provider's 9Router API key field. ForgePilot does not store your OAuth tokens or passwords.", { size = 12 })
    routerInfo.LayoutOrder = 0
    routerInfo.Parent = routerBody
    local passwordRow, passwordHolder = Components.field("9Router dashboard password", { order = 1, hint = "Use when account status requires dashboard login. This is separate from a provider's OAuth login." })
    passwordRow.Parent = routerBody
    local password = Theme.input("Dashboard password")
    password.Name = "RouterPassword"; password.Size = UDim2.new(1, 0, 0, Theme.Metrics.InputHeight); password.TextTransparency = 1; password.Parent = passwordHolder
    local passwordMask = Theme.label("Dashboard password", { size = 12, color = Theme.Extra.Muted })
    passwordMask.Size = UDim2.fromScale(1, 1); passwordMask.TextTruncate = Enum.TextTruncate.AtEnd; passwordMask.Parent = password
    password:GetPropertyChangedSignal("Text"):Connect(function() passwordMask.Text = if #password.Text > 0 then string.rep("•", math.min(32, #password.Text)) else "Dashboard password" end)
    local dashboardLogin = Components.textButton("Connect 9Router dashboard", { order = 2 })
    dashboardLogin.Name = "ConnectRouter"; dashboardLogin.Size = UDim2.new(1, 0, 0, 30); dashboardLogin.Parent = routerBody
    local routerStatus = Theme.autoText("Password stays out of chat and is cleared after connection.", { size = 11, color = Theme.Extra.Muted })
    routerStatus.Name = "RouterSessionStatus"; routerStatus.LayoutOrder = 3; routerStatus.Parent = routerBody
    dashboardLogin.MouseButton1Click:Connect(function()
        if busy or StateManager.isBusy() or not BridgeClient.isConnected() then return end
        if #password.Text == 0 then routerStatus.Text = "Enter the local 9Router dashboard password first."; return end
        local value = password.Text; password.Text = ""
        busy = true; dashboardLogin.Interactable = false; dashboardLogin.Text = "Connecting…"
        task.spawn(function()
            local result, err = BridgeClient.signInRouter(value); value = ""
            if destroyed then return end
            busy = false; dashboardLogin.Interactable = true; dashboardLogin.Text = "Connect 9Router dashboard"
            routerStatus.Text = if result then result.message else err or "Dashboard connection failed."
            routerStatus.TextColor3 = if result then Theme.Colors.Success else Theme.Colors.Error
        end)
    end)
    showHealth()
    scroll.Destroying:Connect(function() destroyed = true end)
    return scroll, { destroy = function() destroyed = true end }
end
return AgentAccessView
