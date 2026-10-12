# Cara kerja dari pesan sampai hasil

## Komponen

| Komponen | Tugas |
| --- | --- |
| Plugin Studio | UI, percakapan, mode, konteks place, adapter provider, dan tool Roblox |
| 9router | Login/koneksi penyedia dan relay API/model untuk profil router |
| ForgePilot Bridge | Web/file/download/terminal, dashboard bridge, dan relay stream yang bisa dipantau lewat request pendek |

Router dan bridge adalah layanan terpisah. Provider API langsung tidak memerlukan router. Plugin masih bisa memakai chat/Roblox tools tanpa bridge, selama API dan izin HTTP Studio tersedia. Saat fitur lokal tidak tersedia, banner dan instruksi per-turn memberi petunjuk setup melalui repository ForgePilot.

## Satu giliran chat

1. Enter atau tombol Send menyimpan pesan pada percakapan aktif; Shift+Enter hanya mengubah draft.
2. Agent menyiapkan konteks selection/place, riwayat yang relevan, ringkasan jika context penuh, mode, dan daftar tool yang tersedia.
3. Adapter membentuk request sesuai protokol endpoint. Profil router memakai endpoint router; profil langsung memakai API penyedia.
4. Teks dan reasoning yang benar-benar diterima diteruskan ke UI segera. Plugin tidak menciptakan reasoning model atau mengetik ulang jawaban setelah selesai.
5. Bila model meminta tool, argumen dan izin diperiksa. Tool Roblox berjalan di Studio; tool eksternal berjalan di bridge. Konfirmasi yang diperlukan ditampilkan pada panel.
6. Tool result mencatat hasil aktual/verified atau kegagalan. Hasil kembali ke model untuk langkah berikutnya.
7. Completion provider mengakhiri giliran. Agent melanjutkan tool rounds sampai jawaban selesai, dibatalkan pengguna, atau mencapai limit dengan penjelasan.

Input tetap terjaga ketika task aktif. Stop membatalkan stream/retry/tool; cleanup melepaskan lock sehingga chat berikutnya dapat berjalan. History menyimpan manifest attachment, bukan byte media; untuk retry setelah restart, pilih ulang file yang diperlukan.

## Build dan Plan

**Build** adalah default chat baru. Agent dapat mengubah place/file dengan tool yang diizinkan. Izin tool, konfirmasi destructive, dan konfirmasi write tetap berlaku; default Build tidak otomatis menyetujui semua tindakan.

**Plan** membatasi agent pada pembacaan/pemeriksaan. Ia dapat menyusun rencana tetapi tidak membuat/edit objek, download, atau mengeksekusi terminal. Tombol mode di composer mengubah mode percakapan; Builder dan Settings memberi akses ke preferensi/izin yang sama.

## Stream aktif dan timeout

Bridge memakai fetch streaming dan menyimpan event bercursor. Plugin membaca batch melalui short long-poll yang memberi kesempatan kepada UI scheduler. Komentar SSE/heartbeat ikut dianggap aktivitas upstream.

Idle timeout dimulai ulang setiap ada data upstream; polling lokal kosong tidak memperpanjangnya. Jadi jawaban aktif yang berlangsung lama tidak dipotong hanya karena lewat dua menit. Watchdog agent memiliki tambahan waktu cleanup dan menghormati durasi tunggu retry yang dijadwalkan.

Jika koneksi ditutup tanpa marker selesai protokol, hasil parsial dipertahankan dan error ditampilkan. Jika provider memberi finish reason batas token, agent meminta kelanjutan sampai tiga kali. Putaran tambahan memakai konteks jawaban sebelumnya; kelanjutan teks yang tepat tetap bergantung pada model. Jumlah tool call, build action, dan putaran tool tidak memakai budget task. Agent melanjutkan hingga selesai, Stop, atau error, serta memberikan giliran pada scheduler di antara aksi/putaran agar UI tetap merespons.

## Vision dan referensi

`view_image` membaca gambar nyata dari bridge dan menyiapkan input multimodal pada giliran berikutnya bila model/adapter mendukung. Attachment dari tombol Attach memakai file picker Studio dan pemeriksaan capability yang terpisah. Membaca byte file belum berarti model memahami gambar, PDF, audio, atau video.

`web_search` mengembalikan snippet dan URL. Agent perlu `web_fetch` untuk membaca halaman sebelum mengandalkan detailnya. Konten dinamis/login/CAPTCHA dapat gagal; kegagalan tersebut ditampilkan sebagai tool result, bukan hasil pencarian palsu. File hasil download tetap file lokal dan belum menjadi asset Roblox.

## Data dan scope

Bridge menerima request terautentikasi pada localhost. API key plugin/token pairing bersifat sesi; endpoint/profil non-secret dan riwayat percakapan dapat bertahan di pengaturan plugin. Data chat, konteks script yang disertakan, dan attachment yang diterima dikirim ke endpoint model pilihanmu.

Full access berarti scope file/terminal seluas permission akun OS, mengikuti mode dan pengaturan tool. Opsi workspace-only membatasi path file dan menonaktifkan terminal karena subprocess tidak bisa dikurung hanya dengan pembatasan path. Edit file membuat backup dan memakai hash untuk mendeteksi perubahan konkuren.
