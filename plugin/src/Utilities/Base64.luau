--!strict
local HttpService = game:GetService("HttpService")
--[[
	ForgePilot / Utilities / Base64
	Pure-Luau base64 encoder/decoder for binary payloads.

	Roblox does not expose a base64 helper to plugins, and `HttpService:Base64Encode`
	only accepts strings (which cannot hold arbitrary binary safely), so the codec
	below operates on byte buffers directly. Data passed to the provider is always
	converted to a latin-1 string first, which is a lossless byte->codeunit mapping.
]]

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PAD = "="

-- Precomputed decode table: byte value -> 6-bit value, or nil when invalid.
local DECODE: { [number]: number } = {}
for index = 1, #ALPHABET do
	DECODE[string.byte(ALPHABET, index)] = index - 1
end

--- Converts a latin-1 (byte-per-codeunit) string into a buffer.
function Base64.stringToBuffer(data: string): buffer
	local buffer_ = buffer.create(#data)
	if #data == 0 then
		return buffer_
	end
	if typeof(buffer.write) == "function" then
		buffer.write(buffer_, 0, data)
	else
		-- Older/embedded runtimes expose only the u8 accessors.
		for index = 1, #data do
			buffer.writeu8(buffer_, index - 1, string.byte(data, index))
		end
	end
	return buffer_
end

--- Converts a buffer into a latin-1 string. Lossless for any byte value.
function Base64.bufferToString(buf: buffer): string
	local length = buffer.len(buf)
	if length == 0 then
		return ""
	end
	if typeof(buffer.read) == "function" then
		return string.char(buffer.read(buf, 0, length))
	end
	-- Fallback for runtimes that only expose the u8 accessors.
	local out = table.create(length)
	for index = 0, length - 1 do
		out[index + 1] = string.char(buffer.readu8(buf, index))
	end
	return table.concat(out)
end

--- Reads a Roblox `File` into a buffer via its binary contents (latin-1 string).
function Base64.fileToBuffer(file: Instance): (buffer?, string?)
	local ok, contents = pcall(function()
		return (file :: any):GetBinaryContents()
	end)
	if not ok or type(contents) ~= "string" then
		return nil, "File could not be read as binary content."
	end
	return Base64.stringToBuffer(contents), nil
end

--=============================================================================
-- ENCODE
--=============================================================================

--- Encodes a buffer as standard (padded) base64.
function Base64.encodeBuffer(buf: buffer): string
	local length = buffer.len(buf)
	if length == 0 then
		return ""
	end

	local pieces: { string } = {}
	local chunk: { [number]: number } = table.create(2048)
	local chunkCount = 0
	local out = table.create(math.ceil(length / 3) * 4)

	local i = 0
	while i < length do
		local b0 = buffer.readu8(buf, i)
		local b1: number = if i + 1 < length then buffer.readu8(buf, i + 1) else 0
		local b2: number = if i + 2 < length then buffer.readu8(buf, i + 2) else 0

		local n = b0 * 65536 + b1 * 256 + b2

		chunkCount += 1
		chunk[chunkCount] = string.byte(ALPHABET, math.floor(n / 262144) % 64 + 1)
		chunkCount += 1
		chunk[chunkCount] = string.byte(ALPHABET, math.floor(n / 4096) % 64 + 1)
		chunkCount += 1
		chunk[chunkCount] = if i + 1 < length
			then string.byte(ALPHABET, math.floor(n / 64) % 64 + 1)
			else string.byte(PAD)
		chunkCount += 1
		chunk[chunkCount] = if i + 2 < length
			then string.byte(ALPHABET, n % 64 + 1)
			else string.byte(PAD)

		if chunkCount >= 2048 then
			out[#out + 1] = string.char(table.unpack(chunk, 1, chunkCount))
			chunkCount = 0
		end

		i += 3
	end

	if chunkCount > 0 then
		out[#out + 1] = string.char(table.unpack(chunk, 1, chunkCount))
	end
	return table.concat(out)
end

--- Encodes a latin-1 string as base64.
function Base64.encode(data: string): string
	return Base64.encodeBuffer(Base64.stringToBuffer(data))
end

--=============================================================================
-- DECODE
--=============================================================================

--- Decodes base64 (padded or unpadded, whitespace tolerated) into a buffer.
--- Returns `nil` plus a message when the input contains invalid characters.
function Base64.decodeToBuffer(data: string): (buffer?, string?)
	local clean = data:gsub("[%s\r\n\t]", "")

	-- Split off trailing padding so the group walker knows which bytes are real.
	local padding = 0
	while #clean > 0 and string.byte(clean, #clean) == string.byte(PAD) do
		clean = string.sub(clean, 1, -2)
		padding += 1
	end
	if padding > 2 then
		return nil, "Invalid base64: too much padding."
	end

	local remainder = #clean % 4
	if remainder == 1 then
		return nil, "Invalid base64: truncated group."
	end

	local groupCount = math.floor(#clean / 4)
	local tail = string.sub(clean, groupCount * 4 + 1)

	local capacity = groupCount * 3
	if #tail > 0 then
		capacity += if #tail >= 4 then 3 elseif #tail >= 3 then 2 else 1
	end

	local out = buffer.create(capacity)
	local outIndex = 0

	local function writeByte(value: number)
		buffer.writeu8(out, outIndex, value)
		outIndex += 1
	end

	for group = 0, groupCount - 1 do
		local offset = group * 4
		local a = DECODE[string.byte(clean, offset + 1)]
		local b = DECODE[string.byte(clean, offset + 2)]
		local c = DECODE[string.byte(clean, offset + 3)]
		local d = DECODE[string.byte(clean, offset + 4)]
		if a == nil or b == nil or c == nil or d == nil then
			return nil, "Invalid base64: unexpected character in payload."
		end
		local n = a * 262144 + b * 4096 + c * 64 + d
		writeByte(math.floor(n / 65536) % 256)
		writeByte(math.floor(n / 256) % 256)
		writeByte(n % 256)
	end

	-- Final partial group: how many real characters it holds decides how many
	-- bytes were actually encoded.
	if #tail > 0 then
		local a = #tail >= 1 and DECODE[string.byte(tail, 1)] or 0
		local b = #tail >= 2 and DECODE[string.byte(tail, 2)] or 0
		local c = #tail >= 3 and DECODE[string.byte(tail, 3)] or 0
		if a == nil or b == nil or c == nil then
			return nil, "Invalid base64: unexpected character in payload."
		end
		local n = a * 262144 + b * 4096 + c * 64
		writeByte(math.floor(n / 65536) % 256)
		if #tail >= 3 then
			writeByte(math.floor(n / 256) % 256)
		end
		if #tail == 4 then
			writeByte(n % 256)
		end
	end

	return out, nil
end

--- Decodes base64 into a latin-1 string.
function Base64.decode(data: string): (string?, string?)
	local buf, err = Base64.decodeToBuffer(data)
	if not buf then
		return nil, err
	end
	return Base64.bufferToString(buf), nil
end

--=============================================================================
-- DATA URL
--=============================================================================

local MIME_BY_EXTENSION: { [string]: string } = {
	png = "image/png",
	jpg = "image/jpeg",
	jpeg = "image/jpeg",
	webp = "image/webp",
	gif = "image/gif",
	bmp = "image/bmp",
	txt = "text/plain",
	md = "text/markdown",
	csv = "text/csv",
	json = "application/json",
	xml = "application/xml",
	html = "text/html",
	css = "text/css",
	js = "text/javascript",
	ts = "text/plain",
	py = "text/x-python",
	lua = "text/plain",
	luau = "text/plain",
	pdf = "application/pdf",
	mp3 = "audio/mpeg",
	wav = "audio/wav",
	ogg = "audio/ogg",
	flac = "audio/flac",
	m4a = "audio/mp4",
	mp4 = "video/mp4",
	webm = "video/webm",
	avi = "video/x-msvideo",
	mov = "video/quicktime",
}

function Base64.mimeTypeFor(fileName: string): string
	local extension = string.match(string.lower(fileName), "%.([%w]+)$")
	if not extension then
		return "application/octet-stream"
	end
	return MIME_BY_EXTENSION[extension] or "application/octet-stream"
end

--- Builds a `data:` URL for providers that accept inline media.
function Base64.dataUrl(fileName: string, buf: buffer): string
	return string.format("data:%s;base64,%s", Base64.mimeTypeFor(fileName), Base64.encodeBuffer(buf))
end

return Base64