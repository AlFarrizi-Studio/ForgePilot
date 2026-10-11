--!strict
--[[
	ForgePilot / Roblox / ModelBuilder
	Higher-level construction helpers used by the write tools.

	Everything here creates real Instances with real geometry. Nothing is a
	placeholder: a "building" is an actual walled Model with Parts inside it.
]]

local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

-- Self-contained pure conversion helpers. Do not import ActionExecutor here.
local function toVector3(value: any, fallback: Vector3): Vector3
	if type(value) == "table" then
		local x = value.x or value.X or value[1]
		local y = value.y or value.Y or value[2]
		local z = value.z or value.Z or value[3]
		if x and y and z then
			return Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
		end
	elseif type(value) == "string" then
		local x, y, z = string.match(value, "^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*$")
		if x then
			return Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
		end
	end
	return fallback
end

local function toColor3(value: any, fallback: Color3): Color3
	if type(value) == "string" then
		local hex = string.gsub(StringUtil.trim(value), "^#", "")
		if string.match(hex, "^%x%x%x%x%x%x$") then
			return Color3.fromHex(hex)
		end
		return fallback
	elseif type(value) == "table" then
		local r = value.r or value.R
		local g = value.g or value.G
		local b = value.b or value.B
		if r and g and b then
			return Color3.new(math.clamp(tonumber(r) or 0, 0, 1), math.clamp(tonumber(g) or 0, 0, 1), math.clamp(tonumber(b) or 0, 0, 1))
		end
	end
	return fallback
end

local ModelBuilder = {}

--=============================================================================
-- COLOUR HELPERS
--=============================================================================

local function resolveColor(value: any, fallback: Color3): Color3
	return toColor3(value, fallback)
end

local function resolveMaterial(name: any, fallback: Enum.Material): Enum.Material
	if type(name) == "string" then
		local ok, result = pcall(function()
			return Enum.Material[name]
		end)
		if ok and result then
			return result
		end
	end
	return fallback
end

--=============================================================================
-- BUILDINGS
--=============================================================================

local Buildings = {}

--- Builds a simple walled building: floor, four walls, optional ceiling.
function Buildings.create(args): (Instance?, string?)
	local size = toVector3(args.size, Vector3.new(20, 12, 20))
	local position = toVector3(args.position, Vector3.zero)
	local thickness = args.wallThickness or 1
	local wallColor = resolveColor(args.color, Color3.fromRGB(190, 185, 180))
	local material = resolveMaterial(args.material, Enum.Material.Concrete)

	local model = Instance.new("Model")
	model.Name = args.name
	model:SetAttribute("ForgePilotOrigin", "create_building")

	local baseY = position.Y
	local floorPart = nil

	if args.floor ~= false then
		floorPart = Instance.new("Part")
		floorPart.Name = "Floor"
		floorPart.Size = Vector3.new(size.X, thickness, size.Z)
		floorPart.CFrame = CFrame.new(position + Vector3.new(0, baseY + thickness / 2, 0))
		floorPart.Anchored = true
		floorPart.Material = material
		floorPart.Color = wallColor:Lerp(Color3.new(0, 0, 0), 0.15)
		floorPart.Parent = model
	end

	local wallHeight = size.Y
	local base = baseY + (if floorPart then thickness else 0)
	local wallY = base + wallHeight / 2

	local walls = {
		{ "WallNorth", Vector3.new(size.X, wallHeight, thickness), Vector3.new(0, 0, -size.Z / 2 + thickness / 2) },
		{ "WallSouth", Vector3.new(size.X, wallHeight, thickness), Vector3.new(0, 0, size.Z / 2 - thickness / 2) },
		{ "WallWest", Vector3.new(thickness, wallHeight, size.Z - thickness * 2), Vector3.new(-size.X / 2 + thickness / 2, 0, 0) },
		{ "WallEast", Vector3.new(thickness, wallHeight, size.Z - thickness * 2), Vector3.new(size.X / 2 - thickness / 2, 0, 0) },
	}

	for _, wall in walls do
		local part = Instance.new("Part")
		part.Name = wall[1]
		part.Size = wall[2]
		part.CFrame = CFrame.new(position + Vector3.new(wall[3].X, wallY, wall[3].Z))
		part.Anchored = true
		part.Material = material
		part.Color = wallColor
		part.Parent = model
	end

	if args.ceilings then
		local ceiling = Instance.new("Part")
		ceiling.Name = "Ceiling"
		ceiling.Size = Vector3.new(size.X, thickness, size.Z)
		ceiling.CFrame = CFrame.new(position + Vector3.new(0, base + wallHeight + thickness / 2, 0))
		ceiling.Anchored = true
		ceiling.Material = material
		ceiling.Color = wallColor:Lerp(Color3.new(0, 0, 0), 0.1)
		ceiling.Parent = model
	end

	local pivotPart = floorPart or model:GetChildren()[1] or nil
	if pivotPart and pivotPart:IsA("BasePart") then
		model.PrimaryPart = pivotPart
	end

	return model, string.format(
		"Building is %.0f x %.0f x %.0f studs with %d wall(s).",
		size.X,
		size.Y,
		size.Z,
		#walls
	)
