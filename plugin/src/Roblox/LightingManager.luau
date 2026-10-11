--!strict
--[[
	ForgePilot / Roblox / LightingManager
	Applies Lighting changes and manages common look presets.

	Every write is verified by reading the property back from Lighting.
]]

local StringUtil = require(script.Parent.Parent.Utilities.StringUtil)

-- Self-contained pure conversion helpers. Do not import ActionExecutor here.
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

local LightingManager = {}

local ALLOWED_PROPERTIES: {[string]: boolean} = {
    ClockTime = true,
    Brightness = true,
    Ambient = true,
    OutdoorAmbient = true,
    EnvironmentDiffuseScale = true,
    EnvironmentSpecularScale = true,
    ExposureCompensation = true,
    GlobalShadows = true,
    ShadowSoftness = true,
    Technology = true,
    Attenuation = true,
    OutdoorExposure = true,
}

--=============================================================================
-- APPLY
--=============================================================================

--- Applies a settings table to Lighting. Returns nil plus a message on success
--- (Lighting is a singleton, not an instance we create), or nil plus an error.
function LightingManager.apply(settings: any): (any?, string?)
	if type(settings) ~= "table" then
		return nil, "`settings` must be an object of Lighting property names to values."
	end

	local lighting = game:GetService("Lighting")
	local applied = {}
	local rejected = {}

	for property, value in settings do
		if type(property) ~= "string" or not ALLOWED_PROPERTIES[property] then
			rejected[#rejected + 1] = string.format("%s (not a supported Lighting property)", tostring(property))
		else
			local resolved = value
			if property == "Ambient" or property == "OutdoorAmbient" then
				resolved = toColor3(value, lighting[property])
			end
			local ok, err = pcall(function()
				(lighting :: any)[property] = resolved
			end)
			if ok then
				applied[#applied + 1] = property
			else
				rejected[#rejected + 1] = string.format("%s (%s)", property, tostring(err))
			end
		end
	end

	if #applied == 0 then
		return nil,
			string.format(
				"No Lighting setting was applied. Rejected: %s",
				#rejected > 0 and table.concat(rejected, "; ") or "(nothing provided)"
			)
	end

	-- Verify by reading back.
	local verified = {}
	for _, property in applied do
		local ok, value = pcall(function()
			return (lighting :: any)[property]
		end)
		if ok then
			verified[#verified + 1] = string.format("%s=%s", property, tostring(value))
		end
	end

	local message = string.format("Applied %s.", table.concat(applied, ", "))
	if #rejected > 0 then
		message ..= string.format(" Rejected: %s", table.concat(rejected, "; "))
	end
	return nil, message .. string.format(" Verified: %s.", table.concat(verified, ", "))
end

--=============================================================================
-- PRESETS
--=============================================================================

LightingManager.Presets = {
	Daylight = {
		ClockTime = 13,
		Brightness = 2.5,
		Ambient = Color3.fromRGB(120, 120, 130),
		OutdoorAmbient = Color3.fromRGB(150, 150, 160),
		GlobalShadows = true,
	},
	Night = {
		ClockTime = 0.5,
		Brightness = 0.6,
		Ambient = Color3.fromRGB(20, 20, 35),
		OutdoorAmbient = Color3.fromRGB(30, 30, 55),
		GlobalShadows = true,
	},
	Sunset = {
		ClockTime = 18.4,
		Brightness = 1.6,
		Ambient = Color3.fromRGB(90, 70, 80),
		OutdoorAmbient = Color3.fromRGB(200, 130, 90),
		GlobalShadows = true,
	},
	Clean = {
		ClockTime = 14,
		Brightness = 3,
		Ambient = Color3.fromRGB(140, 140, 145),
		OutdoorAmbient = Color3.fromRGB(160, 160, 165),
		EnvironmentDiffuseScale = 0.5,
		EnvironmentSpecularScale = 0.4,
		GlobalShadows = true,
		ShadowSoftness = 0.2,
	},
}

function LightingManager.applyPreset(name: string): (any?, string?)
	local preset = LightingManager.Presets[name]
	if not preset then
		local names = {}
		for key in pairs(LightingManager.Presets) do
			names[#names + 1] = key
		end
		table.sort(names)
		return nil, string.format("Unknown preset `%s`. Available: %s.", name, table.concat(names, ", "))
	end
	return LightingManager.apply(preset)
end

--=============================================================================
-- ATMOSPHERE
--=============================================================================

--- Creates or updates an Atmosphere for the current look.
function LightingManager.ensureAtmosphere(options: { density: number?, offset: number?, color: any?, decalColor: any?, glare: number?, haze: number? }?): (any?, string?)
	local opts = options or {}
	local lighting = game:GetService("Lighting")

	local atmosphere = lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		local created = Instance.new("Atmosphere")
		created.Name = "Atmosphere"
		created.Parent = lighting
		atmosphere = created
	end

	atmosphere.Density = math.clamp(opts.density or 0.3, 0, 1)
	atmosphere.Offset = math.clamp(opts.offset or 0, -1, 1)
	atmosphere.Color = toColor3(opts.color, Color3.fromRGB(205, 205, 210))
	atmosphere.DecalColor = toColor3(opts.decalColor, Color3.fromRGB(20, 20, 20))
	atmosphere.Glare = math.clamp(opts.glare or 0, 0, 1)
	atmosphere.Haze = math.clamp(opts.haze or 1, 0, 1)

	return nil,
		string.format(
			"Atmosphere ready: density %.2f, haze %.2f, glare %.2f.",
			atmosphere.Density,
			atmosphere.Haze,
			atmosphere.Glare
		)
end

return LightingManager