import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { parseArguments } from '../options.mjs';
import { startBridge } from '../bridge.mjs';
import { startRouter } from '../router.mjs';
import { detectPluginDirectory, installPlugin } from '../install.mjs';
const fixture = fileURLToPath(new URL('./fixtures/router.mjs', import.meta.url));
async function temp(t) { const root = await fs.mkdtemp(path.join(os.tmpdir(), 'forgepilot runtime ')); t.after(() => fs.rm(root, { recursive: true, force: true })); return root; }
async function port() { const server = http.createServer(); server.listen(0, '127.0.0.1'); await once(server, 'listening'); const p = server.address().port; await new Promise(r => server.close(r)); return p; }
function child(port, mode) { return spawn(process.execPath, [fixture, String(port), mode || ''], { detached: process.platform !== 'win32', stdio: 'ignore' }); }
test('separate launcher options are strict and bridge defaults to full access', () => {
  const defaults = parseArguments([], 'bridge'); assert.equal(defaults.fullAccess, true);
  assert.equal(parseArguments([], 'router').port, 20128);
  assert.equal(parseArguments(['--workspace-only', '--workspace', './with spaces'], 'bridge').fullAccess, false);
  for (const args of [['--port','0'], ['--port','20128'], ['--workspace'], ['--startup-timeout','1'], ['--unknown']]) assert.throws(() => parseArguments(args, 'bridge'));
  for (const args of [['--port','0'], ['--startup-timeout','0'], ['--router-package','9router; echo bad'], ['--workspace-only']]) assert.throws(() => parseArguments(args, 'router'));
});
const routerOptions = port => ({ ...parseArguments([], 'router'), port, startupTimeoutMs: 2000 });
test('bridge starts without 9router and never starts a router child', async t => {
  const instance = await startBridge({ workspace: await temp(t), port: 0, routerPort: await port() }, { log: () => {}, spawnRouter: () => { throw new Error('Must not spawn'); } });
  t.after(() => instance.close());
  const base = 'http://127.0.0.1:' + instance.bridge.server.address().port;
  const headers = { Authorization: 'Bearer ' + instance.bridge.token };
  const health = await fetch(base + '/health', { headers });
  const data = await health.json(); assert.equal(data.fullAccess, true); assert.equal(data.capabilities.streamIdleTimeout, true);
  await instance.close(); await assert.rejects(fetch(base + '/health', { headers }));
});
test('router launcher owns only its child and does not require a workspace or bridge', async t => {
  let spawns = 0;
  const instance = await startRouter(routerOptions(await port()), { log: () => {}, pollMs: 10, spawnRouter: p => { spawns++; return child(p); } });
  t.after(() => instance.close()); assert.equal(spawns, 1); assert.equal(instance.bridge, undefined);
  assert.equal((await fetch(instance.routerUrl + '/api/health')).status, 200);
  await instance.close(); assert(instance.child.exitCode !== null || instance.child.signalCode !== null);
});
test('stopping either service leaves the other service responsive', async t => {
  const router = await startRouter(routerOptions(await port()), { log: () => {}, pollMs: 10, spawnRouter: p => child(p) });
  const bridge = await startBridge({ workspace: await temp(t), port: 0, routerPort: new URL(router.routerUrl).port }, { log: () => {} });
  t.after(async () => { await bridge.close(); await router.close(); });
  const base = 'http://127.0.0.1:' + bridge.bridge.server.address().port;
  const headers = { Authorization: 'Bearer ' + bridge.bridge.token };
  await router.close(); assert.equal((await fetch(base + '/health', { headers })).status, 200);
  const replacement = await startRouter(routerOptions(await port()), { log: () => {}, pollMs: 10, spawnRouter: p => child(p) });
  t.after(() => replacement.close()); await bridge.close();
  assert.equal((await fetch(replacement.routerUrl + '/api/health')).status, 200);
});
test('an existing router is reused and survives router launcher shutdown', async t => {
  const server = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('{"ok":true}'); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening'); t.after(() => server.close());
  const instance = await startRouter(routerOptions(server.address().port), { log: () => {}, spawnRouter: () => { throw new Error('Must not spawn'); } });
  assert.equal(instance.reusedRouter, true); await instance.close();
  assert.equal((await fetch(instance.routerUrl + '/api/health')).status, 200);
});
test('router startup timeout cleans its child and does not hang', async t => {
  let spawned;
  await assert.rejects(startRouter({ ...routerOptions(await port()), startupTimeoutMs: 100 }, { log: () => {}, pollMs: 10, spawnRouter: p => spawned = child(p, 'never-ready') }), /startup timed out/);
  assert(spawned.exitCode !== null || spawned.signalCode !== null);
});
test('cancelling first-run router startup stops only its spawned child', async t => {
  const controller = new AbortController(); let spawned;
  const promise = startRouter({ ...routerOptions(await port()), startupTimeoutMs: 5000 }, { signal: controller.signal, log: () => {}, pollMs: 10, spawnRouter: p => { spawned = child(p, 'never-ready'); setTimeout(() => controller.abort(), 40); return spawned; } });
  await assert.rejects(promise, /cancelled/); assert(spawned.exitCode !== null || spawned.signalCode !== null);
});
test('a crashing router fails startup immediately', async t => {
  await assert.rejects(startRouter(routerOptions(await port()), { log: () => {}, pollMs: 10, spawnRouter: p => child(p, 'crash') }), /stopped/);
});
test('installer finds Windows, macOS and Linux Wine/Vinegar plugin folders', async t => {
  const root = await temp(t);
  assert.equal(await detectPluginDirectory({ platform: 'win32', env: { LOCALAPPDATA: root } }), path.join(root, 'Roblox', 'Plugins'));
  assert.equal(await detectPluginDirectory({ platform: 'darwin', env: {}, home: root }), path.join(root, 'Documents', 'Roblox', 'Plugins'));
  const prefix = path.join(root, 'wine prefix'); const roblox = path.join(prefix, 'drive_c', 'users', 'studio-user', 'AppData', 'Local', 'Roblox'); await fs.mkdir(roblox, { recursive: true });
  assert.equal(await detectPluginDirectory({ platform: 'linux', env: { WINEPREFIX: prefix }, home: root }), path.join(roblox, 'Plugins'));
  await assert.rejects(detectPluginDirectory({ platform: 'linux', env: {}, home: path.join(root, 'missing') }), /No Studio/);
  const custom = path.join(root, 'my plugin folder'); assert.equal(await detectPluginDirectory({ platform: 'linux', explicit: custom }), custom);
});
async function packageFixture(root) {
  const bytes = Buffer.from('fixture RBXM bytes'); await fs.mkdir(path.join(root, 'plugin')); await fs.writeFile(path.join(root, 'plugin', 'ForgePilot.rbxm'), bytes);
  await fs.writeFile(path.join(root, 'SHA256SUMS.txt'), createHash('sha256').update(bytes).digest('hex') + '  plugin/ForgePilot.rbxm\n');
  return bytes;
}
test('installer verifies bytes, backs up both plugin variants, and copies only the plugin', async t => {
  const root = await temp(t); const bytes = await packageFixture(root); const plugins = path.join(root, 'plugins'); await fs.mkdir(plugins);
  await fs.writeFile(path.join(plugins, 'ForgePilot.rbxm'), 'previous binary'); await fs.writeFile(path.join(plugins, 'ForgePilot.rbxmx'), 'previous XML');
  const result = await installPlugin({ packageRoot: root, pluginDirectory: plugins, platform: 'linux', home: root, env: {}, isStudioRunning: async () => false });
  assert.deepEqual(await fs.readFile(result.target), bytes);
  assert.equal(await fs.readFile(path.join(result.backupDir, 'ForgePilot.rbxm'), 'utf8'), 'previous binary');
  assert.equal(await fs.readFile(path.join(result.backupDir, 'ForgePilot.rbxmx'), 'utf8'), 'previous XML');
  assert.deepEqual(await fs.readdir(plugins), ['ForgePilot.rbxm']);
  await fs.writeFile(path.join(root, 'plugin', 'ForgePilot.rbxm'), 'corrupt');
  await assert.rejects(installPlugin({ packageRoot: root, pluginDirectory: plugins }), /checksum/);
  assert.deepEqual(await fs.readFile(result.target), bytes);
});
test('installer failure before replacement keeps the original plugin intact', async t => {
  const root = await temp(t); await packageFixture(root); const plugins = path.join(root, 'plugins'); await fs.mkdir(plugins);
  const target = path.join(plugins, 'ForgePilot.rbxm'); await fs.writeFile(target, 'previous binary');
  const blocked = path.join(root, 'blocked-data'); await fs.writeFile(blocked, 'file, not directory');
  await assert.rejects(installPlugin({ packageRoot: root, pluginDirectory: plugins, platform: 'linux', env: { XDG_DATA_HOME: blocked }, home: root, isStudioRunning: async () => false }));
  assert.equal(await fs.readFile(target, 'utf8'), 'previous binary'); assert.deepEqual(await fs.readdir(plugins), ['ForgePilot.rbxm']);
});
