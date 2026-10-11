const denial = 'Request declined: jailbreaks and extraction of highly sensitive credentials are not allowed.';
export function checkRequest(text) {
  const value = String(text).toLowerCase().replace(/[\u200b-\u200d]/g, '').replace(/\s+/g, ' ');
  const sensitive = (/password|kata sandi|private key|seed phrase|recovery phrase|session cookie|oauth token|refresh token|akun (?:yang )?tertanam|embedded account|kredensial|api key|api_key/.test(value) || /akun|account/.test(value) && /tertanam|embedded|hardcoded/.test(value));
  const extracting = /extract|ekstrak|ambil|curi|steal|dump|reveal|bongkar|carikan|reverse engineer|rekayasa balik|bypass/.test(value);
  const defensive = /blokir jailbreak|block jailbreak|cegah jailbreak|detect jailbreak|deteksi jailbreak|jailbreak protection|menolak jailbreak/.test(value);
  const bypass = /ignore (?:all )?previous instructions|abaikan (?:semua instruksi|instruksi sebelumnya)|disable safety|nonaktifkan pengamanan|bypass safety|tanpa aturan keselamatan/.test(value);
  const jailbreak = /jailbreak|dan mode|unrestricted mode/.test(value) && /buat|generate|write|berikan|aktifkan|enable|prompt|bypass/.test(value);
  return sensitive && extracting || !defensive && (bypass || jailbreak) ? denial : null;
}
export function checkToolRequest(name, args) {
  const target = '/' + [args.path, args.cwd, args.command, args.source, args.newSource].filter(Boolean).join(' ').toLowerCase().replaceAll('\\', '/');
  if (['.ssh/id_', '.aws/credentials', '/login data', '/network/cookies', '/keychains/', '/wallet.dat'].some(p => target.includes(p))) return denial;
  return checkRequest(args.command || args.query || args.source || args.newSource || '');
}
