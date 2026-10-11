# ForgePilot

**Asisten AI multi-provider untuk Roblox Studio.** Chat, baca script, bangun objek, dan jalankan tool yang tersedia langsung dari panel Studio.

[Instalasi](docs/INSTALLATION.md) · [Provider](docs/PROVIDERS.md) · [Cara kerja](docs/HOW-IT-WORKS.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Verifikasi](docs/TEST-REPORT.md)

Repository: [AlFarrizi-Studio/ForgePilot](https://github.com/AlFarrizi-Studio/ForgePilot). Versi paket: **3.5.0**.

## Yang tersedia

- Chat dengan teks/reasoning yang muncul mengikuti data provider, tanpa antrean animasi typing setelah jawaban selesai.
- **Build sebagai mode awal chat baru**; Plan tersedia untuk pemeriksaan dan perencanaan tanpa perubahan.
- Pemeriksaan Workspace, hierarki Instance, script, Lighting, selection, dan UI.
- Pembuatan/edit objek, terrain, script Luau, serta GUI melalui tool tervalidasi.
- Panel Thinking, tool call, tool result, dan aktivitas web yang dapat dibuka/ditutup, termasuk hasil pendek. Hasil panjang memakai area scroll terbatas.
- **Enter mengirim chat; Shift+Enter membuat baris baru.** Tombol kirim berubah menjadi Stop saat agent bekerja.
- 82 preset router: 21 OAuth, 16 free/free-tier, 45 API key. Katalog ini merupakan snapshot referensi 9router, bukan jaminan semua akun/provider dapat dipakai.
- Logo provider dari 9router, serta ikon native untuk Thinking, Custom Provider, web, terminal, dan tool. Ikon tetap terlihat tanpa mengunduh asset Roblox tambahan.
- Bridge lokal untuk web search, membaca URL/file, mencari file, download, input gambar, editing, dan terminal sesuai mode/izin.

## Mulai menggunakan

Prasyarat: **Node.js 22+ dengan npm/npx** dan Roblox Studio. Bridge tidak memerlukan `npm install`; ia memakai modul bawaan Node. Pengunduhan 9router dan penggunaan provider membutuhkan internet.

1. Ekstrak ZIP lengkap. Tutup Roblox Studio dan jalankan installer OS-mu.
2. Jalankan **9router dan bridge secara terpisah**, masing-masing pada terminalnya.
3. Buka Studio → Plugins → ForgePilot. Izinkan permintaan HTTP jika Studio menampilkannya.
4. Buka **Settings → Agent Access**. Salin token dari terminal bridge, lalu **Connect bridge**.
5. Buka **AI & Provider**, tambah provider, pilih model, simpan, dan uji koneksi.
6. Untuk provider router, sambungkan akun/API key di dashboard 9router, refresh status dan model. Jika client API key router diwajibkan, isikan key tersebut juga.
7. Kirim pesan di tab Chat. Pilih Plan bila hanya ingin merencanakan; Build memungkinkan perubahan sesuai izin tool.

| OS | Pasang plugin | Terminal 9router | Terminal bridge |
| --- | --- | --- | --- |
| Windows | `scripts/windows/Install-ForgePilot.cmd` | `scripts/windows/Start-9Router.cmd` | `scripts/windows/Start-ForgePilot-Bridge.cmd` |
| macOS | `scripts/macos/Install-ForgePilot.command` | `scripts/macos/Start-9Router.command` | `scripts/macos/Start-ForgePilot-Bridge.command` |
| Linux | `sh scripts/linux/Install-ForgePilot.sh` | `sh scripts/linux/Start-9Router.sh` | `sh scripts/linux/Start-ForgePilot-Bridge.sh` |

Alternatif yang sama untuk semua OS, dari folder berisi README ini:

```sh
npm run install:plugin
npm run start:router
```

Pada terminal kedua:

```sh
npm run start:bridge
```

`npm start` menjalankan **bridge saja**. Installer hanya menyalin plugin dan membuat backup versi sebelumnya. Menghentikan bridge tidak menghentikan 9router; menghentikan 9router tidak menghentikan bridge.

Bridge mengaktifkan akses file seluas izin pengguna OS secara default. Untuk membatasinya ke workspace:

```sh
npm run start:bridge -- --workspace-only --workspace "/path/to/project"
```

## Pilih koneksi provider

| Koneksi | Cara mendapat akses | Yang perlu diisi |
| --- | --- | --- |
| OAuth via 9router | Sign in / Connect di dashboard, lalu login pada penyedia | Akun penyedia, model tersedia, dan client API key router bila diperlukan |
| Free/free-tier via 9router | Sambungkan penyedia sesuai persyaratannya | Akun/API key bila diperlukan; kuota gratis mengikuti penyedia |
| API key via 9router | Tambahkan key penyedia di dashboard | API key penyedia di 9router; key router terpisah bila diwajibkan |
| API langsung / Custom | Hubungkan endpoint API tanpa relay 9router | Base URL, protokol/adapter, model ID, metode auth, API key bila diperlukan |

**Login dashboard 9router, OAuth penyedia, dan client API key router adalah tiga hal berbeda.** Berhasil login belum membuktikan model menerima chat, tool calling, atau gambar. Gunakan Test connection dan pemeriksaan capability; lihat [panduan provider](docs/PROVIDERS.md).

## Cara chat dan tool bekerja

Plugin menyiapkan konteks place, percakapan, mode, dan daftar tool yang benar-benar tersedia. Adapter mengirim request ke endpoint model, lalu teks/reasoning diteruskan ke UI begitu datanya tiba. Jika model meminta tool, plugin memeriksa nama, argumen, mode, izin, dan konfirmasi yang diperlukan; hasil nyata dikirim kembali ke model sampai tugas selesai atau muncul batas/error yang jelas.

Tool Roblox berjalan di Studio. Tool web/file/terminal berjalan di bridge pada komputer pengguna. 9router menangani koneksi/model penyedia; bridge menangani akses lokal dan relay streaming. API langsung dapat digunakan tanpa 9router. Bridge tetap diperlukan untuk tool di luar Studio.

Timeout streaming mengukur **waktu tanpa data upstream**, bukan durasi total jawaban. Stream aktif, termasuk heartbeat provider, dapat berjalan melewati dua menit. Jika koneksi benar-benar diam, terputus sebelum selesai, atau provider mengirim error, teks parsial tetap tersedia dan chat bisa dipakai lagi. Batas output provider tertentu dilanjutkan otomatis sampai tiga kali; setelah itu plugin memberi penjelasan untuk melanjutkan secara manual.

## Batas kemampuan

| Kemampuan | Batas/syarat |
| --- | --- |
| Studio tanpa bridge | Chat API dan tool Roblox tetap tersedia; web search, URL fetch, file lokal, download, serta terminal belum tersedia. UI dan AI memberikan petunjuk setup. |
| Vision | Memerlukan model **dan adapter** yang menerima gambar. Bridge dapat membaca byte gambar, tetapi tidak menambahkan vision ke model teks. |
| Audio/video/dokumen | Bergantung pada model, adapter, dan hasil capability check. Jangan menganggap setiap attachment dapat dipahami. Plugin tidak menyediakan generator media universal. |
| Web search | Menggunakan DuckDuckGo HTML atau endpoint SearXNG JSON pilihanmu. CAPTCHA, rate limit, dan halaman yang perlu login/JavaScript dapat menghalangi hasil. |
| Download/import asset | Download menyimpan file lokal; file tersebut tidak otomatis menjadi asset ID Roblox atau diterbitkan. |
| Akses penuh | Mengikuti akun/permission OS, scope bridge, mode, dan izin tool. Bukan izin administrator otomatis. Kedua layanan bind localhost. |
| Provider | Kuota, pembayaran, model tersedia, kebijakan OAuth, dan rate limit mengikuti penyedia. Kategori gratis tidak berarti tanpa batas atau gratis selamanya. |
| Linux | Launcher Node tersedia; Roblox Studio belum memiliki build Linux resmi. Installer mendeteksi Wine/Vinegar yang sudah terpasang. |
| Verifikasi | Simulasi Luau dan tes Node disertakan. Studio nyata, wrapper Windows/macOS, serta akun OAuth/provider nyata belum diuji pada lingkungan rilis ini. |

Batas ukuran, timeout, dan contoh error dijelaskan di [troubleshooting](docs/TROUBLESHOOTING.md). API key plugin dan token bridge disimpan untuk sesi berjalan; detail penyimpanan akun OAuth mengikuti 9router. Jangan memasukkan credential ke chat atau commit repository.

## Struktur repository

| Folder/file | Isi |
| --- | --- |
| `plugin/` | RBXM/RBXMX hasil build dan source Luau di `plugin/src/` |
| `scripts/` | Installer dan dua launcher terpisah untuk Windows, macOS, Linux |
| `runtime/` | Entry point Node, deteksi folder plugin, dan pengelolaan proses router |
| `bridge/` | Server localhost, metadata provider, dan tes Node bridge |
| `assets/` | Logo provider beserta atribusi upstream |
| `tests/` | Harness/simulasi Luau, fixture, dan laporan verifikasi |
| `docs/` | Panduan pengguna, arsitektur, troubleshooting, dan publikasi |
| `SHA256SUMS.txt` | Checksum file paket; installer memverifikasi RBXM dengannya |

Untuk mengembangkan atau build ulang, baca [CONTRIBUTING.md](CONTRIBUTING.md). Untuk menyiapkan GitHub Release, baca [publikasi](docs/PUBLISHING.md) dan [catatan rilis](docs/RELEASE_NOTES.md). Atribusi dan status lisensi berada di [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
