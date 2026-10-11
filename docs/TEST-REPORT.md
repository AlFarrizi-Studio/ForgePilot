# Verifikasi ForgePilot 3.5.0

Tanggal verifikasi: 2026-10-11. Paket ini diuji secara lokal dengan data/account fixture, tanpa credential provider nyata.

| Pemeriksaan | Hasil |
| --- | --- |
| Simulasi Luau pada module produksi | 659 pemeriksaan lulus; 0 kegagalan dan 0 warning |
| Tes Node | 27 lulus; 16 bridge dan 11 runtime/installer |
| Syntax Luau | 99 file compile tanpa error, termasuk harness yang dapat dibuat ulang |
| Build plugin | RBXM dan RBXMX berhasil dibangun dengan Rojo |
| Source hasil build XML | 88 script cocok dengan source: 1 main Script + 87 ModuleScript |
| JSON Schema wire | 372 definisi valid pada 6 protokol / 12 request fixture |
| POSIX wrapper | Syntax serta entry-point help Linux/macOS wrapper dijalankan pada Linux |
| Katalog/logo | Snapshot 82 provider / 75 PNG; byte PNG upstream dipertahankan |
| ZIP | CRC, byte comparison, checksum dan executable bits Unix diperiksa |

## Perilaku yang diperiksa

- Stream aktif melalui HTTP SSE lokal tetap berjalan melewati idle timeout; stream diam berhenti dan request berikutnya tetap dapat berjalan.
- Bridge polling dan watchdog plugin memperbarui timer pada data/heartbeat upstream; polling kosong tidak mengunci UI.
- EOF sebelum completion dilaporkan; actual agent mempertahankan teks parsial di samping error dan melepas run lock.
- Agent menyelesaikan 13 tool rounds lalu jawaban akhir; batas output otomatis memakai continuation internal dan batas build mencegah tindakan berikutnya.
- Enter melalui fallback native mengirim chat; Shift+Enter lewat fallback menyisipkan satu newline. Event duplikat tidak mengirim dua kali dan draft sibuk tetap tersedia.
- Detail pendek/panjang dapat dibuka/Close dengan viewport terbatas.
- Resolver Roblox menerima path service/anak dotted dan slash; registry memakai resolusi yang konsisten.
- Router dan bridge dapat dimulai/dihentikan independen; bridge tetap tersedia ketika router tidak aktif. Timeout/cancel/crash startup membersihkan child yang dimiliki launcher.
- Installer mendeteksi struktur path Windows/macOS/Wine/Vinegar, memeriksa checksum, mencadangkan plugin dan memulihkan kondisi saat gagal.
- Simulasi sebelumnya tetap mencakup adapter/provider, metadata capability, schema tools, UI berbagai ukuran panel, reasoning/text delta, retry/countdown/Cancel, generation guard, state lock, dan teardown.

## Batas bukti

Luau memakai engine mock dan scheduler deterministik, bukan Studio nyata. Layout/font, izin HTTP, file picker, keyboard/IME native dan lifecycle plugin dapat berbeda di Studio. Tes Node memakai file, HTTP, dan subprocess sungguhan di Linux; proses router adalah fixture yang menyediakan health endpoint, bukan paket 9router sungguhan.

Windows/macOS path handling disimulasikan. Wrapper CMD, macOS native launch/TCC, Wine/Vinegar aktif, OAuth/device login, real provider/model, serta web search publik belum diuji langsung. Status supported dari metadata bukan bukti setiap akun dapat memakai fitur tersebut. Verifikasi ini tidak menjamin seluruh penyedia/OS bebas error.

## Bukti yang disertakan

- [Hasil Luau](../tests/reports/luau-test-result.txt)
- [Hasil Node](../tests/reports/node-test-result.txt)
- [Hasil schema](../tests/reports/schema-test-result.txt)
- [Syntax](../tests/reports/syntax-test-result.json) dan [build](../tests/reports/build-test-result.json)
- [Katalog](../tests/reports/catalog-test-result.json)
- [Wire fixtures](../tests/luau/tool-request-fixtures.json) dan [provenance](../tests/luau/PROVENANCE.md)

Harness tidak dibundel karena dapat dibuat ulang dengan `python tests/luau/generate_harness.py`. Cara menjalankan dan membangun ulang tersedia di [CONTRIBUTING.md](../CONTRIBUTING.md).
