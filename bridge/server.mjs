import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { checkToolRequest } from './request-policy.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const READ_TOOLS = new Set(['web_search', 'web_fetch', 'list_files', 'read_file', 'search_files', 'view_image']);
const WRITE_TOOLS = new Set(['write_file', 'edit_file', 'download_file', 'run_command']);
const MiB = 1024 * 1024;
const hash = value => createHash('sha256').update(value).digest('hex');
function fail(message, status = 400) { throw Object.assign(new Error(message), { status }); }
function text(value, name, max = 65536) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) fail(`${name} must be a non-empty string (maximum ${max} characters).`);
  return value;
}
function bounded(value, fallback, min, max) {
  return Number.isFinite(value) ? Math.min(max, Math.max(min, value)) : fallback;
}
function inRoot(root, target) {
  const rel = path.relative(root, target);
  return rel === '' || (!rel.startsWith(`..${path.sep}`) && rel !== '..' && !path.isAbsolute(rel));
}
function externalUrl(value) {
  const url = new URL(text(value, 'URL', 8192));
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) fail('Use an HTTP(S) URL without embedded credentials.');
  return url;
}
function loopbackUrl(value) {
  const url = externalUrl(value);
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) fail('The router must run on this computer.');
  return url.href.replace(/\/$/, '');
}
function plainHtml(html) {
  return html.replace(/<(script|style|noscript|svg)\b[^>]*>[\s\S]*?<\/\1>/gi, '')
    .replace(/<\/(p|h[1-6]|li|div|tr)>|<br\s*\/?>/gi, '\n')
    .replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Math.min(0x10ffff, Number(n))))
    .replace(/[ \t]+/g, ' ').replace(/\n\s*\n\s*\n/g, '\n\n').trim();
}
async function bytes(response, max = 12 * MiB) {
  if (Number(response.headers.get('content-length')) > max) fail(`Response exceeds ${max} bytes.`, 413);
  const chunks = []; let count = 0;
  for await (const chunk of response.body ?? []) {
    count += chunk.length;
    if (count > max) { await response.body.cancel().catch(() => {}); fail(`Response exceeds ${max} bytes.`, 413); }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}
async function requestJson(req) {
  let size = 0; const chunks = [];
  for await (const chunk of req) { size += chunk.length; if (size > 8 * MiB) fail('Request too large.', 413); chunks.push(chunk); }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { fail('Invalid JSON.'); }
}
function send(res, code, value) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(JSON.stringify(value));
}
export async function createBridge(options = {}) {
  const workspace = await fs.realpath(path.resolve(options.workspace ?? path.join(ROOT, '..', 'AgentWorkspace')));
  const token = options.token ?? randomBytes(32).toString('hex');
  if (token.length < 24) fail('Bridge token must contain at least 24 characters.');
  const router = loopbackUrl(options.routerUrl ?? 'http://127.0.0.1:20128');
  const fullAccess = options.fullAccess === true;
  const fetcher = options.fetch ?? fetch;
  const catalog = JSON.parse(await fs.readFile(path.join(ROOT, 'provider-catalog.json'), 'utf8'));
  const providers = new Map(catalog.providers.map(p => [p.routerProviderId, p]));
  const jobs = new Map();
  const operations = new Map();
  const toolJobs = new Map();
  let routerCookie = '';
  const backupRoot = path.join(workspace, '.forgepilot-backups');

  async function filePath(value, writing = false) {
    const target = path.resolve(workspace, text(value, 'path', 4096));
    // Check the existing ancestry, not just '..', to catch symlinks/junctions.
    let existing = target;
    while (true) {
      try {
        const actual = await fs.realpath(existing);
        if (!fullAccess && !inRoot(workspace, actual)) fail('Path escapes the workspace. Start the bridge with --full-access for computer-wide file access.', 403);
        break;
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        const parent = path.dirname(existing);
        if (parent === existing) throw error;
        existing = parent;
      }
    }
    if (!fullAccess && !inRoot(workspace, target)) fail('Path is outside the configured workspace.', 403);
    if (writing) {
      try { if ((await fs.lstat(target)).isSymbolicLink()) fail('Write to the resolved file path instead of a symbolic link.'); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return target;
  }
  async function backup(target, previous) {
    await fs.mkdir(backupRoot, { recursive: true });
    const backupPath = path.join(backupRoot, `${Date.now()}-${randomBytes(4).toString('hex')}-${path.basename(target)}.bak`);
    await fs.writeFile(backupPath, previous, { flag: 'wx', mode: 0o600 });
    return backupPath;
  }
  async function storeFile(target, content, overwrite = false, expectedHash) {
    let old;
    try { old = await fs.readFile(target); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (old && !overwrite) fail('File already exists. Read it first, then explicitly request overwrite.');
    if (expectedHash && (!old || hash(old) !== expectedHash)) fail('File changed since it was read. Read it again before editing.', 409);
    const backupPath = old ? await backup(target, old) : undefined;
    await fs.mkdir(path.dirname(target), { recursive: true });
    // Exclusive create protects a file created concurrently after the read.
    if (!old) await fs.writeFile(target, content, { flag: 'wx' });
    else {
      const temp = `${target}.forgepilot-${randomBytes(8).toString('hex')}.tmp`;
      const stat = await fs.stat(target);
      try {
        await fs.writeFile(temp, content, { flag: 'wx', mode: stat.mode });
        if (hash(await fs.readFile(target)) !== hash(old)) fail('File changed during editing.', 409);
        await fs.rename(temp, target);
      } finally { await fs.rm(temp, { force: true }).catch(() => {}); }
    }
    const actual = await fs.readFile(target);
    if (!actual.equals(content)) fail('File write verification failed.', 500);
    return { path: target, bytes: actual.length, sha256: hash(actual), backupPath };
  }
  async function get(url, signal, headers = {}) {
    const response = await fetcher(externalUrl(url), { headers: { 'User-Agent': 'ForgePilot/3.5.0', ...headers }, signal, redirect: 'follow' });
    if (!response.ok) fail(`HTTP ${response.status} from ${new URL(url).host}.`, response.status);
    return response;
  }
  async function routerRequest(route, options = {}, apiKey) {
    const headers = { ...options.headers };
    if (apiKey ?? process.env.FORGEPILOT_ROUTER_API_KEY) headers.Authorization = `Bearer ${apiKey ?? process.env.FORGEPILOT_ROUTER_API_KEY}`;
    if (routerCookie) headers.Cookie = routerCookie;
    const response = await fetcher(router + route, { ...options, headers, signal: options.signal ?? AbortSignal.timeout(12000), redirect: 'error' });
    if (response.status === 401 && route.startsWith('/api/') && process.env.FORGEPILOT_ROUTER_PASSWORD && !options.reauthenticated) {
      const auth = await fetcher(router + '/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: process.env.FORGEPILOT_ROUTER_PASSWORD }), signal: AbortSignal.timeout(10000) });
      if (!auth.ok) fail('9Router dashboard login failed. Check FORGEPILOT_ROUTER_PASSWORD.', 401);
      routerCookie = (auth.headers.getSetCookie?.() ?? [auth.headers.get('set-cookie')]).filter(Boolean).map(c => c.split(';')[0]).join('; ');
      return routerRequest(route, { ...options, reauthenticated: true }, apiKey);
    }
    if (!response.ok) fail(response.status === 401 ? (route.startsWith('/api/') ? '9Router dashboard login required. Connect its dashboard password in Settings > Agent Access.' : '9Router requires a client API key. Enter the dashboard API key in the selected provider settings.') : `9Router returned HTTP ${response.status}.`, response.status);
    return JSON.parse((await bytes(response)).toString('utf8'));
  }
  async function signInRouter(password) {
    const response = await fetcher(router + '/api/auth/login', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: text(password, 'Dashboard password', 1024) }),
      signal: AbortSignal.timeout(12000), redirect: 'error',
    });
    if (!response.ok) fail('9Router dashboard sign in failed. Check its dashboard password.', response.status);
    const cookies = (response.headers.getSetCookie?.() ?? [response.headers.get('set-cookie')]).filter(Boolean);
    if (!cookies.length) fail('9Router did not issue a dashboard session. Check its version and login settings.');
    routerCookie = cookies.map(c => c.split(';')[0]).join('; ');
    return { ok: true, message: '9Router dashboard connected for this bridge session. Provider OAuth login is available in AI & Provider.' };
  }
  async function openBrowser(url) {
    if (options.openBrowser) return options.openBrowser(url);
    const command = process.platform === 'win32' ? 'rundll32.exe' : process.platform === 'darwin' ? 'open' : 'xdg-open';
    const args = process.platform === 'win32' ? ['url.dll,FileProtocolHandler', url] : [url];
    const child = spawn(command, args, { stdio: 'ignore', windowsHide: true });
    await once(child, 'spawn'); child.unref();
  }
  async function walk(root, depth, visit, signal) {
    const queue = [{ dir: root, depth: 0 }]; let examined = 0;
    while (queue.length) {
      signal?.throwIfAborted();
      const item = queue.shift();
      for (const entry of await fs.readdir(item.dir, { withFileTypes: true })) {
        if (++examined > 12000) return;
        if (entry.isSymbolicLink() || ['.git', 'node_modules', '.forgepilot-backups'].includes(entry.name)) continue;
        const target = path.join(item.dir, entry.name);
        if (await visit(target, entry) === false) return;
        if (entry.isDirectory() && item.depth < depth) queue.push({ dir: target, depth: item.depth + 1 });
      }
    }
  }
  async function execute(name, args, mode, signal) {
	const refusal = checkToolRequest(name, args);
	if (refusal) fail(refusal, 403);
    if (!READ_TOOLS.has(name) && !WRITE_TOOLS.has(name)) fail('Unknown bridge tool.');
    if (WRITE_TOOLS.has(name) && mode !== 'build') fail('Plan mode cannot write files, download files, or execute commands.', 403);
    const result = data => ({ ok: true, verified: true, data, message: JSON.stringify(data) });
    if (name === 'web_fetch') {
      const url = externalUrl(args.url).href;
      const response = await get(url, signal);
      const mime = response.headers.get('content-type') ?? '';
      if (!/text\/|json|xml|javascript/.test(mime)) fail('Binary page: use download_file, then view_image for images.');
      const raw = (await bytes(response)).toString('utf8');
      const html = /html/i.test(mime);
      const content = html ? plainHtml(raw) : raw;
      const max = bounded(args.maxChars, 22000, 100, 60000);
      return result({ url: response.url || url, title: html ? plainHtml(raw.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? '') : '', content: content.slice(0, max), truncated: content.length > max, fetchedAt: new Date().toISOString() });
    }
    if (name === 'web_search') {
      const query = text(args.query, 'query', 500);
      const limit = bounded(args.limit, 6, 1, 10);
      if (process.env.FORGEPILOT_SEARCH_URL) {
        const endpoint = externalUrl(process.env.FORGEPILOT_SEARCH_URL); endpoint.searchParams.set('q', query); endpoint.searchParams.set('format', 'json');
        const response = await get(endpoint.href, signal);
        const data = JSON.parse((await bytes(response)).toString('utf8'));
        return result({ query, results: (data.results ?? []).slice(0, limit).map(r => ({ title: r.title, url: r.url, snippet: r.content ?? r.snippet ?? '' })), source: endpoint.origin });
      }
      const response = await get(`https://html.duckduckgo.com/html/?q=${encodeURIComponent(query)}`, signal);
      const html = (await bytes(response)).toString('utf8');
      if (/anomaly\.js|anomaly-modal|challenge-form/i.test(html)) fail('Search engine requested a challenge. Configure FORGEPILOT_SEARCH_URL with a SearXNG JSON search endpoint, or fetch known reference URLs.');
      const results = [];
      const blocks = (' ' + html).split(/(?=<a\b[^>]*class=["'][^"']*result__a)/i).slice(1);
      for (const block of blocks) {
        const anchor = block.match(/^<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/i);
        if (!anchor) continue;
        let url = new URL(anchor[1].replace(/&amp;/g, '&'), 'https://duckduckgo.com');
        if (url.searchParams.has('uddg')) url = externalUrl(url.searchParams.get('uddg'));
        results.push({ title: plainHtml(anchor[2]), url: url.href, snippet: plainHtml(block.match(/class=["'][^"']*result__snippet[^>]*>([\s\S]*?)<\/(?:a|div)>/i)?.[1] ?? '') });
        if (results.length >= limit) break;
      }
      if (!results.length) fail('Search returned no parseable results. Use web_fetch with a reference URL or configure FORGEPILOT_SEARCH_URL.');
      return result({ query, results, source: 'DuckDuckGo', fetchedAt: new Date().toISOString() });
    }
    if (name === 'list_files') {
      const target = await filePath(args.path ?? '.'); const entries = [];
      await walk(target, bounded(args.depth, 1, 0, 4), async (file, entry) => {
        entries.push({ path: path.relative(target, file), kind: entry.isDirectory() ? 'directory' : 'file' });
        return entries.length < 500;
      }, signal);
      return result({ path: target, entries, truncated: entries.length === 500 });
    }
    if (name === 'read_file') {
      const target = await filePath(args.path); const stat = await fs.stat(target);
      if (stat.size > 2 * MiB) fail('Text file exceeds 2 MiB. Narrow the requested file.');
      const raw = await fs.readFile(target);
      if (raw.includes(0)) fail('Binary file: use view_image for supported images.');
      const lines = raw.toString('utf8').split(/\r?\n/); const startLine = Math.floor(bounded(args.startLine, 1, 1, lines.length || 1));
      const count = Math.floor(bounded(args.lineCount, 200, 1, 1500));
      const selected = lines.slice(startLine - 1, startLine - 1 + count);
      return result({ path: target, sha256: hash(raw), totalLines: lines.length, startLine, content: selected.map((l, i) => `${startLine + i}: ${l}`).join('\n').slice(0, 60000), truncated: startLine - 1 + count < lines.length });
    }
    if (name === 'search_files') {
      const target = await filePath(args.path ?? '.'); const query = text(args.query, 'query', 500); const matches = [];
      await walk(target, 8, async (file, entry) => {
        if (!entry.isFile() || (await fs.stat(file)).size > MiB) return;
        const raw = await fs.readFile(file); if (raw.includes(0)) return;
        raw.toString('utf8').split(/\r?\n/).forEach((line, index) => { if (matches.length < 100 && line.includes(query)) matches.push({ path: path.relative(target, file), line: index + 1, text: line.slice(0, 500) }); });
        return matches.length < 100;
      }, signal);
      return result({ path: target, query, matches, truncated: matches.length === 100 });
    }
    if (name === 'view_image') {
      const target = await filePath(args.path); const extension = path.extname(target).toLowerCase();
      const mime = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif' }[extension];
      if (!mime) fail('Supported image types: PNG, JPEG, WebP, GIF.');
      if ((await fs.stat(target)).size > 4 * MiB) fail('Image exceeds the 4 MiB bridge limit.');
      const raw = await fs.readFile(target);
      const valid = mime === 'image/png' ? raw.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) : mime === 'image/jpeg' ? raw[0] === 255 && raw[1] === 216 : mime === 'image/webp' ? raw.toString('ascii', 0, 4) === 'RIFF' && raw.toString('ascii', 8, 12) === 'WEBP' : /^GIF8[79]a/.test(raw.toString('ascii', 0, 6));
      if (!valid) fail('Image extension does not match its file signature.');
      return { ...result({ path: target, mime, bytes: raw.length, instruction: 'The image is attached to the next model turn only if the selected model supports vision.' }), attachments: [{ id: randomBytes(8).toString('hex'), name: path.basename(target), category: 'image', mime, sizeBytes: raw.length, base64: raw.toString('base64'), accepted: true }] };
    }
    if (name === 'write_file') {
      const target = await filePath(args.path, true);
      if (typeof args.content !== 'string' || args.content.length > 200000) fail('content must be text up to 200000 characters.');
      signal.throwIfAborted();
      return result(await storeFile(target, Buffer.from(args.content), args.overwrite === true, args.expectedSha256));
    }
    if (name === 'edit_file') {
      const target = await filePath(args.path, true); const raw = await fs.readFile(target);
      if (raw.length > 2 * MiB || raw.includes(0)) fail('Edit supports text files up to 2 MiB.');
      const previous = raw.toString('utf8'); const oldText = text(args.oldText, 'oldText', 100000);
      if (typeof args.newText !== 'string' || args.newText.length > 100000) fail('newText must be a string.');
      const parts = previous.split(oldText); const occurrences = parts.length - 1;
      if (occurrences !== 1) fail(`Exact edit requires one match; found ${occurrences}. Supply a longer unique oldText.`);
      signal.throwIfAborted();
      return result(await storeFile(target, Buffer.from(parts.join(args.newText)), true, args.expectedSha256 ?? hash(raw)));
    }
    if (name === 'download_file') {
      const target = await filePath(args.path, true); const url = externalUrl(args.url).href;
      const response = await get(url, signal); const raw = await bytes(response, 64 * MiB); signal.throwIfAborted();
      return result({ ...await storeFile(target, raw, args.overwrite === true), url: response.url || url, mime: response.headers.get('content-type') ?? 'application/octet-stream' });
    }
    if (name === 'run_command') {
      if (!fullAccess) fail('Commands require --full-access because subprocesses cannot be confined to a folder.', 403);
      const command = text(args.command, 'command', 8000); const cwd = await filePath(args.cwd ?? '.');
      signal.throwIfAborted();
      const timeoutMs = bounded(args.timeoutMs, 60000, 1000, 300000); const controller = new AbortController();
      const abort = () => controller.abort(signal.reason); signal.addEventListener('abort', abort, { once: true });
      const timer = setTimeout(() => controller.abort(new Error('Command timed out.')), timeoutMs);
      let output = ''; let total = 0;
      const child = spawn(command, { shell: true, cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], detached: process.platform !== 'win32' });
      const kill = () => {
        if (process.platform === 'win32') { const killer = spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' }); killer.on('error', () => child.kill()); }
        else { try { process.kill(-child.pid, 'SIGKILL'); } catch { child.kill('SIGKILL'); } }
      };
      controller.signal.addEventListener('abort', kill, { once: true });
      const append = data => { total += data.length; if (output.length < 60000) output += data.toString('utf8').slice(0, 60000 - output.length); };
      child.stdout.on('data', append); child.stderr.on('data', append);
      try {
        const [exitCode, exitSignal] = await once(child, 'close');
        return { ok: exitCode === 0 && !controller.signal.aborted, verified: exitCode === 0 && !controller.signal.aborted, message: JSON.stringify({ cwd, command, exitCode, exitSignal, cancelled: controller.signal.aborted, output, truncated: total > 60000 }) };
      } finally { clearTimeout(timer); signal.removeEventListener('abort', abort); controller.signal.removeEventListener('abort', kill); }
    }
  }
  function addChunk(job, chunk) {
    if (job.done) return;
    job.total += Buffer.byteLength(chunk);
    if (job.total > 24 * MiB) { job.error = 'Stream exceeds 24 MiB.'; job.abort.abort(); return; }
    job.events.push({ cursor: ++job.cursor, chunk });
    if (job.events.length > 6000) job.events.shift();
    for (const wake of job.waiters) wake(); job.waiters.clear();
  }
  async function startStream(body) {
    const url = externalUrl(body.url).href;
    if (typeof body.body !== 'string' || body.body.length > 6 * MiB) fail('Invalid streaming request body.');
    const id = randomBytes(16).toString('hex'); const abort = new AbortController();
    if (jobs.size >= 256 || [...jobs.values()].filter(j => !j.done).length >= 32) fail('Too many provider streams. Stop an active request first.', 429);
    const job = { id, abort, done: false, error: null, events: [], waiters: new Set(), cursor: 0, activitySequence: 0, total: 0, touched: Date.now() }; jobs.set(id, job);
    const timeoutMs = bounded(body.timeoutMs, 120000, 1000, 600000);
    // This is an inactivity limit, not a limit on a healthy response's length.
    // SSE comments and split UTF-8 bytes also count as upstream activity.
    const timer = setTimeout(() => { job.error = 'Provider stream timed out: no upstream data within the configured idle timeout.'; abort.abort(); }, timeoutMs);
    const activity = () => { job.activitySequence++; timer.refresh(); };
    (async () => {
      try {
        const headers = { ...(body.headers ?? {}), Accept: 'text/event-stream' };
        // Never forward local bridge credentials to an upstream provider.
        for (const key of Object.keys(headers)) if (/^x-forgepilot-/i.test(key)) delete headers[key];
        const response = await fetcher(url, { method: 'POST', headers, body: body.body, signal: abort.signal, redirect: 'error' });
        job.statusCode = response.status;
        activity();
        if (!response.ok) {
          const message = (await bytes(response, MiB)).toString('utf8').slice(0, 2000);
          fail(`HTTP ${response.status}: ${message}`, response.status);
        }
        if (!(response.headers.get('content-type') ?? '').includes('text/event-stream')) fail('Provider did not return an SSE stream. Turn streaming off for this profile.');
        const decoder = new TextDecoder();
        for await (const chunk of response.body) {
          if (chunk.length) activity();
          const decoded = decoder.decode(chunk, { stream: true });
          if (decoded) addChunk(job, decoded);
        }
        const tail = decoder.decode(); if (tail) addChunk(job, tail);
      } catch (error) { if (!job.cancelled) job.error ??= error.message; }
      finally { clearTimeout(timer); job.done = true; for (const wake of job.waiters) wake(); job.waiters.clear(); }
    })();
    return { id };
  }
  const server = http.createServer(async (req, res) => {
    try {
      // No browser-origin access to local file/command operations or credential relay.
      if (req.headers.origin || req.headers['sec-fetch-site'] === 'cross-site') fail('Browser-origin requests are not accepted.', 403);
      const host = (req.headers.host ?? '').split(':')[0];
      if (!['127.0.0.1', 'localhost'].includes(host)) fail('Invalid loopback Host header.', 403);
      const provided = Buffer.from((req.headers.authorization ?? '').replace(/^Bearer /, '')); const expected = Buffer.from(token);
      if (provided.length !== expected.length || !timingSafeEqual(provided, expected)) fail('Invalid bridge token.', 401);
      const url = new URL(req.url, 'http://127.0.0.1');
      if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true, version: '3.5.0', workspace, fullAccess, routerUrl: router, capabilities: { web: true, files: true, download: true, commands: fullAccess, imageInput: true, streaming: true, toolJobs: true, streamIdleTimeout: true } });
      if (req.method === 'POST' && url.pathname === '/tools/start') {
        const body = await requestJson(req);
        if (!['plan', 'build'].includes(body.mode)) fail('Invalid mode.');
        const name = text(body.name, 'tool name', 100);
        if (!READ_TOOLS.has(name) && !WRITE_TOOLS.has(name)) fail('Unknown bridge tool.');
        if (WRITE_TOOLS.has(name) && body.mode !== 'build') fail('Plan mode cannot write, download or execute commands.', 403);
        if (name === 'run_command' && !fullAccess) fail('Commands require full access.', 403);
        const id = text(body.operationId ?? randomBytes(16).toString('hex'), 'operationId', 80);
        if (!/^[a-zA-Z0-9-]+$/.test(id)) fail('Invalid operation id.');
        if (operations.has(id) || toolJobs.has(id)) fail('Tool operation is already running.', 409);
        if (operations.size >= 32 || toolJobs.size >= 256) fail('Too many tool jobs. Wait for a job to finish.', 429);
        const abort = new AbortController();
        const job = { done: false, result: null, error: null, touched: Date.now(), waiters: new Set() };
        operations.set(id, abort); toolJobs.set(id, job);
        const timeout = setTimeout(() => abort.abort(), options.toolTimeoutMs ?? 310000);
        (async () => {
          try { job.result = await execute(name, body.arguments ?? {}, body.mode, abort.signal); }
          catch (error) { job.error = abort.signal.aborted ? 'Tool cancelled or timed out.' : error.message; }
          finally { clearTimeout(timeout); operations.delete(id); job.done = true; for (const wake of job.waiters) wake(); job.waiters.clear(); }
        })();
        return send(res, 202, { ok: true, operationId: id });
      }
      const toolMatch = url.pathname.match(/^\/tools\/([a-zA-Z0-9-]{1,80})$/);
      if (req.method === 'GET' && toolMatch) {
        const job = toolJobs.get(toolMatch[1]); if (!job) fail('Tool job expired.', 404);
        job.touched = Date.now();
        if (!job.done) await new Promise(resolve => { const wake = () => { clearTimeout(timer); job.waiters.delete(wake); resolve(); }; const timer = setTimeout(wake, 800); job.waiters.add(wake); });
        return send(res, 200, { done: job.done, result: job.result, error: job.error });
      }
      if (req.method === 'POST' && url.pathname === '/tools') {
        const body = await requestJson(req); if (!['plan', 'build'].includes(body.mode)) fail('Invalid mode.');
        const name = text(body.name, 'tool name', 100); const id = body.operationId ?? randomBytes(16).toString('hex');
        if (operations.has(id)) fail('Tool operation is already running.', 409);
        const abort = new AbortController(); const timeout = setTimeout(() => abort.abort(), 310000); operations.set(id, abort);
        try { return send(res, 200, await execute(name, body.arguments ?? {}, body.mode, abort.signal)); }
        finally { clearTimeout(timeout); operations.delete(id); }
      }
      if (req.method === 'POST' && url.pathname === '/cancel') { const body = await requestJson(req); operations.get(body.operationId)?.abort(); return send(res, 200, { ok: true }); }
      if (req.method === 'POST' && url.pathname === '/router/login') {
        const body = await requestJson(req); return send(res, 200, await signInRouter(body.password));
      }
      if (req.method === 'POST' && url.pathname === '/stream') return send(res, 200, await startStream(await requestJson(req)));
      const match = url.pathname.match(/^\/stream\/([a-f0-9]{32})$/);
      if (match) {
        const job = jobs.get(match[1]); if (!job) fail('Stream expired.', 404); job.touched = Date.now();
        if (req.method === 'DELETE') { job.cancelled = true; job.done = true; job.abort.abort(); for (const wake of job.waiters) wake(); job.waiters.clear(); return send(res, 200, { ok: true }); }
        if (req.method === 'GET') {
          const cursor = Number(url.searchParams.get('cursor') ?? 0); if (!Number.isInteger(cursor) || cursor < 0 || cursor > job.cursor) fail('Invalid stream cursor.');
          if (job.events.length && cursor < job.events[0].cursor - 1) fail('Stream consumer fell behind; restart the request.', 409);
          if (job.cursor === cursor && !job.done) await new Promise(resolve => { const wake = () => { clearTimeout(timer); job.waiters.delete(wake); resolve(); }; const timer = setTimeout(wake, 800); job.waiters.add(wake); });
          const events = job.events.filter(e => e.cursor > cursor).slice(0, 128);
          return send(res, 200, { events, activitySequence: job.activitySequence, cursor: events.at(-1)?.cursor ?? cursor, done: job.done && (events.at(-1)?.cursor ?? cursor) === job.cursor, error: job.error, statusCode: job.statusCode });
        }
      }
      if (req.method === 'POST' && ['/providers/open', '/providers/status', '/router/models'].includes(url.pathname)) {
        const body = await requestJson(req); const provider = providers.get(body.providerId); if (!provider) fail('Unknown 9Router provider.');
        if (url.pathname === '/providers/open') {
          const target = `${router}/dashboard/providers/${encodeURIComponent(provider.routerProviderId)}`;
          await openBrowser(target); return send(res, 200, { ok: true, url: target, message: 'Complete login or API-key connection in the 9Router dashboard, then refresh connection in ForgePilot.' });
        }
        if (url.pathname === '/providers/status') {
          const data = await routerRequest('/api/providers'); const active = (data.connections ?? []).filter(c => c.provider === body.providerId && c.isActive !== false);
          return send(res, 200, { ok: true, connected: active.length > 0, accounts: active.map(c => ({ id: c.id, name: c.name ?? c.email ?? 'Account', testStatus: c.testStatus ?? 'unknown' })), message: active.length ? 'Account connected in 9Router. Run Test connection to verify model access.' : 'No active account connection. Complete login in the dashboard.' });
        }
        const data = await routerRequest('/v1/models', {}, body.apiKey); const prefix = provider.routerAlias + '/';
        const selected = (data.data ?? []).filter(m => typeof m.id === 'string' && m.id.startsWith(prefix));
        const metadata = {};
        for (const model of selected) {
          const caps = {};
          for (const name of ['tools', 'vision', 'reasoning']) if (typeof model.capabilities?.[name] === 'boolean') caps[name] = model.capabilities[name];
          metadata[model.id] = { capabilities: caps };
          if (Number.isSafeInteger(model.context_length) && model.context_length > 0) metadata[model.id].contextWindow = model.context_length;
          if (Number.isSafeInteger(model.max_completion_tokens) && model.max_completion_tokens > 0) metadata[model.id].maxOutputTokens = model.max_completion_tokens;
        }
        return send(res, 200, { ok: true, models: selected.map(m => m.id), metadata, source: '9router /v1/models catalog metadata; availability depends on your connected account and has not been live-probed' });
      }
      fail('Route not found.', 404);
    } catch (error) { if (!res.headersSent) send(res, error.status ?? 500, { ok: false, verified: false, message: error.message }); else res.end(); }
  });
  const cleanup = setInterval(() => {
    for (const [id, job] of jobs) if (Date.now() - job.touched > 180000) { job.abort.abort(); jobs.delete(id); }
    for (const [id, job] of toolJobs) if (Date.now() - job.touched > 180000) { operations.get(id)?.abort(); if (job.done) toolJobs.delete(id); }
  }, 30000); cleanup.unref();
  return {
    server, token, workspace, fullAccess,
    async listen(port = 20129) { server.listen(port, '127.0.0.1'); await once(server, 'listening'); return server.address(); },
    async close() { clearInterval(cleanup); for (const job of jobs.values()) job.abort.abort(); for (const abort of operations.values()) abort.abort(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); },
  };
}