end

--=============================================================================
-- ROADS
--=============================================================================

local Roads = {}

--- Builds a road between two points, with optional kerbs and centre line.
function Roads.create(args): (Instance?, string?)
	local start = toVector3(args.start, Vector3.zero)
	local finish = toVector3(args["end"], start + Vector3.new(0, 0, 60))
	local width = args.width or 12
	local roadColor = resolveColor(args.color, Color3.fromRGB(45, 45, 48))

	local delta = finish - start
	local length = delta.Magnitude
	if length < 1 then
		return nil, "The road start and end points are too close together."
	end

	local model = Instance.new("Model")
	model.Name = args.name
	model:SetAttribute("ForgePilotOrigin", "create_road")

	local midpoint = (start + finish) / 2
	local orientation = Vector3.new(delta.X, 0, delta.Z)
	if orientation.Magnitude < 0.001 then
		orientation = Vector3.new(0, 0, 1)
	end

	local surface = Instance.new("Part")
	surface.Name = "RoadSurface"
	surface.Size = Vector3.new(width, 0.5, length)
	surface.CFrame = CFrame.lookAt(midpoint - Vector3.new(0, 0.25, 0), midpoint + orientation) * CFrame.Angles(0, math.pi / 2, 0)
	surface.Anchored = true
	surface.Material = Enum.Material.Asphalt
	surface.Color = roadColor
	surface.TopSurface = Enum.SurfaceType.Smooth
	surface.BottomSurface = Enum.SurfaceType.Smooth
	surface.Parent = model

	local kerbOffset = width / 2 + 0.5
	local kerbColor = Color3.fromRGB(160, 160, 165)
	if args.kerbs ~= false then
		for _, side in { -1, 1 } do
			local kerb = Instance.new("Part")
			kerb.Name = side < 0 and "KerbLeft" or "KerbRight"
			kerb.Size = Vector3.new(1, 0.75, length)
			kerb.CFrame = surface.CFrame * CFrame.new(side * kerbOffset, 0.12, 0)
			kerb.Anchored = true
			kerb.Material = Enum.Material.Concrete
			kerb.Color = kerbColor
			kerb.Parent = model
		end
	end

	if args.centerLine ~= false then
		local dashes = math.max(1, math.floor(length / 12))
		local dashLength = math.max(1.5, length / dashes * 0.45)
		for index = 1, dashes do
			local t = (index - 0.5) / dashes
			local dash = Instance.new("Part")
			dash.Name = string.format("CentreLine%02d", index)
			dash.Size = Vector3.new(0.6, 0.06, dashLength)
			dash.CFrame = surface.CFrame * CFrame.new(0, 0.28, (t - 0.5) * length)
			dash.Anchored = true
			dash.Material = Enum.Material.SmoothPlastic
			dash.Color = Color3.fromRGB(235, 220, 120)
			dash.Parent = model
		end
	end

	model.PrimaryPart = surface
	return model, string.format("Road is %.1f studs long, %.0f studs wide.", length, width)
end

--=============================================================================
-- TERRAIN
--=============================================================================

local Terrain = {}

local REGION_PATTERN = "^(%-?%d+)%s*,%s*(%-?%d+)%s*,%s*(%-?%d+)$"

--- Parses "512,512,128" into three Vector3i values.
function Terrain.parseRegion(region: string): (Vector3i?, string?)
	local x, y, z = string.match(tostring(region), REGION_PATTERN)
	if not x then
		return nil, "Region must be three comma-separated integers such as 512,512,128."
	end
	return Vector3i.new(tonumber(x) or 4, tonumber(y) or 4, tonumber(z) or 4), nil
end

--=============================================================================
-- TERRAIN MATERIALS
--=============================================================================

-- Roblox raises `Lava is not a valid member of "Enum.Material"` the moment an
-- unknown Enum.Material member is read. Because this table is built at MODULE
-- SCOPE, a single wrong name used to abort require(ModelBuilder) and surface as
-- the useless "Requested module experienced an error while loading."
--
-- Every entry is therefore probed individually: a member this Studio build does
-- not know is dropped and reported, never fatal.

local TERRAIN_CANDIDATES: { string } = {
	"Plastic", "SmoothPlastic", "Neon", "Wood", "WoodPlanks", "Marble", "Basalt", "Slate",
	"CrackedLava", "Concrete", "Limestone", "Granite", "Pavement", "Brick", "Pebble",
	"Cobblestone", "Rock", "Sandstone", "CorrodedMetal", "DiamondPlate", "Foil", "Metal",
	"Grass", "LeafyGrass", "Sand", "Fabric", "Snow", "Mud", "Ground", "Asphalt", "Salt",
	"Ice", "Glacier", "Glass", "ForceField", "Air", "Water", "Cardboard", "Carpet",
	"CeramicTiles", "ClayRoofTiles", "RoofShingles", "Leather", "Plaster", "Rubber",
}

local TERRAIN_ENUM: { [string]: Enum.Material } = {}
local UNSUPPORTED_MATERIALS: { string } = {}

