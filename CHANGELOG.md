# Changelog

## 3.5.0 — 2026-10-11

- Separate router/bridge launchers for Windows, macOS, and Linux; plugin-only installer.
- Idle timeout across bridge, provider, and turn watchdog; partial-output recovery and explicit premature EOF.
- Native Return submission fallback, Shift+Return newline, and Build default for new chats.
- Collapsible bounded tool/reasoning details, completed icons, and missing-access setup hints.
- Visible tool/build/output limits; up to three output continuations; consistent Roblox paths.
- Organized source, runtime, scripts by OS, tests, assets, and user/developer documentation.

# Perubahan

## 3.4.1 — launcher lintas OS dan pemulihan timeout

- Gabungkan startup 9router dan bridge dalam satu runtime Node dan wrapper CMD/SH/COMMAND. Full access default, startup deadline/health check, reuse router aktif dan cleanup child pada Ctrl+C.
- Installer lintas OS hanya memasang plugin dengan checksum/backup. Deteksi Windows/macOS serta prefix Wine/Vinegar Linux; folder khusus dapat diberikan lewat --plugin-dir. Installer tidak mengubah konten aplikasi Studio.
- Job tool asinkron menggantikan request localhost yang menunggu operasi panjang. Loop polling selalu yield; Stop/timeout membatalkan job atau subprocess.
- Deadline mandiri pada stream/provider/turn, proteksi callback, cancel worker HTTP dan cleanup mencegah status sibuk tertinggal setelah timeout/error. Tes Agent run membuktikan tugas berikutnya dapat selesai.
- Tambahkan dokumen GitHub, atribusi, gitignore dan aturan line ending. Dua launcher startup lama diganti Start-ForgePilot.
- 609 pemeriksaan simulasi dan 23 tes Node lulus; 372 schema valid; 95 file lolos sintaks serta 85 script build cocok. Studio native, installer Windows/macOS dan OAuth akun nyata belum diuji.

## Agent Access 3.4 — file, web, login provider dan streaming

- Companion localhost dengan token sesi menyediakan 10 tools web, file, gambar, download dan terminal. Launcher memakai full access pengguna OS; opsi WorkspaceOnly tersedia. Plan tetap membaca/riset, Build dapat mengubah/download/menjalankan perintah.
- Write/edit membuat backup, memeriksa konflik SHA-256 dan memverifikasi hasil. Stop membatalkan stream dan subprocess. Hasil inspeksi Roblox kini meneruskan teks handler sebenarnya.
- Tambah 82 preset chat 9router dalam kategori OAuth, Free / Free tier dan API key, pencarian, pagination serta kontrol akun. Login OAuth berjalan melalui dashboard browser 9router, dengan refresh status/model dan password dashboard lokal bila diperlukan.
- Pakai 75 PNG logo asli 9router serta fallback native dari PNG yang sama. Installer menyalin aset logo lokal, dan lisensi upstream disertakan.
- HTTP localhost diizinkan untuk bridge/router. URL loopback mempertahankan scheme HTTP; endpoint remote tetap HTTPS. Prefix model mengikuti alias tampilan registry 9router dan tidak digandakan.
- Metadata `/v1/models` memperbarui dukungan tools/vision/reasoning dan batas token. Model router yang belum terdaftar memakai fallback aksi JSON; capability katalog dibedakan dari live probe.
- Jawaban dan thinking mengikuti delta stream tanpa timer typewriter/drain. Indikator thinking memakai tween; field reasoning ditampilkan terpisah ketika provider menyediakannya. SSE menjaga UTF-8 dan terminal event.
- Bridge token, password dashboard dan cookie tidak masuk prompt/persistensi setting. OAuth credential tetap dikelola 9router. Gambar tool hanya masuk turn berikutnya ketika model/protokol mendukung vision.
- 593 pemeriksaan simulasi dan 10 tes Node lulus; 372 schema valid; 94 file lolos sintaks dan source seluruh 85 script build cocok. Studio native dan akun provider nyata belum diuji.

