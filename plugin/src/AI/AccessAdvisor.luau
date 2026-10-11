--!strict
local BridgeClient = require(script.Parent.Parent.Core.BridgeClient)
local AccessAdvisor = {}
AccessAdvisor.setupUrl = "https://github.com/AlFarrizi-Studio/ForgePilot"
function AccessAdvisor.notice(text: string, report: any?): string?
	local input = text:lower()
	if not BridgeClient.isConnected() then
		for _, term in { "search", "web", "internet", "browse", "cari referensi", "download", "unduh", "local file", "file lokal", "https://", "http://" } do
			if input:find(term, 1, true) then
				return "Web dan file lokal belum tersedia karena bridge belum terhubung. Panduan: " .. AccessAdvisor.setupUrl .. ". Hubungkan lewat Settings > Agent Access."
			end
		end
	end
	if input:find("vision", 1, true) or input:find("lihat gambar", 1, true) or input:find("lihat foto", 1, true) then
		local vision = report and report.capabilities and report.capabilities.vision
		if not vision or vision.status ~= "supported" then return "Vision model ini belum didukung atau belum terverifikasi. Pilih model dan adapter yang menerima gambar; bridge saja tidak menambahkan vision ke model." end
	end
	return nil
end
return AccessAdvisor
