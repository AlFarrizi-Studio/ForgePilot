import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { once } from 'node:events';
import { createBridge } from '../server.mjs';
import { checkRequest } from '../request-policy.mjs';

const TOKEN = 'bridge-test-token-only-0123456789abcdef';
async function setup(t, extra = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'forgepilot-'));
  const workspace = path.join(root, 'workspace'); await fs.mkdir(workspace);
  const bridge = await createBridge({ workspace, token: TOKEN, ...extra });
  const address = await bridge.listen(0); const base = `http://127.0.0.1:${address.port}`;
  t.after(async () => { await bridge.close(); await fs.rm(root, { recursive: true, force: true }); });
  const call = async (route, body, headers = {}, method) => {
    const response = await fetch(base + route, { method: method ?? (body ? 'POST' : 'GET'), headers: { Authorization: `Bearer ${TOKEN}`, ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
    return { status: response.status, data: await response.json() };
  };
  return { bridge, root, workspace, base, call, tool: (name, args, mode = 'build') => call('/tools', { name, arguments: args, mode }) };
}
test('pairing, origin protection, host validation and exact mode checks', async t => {
  const { call, tool, base } = await setup(t);
  assert.equal((await call('/health', null, { Authorization: '' })).status, 401);
  assert.equal((await call('/health', null, { Origin: 'https://example.test' })).status, 403);
  const hostStatus = await new Promise((resolve, reject) => { const req = http.request(new URL('/health', base), { headers: { Host: 'evil.test', Authorization: `Bearer ${TOKEN}` } }, res => { res.resume(); resolve(res.statusCode); }); req.on('error', reject); req.end(); });
  assert.equal(hostStatus, 403);
  assert.equal((await call('/health')).data.capabilities.streaming, true);
  for (const name of ['write_file', 'edit_file', 'download_file', 'run_command']) assert.equal((await tool(name, {}, 'plan')).status, 403);
  assert.equal((await tool('undeclared', {})).status, 400);
  assert.equal((await tool('run_command', { command: 'echo nope' })).status, 403);
});
test('real text read, directory listing, search, backup, exact editing and conflict guard', async t => {
  const { tool, workspace } = await setup(t);
  const saved = await tool('write_file', { path: 'src/app.luau', content: 'local hello = "world"\nreturn hello\n' });
  assert.equal(saved.data.verified, true);
  const read = await tool('read_file', { path: 'src/app.luau', startLine: 2, lineCount: 1 }, 'plan');
  assert.equal(read.data.data.content, '2: return hello');
  assert.equal((await tool('write_file', { path: 'src/app.luau', content: 'overwrite' })).status, 400);
  const changed = await tool('edit_file', { path: 'src/app.luau', oldText: 'world', newText: 'Roblox', expectedSha256: read.data.data.sha256 });
  assert.equal(changed.data.verified, true);
  assert.match(await fs.readFile(changed.data.data.backupPath, 'utf8'), /world/);
  assert.match(await fs.readFile(path.join(workspace, 'src/app.luau'), 'utf8'), /Roblox/);
  assert.equal((await tool('edit_file', { path: 'src/app.luau', oldText: 'hello', newText: 'x' })).status, 400);
  assert.equal((await tool('edit_file', { path: 'src/app.luau', oldText: 'Roblox', newText: 'x', expectedSha256: read.data.data.sha256 })).status, 409);
  const search = await tool('search_files', { path: '.', query: 'Roblox' }, 'plan');
  assert.equal(search.data.data.matches.length, 1);
  assert.equal(search.data.data.matches[0].line, 1);
  const listing = await tool('list_files', { path: '.', depth: 1 }, 'plan');
  assert(listing.data.data.entries.some(e => e.path === path.join('src', 'app.luau')));
  assert(!listing.data.data.entries.some(e => e.path.includes('.forgepilot-backups')));
});
test('workspace boundary catches absolute, traversal and symlink/junction escapes', async t => {
  const { root, workspace, tool } = await setup(t);
  const outside = path.join(root, 'outside'); await fs.mkdir(outside); await fs.writeFile(path.join(outside, 'private.txt'), 'outside');
  await fs.symlink(outside, path.join(workspace, 'link'), 'dir');
  for (const candidate of ['../outside/private.txt', path.join(outside, 'private.txt'), 'link/private.txt']) assert.equal((await tool('read_file', { path: candidate }, 'plan')).status, 403);
  assert.equal((await tool('write_file', { path: 'link/new.txt', content: 'no' })).status, 403);
  assert.equal((await fs.readdir(outside)).length, 1);
});
test('full access permits explicit outside paths and returns actual command exit/output', async t => {
  const { root, tool } = await setup(t, { fullAccess: true });
  const target = path.join(root, 'outside.txt');
  assert.equal((await tool('write_file', { path: target, content: 'authorized' })).data.verified, true);
  const command = await tool('run_command', { command: 'node -e "process.stdout.write(\'forgepilot-ok\')"' });
  assert.equal(command.data.ok, true); assert.match(command.data.message, /forgepilot-ok/);
  const bad = await tool('run_command', { command: 'node -e "process.exit(7)"' });
  assert.equal(bad.data.ok, false); assert.equal(JSON.parse(bad.data.message).exitCode, 7);
});
test('network fetch, HTML reference extraction, literal search URLs and binary download verification', async t => {
  const fetched = [];
  const fakeFetch = async input => {
    const url = String(input); fetched.push(url);
    if (url.includes('duckduckgo')) return new Response('<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fcreate.roblox.com%2Fdocs">Roblox Docs</a><a class="result__snippet">Official <b>reference</b>.</a>', { headers: { 'content-type': 'text/html' } });
    if (url.endsWith('asset.png')) return new Response(Buffer.from([137,80,78,71,13,10,26,10]), { headers: { 'content-type': 'image/png' } });
    return new Response('<title>Reference</title><script>ignore()</script><p>Read &amp; verify.</p>', { headers: { 'content-type': 'text/html' } });
  };
  const { tool, workspace } = await setup(t, { fetch: fakeFetch });
  const web = await tool('web_fetch', { url: 'https://docs.example/reference' }, 'plan');
  assert.equal(web.data.data.title, 'Reference'); assert.match(web.data.data.content, /Read & verify/); assert(!web.data.data.content.includes('ignore()'));
  const search = await tool('web_search', { query: 'Roblox & Luau' }, 'plan');
  assert.equal(search.data.data.results[0].url, 'https://create.roblox.com/docs'); assert(fetched.some(url => url.includes('q=Roblox%20%26%20Luau')));
  const downloaded = await tool('download_file', { url: 'https://assets.example/asset.png', path: 'assets/asset.png' });
  assert.equal(downloaded.data.data.bytes, 8); assert.equal((await fs.readFile(path.join(workspace, 'assets/asset.png'))).length, 8);
  const image = await tool('view_image', { path: 'assets/asset.png' }, 'plan');
  assert.equal(image.data.attachments[0].mime, 'image/png'); assert.equal(image.data.attachments[0].base64, 'iVBORw0KGgo=');
  assert.equal((await tool('web_fetch', { url: 'file:///etc/passwd' }, 'plan')).status, 400);
});
test('search challenge and missing results produce an explicit failure', async t => {
  const { tool } = await setup(t, { fetch: async () => new Response('<form id="challenge-form">Captcha</form>', { headers: { 'content-type': 'text/html' } }) });
  const result = await tool('web_search', { query: 'Roblox' }, 'plan'); assert.equal(result.data.ok, false); assert.match(result.data.message, /challenge/);
});
test('OAuth opens actual provider dashboard, checks active connections and filters account models', async t => {
  const opened = []; const requests = [];
  const fakeFetch = async (input, options) => {
    requests.push({ url: String(input), headers: options.headers });
    if (String(input).endsWith('/api/providers')) return Response.json({ connections: [{ id: 'a', provider: 'codex', name: 'User', isActive: true }, { id: 'b', provider: 'codex', isActive: false }, { id: 'c', provider: 'github', isActive: true }] });
    if (String(input).endsWith('/v1/models')) return Response.json({ data: [{ id: 'cx/model-a', capabilities: { tools: false, vision: true, reasoning: true, unrelated: 'ignored' }, context_length: 200000, max_completion_tokens: 16000 }, { id: 'gh/model-b' }] });
    throw new Error('Unexpected endpoint');
  };
  const { call } = await setup(t, { fetch: fakeFetch, openBrowser: async url => opened.push(url) });
  const open = await call('/providers/open', { providerId: 'codex' }); assert.equal(open.data.ok, true); assert.deepEqual(opened, ['http://127.0.0.1:20128/dashboard/providers/codex']);
  const status = await call('/providers/status', { providerId: 'codex' }); assert.equal(status.data.connected, true); assert.equal(status.data.accounts.length, 1); assert(!JSON.stringify(status).includes('token'));
  const models = await call('/router/models', { providerId: 'codex', apiKey: 'router-test-key' }); assert.deepEqual(models.data.models, ['cx/model-a']); assert.equal(requests.at(-1).headers.Authorization, 'Bearer router-test-key');
  assert.deepEqual(models.data.metadata['cx/model-a'], { capabilities: { tools: false, vision: true, reasoning: true }, contextWindow: 200000, maxOutputTokens: 16000 });
  assert(!models.data.metadata['gh/model-b']);
  assert.equal((await call('/providers/open', { providerId: '../settings' })).status, 400);
});
test('dashboard authentication keeps its session cookie in the bridge', async t => {
  let loginPassword; let receivedCookie;
  const fakeFetch = async (input, options) => {
    if (String(input).endsWith('/api/auth/login')) { loginPassword = JSON.parse(options.body).password; return Response.json({ success: true }, { headers: { 'set-cookie': '9router-dashboard=fixture-session; Path=/; HttpOnly' } }); }
    receivedCookie = options.headers.Cookie;
    return Response.json({ connections: [{ id: 'a', provider: 'codex', isActive: true }] });
  };
  const { call } = await setup(t, { fetch: fakeFetch });
  const login = await call('/router/login', { password: 'fixture-dashboard-password' });
  assert.equal(login.data.ok, true); assert.equal(loginPassword, 'fixture-dashboard-password');
  assert(!JSON.stringify(login.data).includes('fixture-session')); assert(!JSON.stringify(login.data).includes('fixture-dashboard-password'));
  assert.equal((await call('/providers/status', { providerId: 'codex' })).data.connected, true);
  assert.equal(receivedCookie, '9router-dashboard=fixture-session');
});
test('real HTTP stream relays split UTF-8/SSE bytes, terminal events and upstream errors', async t => {
  const upstream = http.createServer((req, res) => {
    if (req.url === '/error') { res.writeHead(429, { 'Content-Type': 'application/json' }); res.end('{"error":"rate limited"}'); return; }
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const payload = Buffer.from('data: {"choices":[{"delta":{"content":"Halo 日本"}}]}\n\ndata: [DONE]\n\n');
    const split = payload.indexOf(Buffer.from('日')) + 1;
    res.write(payload.subarray(0, split)); setTimeout(() => { res.write(payload.subarray(split)); res.end(); }, 25);
  }); upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening'); t.after(() => upstream.close());
  const { call } = await setup(t); const up = `http://127.0.0.1:${upstream.address().port}`;
  const started = await call('/stream', { url: up + '/ok', body: '{}', headers: {}, timeoutMs: 5000 });
  let cursor = 0; let content = ''; let done = false;
  for (let n = 0; n < 20 && !done; n++) { const poll = await call(`/stream/${started.data.id}?cursor=${cursor}`); content += poll.data.events.map(e => e.chunk).join(''); cursor = poll.data.cursor; done = poll.data.done; assert.equal(poll.data.error, null); }
  assert.equal(done, true); assert.match(content, /Halo 日本/); assert.match(content, /data: \[DONE\]/); assert(!content.includes('�'));
  const failed = await call('/stream', { url: up + '/error', body: '{}', headers: {} });
  let error;
  for (let n = 0; n < 20; n++) { const poll = await call(`/stream/${failed.data.id}?cursor=0`); if (poll.data.done) { error = poll.data.error; break; } }
  assert.match(error, /HTTP 429/);
});
test('cancelling a pending command kills its process and finishes the tool', async t => {
  const { call } = await setup(t, { fullAccess: true });
  const pending = call('/tools', { name: 'run_command', arguments: { command: 'node -e "setTimeout(()=>{},100000)"' }, mode: 'build', operationId: 'cancel-command' });
  await new Promise(resolve => setTimeout(resolve, 80)); await call('/cancel', { operationId: 'cancel-command' });
  const result = await pending; assert.equal(result.data.ok, false); assert.equal(JSON.parse(result.data.message).cancelled, true);
});
test('async tool jobs answer immediately and keep health responsive during a command', async t => {
  const { call } = await setup(t, { fullAccess: true });
  const started = await call('/tools/start', { operationId: 'async-command', name: 'run_command', arguments: { command: 'node -e "setTimeout(()=>process.stdout.write(\'async-ok\'),150)"' }, mode: 'build' });
  assert.equal(started.status, 202);
  assert.equal((await call('/health')).data.ok, true);
  assert.equal((await call('/tools/start', { operationId: 'async-command', name: 'read_file', arguments: {}, mode: 'plan' })).status, 409);
  let completed;
  for (let n = 0; n < 8; n++) { const poll = await call('/tools/async-command'); if (poll.data.done) { completed = poll.data; break; } }
  assert.equal(completed.result.ok, true); assert.match(completed.result.message, /async-ok/);
  assert.equal((await call('/tools/start', { operationId: 'plan-write', name: 'write_file', arguments: {}, mode: 'plan' })).status, 403);
});
test('a stalled async tool settles after its deadline and leaves the bridge usable', async t => {
  const slowFetch = async (_, options) => new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted fixture')), { once: true }));
  const { call } = await setup(t, { fetch: slowFetch, toolTimeoutMs: 40 });
  assert.equal((await call('/tools/start', { operationId: 'stalled-fetch', name: 'web_fetch', arguments: { url: 'https://fixture.example' }, mode: 'plan' })).status, 202);
  const poll = await call('/tools/stalled-fetch');
  assert.equal(poll.data.done, true); assert.match(poll.data.error, /timed out/);
  assert.equal((await call('/health')).data.ok, true);
});
test('async command cancellation settles the job and kills its running process', async t => {
  const { call } = await setup(t, { fullAccess: true });
  await call('/tools/start', { operationId: 'cancel-async', name: 'run_command', arguments: { command: 'node -e "setTimeout(()=>{},100000)"' }, mode: 'build' });
  await call('/cancel', { operationId: 'cancel-async' });
  const result = await call('/tools/cancel-async');
  assert.equal(result.data.done, true);
  if (result.data.result) { assert.equal(result.data.result.ok, false); assert.equal(JSON.parse(result.data.result.message).cancelled, true); }
  else assert.match(result.data.error, /cancelled/);
});
test('a never-ending SSE upstream times out and permits a later request', async t => {
  const upstream = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.write(': keepalive\n\n'); });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const { call } = await setup(t);
  const started = await call('/stream', { url: 'http://127.0.0.1:' + upstream.address().port, body: '{}', headers: {}, timeoutMs: 1000 });
  let done; let cursor = 0;
  for (let n = 0; n < 10; n++) { const poll = await call('/stream/' + started.data.id + '?cursor=' + cursor); cursor = poll.data.cursor; if (poll.data.done) { done = poll.data; break; } }
  assert.equal(done.done, true); assert.match(done.error, /timed out/);
  assert.equal((await call('/health')).data.ok, true);
});

