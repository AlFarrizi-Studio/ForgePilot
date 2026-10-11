--!strict
local StudioService = game:GetService("StudioService")
--[[
	ForgePilot / AI / AttachmentEncoder
	Reads files from Studio, validates them against the model's real capabilities,
	and prepares provider-ready payloads.

	IMPORTANT: reading a PDF's bytes does not mean a chat model can read a PDF.
	The encoder enforces the model's declared capabilities and rejects anything it
	cannot honestly deliver.
]]

local Base64 = require(script.Parent.Parent.Utilities.Base64)
local EventBus = require(script.Parent.Parent.Core.EventBus)
local Logger = require(script.Parent.Parent.Utilities.Logger)
local ModelCapabilityDetector = require(script.Parent.ModelCapabilityDetector)
local Time = require(script.Parent.Parent.Utilities.Time)

local AttachmentEncoder = {}

--=============================================================================
-- LIMITS
--=============================================================================

AttachmentEncoder.Limits = {
	MAX_FILE_BYTES = 20 * 1024 * 1024,
	MAX_TOTAL_BYTES = 60 * 1024 * 1024,
	MAX_TEXT_INLINE_BYTES = 300 * 1024,
	MAX_IMAGE_BYTES = 20 * 1024 * 1024,
	MAX_TEXT_CHARS = 400_000,
}

--=============================================================================
-- FILE CATEGORIES
--=============================================================================

export type Category = "image" | "document" | "code" | "audio" | "video" | "unsupported"

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, webp = true }
local TEXT_EXT = { txt = true, md = true, csv = true, json = true }
local CODE_EXT = {
	lua = true,
	luau = true,
	js = true,
	ts = true,
	py = true,
	html = true,
	css = true,
	xml = true,
}
local AUDIO_EXT = { mp3 = true, wav = true, ogg = true, flac = true, m4a = true }
local VIDEO_EXT = { mp4 = true, webm = true, mov = true, avi = true }

function AttachmentEncoder.categorise(fileName: string): Category
	local extension = string.lower(string.match(fileName, "%.([%w]+)$") or "")
	if IMAGE_EXT[extension] then
		return "image"
	elseif extension == "pdf" then
		return "document"
	elseif TEXT_EXT[extension] then
		return "document"
	elseif CODE_EXT[extension] then
		return "code"
	elseif AUDIO_EXT[extension] then
		return "audio"
	elseif VIDEO_EXT[extension] then
		return "video"
	end
	return "unsupported"
end

function AttachmentEncoder.categoryLabel(category: Category): string
	if category == "image" then
		return "Image"
	elseif category == "document" then
		return "Document"
	elseif category == "code" then
		return "Source Code"
	elseif category == "audio" then
		return "Audio"
	elseif category == "video" then
		return "Video"
	end
	return "Unsupported"
end

--=============================================================================
-- ATTACHMENT RECORD
--=============================================================================

export type Attachment = {
	id: string,
	name: string,
	category: Category,
	mime: string,
	sizeBytes: number,
	base64: string?,
	text: string?,
	previewAssetId: number?,
	accepted: boolean,
	rejectionReason: string?,
	warning: string?,
}

local attachments: { Attachment } = {}

function AttachmentEncoder.getAll(): { Attachment }
	return attachments
end

function AttachmentEncoder.count(): number
	return #attachments
end

function AttachmentEncoder.totalBytes(): number
	local total = 0
	for _, attachment in attachments do
		total += attachment.sizeBytes
	end
	return total
end

function AttachmentEncoder.clear()
	attachments = {}
	EventBus.emit(EventBus.Events.AttachmentsChanged, { count = 0, bytes = 0 })
end

function AttachmentEncoder.remove(id: string)
	for index, attachment in attachments do
		if attachment.id == id then
			table.remove(attachments, index)
			EventBus.emit(EventBus.Events.AttachmentsChanged, {
				count = #attachments,
				bytes = AttachmentEncoder.totalBytes(),
			})
			return
		end
	end
end

function AttachmentEncoder.emitChanged()
	EventBus.emit(EventBus.Events.AttachmentsChanged, {
		count = #attachments,
		bytes = AttachmentEncoder.totalBytes(),
	})
end

--=============================================================================
-- PICKER
--=============================================================================

--- Opens the Studio file picker. Returns the chosen `File` instances.
--- Returns an empty list when the user cancels (this is not an error).
function AttachmentEncoder.pickFiles(multiple: boolean?): { Instance }
	local ok, files = pcall(function()
		if multiple == false then
			local file = StudioService:PromptImportFileAsync()
			return if file then { file } else {}
		end
		local picked = StudioService:PromptImportFilesAsync()
		return picked or {}
	end)
	if not ok then
		Logger.error("File Attachments", "The Studio file picker could not be opened.", { detail = tostring(files) })
		return {}
	end
	return files
