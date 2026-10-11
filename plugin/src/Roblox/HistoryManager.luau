--!strict
local ChangeHistoryService = game:GetService("ChangeHistoryService")
--[[
	ForgePilot / Roblox / HistoryManager
	ChangeHistoryService wrapper so every ForgePilot edit is undoable as one step.
]]

local Logger = require(script.Parent.Parent.Utilities.Logger)
local EventBus = require(script.Parent.Parent.Core.EventBus)

local HistoryManager = {}

local recordingId: number? = nil
local recordingLabel: string? = nil
local operationCount = 0

--- True while a ForgePilot recording is open.
function HistoryManager.isRecording(): boolean
	return recordingId ~= nil
end

function HistoryManager.getRecordingLabel(): string?
	return recordingLabel
end

function HistoryManager.begin(label: string): boolean
	if recordingId ~= nil then
		return false
	end
	local ok, id = pcall(function()
		return ChangeHistoryService:TryBeginRecording(label)
	end)
	if not ok or id == nil then
		Logger.warn("Build", "Could not start a Change History recording.", { detail = tostring(id) })
		return false
	end
	recordingId = id
	recordingLabel = label
	operationCount = 0
	Logger.info("Build", "Change recording started.", { detail = label })
	return true
end

--- Sets a waypoint inside the current recording so each action is its own undo step.
function HistoryManager.waypoint(label: string)
	if recordingId == nil then
		return
	end
	local ok, err = pcall(function()
		ChangeHistoryService:SetWaypoint(recordingId, label)
	end)
	if ok then
		operationCount += 1
	else
		Logger.warn("Build", "Could not set a change waypoint.", { detail = tostring(err) })
	end
end

function HistoryManager.finish()
	if recordingId == nil then
		return
	end
	local id = recordingId
	local label = recordingLabel or "ForgePilot changes"
	local count = operationCount
	recordingId = nil
	recordingLabel = nil
	operationCount = 0
	pcall(function()
		ChangeHistoryService:FinishRecording(id)
	end)
	Logger.success("Build", string.format("Change recording finished (%d action%s).", count, if count == 1 then "" else "s"), {
		detail = label,
	})
	EventBus.emit(EventBus.Events.BuildProgress, { phase = "recorded", count = count })
end

--- Runs `fn` inside a recording, guaranteeing the recording is closed.
function HistoryManager.transact(label: string, fn: () -> ()): (boolean, string?)
	local alreadyRecording = recordingId ~= nil
	if not alreadyRecording then
		HistoryManager.begin(label)
	end

	local ok, err = pcall(fn)

	if not alreadyRecording then
		HistoryManager.finish()
	end

	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

function HistoryManager.undo()
	local ok, err = pcall(function()
		ChangeHistoryService:Undo()
	end)
	if ok then
		Logger.info("Build", "Undo requested.")
		EventBus.emit(EventBus.Events.BuildProgress, { phase = "undo" })
		return true
	end
	Logger.error("Build", "Undo failed.", { detail = tostring(err) })
	return false
end

function HistoryManager.redo()
	local ok, err = pcall(function()
		ChangeHistoryService:Redo()
	end)
	if ok then
		Logger.info("Build", "Redo requested.")
		EventBus.emit(EventBus.Events.BuildProgress, { phase = "redo" })
		return true
	end
	Logger.error("Build", "Redo failed.", { detail = tostring(err) })
	return false
end

--- Guards against an orphaned recording after a plugin reload.
function HistoryManager.resetOrphan()
	if recordingId ~= nil then
		pcall(function()
			ChangeHistoryService:FinishRecording(recordingId)
		end)
		recordingId = nil
		recordingLabel = nil
	end
end

return HistoryManager