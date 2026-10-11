# Pengembangan

Runtime membutuhkan Node.js 22+. Verifikasi/build Luau membutuhkan Luau compiler/runtime dan Rojo; executable tool tersebut tidak dibundel. Validator wire schema memerlukan Python 3 dan jsonschema.

```sh
npm test
python tests/luau/generate_harness.py
luau tests/luau/runtime-harness.luau
python -m pip install jsonschema
python tests/luau/validate_wire_schemas.py
rojo build plugin/src/default.project.json -o plugin/ForgePilot.rbxm
rojo build plugin/src/default.project.json -o plugin/ForgePilot.rbxmx
python tools/package_release.py
```

Setelah menambah tool, tangkap ulang baris `TOOL_REQUEST_JSON <protocol> <json>` dari harness menjadi array `{ "protocol": ..., "body": ... }` dalam `tests/luau/tool-request-fixtures.json`, lalu jalankan validator. Jangan mengirim credential nyata ke fixture. Simulasi API/scheduler/layout bukan pengganti uji Studio nyata.

Perubahan source harus disertai build plugin terbaru dan SHA256SUMS yang cocok. Script packaging hanya membuat arsip dari file saat ini; build dan tes perlu dijalankan sebelum packaging. Arsip memakai top-folder ForgePilot, mempertahankan executable bits Unix, dan mengecualikan workspace/cache/harness regenerable.

9router tidak dibundel; launcher menggunakan paket npm versi pin pada `runtime/options.mjs`. Perubahan pin perlu diverifikasi terhadap CLI, dashboard/API account, model alias, dan login flow upstream. Logo dan metadata snapshot mempunyai notice tersendiri di [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