## Perbaikan schema tool, freeze retry, ikon, dan keyboard

- Schema tool kosong mempertahankan object JSON pada `parameters`, `properties`, schema bersarang, dan argument function. Transport HTTP memakai encoder yang sama dengan adapter; array tetap array.
- Tipe schema `any` yang tidak valid dihilangkan. Panjang string memakai minLength/maxLength. Elemen create_ui dinyatakan sebagai object, dan posisi vector menerima komponen x/y/z yang didokumentasikan.
- Countdown retry tidak lagi memanggil fungsi yang membuat worker baru dari dalam worker itu sendiri. Satu ticker memberi jeda 250 ms dan dihentikan saat retry berjalan, dijeda, dibatalkan, atau kartunya dihapus.
- Kartu retry memakai ID tugas chat yang benar. Cancel Retry membatalkan tugas dan request terkait. Tombol kartu menyesuaikan panel sempit.
- Exception dan completion yang hilang pada streaming melepaskan status tugas aktif. Callback terlambat dari request yang dibatalkan tidak dapat membuka atau menimpa tugas berikutnya.
- Transisi dari kerja aktif menuju koneksi provider diterima oleh state machine. Retry mempertahankan pesan exception asli.
- Toast Sending your API key dihapus dari jalur pengiriman pesan; catatan host tetap tersedia pada Logs.
- Seluruh ikon yang ditampilkan menggunakan garis native, termasuk kontrol chat, dropdown, tombol log, dan History. Warna ikon mengikuti tema; ikon navigasi tidak disembunyikan pada panel sedang.
- Enter mengirim sekali. Shift+Enter menyisipkan satu baris baru pada kursor atau mengganti seleksi, mempertahankan fokus, dan tidak mengirim. Numpad Enter serta fallback FocusLost ditangani.
- 454 pemeriksaan simulasi lulus tanpa kegagalan atau peringatan. Validator JSON Schema standar menerima 156 definisi tool pada enam protokol. Pemeriksaan ini tidak memakai provider AI atau Roblox Studio nyata.

## Perbaikan draft Custom dan tes provider

- Custom OpenAI-Compatible dan Custom REST membuat draft yang dapat diedit sebelum URL atau schema diisi. Membuka draft tidak mengirim request.
- Isian draft dapat disimpan bertahap; validasi lengkap tetap berlaku untuk Save changes, aktivasi provider, dan tes.
- Apply schema mapping memakai hasil decode JSON dengan benar. Endpoint Path yang diedit manual ikut disimpan.
- Tes provider dijadwalkan setelah UI mendapat kesempatan merender status proses.
- Tombol Stop test membatalkan diagnostik. Deadline seluruh tes 60 detik; setiap request diagnostik maksimal 15 detik, dengan retry dinonaktifkan untuk tes.
- Request HTTP memantau deadline dan pembatalan sambil memberi waktu kepada scheduler. Opsi timeout native dikirim sebagai integer untuk memperpendek timeout.
- Probe protokol, refresh model, dan capability inspector meneruskan pembatalan. Stream yang belum selesai ditutup pada Stop atau timeout.
- Kontrol pulih setelah error, Stop, atau timeout; hasil terlambat diabaikan. Penutupan view menghentikan proses tes miliknya.

## Pembaruan Settings dan AI & Provider

