--!strict
--[[
	ForgePilot / Roblox / ActionRegistry
	Duplicate build prevention.

	PROBLEM
	If ForgePilot successfully creates ten buildings and the provider then fails,
	retrying the request must not create ten more.

	APPROACH
	  * Every write tool call gets a stable key derived from the task id, the tool
	    call id and the tool arguments.
	  * A completed action is recorded ONLY after ActionExecutor verifies success.
	  * Before a call runs, the registry answers "has this already happened?".
	  * When the answer is genuinely unknown (an action failed mid-flight, or the
	    instance vanished), the caller is told to INSPECT rather than blindly repeat.
	  * Registry state is cleared when a task ends, so a fresh task legitimately
	    recreates the same objects.

	Verification is not inferred from the registry alone: the registry also checks
	that the instance it recorded still exists in the DataModel.
]]

local InstanceManager = require(script.Parent.InstanceManager)

local ActionRegistry = {}

--=============================================================================
-- RECORDS
--=============================================================================

export type Record = {
	key: string,
	taskId: string,
	toolCallId: string?,
	toolName: string,
	argumentsHash: string,
	verified: boolean,
	instancePath: string?,
	instanceClass: string?,
	completedAt: number,
	at: number,
}

local records: { [string]: Record } = {}
local order: { string } = {}
local byTask: { [string]: { string } } = {}

local MAX_RECORDS = 500

--=============================================================================
-- KEYS
--=============================================================================

