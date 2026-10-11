--!strict
--[[
	ForgePilot / Roblox / WorkspaceInspector
	Read-only inspection of the open place.

	Everything here is observation. Nothing in this module mutates the DataModel.
	Output is capped and summarised so a large place does not flood the model.
]]

local WorkspaceInspector = {}

local LIMITS = {
	MAX_CHILDREN = 200,
	MAX_DEPTH = 4,
	MAX_PROPERTIES = 40,
	MAX_SCRIPT_CHARS = 12000,
}

WorkspaceInspector.LIMITS = LIMITS

--=============================================================================
-- BASIC INFO
--=============================================================================

function WorkspaceInspector.getPlaceInfo(): { [string]: any }
	local game = game
	local info: { [string]: any } = {
		name = game.Name,
		placeId = game.PlaceId,
		gameId = game.GameId,
		creatorId = game.CreatorId,
		creatorType = if game.CreatorType == Enum.CreatorType.User then "User" else "Group",
		jobId = game.JobId,
		genre = nil,
	}

	-- Enum.InfoType has no `Game` member (Asset, Product, GamePass,
	-- Subscription, Bundle), so experience metadata is read from the place asset
	-- instead. Any failure just falls back to the place name below.
	local ok, placeInfo = pcall(function()
		return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId, Enum.InfoType.Asset)
	end)
	if ok and type(placeInfo) == "table" then
		info.description = placeInfo.Description
		info.thumbnailId = placeInfo.Thumbnail
	end

	return info
end

--=============================================================================
-- TREE WALK
--=============================================================================

