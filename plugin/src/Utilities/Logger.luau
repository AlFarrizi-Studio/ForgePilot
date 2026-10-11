--!strict
--[[
	ForgePilot / Utilities / Logger
	Central activity log. Every entry produced here describes something that
	actually happened; nothing is synthesised for display purposes.
]]

local Redact = require(script.Parent.Redact)

local Logger = {}

export type Level = "INFO" | "SUCCESS" | "WARN" | "ERROR" | "CONNECT" | "AGENT" | "PLAN" | "QUESTION" | "TOOL" | "DEBUG"

export type Entry = {
	id: number,
	--- Wall-clock seconds since the Unix epoch. Used for display.
	timestamp: number,
	--- os.clock() at the time of the event. Used for ordering and durations.
	monotonic: number,
	level: Level,
	category: string,
	message: string,
	detail: string?,
	toolName: string?,
	taskId: string?,
	durationMs: number?,
}

local MAX_ENTRIES = 3000
local listeners: { { [any]: (...any) -> () } } = {}

local levelWeights: { [Level]: number } = {
	DEBUG = 10,
	INFO = 20,
	CONNECT = 20,
	AGENT = 20,
	PLAN = 20,
	QUESTION = 20,
	TOOL = 20,
	SUCCESS = 20,
	WARN = 30,
	ERROR = 40,
}

Logger.levels = levelWeights

local levelColors: { [Level]: Color3 } = {
	DEBUG = Color3.fromHex("#6B6377"),
	INFO = Color3.fromHex("#A7A0B2"),
	CONNECT = Color3.fromHex("#6FA8DC"),
	AGENT = Color3.fromHex("#9879E8"),
	PLAN = Color3.fromHex("#9879E8"),
	QUESTION = Color3.fromHex("#E8B661"),
	TOOL = Color3.fromHex("#F4F1F8"),
	SUCCESS = Color3.fromHex("#49C591"),
	WARN = Color3.fromHex("#E8B661"),
	ERROR = Color3.fromHex("#F16E7A"),
}

Logger.levelColor = levelColors

local allEntries: { Entry } = {}
local nextId = 1
local minimumLevel: number = Logger.levels.INFO

--=============================================================================
-- SUBSCRIPTION
--=============================================================================

--- Subscribes to the log stream. Returns a function that unsubscribes.
function Logger.subscribe(callback: (Entry) -> ()): () -> ()
	local holder = { callback = callback }
	table.insert(listeners, holder)
	return function()
		for index, entry in listeners do
			if entry == holder then
				table.remove(listeners, index)
				return
			end
		end
	end
end

function Logger.unsubscribe(callback: (Entry) -> ())
	for index, holder in listeners do
		if holder.callback == callback then
			table.remove(listeners, index)
			return
		end
	end
end

local function dispatch(entry: Entry)
	for _, holder in listeners do
		local ok, err = pcall(holder.callback, entry)
		if not ok then
			warn("[ForgePilot] log listener error: " .. tostring(err))
		end
	end
end

--=============================================================================
-- EMIT
--=============================================================================

local function normaliseLevel(level: any): Level
	local resolved = tostring(level):upper()
	if Logger.levels[resolved] then
		return resolved
	end
	return "INFO"
end

function Logger.log(level: any, category: string, message: string, options: {
	detail: string?,
	toolName: string?,
	taskId: string?,
	durationMs: number?,
}?)
	local resolvedLevel = normaliseLevel(level)
	if Logger.levels[resolvedLevel] < minimumLevel then
		return nil
	end

	local entry: Entry = {
		id = nextId,
		timestamp = os.time(),
		monotonic = os.clock(),
		level = resolvedLevel,
		category = Redact.scrubText(category),
		message = Redact.scrubText(message),
		detail = if options and options.detail then Redact.scrubText(options.detail) else nil,
		toolName = options and options.toolName or nil,
		taskId = options and options.taskId or nil,
		durationMs = options and options.durationMs or nil,
	}
	nextId += 1

	allEntries[#allEntries + 1] = entry
	if #allEntries > MAX_ENTRIES then
		table.remove(allEntries, 1)
	end

	dispatch(entry)
	return entry
end

-- Convenience wrappers -------------------------------------------------

function Logger.info(category: string, message: string, options: { detail: string?, toolName: string?, taskId: string?, durationMs: number? }?)
	return Logger.log("INFO", category, message, options)
end

function Logger.success(category: string, message: string, options: { detail: string?, toolName: string?, taskId: string?, durationMs: number? }?)
	return Logger.log("SUCCESS", category, message, options)
end

function Logger.warn(category: string, message: string, options: { detail: string?, toolName: string?, taskId: string?, durationMs: number? }?)
	return Logger.log("WARN", category, message, options)
end

function Logger.error(category: string, message: string, options: { detail: string?, toolName: string?, taskId: string?, durationMs: number? }?)
	return Logger.log("ERROR", category, message, options)
end

function Logger.debug(category: string, message: string, options: { detail: string?, toolName: string?, taskId: string?, durationMs: number? }?)
	return Logger.log("DEBUG", category, message, options)
end

--=============================================================================
-- LEVEL CONTROL
--=============================================================================

function Logger.setLevel(level: Level)
	minimumLevel = Logger.levels[level] or Logger.levels.INFO
end

function Logger.getLevel(): Level
	for name, value in Logger.levels do
		if value == minimumLevel then
			return name
		end
	end
	return "INFO"
end

--=============================================================================
-- RETRIEVAL
--=============================================================================

function Logger.getEntries(): { Entry }
	local copy = table.clone(allEntries)
	return copy
end

function Logger.getCategoryList(): { string }
	local seen: { [string]: boolean } = {}
	local list: { string } = {}
	for _, entry in allEntries do
		if not seen[entry.category] then
			seen[entry.category] = true
			list[#list + 1] = entry.category
		end
	end
	table.sort(list)
	return list
end

function Logger.clear()
	allEntries = {}
end

--- Formats an entry the way the Logs panel renders it.
function Logger.format(entry: Entry, includeDetail: boolean?): string
	-- FormatLocalTime already renders in the viewer's local zone, so there is
	-- no ToLocal() step here. Calling it was both redundant and rejected by the
	-- real engine ("ToLocal is not a valid member of DateTime").
	local stamp = DateTime.fromUnixTimestampMillis(entry.timestamp * 1000)
		:FormatLocalTime("HH:mm:ss", "short")
	local line = string.format("[%s] [%s] %s", stamp, entry.level, entry.message)
	if entry.toolName then
		line ..= string.format("  «%s»", entry.toolName)
	end
	if includeDetail and entry.detail and #entry.detail > 0 then
		line ..= "\n    " .. entry.detail:gsub("\n", "\n    ")
	end
	return Redact.scrubText(line)
end

function Logger.copyAll(): string
	local parts: { string } = {}
	for _, entry in allEntries do
		parts[#parts + 1] = Logger.format(entry, true)
	end
	return table.concat(parts, "\n")
end

return Logger