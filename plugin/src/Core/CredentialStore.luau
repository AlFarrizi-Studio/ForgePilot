--!strict
--[[
	ForgePilot / Core / CredentialStore
	Session-only secret storage.

	This is a plain in-memory table, not an encrypted vault and not persisted
	anywhere. Its lifetime is the current Roblox Studio session. On restart the
	user must re-enter each API key, which the UI states plainly.
]]

local EventBus = require(script.Parent.EventBus)
local Redact = require(script.Parent.Parent.Utilities.Redact)

local CredentialStore = {}

-- slot id -> secret string
local slots: { [string]: string } = {}

local function fingerprintOf(id: string): string
	return Redact.fingerprint(slots[id] or "")
end

--=============================================================================
-- CRUD
--=============================================================================

--- Stores a secret in a named slot (usually `<providerId>`).
function CredentialStore.set(id: string, secret: string)
	if type(id) ~= "string" or #id == 0 then
		return false
	end
	if type(secret) ~= "string" or #secret == 0 then
		slots[id] = nil
	else
		slots[id] = secret
	end
	EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "credential", slotId = id })
	return true
end

--- Reads a secret. Callers should minimise how long they hold the value.
function CredentialStore.get(id: string): string?
	return slots[id]
end

function CredentialStore.has(id: string): boolean
	return slots[id] ~= nil
end

--- Non-reversible fingerprint for "is a key loaded?" indicators.
function CredentialStore.fingerprint(id: string): string
	return fingerprintOf(id)
end

--- Safe preview for UI: only ever shows head/tail characters.
function CredentialStore.preview(id: string): string
	local secret = slots[id]
	if not secret then
		return ""
	end
	return Redact.mask(secret)
end

function CredentialStore.clear(id: string)
	slots[id] = nil
	EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "credentialCleared", slotId = id })
end

function CredentialStore.clearAll()
	table.clear(slots)
	EventBus.emit(EventBus.Events.ProvidersChanged, { reason = "credentialsCleared" })
end

function CredentialStore.count(): number
	local n = 0
	for _ in slots do
		n += 1
	end
	return n
end

--- Returns ids of slots that hold a secret (ids are not secret).
function CredentialStore.slots(): { string }
	local list = {}
	for id in slots do
		list[#list + 1] = id
	end
	table.sort(list)
	return list
end

return CredentialStore