import { spawn } from 'node:child_process';
import { once } from 'node:events';

export async function stopChild(child, graceMs = 3000) {
  if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit').catch(() => {});
  if (process.platform === 'win32') {
    const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true });
    await Promise.race([once(killer, 'exit').catch(() => {}), new Promise(resolve => setTimeout(resolve, graceMs))]);
  } else {
    try { process.kill(-child.pid, 'SIGTERM'); } catch { child.kill('SIGTERM'); }
  }
  let timer;
  const stopped = await Promise.race([exited.then(() => true), new Promise(resolve => { timer = setTimeout(() => resolve(false), graceMs); })]);
  clearTimeout(timer);
  if (!stopped) {
    try { process.kill(-child.pid, 'SIGKILL'); } catch { child.kill('SIGKILL'); }
  }
}

export function spawnRouter(port, packageName = '9router@0.5.99') {
  const args = ['--yes', packageName, '--host', '127.0.0.1', '--port', String(port), '--no-browser', '--skip-update', '--log'];
  // Windows batch executables need cmd.exe. All interpolated arguments are
  // strictly constrained here; paths/workspace/user text never enter this shell.
  if (!/^9router(?:@(?:latest|\d+\.\d+\.\d+))?$/.test(packageName) || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid router package or port.');
  return process.platform === 'win32'
    ? spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', 'npx ' + args.join(' ')], { stdio: ['ignore', 'inherit', 'inherit'], windowsHide: true })
    : spawn('npx', args, { stdio: ['ignore', 'inherit', 'inherit'], detached: true });
}
