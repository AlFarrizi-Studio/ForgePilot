# Sumber dan atribusi

## 9router

Referensi: https://github.com/decolua/9router

Snapshot katalog/logo: commit `ce4460ef79382bfddb4aa5fc0ff9f3cb0d5f95a8`. Paket berisi metadata tampilan untuk 82 provider chat yang terlihat pada kategori OAuth, free/freeTier dan API key, serta 75 PNG asli dari `public/providers`. Alias memakai `uiAlias || alias`. Credential/client secret OAuth upstream tidak disertakan.

Lisensi MIT upstream disalin ke `assets/9router-LICENSE.txt`. Nama/logo provider tetap berkaitan dengan pemilik mereknya. Runtime menjalankan paket npm 9router, bukan membundel source/binary layanan tersebut.

## Referensi lainnya

- OpenCode: https://github.com/anomalyco/opencode — referensi interaksi streaming/settings; source OpenCode tidak dibundel.
- Roblox HTTP/plugin API: https://create.roblox.com/docs/cloud-services/http-service dan https://create.roblox.com/docs/studio/plugins.
- Roblox Studio requirements: https://create.roblox.com/docs/studio/setup.
- Vinegar: https://github.com/vinegarhq/vinegar — konteks pemasangan Studio melalui Wine di Linux.
- Luau: https://github.com/luau-lang/luau — compiler/runtime verifikasi.
- Rojo: https://github.com/rojo-rbx/rojo — build RBXM/RBXMX.

Snapshot signature API dan versi tool yang dipakai dijelaskan di `tests/luau/PROVENANCE.md`. Paket tidak menetapkan lisensi baru untuk source ForgePilot; lihat panduan publikasi untuk memilih lisensi proyek.