end

--=============================================================================
-- READING
--=============================================================================

local function readFile(file: Instance): (buffer?, string?)
	local ok, contents = pcall(function()
		return (file :: any):GetBinaryContents()
	end)
	if ok and type(contents) == "string" then
		return Base64.stringToBuffer(contents), nil
	end
	-- Some file types only expose text.
	local textOk, text = pcall(function()
		return (file :: any):GetContents()
	end)
	if textOk and type(text) == "string" then
		return Base64.stringToBuffer(text), nil
	end
	return nil, "Studio could not read this file's contents."
end

--=============================================================================
-- VALIDATION
--=============================================================================

--- Checks whether the model can genuinely accept this attachment.
--- `capabilityReport` comes from ModelCapabilityDetector; nil means unknown model,
--- in which case only text-like content is allowed (a conservative default).
function AttachmentEncoder.validate(
	attachment: Attachment,
	capabilityReport: any?,
	protocolId: string?
): (boolean, string?)
	local limits = AttachmentEncoder.Limits

	if attachment.sizeBytes > limits.MAX_FILE_BYTES then
		return false,
			string.format(
				"`%s` is %s, over the %s per-file limit ForgePilot will send.",
				attachment.name,
				Time.formatBytes(attachment.sizeBytes),
				Time.formatBytes(limits.MAX_FILE_BYTES)
			)
	end

	if AttachmentEncoder.totalBytes() + attachment.sizeBytes > limits.MAX_TOTAL_BYTES then
		return false,
			string.format(
				"Attachments would exceed the %s total limit.",
				Time.formatBytes(limits.MAX_TOTAL_BYTES)
			)
	end

	local allowed = ModelCapabilityDetector.allowedAttachmentKinds(capabilityReport, protocolId)

	if attachment.category == "image" then
		if not allowed.image then
			return false,
				string.format(
					"The selected model does not report vision (image input) support, so `%s` cannot be sent. Choose a vision-capable model or attach text instead.",
					attachment.name
				)
		end
		return true, nil
	end

	if attachment.category == "audio" then
		if not allowed.audio then
			return false,
				string.format(
					"`%s` is audio. Only the Google Gemini native protocol accepts inline audio through a chat endpoint; the current selection cannot accept it.",
					attachment.name
				)
		end
		return true, nil
	end

	if attachment.category == "video" then
		if not allowed.video then
			return false,
				string.format(
					"`%s` is video. Only the Google Gemini native protocol accepts inline video through a chat endpoint; the current selection cannot accept it.",
					attachment.name
				)
		end
		return true, nil
	end

	if attachment.category == "document" and string.match(string.lower(attachment.name), "%.pdf$") then
		if not allowed.pdf then
			return false,
				string.format(
					"`%s` is a PDF. ForgePilot can read the file bytes, but the selected model's chat endpoint does not accept inline PDF data, and ForgePilot cannot parse PDF text inside a Studio plugin. Extract the text and attach that instead.",
					attachment.name
				)
		end
		return true, "PDF is sent as raw inline bytes. Complex layouts may not be understood."
	end

	if attachment.category == "document" or attachment.category == "code" then
		if attachment.text == nil then
			return false, string.format("`%s` could not be decoded as text.", attachment.name)
		end
		if #attachment.text > limits.MAX_TEXT_CHARS then
			return false,
				string.format(
					"`%s` is %d characters, over the %s inline limit. Split the file before attaching.",
					attachment.name,
					#attachment.text,
					Time.formatBytes(limits.MAX_TEXT_CHARS)
				)
		end
		return true, nil
	end

	return false,
		string.format(
			"`%s` has an unsupported extension. ForgePilot can read images (png/jpg/jpeg/webp), text (txt/md/csv/json), code (lua/luau/js/ts/py/html/css/xml), and — where the model supports them — pdf, audio and video.",
			attachment.name
		)
end

--=============================================================================
-- LOAD
--=============================================================================

--- Reads, validates and stores files. Returns accepted and rejected counts.
export type LoadResult = {
	accepted: { Attachment },
	rejected: { { name: string, reason: string } },
}

