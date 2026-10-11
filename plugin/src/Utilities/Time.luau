--!strict
--[[
	ForgePilot / Utilities / Time
	Small time formatting helpers plus a monotonic id generator used for
	task IDs, action IDs and conversations.
]]

local Time = {}

Time._counter = 0

--- Monotonic, collision-free identifier with a readable prefix.
function Time.newId(prefix: string?): string
	Time._counter += 1
	local suffix = string.format("%x", math.floor(os.clock() * 1000000) % 0xFFFFFF):sub(-4)
	return string.format("%s-%d%s", prefix or "id", Time._counter, suffix)
end

--- Formats seconds as `8.4s` / `1m 04s` / `0.9s`.
function Time.formatDuration(seconds: number): string
	if seconds < 0 then
		seconds = 0
	end
	if seconds < 60 then
		return string.format("%.1fs", seconds)
	end
	local minutes = math.floor(seconds / 60)
	local remainder = math.floor(seconds % 60)
	if minutes < 60 then
		return string.format("%dm %02ds", minutes, remainder)
	end
	local hours = math.floor(minutes / 60)
	return string.format("%dh %02dm", hours, minutes % 60)
end

--- Formats a byte count for attachment rows.
function Time.formatBytes(bytes: number): string
	if bytes < 1024 then
		return string.format("%d B", bytes)
	elseif bytes < 1024 * 1024 then
		return string.format("%.1f KB", bytes / 1024)
	elseif bytes < 1024 * 1024 * 1024 then
		return string.format("%.1f MB", bytes / (1024 * 1024))
	end
	return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
end

--- Comma separated integer formatting for token counts.
function Time.formatNumber(value: number): string
	local rounded = math.floor(value + 0.5)
	local text = tostring(rounded)
	local sign = if string.sub(text, 1, 1) == "-" then "-" else ""
	text = string.sub(text, #sign + 1)
	local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = string.gsub(out, "^,", "")
	return sign .. out
end

--- Wall-clock stamp used in log rows and message headers.
function Time.timestamp(): string
	-- FormatLocalTime already renders in the viewer's local zone, so no
	-- ToLocal() step is needed (and the real engine rejects the call).
	return DateTime.now():FormatLocalTime("HH:mm:ss", "short")
end

function Time.clockNow(): number
	return os.clock()
end

return Time