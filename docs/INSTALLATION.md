# Instalasi dan upgrade

## Prasyarat

- [Node.js 22+](https://nodejs.org/) beserta npm/npx.
- Roblox Studio yang dapat membuka plugin lokal. Studio resmi tersedia untuk Windows/macOS; Linux memerlukan instalasi Wine/Vinegar yang telah berfungsi.
- Internet untuk pemasangan pertama 9router dan koneksi penyedia.
- Ekstrak **seluruh** ZIP; satu RBXM saja tidak berisi layanan Node/launcher.

Runtime memakai modul bawaan Node. `npm install` pada root ForgePilot tidak diperlukan. Launcher router mengunduh `9router@0.5.99` melalui npx, mengikat host ke `127.0.0.1`, dan menggunakan port 20128. Versi ini dipin sesuai CLI referensi; mengubah versi router dapat mengubah kontrak endpoint.

## 1. Pasang plugin

Tutup Studio, lalu jalankan:

| OS | Installer | Folder otomatis |
| --- | --- | --- |
| Windows | `scripts/windows/Install-ForgePilot.cmd` | `%LOCALAPPDATA%\Roblox\Plugins` |
| macOS | `scripts/macos/Install-ForgePilot.command` | Default `~/Documents/Roblox/Plugins`; folder alternatif Roblox yang sudah ada turut diperiksa |
| Linux | `sh scripts/linux/Install-ForgePilot.sh` | Prefix `WINEPREFIX`, Wine, Vinegar/Flatpak, dan redirect AppData/XDG yang terdeteksi |

Installer memeriksa checksum `plugin/ForgePilot.rbxm`, mencadangkan RBXM/RBXMX lama, memasang satu RBXM, lalu memverifikasi byte hasilnya. Installer tidak menyalakan layanan, tidak mengubah PATH, dan tidak menulis ke application bundle/konten aplikasi Studio.

Jika folder berbeda, atau Linux menemukan beberapa prefix, buka **Plugins Folder** di Studio dan gunakan path tersebut:

```sh
npm run install:plugin -- --plugin-dir "/path/to/Plugins"
```

Contoh Windows:

```powershell
.\scripts\windows\Install-ForgePilot.cmd --plugin-dir "D:\StudioData\Plugins"
```

Jangan memasang RBXM dan RBXMX bersamaan. Nonaktifkan/hapus plugin ForgePilot lama dengan nama lain agar panel tidak ganda. Backup otomatis dicatat oleh installer.

## 2. Jalankan layanan terpisah

Buka launcher **Start-9Router** pada folder OS-mu, lalu buka **Start-ForgePilot-Bridge** pada terminal lain. Alternatif:

```sh
npm run start:router
```

Terminal kedua:

```sh
npm run start:bridge
```

Dashboard router: `http://127.0.0.1:20128/dashboard`. Bridge: `http://127.0.0.1:20129`. Biarkan kedua terminal terbuka saat memakai provider router dan akses lokal. Ctrl+C pada satu terminal hanya menutup layanan miliknya. Bridge tetap dapat melayani tool lokal dan provider langsung ketika router berhenti.

`npm start` juga hanya menjalankan bridge. Tidak ada launcher gabungan pada versi ini.

## 3. Pasangkan bridge

Buka ForgePilot di Studio. Izinkan permintaan HTTP melalui prompt Studio jika muncul. Masuk **Settings → Agent Access**, pastikan URL localhost benar, tempel token dari terminal bridge, kemudian **Connect bridge**.

Token baru dibuat setiap kali bridge dijalankan. Token hanya disimpan pada sesi plugin; pasangkan ulang setelah restart Studio/bridge. Endpoint dan preferensi non-secret tetap dapat disimpan. Token bridge bukan API key router dan bukan token OAuth.

Akses penuh mengikuti permission pengguna OS. Untuk scope satu folder:

```sh
npm run start:bridge -- --workspace-only --workspace "/path/to/project"
```

## 4. Sambungkan provider

Gunakan [panduan provider](PROVIDERS.md). Untuk OAuth, masuk dashboard 9router, sambungkan akun penyedia, refresh status/model di plugin, pilih model, lalu uji koneksi. API langsung dapat melewati router; pilih adapter/protokol yang sesuai.

Chat baru menggunakan Build. Mode percakapan lama tetap terlihat pada tombol mode; ganti ke Build bila ingin melakukan perubahan. Default lama dimigrasikan ke Build sekali saat upgrade; setelah itu pilihan default yang kamu simpan akan dihormati.

## Upgrade dari 3.4.1

1. Tutup Studio dan terminal launcher gabungan/bridge lama.
2. Ekstrak versi baru ke folder terpisah; jangan menumpuk file launcher lama.
3. Jalankan installer baru.
4. Jalankan dua launcher baru dari `scripts/<OS>/`.
5. Hubungkan token baru. Plugin menolak bridge lama yang belum menyediakan timeout idle.

## Parameter

| Layanan | Parameter |
| --- | --- |
| Bridge | `--workspace PATH`, `--workspace-only`, `--full-access`, `--port 20129`, `--router-port 20128` |
| Router | `--port 20128`, `--startup-timeout 180` (detik), `--router-package 9router@0.5.99` |
| Installer | `--plugin-dir PATH` |

Contoh port berbeda, pada dua terminal:

```sh
npm run start:router -- --port 20228
npm run start:bridge -- --port 20229 --router-port 20228
```

Ubah Bridge URL di Agent Access ke port baru. Untuk provider router yang sudah disimpan, sesuaikan Base URL-nya ke port router baru; nilai bawaan profil adalah `http://127.0.0.1:20128/v1`.
