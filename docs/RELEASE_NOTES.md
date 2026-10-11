# ForgePilot 3.5.0 — Separate Launchers & Chat Recovery

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
