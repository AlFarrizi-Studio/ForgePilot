# Troubleshooting dan batas teknis

## Jawaban berhenti setelah beberapa menit

Upgrade plugin **dan bridge** ke 3.5.0. Tutup launcher gabungan lama, jalankan kedua layanan baru, lalu pasangkan token baru. Plugin menolak companion lama yang belum mengiklankan timeout idle.

Versi ini memakai timeout berdasarkan tidak adanya data upstream. Teks/reasoning/heartbeat provider yang terus masuk menjaga stream tetap berjalan; polling localhost kosong tidak dianggap aktivitas provider. Jika provider benar-benar diam, timeout tetap diperlukan agar task tidak mengunci UI. Pesan error dan teks parsial ditampilkan; Stop/cleanup melepaskan task.

Jika output limit provider tercapai, agent melanjutkan sampai tiga kali. Setelah itu, kirim Continue atau naikkan Max Output Tokens sesuai batas model. Jika provider mengakhiri respons secara normal dengan stop/end_turn, plugin mengikuti marker itu; ia tidak dapat memastikan maksud model di luar completion tersebut.

## Tool result atau Thinking terlalu panjang

Gunakan panah pada header untuk membuka/menutup. Hasil pendek dan panjang memiliki kontrol yang sama. Saat terbuka, hasil panjang dibatasi pada area scroll; tombol Close di bawah menutup panel. Copy menyalin isi detail penuh yang tersedia.

## Enter masih membuat paragraf

Pastikan memakai RBXM 3.5.0 dan tidak ada plugin versi lama yang aktif. Composer Chat menggunakan submit Return bawaan Studio dengan fallback FocusLost; Shift+Enter menyisipkan newline sendiri. Kotak editor/provider lainnya tetap dapat memakai Enter sesuai fungsi masing-masing. Keyboard native/IME pada Studio nyata belum diuji dalam lingkungan rilis ini.

## `No child named game.ServerScriptService`

Resolver kini menerima `game.ServerScriptService`, `ServerScriptService`, dan `game/ServerScriptService`, serta path anak bertitik atau `/`. Nama objek yang mengandung titik dapat memakai slash notation untuk menghindari ambiguitas. Bila anak benar-benar tidak ada, inspect parent lebih dahulu.

## Bridge tidak terhubung

- Jalankan Start-ForgePilot-Bridge dari paket lengkap dan biarkan terminal terbuka.
- Periksa Bridge URL dan token **terbaru**; jangan memakai API key router sebagai token bridge.
- Izinkan permintaan HTTP Studio ketika diminta. Periksa firewall/local permission OS jika localhost gagal.
- Port sedang digunakan: tutup bridge lama atau pilih `--port` baru dan sesuaikan URL plugin.

Banner akses hilang setelah pairing berhasil. Saat bridge tidak aktif, tool Roblox tetap tersedia; tool web/file/terminal belum tersedia. Panduan setup: [repository ForgePilot](https://github.com/AlFarrizi-Studio/ForgePilot).

## Router terhubung tetapi chat gagal

Login dashboard, OAuth penyedia, dan API key client router memiliki fungsi berbeda. Uji model setelah refresh status/model. Periksa quota akun, Base URL, model ID beralias yang benar, key router bila diwajibkan, dan protokol. Akun connected tanpa akses model masih dapat menghasilkan 401/403/429.

Test connection membuktikan request tertentu berhasil, bukan semua kemampuan. Vision/tool calling perlu diuji sesuai kebutuhan. Custom REST memerlukan pemetaan response yang benar. Jawaban satu potong berarti endpoint/Studio tidak menyediakan streaming atau streaming dimatikan; plugin tidak membuat animasi token palsu.

## Web search gagal

DuckDuckGo dapat meminta CAPTCHA atau mengubah HTML. Gunakan `web_fetch` pada URL referensi yang diketahui atau konfigurasikan environment `FORGEPILOT_SEARCH_URL` ke endpoint SearXNG yang menerima `q` dan `format=json`. Contoh Windows PowerShell sebelum menjalankan bridge:

```powershell
$env:FORGEPILOT_SEARCH_URL="https://your-search-host.example/search"
npm run start:bridge
```

Jangan menganggap endpoint contoh itu layanan publik yang sudah tersedia. Halaman login/JavaScript, blokir situs, proxy, serta koneksi internet tetap dapat menghalangi fetch.

## Batas runtime

| Operasi | Batas bawaan/maximum |
| --- | --- |
| Stream idle | 120 detik bawaan; profil menerima 1–600 detik tanpa data. Durasi total stream aktif tidak dibatasi oleh angka ini. |
| Watchdog agent | Idle profil + 20 detik cleanup; aktivitas dan tunggu retry memperbarui timer. |
| Tool bridge | 310 detik; polling plugin memiliki batas 320 detik total untuk satu tool. |
| Perintah terminal | 60 detik bawaan, maximum 300 detik, output dibatasi sekitar 60.000 karakter/byte. |
| Startup router | 180 detik bawaan; parameter 1–600 detik. |
| Tool/build per task | 40 tool call / 200 write action bawaan; dapat diatur di Settings → Agent. Pemeriksaan read tidak dihitung sebagai write. |
| Kelanjutan output token | Maksimum 3 kelanjutan otomatis; tool arguments yang terpotong tidak dieksekusi. |
| Download file | 64 MiB melalui bridge. |
| Gambar bridge | 4 MiB per gambar; PNG/JPEG/WebP/GIF dengan signature file yang cocok. |
| Baca teks bridge | File maximum 2 MiB, maximum 1.500 baris per panggilan. |
| Cari file | File maximum 1 MiB, maximum 100 hasil; git internals/node_modules/backup dilewati. |
| Web fetch | Response maximum 12 MiB; teks yang dikembalikan dibatasi maximum 60.000 karakter. |
| Relay stream | Maximum 24 MiB; buffer 6.000 chunk, batch 128 event, maximum 32 stream aktif. Consumer terlalu tertinggal menerima error. |
| Attachment picker | 20 MiB per file, 60 MiB total sebelum encoding; endpoint provider/transport dapat memiliki batas lebih kecil. |

Request non-streaming memakai timeout profil serta batas HttpService/endpoint yang berlaku. Menambah timeout profil tidak memperpanjang batas native Roblox yang tidak mendukungnya. Retry dapat memakai kuota tambahan. Provider tetap menentukan rate limit, panjang context, output token, dan modalitas.

## Installer tidak menemukan plugin

Buka Plugins Folder dari Studio dan gunakan `--plugin-dir`. Pada Linux, installer mendeteksi prefix yang sudah ada; ia tidak memasang Roblox Studio/Wine/Vinegar. Pada macOS, izin akses Documents dapat diperlukan. Tutup Studio sebelum memasang dan pastikan Node ditemukan di terminal/launcher.

## Checksum tidak cocok

Ekstrak ZIP lengkap tanpa mencampur file versi lain. Jika source diubah, build ulang RBXM/RBXMX dan jalankan `python tools/package_release.py` agar checksum dan ZIP sesuai. Jangan menghapus pengecekan checksum untuk melewati error.