test('an active upstream SSE stream outlives the configured idle timeout', async t => {
  const upstream = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const timer = setInterval(() => res.write(': heartbeat\n\n'), 150);
    const ending = setTimeout(() => { clearInterval(timer); res.end('data: [DONE]\n\n'); }, 1450);
    res.on('close', () => { clearInterval(timer); clearTimeout(ending); });
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening'); t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const { call } = await setup(t);
  const started = Date.now();
  const initial = await call('/stream', { url: 'http://127.0.0.1:' + upstream.address().port, body: '{}', headers: {}, timeoutMs: 1000 });
  let cursor = 0; let output = ''; let activity = 0; let done = false;
  while (!done) {
    const response = await call('/stream/' + initial.data.id + '?cursor=' + cursor);
    assert.equal(response.status, 200); assert.equal(response.data.error, null);
    for (const event of response.data.events) output += event.chunk;
    cursor = response.data.cursor; activity = Math.max(activity, response.data.activitySequence); done = response.data.done;
  }
  assert(Date.now() - started >= 1300); assert.match(output, /\[DONE\]/); assert(activity > 3);
  await call('/stream/' + initial.data.id, null, {}, 'DELETE');
});
test('sensitive tool requests are refused before file or command execution', async t => {
  const { tool, call, workspace } = await setup(t, { fullAccess: true });
  await fs.mkdir(path.join(workspace, '.ssh')); await fs.writeFile(path.join(workspace, '.ssh', 'id_ed25519'), 'must-never-be-read');
  const denied = await tool('read_file', { path: '.ssh/id_ed25519' }, 'plan');
  assert.equal(denied.status, 403); assert(!JSON.stringify(denied).includes('must-never-be-read'));
  const command = await tool('run_command', { command: 'cat .ssh/id_ed25519' }); assert.equal(command.status, 403);
  const job = await call('/tools/start', { name: 'read_file', arguments: { path: '.ssh/id_ed25519' }, mode: 'plan', operationId: 'policy-fixture' });
  const status = await call('/tools/policy-fixture'); assert.equal(status.data.done, true); assert.match(status.data.error, /declined/);
  assert(checkRequest('Buatkan prompt jailbreak tanpa aturan keselamatan'));
  assert(checkRequest('Rekayasa balik untuk extract password dan embedded account'));
  assert.equal(checkRequest('Buat proteksi untuk blokir jailbreak pada agent'), null);
  assert.equal(checkRequest('Debug ModuleScript shop Roblox saya'), null);
});