- Navigasi Settings memakai sidebar pada panel lebar dan pemilih halaman pada panel sempit.
- AI & Provider membuka daftar profil tersimpan dan katalog preset, dengan pencarian dan status ringkas.
- Formulir provider dibagi menjadi Connection, Model, Advanced, dan Tests. Tombol Test connection dan Save changes tetap tersedia di bagian bawah.
- Menu More menampung Use for chat, Duplicate profile, Disconnect key, dan Remove profile. Membuka profil tidak lagi otomatis mengganti provider aktif.
- Ukuran tombol, sudut, jarak, judul, petunjuk isian, dan ikon navigasi diseragamkan. Ikon menu memakai garis native Roblox.
- Show/Hide mempertahankan key yang baru diketik. Key tetap disimpan hanya dalam memori sesi.
- Pilihan autentikasi, batas token otomatis/manual, model hasil refresh, dan mode Agent mengikuti nilai yang tersimpan.
- Memutus key profil lain tidak menonaktifkan provider chat. Mengedit profil lain tidak mengubah batas konteks percakapan aktif.
- Batas token manual dihormati oleh laporan kemampuan dan deteksi model. Laporan tanpa data harga tidak lagi menyebabkan exception pada ContextManager.
- Exception saat tes provider mengembalikan kontrol ke kondisi siap. Konfigurasi dikunci selama chat atau tes berjalan.
- Latensi tes memakai nilai hasil request. Tombol tes pada baris kemampuan menjalankan handler yang sama dengan tombol utama.
- Penghapusan view melepaskan langganan event provider dan state. Provider tanpa autentikasi dikenali siap tanpa key.

Referensi antarmuka: [OpenCode](https://github.com/anomalyco/opencode), terutama navigasi Settings dan pengelompokan provider. Implementasi menggunakan widget native Roblox Studio.

## Perbaikan chat dari paket sebelumnya

## Tampilan

- Chat memakai bubble pengguna, jawaban asisten yang lebih tenang, jarak yang konsisten, dan blok kode terpisah.
- Detail model, reasoning, dan hasil tool dilipat agar percakapan mudah dibaca.
- Composer menggabungkan lampiran, mode, provider, dan tombol kirim/Stop dalam satu area.
- Navigasi menyesuaikan lebar panel: ikon selalu tampil dan label ikut tampil saat lebar panel mencukupi.
- Dropdown tampil sebagai menu terbatas, bisa ditutup dari luar atau saat berpindah halaman.
- Tombol di halaman Data dan Retry mengikuti grid agar tetap muat.
- Indikator proses dan konteks dipadatkan; daftar Builder dapat digulir.
- API key memakai tampilan tersamarkan sampai tombol Show ditekan.

## Perbaikan perilaku

- Streaming memakai controller terpisah dari Instance Roblox dan menyelesaikan placeholder chat dengan benar.
- Edit mengganti cabang percakapan sebelumnya; regenerate memakai pesan pengguna yang sama.
- Draft tidak terhapus saat provider/model/key belum siap.
- Enter tidak mengirim dua kali ketika event TextBox dan PluginGui sama-sama diterima; Shift+Enter menjaga draft.
- Stop membatalkan permintaan, pertanyaan, dan persetujuan tanpa membuka tugas baru sebelum pekerjaan lama berakhir.
- Percakapan aktif tidak bisa diganti atau direset ketika tugas masih berjalan.
- Persetujuan tool benar-benar menunggu jawaban pengguna; persetujuan otomatis untuk baca tidak berlaku pada tool penulisan.
- Setiap putaran tool mempertahankan pesan asisten dan ID hasil tool; hasil gagal ditandai sebagai gagal.
- Hasil aksi terstruktur dan pasangan tool yang belum selesai tidak membentuk request native tool yang tidak valid.
- Data token yang tidak tersedia tidak lagi menghentikan tugas; input/output/reasoning dihitung dengan benar.
- Context editor dan lampiran tidak ditambahkan berulang ke seluruh riwayat chat.
- Pilihan provider/protokol, mode, toggle, dan reasoning effort tersinkron dengan profil yang dipilih.
- Isian provider disimpan saat kehilangan fokus, termasuk ketika langsung memilih tombol lain.
- Copy menyediakan dialog teks terpilih ketika akses clipboard langsung tidak tersedia.
- Log pertanyaan memakai parameter yang benar; teks log aman untuk RichText.
- Kegagalan bootstrap dilaporkan sesuai hasil inisialisasi; status tombol toolbar mengikuti jendela plugin.
- Tombol Check UI menjalankan pemeriksaan lokal yang disertakan dalam plugin.
