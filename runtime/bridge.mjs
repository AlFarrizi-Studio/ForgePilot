import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createBridge } from '../bridge/server.mjs';
import { parseArguments, runService } from './options.mjs';

export async function startBridge(options, runtime = {}) {
  if (runtime.signal?.aborted) throw new Error('Startup cancelled.');
  await fs.mkdir(options.workspace, { recursive: true });
  const bridge = await createBridge({ workspace: options.workspace, fullAccess: options.fullAccess !== false, routerUrl: 'http://127.0.0.1:' + options.routerPort });
  let closing;
  const close = () => {
    if (!closing) {
      runtime.signal?.removeEventListener('abort', close);
      closing = bridge.close();
    }
    return closing;
  };
  try {
    const address = await bridge.listen(options.port);
    runtime.signal?.addEventListener('abort', close, { once: true });
    if (runtime.signal?.aborted) { await close(); throw new Error('Startup cancelled.'); }
    const log = runtime.log ?? console.log;
    log('\nForgePilot Bridge 3.5.0');
    log('Bridge: http://127.0.0.1:' + address.port);
    log('Workspace: ' + bridge.workspace);
    log('Access: ' + (bridge.fullAccess ? 'Full computer access (current OS user)' : 'Workspace only'));
    log('\nBridge token — paste in Settings > Agent Access:\n' + bridge.token + '\n');
    log('9router is separate. Run Start-9Router in another terminal for router providers.');
    log('Keep this terminal open. Ctrl+C stops only the bridge.\n');
    return { bridge, close };
  } catch (error) {
    await close();
    if (error.code === 'EADDRINUSE') throw new Error('Bridge port is in use. Stop the old bridge terminal before upgrading, or choose --port.');
    throw error;
  }
}

async function main() {
  const options = parseArguments(process.argv.slice(2), 'bridge');
  if (options.help) { console.log('Start-ForgePilot-Bridge [--workspace PATH] [--workspace-only] [--port 20129] [--router-port 20128]\nRuns only the bridge. Full access is enabled by default; start 9router separately.'); return; }
  await runService(startBridge, options);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => { console.error('ForgePilot Bridge: ' + error.message); process.exitCode = 1; });