for _, name in TERRAIN_CANDIDATES do
	local ok, material = pcall(function()
		return Enum.Material[name]
	end)
	if ok and material then
		TERRAIN_ENUM[name] = material
	else
		UNSUPPORTED_MATERIALS[#UNSUPPORTED_MATERIALS + 1] = name
	end
end

-- Friendly aliases for names the AI may emit. Each alias is bound only when its
-- replacement really exists, so an alias can never reintroduce the crash.
local TERRAIN_ALIASES: { [string]: string } = {
	Lava = "CrackedLava",
	Moss = "Grass",
	MudRock = "Rock",
	Shale = "Slate",
	VolcanicRock = "Basalt",
	Stone = "Concrete",
}
for alias, target in TERRAIN_ALIASES do
	if TERRAIN_ENUM[target] then
		TERRAIN_ENUM[alias] = TERRAIN_ENUM[target]
	end
end

--- Terrain material names this Studio build does not support.
--- Surfaced in the UI so a degraded capability is visible rather than silent.
function ModelBuilder.unsupportedMaterials(): { string }
	return table.clone(UNSUPPORTED_MATERIALS)
end

function Terrain.fill(args): (Instance?, string?)
	local region, regionError = Terrain.parseRegion(args.region or "512,512,128")
	if not region then
		return nil, regionError
	end

	local material = TERRAIN_ENUM[args.material or "Grass"] or Enum.Material.Grass
	local size = toVector3(args.size, Vector3.new(region.X, 4, region.Z))
	local color = resolveColor(args.color, Color3.fromRGB(106, 168, 79))

	local ok, err = pcall(function()
		game:GetService("Workspace").Terrain:FillRegion(region, region, size, material, color)
	end)
	if not ok then
		return nil, "Terrain fill failed: " .. tostring(err)
	end

	return nil,
		string.format(
			"Filled region %d,%d,%d (%d x %d x %d) with %s.",
			region.X,
			region.Y,
			region.Z,
			size.X,
			size.Y,
			size.Z,
			material.Name
		)
end

--=============================================================================
-- SIMPLE MAP GENERATION
--=============================================================================

ModelBuilder.generateSimpleMap = function(options: {
	name: string?,
	origin: Vector3?,
	radius: number?,
	buildings: number?,
	roads: number?,
	color: any?,
}?)
	local origin = options.origin or Vector3.new(0, 0, 0)
	local radius = options.radius or 120
	local buildings = math.clamp(options.buildings or 8, 1, 30)
	local roads = math.clamp(options.roads or 4, 0, 12)
	local color = resolveColor(options.color, Color3.fromRGB(170, 170, 178))

	local model = Instance.new("Model")
	model.Name = options.name or "ForgePilotMap"
	model:SetAttribute("ForgePilotOrigin", "generate_map")

	local ground = Instance.new("Part")
	ground.Name = "Ground"
	ground.Size = Vector3.new(radius * 2, 1, radius * 2)
	ground.CFrame = CFrame.new(origin + Vector3.new(0, -0.5, 0))
	ground.Anchored = true
	ground.Material = Enum.Material.Grass
	ground.Color = Color3.fromRGB(106, 168, 79)
	ground.Parent = model

	for index = 1, buildings do
		local angle = (index / buildings) * math.pi * 2
		local distance = radius * (0.35 + (index % 3) * 0.18)
		local buildingSize = Vector3.new(14 + (index % 4) * 4, 10 + (index % 5) * 3, 12 + (index % 3) * 5)
		local position = origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)

		local building = Instance.new("Model")
		building.Name = string.format("Building%02d", index)

		local floor = Instance.new("Part")
		floor.Name = "Floor"
		floor.Size = buildingSize
		floor.CFrame = CFrame.new(position + Vector3.new(0, 0.5, 0))
		floor.Anchored = true
		floor.Material = Enum.Material.Concrete
		floor.Color = color:Lerp(Color3.new(0, 0, 0), 0.2)
		floor.Parent = building

		local body = Instance.new("Part")
		body.Name = "Body"
		body.Size = buildingSize - Vector3.new(1.6, 1, 1.6)
		body.CFrame = CFrame.new(position + Vector3.new(0, 1 + (buildingSize.Y - 1) / 2, 0))
		body.Anchored = true
		body.Material = Enum.Material.Concrete
		body.Color = color
		body.Transparency = 0.35
		body.CanCollide = true
		body.Parent = building
		building.PrimaryPart = body

		building.Parent = model
	end

	for index = 1, roads do
		local angle = (index / roads) * math.pi * 2
		local startPoint = origin + Vector3.new(math.cos(angle) * radius * 0.15, 0, math.sin(angle) * radius * 0.15)
		local endPoint = origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local road = Roads.create({
			name = string.format("Road%02d", index),
			start = startPoint,
			["end"] = endPoint,
			width = 10,
			kerbs = false,
			centerLine = true,
		})
		if road then
			road.Parent = model
		end
	end

	return model, string.format("Generated %d buildings and %d roads within a %d stud radius.", buildings, roads, radius)
end

ModelBuilder.Buildings = Buildings
ModelBuilder.Roads = Roads
ModelBuilder.Terrain = Terrain

return ModelBuilder