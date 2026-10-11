import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const exists = async candidate => fs.stat(candidate).then(() => true, () => false);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export async function detectPluginDirectory({ platform = process.platform, env = process.env, home = os.homedir(), explicit } = {}) {
  if (explicit) return path.resolve(explicit);
  if (platform === 'win32') {
    if (!env.LOCALAPPDATA) throw new Error('LOCALAPPDATA missing. Use --plugin-dir with Studio Plugins Folder.');
    return path.join(env.LOCALAPPDATA, 'Roblox', 'Plugins');
  }
  if (platform === 'darwin') {
    const defaultDir = path.join(home, 'Documents', 'Roblox', 'Plugins');
    const alternatives = [defaultDir, path.join(home, 'Library', 'Application Support', 'Roblox', 'Plugins'), path.join(home, 'Library', 'Roblox', 'Plugins')];
    const present = await Promise.all(alternatives.map(exists));
    return present.includes(true) ? alternatives[present.findIndex(Boolean)] : defaultDir;
  }
  if (platform !== 'linux') throw new Error('Unsupported OS. Use --plugin-dir with Studio Plugins Folder.');
  const data = env.XDG_DATA_HOME || path.join(home, '.local', 'share');
  const flatpak = path.join(home, '.var', 'app', 'org.vinegarhq.Vinegar', 'data');
  const prefixes = env.WINEPREFIX ? [env.WINEPREFIX] : [
    path.join(data, 'vinegar', 'prefixes', 'studio'), path.join(data, 'vinegar', 'prefix'),
    path.join(flatpak, 'vinegar', 'prefixes', 'studio'), path.join(flatpak, 'vinegar', 'prefix'),
    path.join(home, '.wine'),
  ];
  const found = [];
  for (const prefix of prefixes) {
    const users = path.join(prefix, 'drive_c', 'users');
    for (const user of await fs.readdir(users, { withFileTypes: true }).catch(() => [])) {
      if (!user.isDirectory() || user.name.toLowerCase() === 'public') continue;
      const roblox = path.join(users, user.name, 'AppData', 'Local', 'Roblox');
      if (await exists(roblox)) found.push(path.join(roblox, 'Plugins'));
    }
  }
  // New Wine/Vinegar prefixes can redirect AppData to XDG data directories.
  for (const root of [data, flatpak]) if (await exists(path.join(root, 'Roblox'))) found.push(path.join(root, 'Roblox', 'Plugins'));
  const unique = [...new Set(await Promise.all(found.map(async f => {
    const parent = await fs.realpath(path.dirname(f)).catch(() => path.dirname(f)); return path.join(parent, 'Plugins');
  })))];
  if (unique.length === 1) return unique[0];
  if (unique.length > 1) throw new Error('Multiple Studio plugin folders found. Use --plugin-dir:\n' + unique.join('\n'));
  throw new Error('No Studio Wine/Vinegar folder found. Open Plugins Folder in Studio and run Install-ForgePilot.sh --plugin-dir "<path>". Roblox Studio has no native Linux build.');
}

async function studioRunning() {
  try {
    if (process.platform === 'win32') {
      const { stdout } = await exec('tasklist.exe', ['/FO', 'CSV', '/NH'], { timeout: 3000, maxBuffer: 2 * 1024 * 1024, windowsHide: true });
      return /"RobloxStudio(?:Beta)?\.exe"/i.test(stdout);
    }
    const { stdout } = await exec('pgrep', ['-f', '[R]obloxStudio(Beta)?(\\.exe)?'], { timeout: 3000 });
    return !!stdout.trim();
  } catch (error) {
    if (error.code === 1) return false; // pgrep: no match
    return false; // unknown process utility; README still requires closing Studio
  }
}
export async function installPlugin(options = {}) {
  const root = options.packageRoot ?? PACKAGE_ROOT;
  const platform = options.platform ?? process.platform; const env = options.env ?? process.env; const home = options.home ?? os.homedir();
  const source = await fs.readFile(path.join(root, 'plugin', 'ForgePilot.rbxm'));
  const checksums = await fs.readFile(path.join(root, 'SHA256SUMS.txt'), 'utf8');
  const expected = checksums.match(/^([a-f0-9]{64})\s+plugin\/ForgePilot\.rbxm\r?$/mi)?.[1];
  if (!expected || sha256(source) !== expected.toLowerCase()) throw new Error('Plugin checksum mismatch. Extract the complete release ZIP again.');
  if (await (options.isStudioRunning ?? studioRunning)()) throw new Error('Close Roblox Studio before installing.');
  const directory = await detectPluginDirectory({ platform, env, home, explicit: options.pluginDirectory });
  const data = platform === 'win32' ? env.LOCALAPPDATA || home : platform === 'darwin' ? path.join(home, 'Library', 'Application Support') : env.XDG_DATA_HOME || path.join(home, '.local', 'share');
  const backupDir = path.join(data, 'ForgePilot', 'plugin-backups', Date.now() + '-' + randomBytes(4).toString('hex'));
  await fs.mkdir(directory, { recursive: true });
  const target = path.join(directory, 'ForgePilot.rbxm');
  const temp = target + '.' + randomBytes(8).toString('hex') + '.tmp';
  const backups = [];
  let installed = false;
  try {
    await fs.writeFile(temp, source, { flag: 'wx' });
    for (const name of ['ForgePilot.rbxm', 'ForgePilot.rbxmx']) {
      const old = path.join(directory, name);
      if (await exists(old)) {
        await fs.mkdir(backupDir, { recursive: true });
        const backup = path.join(backupDir, name);
        await fs.copyFile(old, backup); backups.push({ old, backup });
        await fs.rm(old);
      }
    }
    await fs.rename(temp, target);
    installed = true;
    if (sha256(await fs.readFile(target)) !== expected.toLowerCase()) throw new Error('Installed plugin verification failed.');
  } catch (error) {
    await fs.rm(temp, { force: true });
    if (installed) await fs.rm(target, { force: true }).catch(() => {});
    for (const record of backups) await fs.copyFile(record.backup, record.old);
    throw error;
  }
  return { directory, target, backupDir: backups.length ? backupDir : null };
}
async function main() {
  let pluginDirectory;
  for (let i = 2; i < process.argv.length; i++) {
    if (process.argv[i] === '--plugin-dir') { pluginDirectory = process.argv[++i]; if (!pluginDirectory) throw new Error('--plugin-dir needs a path.'); }
    else if (process.argv[i] === '--help') { console.log('Install-ForgePilot [--plugin-dir PATH]\nCopies the checked plugin to Studio Plugins Folder; backs up the previous copy. Does not start services or modify Studio application files.'); return; }
    else throw new Error('Unknown option: ' + process.argv[i]);
  }
  const result = await installPlugin({ pluginDirectory });
  console.log('ForgePilot installed: ' + result.target);
  if (result.backupDir) console.log('Previous plugin backup: ' + result.backupDir);
  console.log('Open Studio. Start 9router and ForgePilot Bridge separately using the scripts for your OS.');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => { console.error('ForgePilot installer: ' + error.message); process.exitCode = 1; });
