# ForgePilot 3.5.0 — Provider Menu Fix, Icon & Auto Retry

Pembaruan ini tetap memakai versi **3.5.0**. Lihat [patch dan cara timpa](PATCH_3.5.0.md).

- Panel AI & Provider tidak lagi terkunci oleh status retry tes koneksi/capability. Tes gagal, Stop, dan timeout mengembalikan kontrol editor.
- Lapisan dropdown dilepas ketika panel disembunyikan, dinonaktifkan, dipindahkan, dihancurkan, atau widget ditutup; klik tidak tertahan oleh overlay yang tertinggal.
- Callback retry dari chat lama tidak mengubah tugas baru atau status Stop. Footer menjelaskan penguncian konfigurasi selama chat aktif.
- Tes diagnostik memakai satu percobaan per request tanpa mengubah preferensi Auto Retry chat; pemulihan chat tetap diuji dengan subscription retry produksi aktif.

- Ikon ForgePilot 512×512 disertakan; toolbar dan header memakai thumbnail plugin yang dipublikasikan.
- Error GetAncestors pada Lighting.Sky diperbaiki; nilai properti, boolean false, angka nol, tag, dan properti turunan dibaca dengan benar.
- Auto Retry kini bekerja untuk stream dan respons biasa. Bug tunggu yang membatalkan retry serta field angka yang tidak tersimpan diperbaiki.
- Preset OpenCode: base 2 detik, multiplier 2, jitter positif 25%, fallback maksimal 30 detik, default lima retry tambahan. Retry-After dan cooldown provider tetap dihormati.
- Status Retry: On/Off terlihat di chat. Stop/Cancel mengakhiri countdown; error permanen tidak diulang. Retry tidak menggandakan teks atau memutar ulang tool yang sudah selesai.

- 9router dan ForgePilot Bridge kembali memakai launcher terpisah pada Windows, macOS, dan Linux. Menghentikan satu layanan tidak menghentikan layanan lainnya.
- Installer hanya menyalin plugin ke folder Studio yang terdeteksi, dengan checksum dan backup.
- Streaming memakai idle timeout; jawaban aktif tidak berhenti karena batas total dua menit.
- Penutupan upstream sebelum completion ditampilkan sebagai error; teks parsial tetap tersedia. Output token yang terpotong dapat dilanjutkan otomatis sampai tiga kali.
- Agent mengikuti batas tool/build yang diatur dengan penjelasan yang terlihat; batas tersembunyi 12 putaran dihapus.
- Tool result, tool call, web activity, dan Thinking mempunyai kontrol expand/Close untuk hasil pendek maupun panjang.
- Enter mengirim pesan; Shift+Enter menyisipkan newline, termasuk fallback submit Studio.
- Chat baru memakai Build; Plan tersedia untuk perencanaan read-only.
- Ikon native Thinking, Custom Provider, web, tool, dan terminal melengkapi logo provider 9router.
- Petunjuk akses lokal dan setup GitHub tampil ketika bridge belum tersambung; kemampuan vision mengikuti model/adapter.
- Path Roblox dengan awalan game dan bentuk dotted/slash dapat di-resolve secara konsisten.
- Folder source, plugin build, runtime, launcher OS, tests, assets, dan docs disusun untuk repository GitHub.

Upgrade plugin dan bridge bersama. Tutup launcher gabungan lama, ekstrak paket lengkap, jalankan installer, lalu dua launcher baru dan pasangkan token terbaru. Node.js 22+ diperlukan.

Tes simulasi Luau dan tes Node disertakan. Pengujian Studio nyata, wrapper Windows/macOS, dan akun OAuth/provider nyata belum dilakukan dalam lingkungan rilis ini. Kuota dan dukungan model mengikuti penyedia.