local function describeInstance(instance: Instance, depth: number, budget: { used: number })
	if budget.used > 12000 then
		return { name = instance.Name, className = instance.ClassName, truncated = true }
	end

	local node: { [string]: any } = {
		name = instance.Name,
		className = instance.ClassName,
	}

	if instance:IsA("BasePart") then
		node.size = instance.Size
		node.position = instance.Position
		node.material = instance.Material.Name
		node.color = instance.Color
		local transparency = instance.Transparency
		node.transparent = transparency > 0.05
	end

	if instance:IsA("Model") or instance:IsA("Folder") or instance:IsA("Configuration") then
		node.childCount = #instance:GetChildren()
	end

	local children = instance:GetChildren()
	if depth < LIMITS.MAX_DEPTH and #children > 0 then
		local list = {}
		local limit = math.min(#children, LIMITS.MAX_CHILDREN)
		for index = 1, limit do
			budget.used += 120
			list[index] = describeInstance(children[index], depth + 1, budget)
		end
		if #children > limit then
			list[limit + 1] = { name = string.format("… %d more children", #children - limit), className = "…" }
		end
		node.children = list
	end

	return node
end

function WorkspaceInspector.describeTree(root: Instance?, maxDepth: number?): { [string]: any }
	local target = root or workspace
	local budget = { used = 0 }
	return describeInstance(target, 0, budget)
end

function WorkspaceInspector.summariseTree(root: Instance?): string
	local lines: { string } = {}
	local total = 0

	local function count(instance: Instance)
		total += 1
		local indent = string.rep("  ", math.min(4, math.floor(#lines / 8)))
		lines[#lines + 1] = string.format("%s%s (%s)", indent, instance.Name, instance.ClassName)
		if #lines > LIMITS.MAX_CHILDREN then
			return
		end
		for _, child in instance:GetChildren() do
			count(child)
		end
	end

	count(root or workspace)
	return table.concat(lines, "\n")
end

--=============================================================================
-- PROPERTY READING
--=============================================================================

local SAFE_PROPERTIES: { [string]: { [string]: any } } = {
	BasePart = {
		Anchored = true,
		CanCollide = true,
		Material = true,
		Reflectance = true,
		Transparency = true,
		TopSurface = true,
		BottomSurface = true,
	},
	Part = { Shape = true, Size = true },
	Model = { PrimaryPart = "InstanceRef" },
	Sky = {
		SkyboxBk = true, SkyboxDn = true, SkyboxFt = true,
		SkyboxLf = true, SkyboxRt = true, SkyboxUp = true,
		SkyboxOrientation = true, CelestialBodiesShown = true,
		StarCount = true, SunAngularSize = true, MoonAngularSize = true,
		SunTextureId = true, MoonTextureId = true,
	},
	Lighting = {
		Ambient = true,
		OutdoorAmbient = true,
		Brightness = true,
		ClockTime = true,
		EnvironmentDiffuseScale = true,
		EnvironmentSpecularScale = true,
		ExposureCompensation = true,
		GlobalShadows = true,
		ShadowSoftness = true,
		Technology = true,
	},
	SoundService = { RespectFilteringEnabled = true },
}

local function tryRead(instance: Instance, property: string): (any?, string?)
	local ok, value = pcall(function()
		return (instance :: any)[property]
	end)
	if ok then
		return value, nil
	end
	return nil, tostring(value)
end

local function serialiseValue(value: any): string
	local valueType = typeof(value)
	if valueType == "EnumItem" then
		return value.Name
	elseif valueType == "Instance" then
		return string.format("%s (%s)", value:GetFullName(), value.ClassName)
	elseif valueType == "Color3" then
		return string.format("#%02X%02X%02X", math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255))
	elseif valueType == "UDim2" or valueType == "UDim" or valueType == "Vector3" or valueType == "Vector2" then
		return tostring(value)
	elseif valueType == "number" then
		return string.format("%.4g", value)
	elseif valueType == "string" then
		return string.len(value) > 120 and (string.sub(value, 1, 120) .. "…") or value
	end
	return tostring(value)
end

WorkspaceInspector.serialiseValue = serialiseValue

--- Reads a safe allowlist of properties from any instance.
function WorkspaceInspector.readProperties(instance: Instance): { [string]: string }
	local out: { [string]: string } = {}
	if not instance then
		return out
	end

	-- Universal, always-safe attributes.
	for _, key in { "Name", "ClassName", "Archivable" } do
		local value, readError = tryRead(instance, key)
		if readError == nil then
			out[key] = serialiseValue(value)
		end
	end
	local tagsOk, tags = pcall(instance.GetTags, instance)
	if tagsOk then
		table.sort(tags)
		out.Tags = table.concat(tags, ", ")
	end

	-- IsA follows class inheritance. An object's Parent is unrelated to the
	-- properties it supports (a Sky under Lighting is still a Sky).
	local classRules: { [string]: boolean } = {}
	for className, properties in SAFE_PROPERTIES do
		if instance:IsA(className) then
			for property in properties do classRules[property] = true end
		end
	end
	local names = {}
	for property in classRules do names[#names + 1] = property end
	table.sort(names)
	for index, property in names do
		if index > LIMITS.MAX_PROPERTIES then break end
		local value, readError = tryRead(instance, property)
		if readError == nil then
			out[property] = serialiseValue(value)
		end
	end

	return out
end

--=============================================================================
-- CHILDREN OF A NODE
--=============================================================================

function WorkspaceInspector.listChildren(path: string): { { name: string, className: string, path: string } }
	local ok, instance = pcall(function()
		return WorkspaceInspector.resolve(path)
	end)
	if not ok or not instance then
		return {}
	end
	local list = {}
	for index, child in instance:GetChildren() do
		if index > LIMITS.MAX_CHILDREN then
			break
		end
		list[#list + 1] = { name = child.Name, className = child.ClassName, path = child:GetFullName() }
	end
	return list
end

function WorkspaceInspector.resolve(path: string): (Instance?, string?)
	if type(path) ~= "string" then return nil, "Path is empty." end
	local text = path:match("^%s*(.-)%s*$") or ""
	if text == "" then return nil, "Path is empty." end
	if text == "game" or text == game.Name then return game, nil end
	for _, prefix in { "game.", "game/", game.Name .. ".", game.Name .. "/" } do
		if text:sub(1, #prefix) == prefix then text = text:sub(#prefix + 1); break end
	end
	-- Slash paths preserve dots inside object names. Dotted paths match the
	-- names returned by Roblox and the paths advertised in the tool schema.
	local separator = if text:find("/", 1, true) then "[^/]+" else "[^%.]+"
	local current: Instance = game
	for segment in text:gmatch(separator) do
		local child: Instance? = nil
		if current == game and (segment == "Workspace" or segment == "workspace") then child = workspace
		else
			child = current:FindFirstChild(segment)
			if not child and current == game then
				local ok, service = pcall(game.GetService, game, segment)
				if ok then child = service end
			end
		end
		if not child then return nil, string.format("No child named '%s' under %s.", segment, current:GetFullName()) end
		current = child
	end
	return current, nil
end

--=============================================================================
-- LIGHTING
--=============================================================================

function WorkspaceInspector.describeLighting(): { [string]: string }
	local out: { [string]: string } = {}
	local lighting = game:GetService("Lighting")
	local properties = SAFE_PROPERTIES.Lighting
	for property in pairs(properties) do
		local value, readError = tryRead(lighting, property)
		if readError == nil then
			out[property] = serialiseValue(value)
		end
	end

	local effects = {}
	for _, child in lighting:GetChildren() do
		if child:IsA("PostEffect") or child:IsA("Atmosphere") or child:IsA("BloomEffect") or child:IsA("Sky") then
			effects[#effects + 1] = child.ClassName .. " (" .. child.Name .. ")"
		end
	end
	if #effects > 0 then
		out.Effects = table.concat(effects, ", ")
	end
	return out
end

--=============================================================================
-- GAME UI
--=============================================================================

function WorkspaceInspector.describeUI(): { [string]: any }
	local playerGuiService = game:GetService("PlayerGui")
	local list = {}
	for _, playerGui in playerGuiService:GetChildren() do
		local entry: { [string]: any } = { name = playerGui.Name, screens = {} }
		local count = 0
		for _, child in playerGui:GetDescendants() do
			if child:IsA("GuiObject") or child:IsA("LayerCollector") then
				count += 1
				if count <= 40 then
					entry.screens[#entry.screens + 1] = string.format("%s (%s)", child.Name, child.ClassName)
				end
			end
		end
		entry.total = count
		table.insert(list, entry)
		if #list >= 10 then
			break
		end
	end
	return { playerGuis = list, note = "PlayerGui contents only exist at runtime unless ScreenGui.Enabled and ResetOnSpawn settings are inspected in the editor." }
end

--=============================================================================
-- GAME PLAY SETTINGS
--=============================================================================

function WorkspaceInspector.describeGameSettings(): { [string]: any }
	local settings = {
		maxPlayers = nil,
		joinRequiresPassword = nil,
		allowThirdPartySales = nil,
		loaded = false,
	}

	local ok = pcall(function()
		local service = game:GetService("GameSettings")
		-- Published settings are not readable from an unpublished place.
		settings.loaded = false
	end)

	if not settings.loaded then
		settings.note = "GameSettings publishing options are only readable from a published place, so ForgePilot cannot read them here."
	end
	return settings
end

--=============================================================================
-- COUNTING HELPERS
--=============================================================================

function WorkspaceInspector.countByClass(root: Instance?): { [string]: number }
	local counts: { [string]: number } = {}
	local target = root or workspace
	local budget = 0
	for _, descendant in target:GetDescendants() do
		budget += 1
		if budget > 20000 then
			break
		end
		counts[descendant.ClassName] = (counts[descendant.ClassName] or 0) + 1
	end
	return counts
end

function WorkspaceInspector.getStats(): { [string]: any }
	local totalDescendants = 0
	for _ in workspace:GetDescendants() do
		totalDescendants += 1
		if totalDescendants > 50000 then
			break
		end
	end
	return {
		workspaceChildren = #workspace:GetChildren(),
		workspaceDescendants = totalDescendants,
		counted = totalDescendants <= 50000,
	}
end

return WorkspaceInspector
