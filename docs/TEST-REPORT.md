# Verifikasi ForgePilot 3.5.0

Tanggal verifikasi: 2026-10-12. Paket ini diuji secara lokal dengan data/account fixture, tanpa credential provider nyata.

| Pemeriksaan | Hasil |
| --- | --- |
| Simulasi Luau pada module produksi | 776 pemeriksaan lulus; 0 kegagalan dan 0 warning |
| Tes Node | 27 lulus; 16 bridge dan 11 runtime/installer |
| Syntax Luau | 102 file compile tanpa error, termasuk harness yang dapat dibuat ulang |
| Build plugin | RBXM dan RBXMX berhasil dibangun dengan Rojo |
| Source hasil build XML | 88 script cocok dengan source: 1 main Script + 87 ModuleScript |
| JSON Schema wire | 372 definisi valid pada 6 protokol / 12 request fixture |
| POSIX wrapper | Syntax serta entry-point help Linux/macOS wrapper dijalankan pada Linux |
| Katalog/logo | Snapshot 82 provider / 75 PNG; byte PNG upstream dipertahankan |
| ZIP | CRC, byte comparison, checksum dan executable bits Unix diperiksa |

## Patch menu provider

- Regresi awal mereproduksi 15 kegagalan sebelum perbaikan, termasuk panel terkunci setelah tes gagal serta overlay dropdown tertinggal. Bukti ringkas ada di [provider-freeze-reproduction.json](../tests/reports/provider-freeze-reproduction.json).
- Subscription RetryStateManager produksi diaktifkan selama pengujian. HTTP 401/429/503 pada tes koneksi dan kegagalan stream tidak mengambil state chat; kontrol editor kembali aktif.
- Request diagnostik benar-benar memakai satu percobaan walaupun Auto Retry chat aktif. Preferensi retry pengguna tetap sama.
- Agent runTask, stream controller, subscription retry, dan panel provider diuji bersama: HTTP 503 pulih setelah retry, state recovery tampil, run lock dilepas, dan teks thinking lama dibersihkan.
- Event retry tanpa task ID, dari chat berbeda, sesudah completion, atau saat Stop tidak mengambil state tugas lain. Penguncian konfigurasi chat aktif dijelaskan di footer.
- Menu beserta MenuDismiss ditutup saat editor disembunyikan, tombol dinonaktifkan, panel dilepas, widget ditutup, atau view dihancurkan.
- Patch menu provider menambah 31 pemeriksaan dan mencapai 729 lulus pada baseline sebelum patch kontrol chat. Ini bukan pengujian interaksi native Studio.

## Patch kontrol chat dan penghapusan budget tool/build

- Regresi awal mereproduksi 8 kegagalan Question, jawaban kustom, Shift+Enter, Always Approve, dan panel Provider Limit sebelum perbaikan.
- Widget Question dan QuestionManager produksi diuji bersama: opsi dengan ID berbeda dari label, custom single/multiple, urutan pilihan, field wajib kosong, false/0, kartu lama, dan hasil yang dilipat/bisa dibuka ulang.
- Native InputObject membawa modifier Shift pada FocusLost tanpa event Shift terpisah. Kursor/seleksi yang direset saat blur dipulihkan; event ganda tidak menambah newline atau mengirim dua kali.
- Always Approve menyetujui aksi saat ini, menyimpan preferensi saat reload, mengikuti switch Settings, dan mempertahankan izin tool serta Plan. Decline tetap berfungsi.
- Question dan Provider Limit memakai viewport bounded dengan Close; countdown hidup saat dilipat dan panel recovered kembali ringkas. Tombol Question/persetujuan diperiksa pada lebar 300/440/760.
- Agent menjalankan 64 putaran tool native, 210 build actions, dan 55 aksi structured tanpa budget jumlah/round. Stop melalui chat melepaskan task tanpa menjalankan aksi berikutnya.
- Status batch tool memakai snapshot agar hasil tiap aksi tidak membangun ulang seluruh batch. Mock registry melepas instance yang telah dihancurkan agar lifecycle fixture mendekati engine.
- 47 pemeriksaan tambahan lulus; total terbaru 776 tanpa warning. Bukti ringkas ada di [chat-controls-reproduction.json](../tests/reports/chat-controls-reproduction.json).

## Patch ikon, Sky dan Auto Retry

- Reproduksi Lighting.Sky memakai API mock yang menolak metode invalid; properti Sky, tag, false/zero dan turunan Part dibaca dengan benar.
- Pengendali retry memakai task.wait normal, mencoba ulang setelah jeda, dan berhenti saat Cancel tanpa menunggu cooldown panjang.
- Preset OpenCode diuji terhadap urutan 2/4/8/16/30 detik, jitter positif, Retry-After dan fallback terbatas meskipun terdapat header lain.
- Jalur sendTurn produksi memulihkan partial stream, EOF dan idle timeout tanpa duplikasi teks/reasoning atau tool call parsial.
- Batas percobaan, retry disabled, error permanen HTTP/SSE dan pemulihan output parsial saat exhausted diuji.
- Field angka Retry tersimpan pada key runtime ketika blur; shortcut chat mengikuti Enabled/Disabled; header memakai thumbnail dan native fallback.
- HTTP bridge Node meneruskan status, body error, Retry-After, retry-after-ms dan reset header tanpa cookie upstream.

## Perilaku yang diperiksa

- Stream aktif melalui HTTP SSE lokal tetap berjalan melewati idle timeout; stream diam berhenti dan request berikutnya tetap dapat berjalan.
- Bridge polling dan watchdog plugin memperbarui timer pada data/heartbeat upstream; polling kosong tidak mengunci UI.
- EOF sebelum completion dilaporkan; actual agent mempertahankan teks parsial di samping error dan melepas run lock.
- Agent menyelesaikan 13 tool rounds lalu jawaban akhir; batas output otomatis memakai continuation internal. Pengujian terbaru juga mencakup task tanpa budget jumlah tool/build dan Stop saat task masih berjalan.
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
