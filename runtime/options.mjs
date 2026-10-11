import path from 'node:path';
import os from 'node:os';

export function parseArguments(args, service) {
  const result = { port: service === 'router' ? 20128 : 20129, routerPort: 20128, fullAccess: true, workspace: path.join(os.homedir(), 'Downloads', 'ForgePilotWorkspace'), startupTimeoutMs: 180000, routerPackage: '9router@0.5.99' };
  const values = service === 'router' ? ['--port', '--startup-timeout', '--router-package'] : ['--port', '--router-port', '--workspace'];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--help' || arg === '-h') result.help = true;
    else if (service === 'bridge' && arg === '--workspace-only') result.fullAccess = false;
    else if (service === 'bridge' && arg === '--full-access') result.fullAccess = true;
    else if (values.includes(arg)) {
      const value = args[++i];
      if (!value || value.startsWith('--')) throw new Error('Missing value for ' + arg + '.');
      if (arg === '--workspace') result.workspace = path.resolve(value);
      else if (arg === '--router-package') result.routerPackage = value;
      else if (arg === '--startup-timeout') result.startupTimeoutMs = Number(value) * 1000;
      else result[arg === '--router-port' ? 'routerPort' : 'port'] = Number(value);
    } else throw new Error('Unknown ' + service + ' option: ' + arg);
  }
  for (const port of [result.port, result.routerPort]) if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Ports must be between 1 and 65535.');
  if (service === 'bridge' && result.port === result.routerPort) throw new Error('Bridge and router need different ports.');
  if (!Number.isFinite(result.startupTimeoutMs) || result.startupTimeoutMs < 1000 || result.startupTimeoutMs > 600000) throw new Error('Startup timeout must be 1-600 seconds.');
  if (!/^9router(?:@(?:latest|\d+\.\d+\.\d+))?$/.test(result.routerPackage)) throw new Error('Use 9router@<version> or 9router@latest.');
  return result;
}

export async function runService(start, options) {
  if (Number(process.versions.node.split('.')[0]) < 22) throw new Error('Node.js 22 or newer is required.');
  const controller = new AbortController();
  let instance; let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true; controller.abort();
    if (instance) await instance.close();
  };
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.once(signal, stop);
  try { instance = await start(options, { signal: controller.signal, onFailure: () => { process.exitCode = 1; } }); }
  catch (error) { if (!stopping) throw error; }
  if (stopping && instance) await instance.close();
}
