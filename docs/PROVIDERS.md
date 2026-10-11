# Menyambungkan provider dan model

## Tiga jenis preset router

Katalog tampilan diambil dari snapshot [9router](https://github.com/decolua/9router), commit `ce4460ef79382bfddb4aa5fc0ff9f3cb0d5f95a8`: **21 OAuth, 16 free/free-tier, 45 API key**. Ada 75 PNG provider; provider tanpa PNG memakai ikon native. Katalog tidak membuktikan semua provider masih aktif atau model/akunmu memiliki kuota.

Preset bertanda deprecated tetap terlihat sesuai referensi; gunakan sesuai status dan dukungan upstream saat ini.

## OAuth

1. Jalankan router dan bridge pada terminal terpisah, lalu pasangkan bridge di Agent Access.
2. Buka **AI & Provider**, pilih preset pada kelompok OAuth dan tambah profil.
3. Klik **Sign in / Connect in 9Router**. Bridge membuka halaman penyedia pada dashboard lokal.
4. Selesaikan login/device-code flow yang ditampilkan router/penyedia. Masukkan credential hanya pada form autentikasi yang sesuai.
5. Kembali ke plugin dan **Refresh status**. Status connected berarti akun terdaftar aktif di router, bukan bukti chat/model berhasil.
6. Klik **Refresh models**, pilih model yang tersedia, lalu simpan profil dan **Test connection**.

Jika dashboard meminta password, gunakan **Connect 9Router dashboard** di Agent Access. Password dashboard berbeda dari login OAuth penyedia. Jika endpoint `/v1` meminta client API key router, buat/copy key dari dashboard dan isikan pada profil plugin. Credential akun/token OAuth dikelola oleh 9router; plugin tidak menyalin token OAuth ke percakapan.

## Free/free-tier

Tambah preset, lalu sambungkan akun atau API key yang diminta penyedia melalui dashboard. Sebagian layanan memberi kredit sementara; sebagian memiliki kuota/RPM, model gratis terbatas, atau tetap meminta akun. Pilih model dari daftar yang benar-benar dikembalikan router. Label free/free-tier tidak menghapus aturan tersebut.

## API key melalui router

API key penyedia disimpan pada koneksi penyedia **di dashboard router**. Profil ForgePilot mengirim request ke API router dan memakai client API key router bila diwajibkan. Jangan menaruh key penyedia ke field token bridge, dan jangan menganggap kedua key selalu sama.

## API langsung dan Custom Provider

Pilih preset API langsung atau Custom, lalu isi:

| Field | Isi |
| --- | --- |
| Provider name | Nama tampilan yang mudah dikenali |
| Base URL | URL API penyedia, bukan halaman dashboard web |
| Protocol/adapter | OpenAI Chat, Responses, Anthropic, Gemini native/compatible, atau Custom REST sesuai kontrak endpoint |
| Endpoint path | Path yang benar untuk protokol yang dipilih; lihat URL preview sebelum menguji |
| Authentication | Bearer, header/API key, query, custom header, atau none bila endpoint memang tanpa auth |
| Model ID | ID yang disediakan endpoint; jangan menebak dari nama produk |
| API key | Key untuk API langsung, jika diperlukan; disimpan hanya pada sesi plugin |
| Streaming/tool calling | Aktifkan bila endpoint dan model mendukung; capability dapat diverifikasi di panel |

Custom REST membutuhkan pemetaan request/response. Koneksi yang berhasil mengembalikan teks belum tentu mendukung native tool calling, system instructions, gambar, atau format SSE.

## Model dan capabilities

Daftar model router difilter memakai alias penyedia dari snapshot. Metadata tools/vision/reasoning dari router dipakai sebagai petunjuk kemampuan; metadata tersebut bukan hasil pengujian akun nyata. Untuk API langsung, laporan menggabungkan informasi protokol, preset/model, dan probe yang dijalankan pengguna.

Probe dapat mengirim request sungguhan dan memakai kuota. Hanya status supported yang mengizinkan attachment tertentu diteruskan melalui adapter yang sesuai. Model dengan status vision unknown/unsupported tidak boleh diklaim sudah melihat gambar.

Jika native tool calling tidak tersedia, agent memakai protokol JSON action tervalidasi. Keberhasilan jalur ini bergantung pada model mengikuti format; output JSON rusak akan ditolak dan diberi penjelasan.

## Checklist koneksi nyata

1. Token bridge sudah berhasil dipasangkan jika fitur lokal/router management dibutuhkan.
2. Router hidup dan akun/key penyedia terhubung bila profil via-router.
3. Base URL dan model ID cocok dengan endpoint yang dipilih.
4. Auth/key untuk endpoint chat sudah benar.
5. Test connection berhasil, lalu kirim pertanyaan sederhana di Chat.
6. Uji tool/attachment yang diperlukan secara terpisah. Connected saja bukan bukti semua capability berhasil.

401/403 berarti autentikasi/izin perlu diperiksa; 429 berarti kuota/rate limit provider; 5xx berarti upstream/router gagal. ForgePilot tidak menghapus limit penyedia. Lihat [troubleshooting](TROUBLESHOOTING.md).