function AttachmentEncoder.load(files: { Instance }, capabilityReport: any?, protocolId: string?): LoadResult
	local result: LoadResult = { accepted = {}, rejected = {} }

	for _, file in files do
		local okName, name = pcall(function()
			return (file :: any):GetName()
		end)
		if not okName or type(name) ~= "string" then
			name = "untitled"
		end

		local okSize, size = pcall(function()
			return (file :: any):GetSize()
		end)
		if not okSize or type(size) ~= "number" then
			size = 0
		end

		local category = AttachmentEncoder.categorise(name)
		local attachment: Attachment = {
			id = Time.newId("att"),
			name = name,
			category = category,
			mime = Base64.mimeTypeFor(name),
			sizeBytes = size,
			accepted = false,
		}

		if category == "unsupported" then
			local _, reason = AttachmentEncoder.validate(attachment, capabilityReport, protocolId)
			result.rejected[#result.rejected + 1] = { name = name, reason = reason or "Unsupported format." }
			continue
		end

		local fileBuffer, readError = readFile(file)
		if not fileBuffer then
			result.rejected[#result.rejected + 1] = { name = name, reason = readError or "Could not read the file." }
			continue
		end

		if size == 0 then
			size = buffer.len(fileBuffer)
			attachment.sizeBytes = size
		end

		if category == "document" or category == "code" then
			local decoded = Base64.bufferToString(fileBuffer)
			if string.byte(decoded, 1, 1) == 0 or decoded:find("\0") then
				result.rejected[#result.rejected + 1] = {
					name = name,
					reason = string.format(
						"`%s` has a text extension but contains binary data. Attach it as its real format instead.",
						name
					),
				}
				continue
			end
			attachment.text = decoded
		else
			attachment.base64 = Base64.encodeBuffer(fileBuffer)
		end

		-- Studio can produce a temporary asset id for a native image preview.
		if category == "image" then
			pcall(function()
				-- GetTemporaryId returns forms like "rbxassetid://1234" or "1234".
				local raw = (file :: any):GetTemporaryId()
				if type(raw) == "string" then
					local digits = string.match(raw, "(%d+)$")
					if digits then
						attachment.previewAssetId = tonumber(digits)
					end
				end
			end)
		end

local accepted, reason = AttachmentEncoder.validate(attachment, capabilityReport, protocolId)
		attachment.accepted = accepted
		attachment.rejectionReason = reason

		if accepted then
			attachments[#attachments + 1] = attachment
			result.accepted[#result.accepted + 1] = attachment
			Logger.info("File Attachments", string.format("Attached %s (%s).", attachment.name, AttachmentEncoder.categoryLabel(category)))
		else
			result.rejected[#result.rejected + 1] = { name = name, reason = reason or "Rejected." }
			Logger.warn("File Attachments", string.format("Rejected %s.", name), { detail = reason })
		end
	end

	AttachmentEncoder.emitChanged()
	return result
end

--=============================================================================
-- PROVIDER PARTS
--=============================================================================

--- Converts accepted attachments into the adapter content-part shape.
--- Only the parts the model genuinely supports are emitted.
function AttachmentEncoder.toProviderParts(capabilityReport: any?, protocolId: string?): { any }
	local allowed = ModelCapabilityDetector.allowedAttachmentKinds(capabilityReport, protocolId)
	local parts: { any } = {}

	for _, attachment in attachments do
		if not attachment.accepted then
			continue
		end

		if attachment.category == "image" and attachment.base64 and allowed.image then
			parts[#parts + 1] = {
				kind = "image",
				mime = attachment.mime,
				data = attachment.base64,
				fileName = attachment.name,
			}
		elseif attachment.category == "audio" and attachment.base64 and allowed.audio then
			parts[#parts + 1] = {
				kind = "audio",
				mime = attachment.mime,
				data = attachment.base64,
				fileName = attachment.name,
			}
		elseif attachment.category == "video" and attachment.base64 and allowed.video then
			parts[#parts + 1] = {
				kind = "video",
				mime = attachment.mime,
				data = attachment.base64,
				fileName = attachment.name,
			}
		elseif attachment.category == "document" and allowed.pdf and attachment.base64 then
			parts[#parts + 1] = {
				kind = "document",
				mime = attachment.mime,
				data = attachment.base64,
				fileName = attachment.name,
			}
		elseif (attachment.category == "document" or attachment.category == "code") and attachment.text then
			local header = string.format("--- BEGIN %s (%s) ---\n", attachment.name, AttachmentEncoder.categoryLabel(attachment.category))
			local footer = string.format("\n--- END %s ---", attachment.name)
			local text = header .. attachment.text .. footer
			local entry = { kind = "text", text = text }
			if attachment.category == "code" then
				entry.language = string.match(string.lower(attachment.name), "%.([%w]+)$")
			end
			parts[#parts + 1] = entry
		end
	end

	return parts
end

--- Lightweight manifest used in chat history and logs. Contains no file bytes.
function AttachmentEncoder.manifest(): { { name: string, mime: string, sizeBytes: number } }
	local list = {}
	for _, attachment in attachments do
		if attachment.accepted then
			list[#list + 1] = { name = attachment.name, mime = attachment.mime, sizeBytes = attachment.sizeBytes }
		end
	end
	return list
end

function AttachmentEncoder.reset()
	AttachmentEncoder.clear()
end

return AttachmentEncoder