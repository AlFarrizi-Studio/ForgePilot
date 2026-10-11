import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnRouter, stopChild } from './processes.mjs';
import { parseArguments, runService } from './options.mjs';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function routerHealth(url, fetcher = fetch) {
  try {
    const response = await fetcher(url + '/api/health', { signal: AbortSignal.timeout(1200), redirect: 'error' });
    return response.ok && (await response.json()).ok === true;
  } catch { return false; }
}

export async function startRouter(options, runtime = {}) {
  const log = runtime.log ?? console.log;
  const routerUrl = 'http://127.0.0.1:' + options.port;
  const fetcher = runtime.fetch ?? fetch;
  let child = null; let closing; let ready = false; let failure;
  const close = () => {
    if (!closing) {
      runtime.signal?.removeEventListener('abort', close);
      closing = stopChild(child);
    }
    return closing;
  };
  try {
    if (runtime.signal?.aborted) throw new Error('Startup cancelled.');
    runtime.signal?.addEventListener('abort', close, { once: true });
    if (await routerHealth(routerUrl, fetcher)) {
      log('9router already running: ' + routerUrl + '/dashboard. This launcher owns no existing service.');
      return { child, close, routerUrl, reusedRouter: true };
    }
    if (closing || runtime.signal?.aborted) throw new Error('Startup cancelled.');
    log('Starting ' + options.routerPackage + '. First run may download npm packages.');
    child = (runtime.spawnRouter ?? spawnRouter)(options.port, options.routerPackage);
    const fail = message => {
      if (closing) return;
      failure = message;
      if (ready) { log(message + ' Restart Start-9Router.'); close().finally(() => runtime.onFailure?.(message)); }
    };
    child.once('error', error => fail('Cannot start 9router: ' + error.message));
    child.once('exit', (code, signal) => fail('9router stopped (' + (signal ?? code) + ').'));
    const deadline = Date.now() + options.startupTimeoutMs;
    while (!(await routerHealth(routerUrl, fetcher))) {
      if (failure) throw new Error(failure);
      if (Date.now() >= deadline) throw new Error('9router startup timed out. Check npm/network and restart Start-9Router.');
      if (closing) throw new Error('Startup cancelled.');
      await sleep(runtime.pollMs ?? 300);
    }
    if (closing || failure) throw new Error(failure ?? 'Startup cancelled.');
    ready = true;
    log('9router ready: ' + routerUrl + '/dashboard');
    log('Start-ForgePilot-Bridge is separate. Ctrl+C here stops only this router.');
    return { child, close, routerUrl, reusedRouter: false };
  } catch (error) { await close(); throw error; }
}

async function main() {
  const options = parseArguments(process.argv.slice(2), 'router');
  if (options.help) { console.log('Start-9Router [--port 20128] [--startup-timeout 180] [--router-package 9router@0.5.99]\nRuns only 9router. The ForgePilot bridge must be started separately.'); return; }
  await runService(startRouter, options);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => { console.error('ForgePilot 9router: ' + error.message); process.exitCode = 1; });
