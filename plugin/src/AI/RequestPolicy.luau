--!strict
local RequestPolicy = {}
local DENIAL = "Saya tidak bisa membantu membuat jailbreak, melewati pengamanan, atau mengambil kredensial dan informasi sensitif."
local function has(text: string, words: { string }): boolean
	for _, word in words do if text:find(word, 1, true) then return true end end
	return false
end
local function normalize(text: string): string
	return (text:lower():gsub("\u{200B}", ""):gsub("\u{200C}", ""):gsub("\u{200D}", ""):gsub("%s+", " "))
end

function RequestPolicy.evaluate(text: string): (boolean, string?)
	local value = normalize(text)
	local sensitive = has(value, { "password", "kata sandi", "private key", "seed phrase", "recovery phrase", "session cookie", "oauth token", "refresh token", "akun tertanam", "akun yang tertanam", "embedded account", "kredensial", "api key", "api_key" }) or (has(value, { "akun", "account" }) and has(value, { "tertanam", "embedded", "hardcoded" }))
	local extraction = has(value, { "extract", "ekstrak", "ambil", "curi", "steal", "dump", "reveal", "bongkar", "carikan", "reverse engineer", "rekayasa balik", "bypass" })
	if sensitive and extraction then return false, DENIAL end
	local defensive = has(value, { "blokir jailbreak", "block jailbreak", "cegah jailbreak", "detect jailbreak", "deteksi jailbreak", "jailbreak protection", "menolak jailbreak" })
	local bypass = has(value, { "ignore all previous instructions", "ignore previous instructions", "abaikan semua instruksi", "abaikan instruksi sebelumnya", "disable safety", "nonaktifkan pengamanan", "bypass safety", "tanpa aturan keselamatan" })
	local jailbreak = has(value, { "jailbreak", "dan mode", "unrestricted mode" }) and has(value, { "buat", "generate", "write", "berikan", "aktifkan", "enable", "prompt", "bypass" })
	if not defensive and (bypass or jailbreak) then return false, DENIAL end
	return true, nil
end

function RequestPolicy.checkTool(name: string, arguments: any): (boolean, string?)
	local path = ("/" .. tostring(arguments.path or arguments.cwd or "") .. " " .. tostring(arguments.command or arguments.source or arguments.newSource or "")):lower():gsub("\\", "/")
	if has(path, { ".ssh/id_", ".aws/credentials", "/login data", "/network/cookies", "/keychains/", "/wallet.dat" }) then return false, DENIAL end
	local value = tostring(arguments.command or arguments.query or arguments.source or arguments.newSource or "")
	return RequestPolicy.evaluate(value)
end
return RequestPolicy