--- A stable, order-independent fingerprint of a tool's arguments.
function ActionRegistry.hashArguments(arguments: any): string
	if type(arguments) ~= "table" then
		return "none"
	end

	local parts: { string } = {}
	for key, value in arguments do
		if key ~= "__required" then
			parts[#parts + 1] = string.format("%s=%s", tostring(key), ActionRegistry.stringify(value))
		end
	end
	table.sort(parts)

	-- FNV-1a over the sorted key/value list.
	local hash = 2166136261
	local text = table.concat(parts, "|")
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = bit32.band(hash * 16777619, 0xFFFFFFFF)
	end
	return string.format("%08x", hash)
end

local function stringify(value: any, depth: number): string
	local level = depth or 0
	if level > 6 then
		return "…"
	end
	local valueType = type(value)
	if valueType == "string" then
		return value
	elseif valueType == "number" or valueType == "boolean" then
		return tostring(value)
	elseif valueType == "table" then
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = {}
		for _, key in keys do
			parts[#parts + 1] = string.format("%s:%s", tostring(key), stringify(value[key], level + 1))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "?"
end

ActionRegistry.stringify = stringify

--- Builds the deduplication key for a call.
function ActionRegistry.key(taskId: string, toolCallId: string?, toolName: string, arguments: any): string
	return string.format(
		"%s|%s|%s|%s",
		taskId,
		toolCallId or "-",
		toolName,
		ActionRegistry.hashArguments(arguments)
	)
end

--=============================================================================
-- RECORD
--=============================================================================

local function push(key: string, record: Record)
	records[key] = record
	order[#order + 1] = key
	byTask[record.taskId] = byTask[record.taskId] or {}
	table.insert(byTask[record.taskId], key)

	while #order > MAX_RECORDS do
		local oldest = table.remove(order, 1)
		local oldRecord = records[oldest]
		records[oldest] = nil
		if oldRecord and byTask[oldRecord.taskId] then
			local taskKeys = byTask[oldRecord.taskId]
			for index, taskKey in taskKeys do
				if taskKey == oldest then
					table.remove(taskKeys, index)
					break
				end
			end
		end
	end
end

--- Records a verified action. Only ever called after the executor confirmed it.
function ActionRegistry.record(entry: {
	taskId: string,
	toolCallId: string?,
	toolName: string,
	arguments: any,
	verified: boolean,
	instance: Instance?,
}): Record
	local record: Record = {
		key = ActionRegistry.key(entry.taskId, entry.toolCallId, entry.toolName, entry.arguments),
		taskId = entry.taskId,
		toolCallId = entry.toolCallId,
		toolName = entry.toolName,
		argumentsHash = ActionRegistry.hashArguments(entry.arguments),
		verified = entry.verified,
		instancePath = if entry.instance and entry.instance.Parent
			then entry.instance:GetFullName()
			else nil,
		instanceClass = if entry.instance then entry.instance.ClassName else nil,
		completedAt = os.clock(),
		at = os.time(),
	}
	push(record.key, record)
	return record
end

--=============================================================================
-- QUERY
--=============================================================================

export type Prior = {
	replayed: boolean,
	reason: string,
	record: Record?,
	--- True when the caller should inspect the project before deciding.
	needsInspection: boolean,
}

--- Answers: has this exact call already completed successfully?
function ActionRegistry.check(
	taskId: string,
	toolCallId: string?,
	toolName: string,
	arguments: any
): Prior
	local key = ActionRegistry.key(taskId, toolCallId, toolName, arguments)
	local existing = records[key]
	if not existing then
		return { replayed = false, reason = "No prior record for this call.", record = nil, needsInspection = false }
	end

	if not existing.verified then
		return {
			replayed = false,
			reason = "A previous attempt at this call did not verify.",
			record = existing,
			needsInspection = true,
		}
	end

	-- The record claims success: confirm the object is still there.
	if existing.instancePath then
		local resolved = InstanceManager.findByPath(existing.instancePath)
		if resolved then
			return {
				replayed = true,
				reason = string.format("Already completed: %s exists.", existing.instancePath),
				record = existing,
				needsInspection = false,
			}
		end
		return {
			replayed = false,
			reason = string.format(
				"A previous attempt verified %s, but that instance no longer exists. Inspect before repeating.",
				existing.instancePath
			),
			record = existing,
			needsInspection = true,
		}
	end

	-- No instance to check (deletes, terrain, lighting): trust the record.
	return {
		replayed = true,
		reason = string.format("Already completed: %s.", existing.toolName),
		record = existing,
		needsInspection = false,
	}
end

function ActionRegistry.isRecorded(taskId: string, toolCallId: string?, toolName: string, arguments: any): boolean
	return records[ActionRegistry.key(taskId, toolCallId, toolName, arguments)] ~= nil
end

function ActionRegistry.get(key: string): Record?
	return records[key]
end

function ActionRegistry.getForTask(taskId: string): { Record }
	local list: { Record } = {}
	for _, key in (byTask[taskId] or {}) do
		local record = records[key]
		if record then
			list[#list + 1] = record
		end
	end
	table.sort(list, function(a, b)
		return a.at < b.at
	end)
	return list
end

function ActionRegistry.countForTask(taskId: string): number
	local n = 0
	for _, key in (byTask[taskId] or {}) do
		if records[key] then
			n += 1
		end
	end
	return n
end

--=============================================================================
-- LIFECYCLE
--=============================================================================

--- Clears everything for a finished task so a new task may recreate the world.
function ActionRegistry.clearTask(taskId: string)
	local keys = byTask[taskId]
	if not keys then
		return
	end
	for _, key in keys do
		records[key] = nil
	end
	byTask[taskId] = nil
	for index = #order, 1, -1 do
		if not records[order[index]] then
			table.remove(order, index)
		end
	end
end

function ActionRegistry.clearAll()
	records = {}
	order = {}
	byTask = {}
end

--- Verification pass: drops records whose instance no longer exists.
function ActionRegistry.audit(): { dropped: number, kept: number }
	local dropped = 0
	local kept = 0
	for key, record in records do
		if record.instancePath and not InstanceManager.findByPath(record.instancePath) then
			records[key] = nil
			dropped += 1
		else
			kept += 1
		end
	end
	if dropped > 0 then
		for index = #order, 1, -1 do
			if not records[order[index]] then
				table.remove(order, index)
			end
		end
	end
	return { dropped = dropped, kept = kept }
end

return ActionRegistry