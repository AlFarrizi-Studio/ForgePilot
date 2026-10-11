# Publikasi ke GitHub

Ekstrak ZIP, lalu pakai folder ForgePilot sebagai root repository [AlFarrizi-Studio/ForgePilot](https://github.com/AlFarrizi-Studio/ForgePilot). README memakai tautan relatif dan semua launcher berada pada folder OS masing-masing.

## Repository baru/kosong

Dari folder yang berisi README:

```sh
npm test
git init
git add .
git commit -m "ForgePilot 3.5.0: separate launchers and chat recovery"
git branch -M main
git remote add origin https://github.com/AlFarrizi-Studio/ForgePilot.git
git push -u origin main
```

Jika repository sudah mempunyai commit, clone repository tersebut, salin perubahan paket ke checkout-nya, lalu review diff dan commit pada branch baru. Jangan mengganti history dengan force push. Pastikan logo dan notice lisensi upstream ikut diunggah. `.gitignore` mengecualikan workspace/cache/credential lokal/log, ZIP hasil packaging, dan harness yang dapat dibuat ulang.

## Release 3.5.0

Tag: **v3.5.0**. Judul: **ForgePilot 3.5.0 — Icon, Sky Fix & Auto Retry**. Gunakan [RELEASE_NOTES.md](RELEASE_NOTES.md) sebagai deskripsi, lampirkan `ForgePilot-3.5.0.zip`, dan optionally `plugin/ForgePilot.rbxm` sebagai unduhan plugin saja. Untuk patch ini, timpa file attachment rilis v3.5.0 yang sudah ada; panduan plugin Store dan ikon tersedia di [patch dan cara timpa](PATCH_3.5.0.md).

GitHub source archive otomatis memiliki perbedaan wrapper top-folder, tetapi path dalam repository tetap sama. Jalankan installer dari paket lengkap. RBXM saja dapat dipasang manual tetapi tidak berisi router/bridge.

Setelah perubahan source, build kedua plugin dan jalankan `python tools/package_release.py`. Script tersebut memperbarui SHA256SUMS dan menghasilkan ZIP dengan executable bits untuk wrapper Unix. Simpan/checksum paket rilis setelah seluruh tes dan build selesai.

## Lisensi dan klaim rilis

Kode proyek ini belum diberi lisensi baru oleh paket pembaruan. Jika ingin mengizinkan penggunaan open-source tertentu, pemilik proyek dapat memilih lisensi dan menambahkan LICENSE. Pertahankan MIT license upstream di `assets/9router-LICENSE.txt` dan [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

[Laporan tes](TEST-REPORT.md) membedakan simulasi, Node nyata, dan bagian yang belum diuji. Jangan mengklaim semua provider/OS telah diuji dengan akun/Studio nyata. Paket ini menyiapkan source dan dokumentasi; tidak melakukan push atau membuat release GitHub secara otomatis.
