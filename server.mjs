import { createServer } from 'node:http';
import { networkInterfaces } from 'node:os';
import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { chmod, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT || 8787);
const stateDir = process.env.CMR_STATE_DIR || join(process.env.HOME || here, 'Library', 'Application Support', 'Codex Mic Remote');
const stateFile = join(stateDir, 'sessions.json');
const adminFile = process.env.CMR_ADMIN_FILE;
const adminToken = adminFile ? randomBytes(32).toString('base64url') : null;
const instanceId = randomBytes(16).toString('hex');
const helperPath = process.env.CMR_HELPER || join(here, 'build', 'codex-voice-ax');
const pairingCode = String(randomInt(100000, 1_000_000));
const pairingExpiresAt = Date.now() + 10 * 60 * 1000;
const sessions = new Map();
const pairingAttempts = new Map();
let saveQueue = Promise.resolve();
let controlQueue = Promise.resolve();
let shutdownRequested = false;
// A process that did not bind the HTTP port must never remove or replace the
// lease of the process that did. This is deliberately separate from the
// random instance ID: it records successful publication by *this* process.
let adminLeasePublished = false;
// Keep the public API deliberately narrow.  These are the models/effort levels
// exposed by the desktop Codex picker; the AX helper still verifies that the
// requested item is actually present before it presses anything.
const models = new Set(['gpt-6.1-sol', 'gpt-6-astra', 'gpt-6-sol', 'gpt-6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna']);
const efforts = new Set(['low', 'medium', 'high', 'xhigh', 'max']);

async function loadSessions() {
  try {
    const saved = JSON.parse(await readFile(stateFile, 'utf8'));
    for (const [token, session] of saved.sessions ?? []) {
      if (session.expires > Date.now()) sessions.set(token, session);
    }
  } catch (error) {
    if (error.code !== 'ENOENT') console.warn(`Could not read saved pairings: ${error.message}`);
  }
}

function saveSessions() {
  const snapshot = JSON.stringify({ sessions: [...sessions] });
  saveQueue = saveQueue.catch(() => {}).then(async () => {
    await mkdir(stateDir, { recursive: true, mode: 0o700 });
    const temporary = `${stateFile}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
    await writeFile(temporary, snapshot, { mode: 0o600 });
    await chmod(temporary, 0o600);
    await rename(temporary, stateFile);
  });
  return saveQueue;
}

await loadSessions();

async function writeAdminLease() {
  if (!adminFile || !adminToken) return;
  await mkdir(dirname(adminFile), { recursive: true, mode: 0o700 });
  const temporary = `${adminFile}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify({ kind: 'codex-mic-remote-admin', protocol: 1, pid: process.pid, instanceId, token: adminToken }), { mode: 0o600 });
    await chmod(temporary, 0o600);
    // rename is atomic on the local filesystem: readers see either the old
    // complete lease or this complete lease, never a partial JSON document.
    await rename(temporary, adminFile);
    adminLeasePublished = true;
  } catch (error) {
    await unlink(temporary).catch(() => {});
    throw error;
  }
}

async function removeAdminLease() {
  if (!adminFile || !adminLeasePublished) return;
  try {
    const lease = JSON.parse(await readFile(adminFile, 'utf8'));
    if (lease.instanceId === instanceId) await unlink(adminFile);
  } catch (error) {
    if (error.code !== 'ENOENT') console.warn(`Could not remove admin lease: ${error.message}`);
  }
}

function localIPv4() {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === 'IPv4' && !address.internal) return address.address;
    }
  }
  return null;
}

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  return new Promise(resolve => res.end(JSON.stringify(body), resolve));
}

const staticFiles = new Map([
  ['/manifest.webmanifest', ['application/manifest+json; charset=utf-8', 'manifest.webmanifest']],
  ['/sw.js', ['text/javascript; charset=utf-8', 'sw.js']],
  ['/icon.svg', ['image/svg+xml', 'icon.svg']],
  ['/icon-180.png', ['image/png', 'icon-180.png']],
]);

async function serveFile(response, type, file) {
  response.writeHead(200, { 'content-type': type, 'cache-control': file === 'sw.js' ? 'no-cache' : 'public, max-age=3600' });
  response.end(await readFile(join(here, 'public', file)));
}

function parseCookies(request) {
  return Object.fromEntries((request.headers.cookie ?? '').split(';').map(v => v.trim().split('=').map(decodeURIComponent)).filter(([k]) => k));
}

function isAuthorized(request) {
  const token = parseCookies(request).cmr;
  const session = token && sessions.get(token);
  if (!session || session.expires < Date.now()) return false;
  return session.ip === request.socket.remoteAddress;
}

function isLoopback(address) {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function adminAuthorized(request, input) {
  if (!isLoopback(request.socket.remoteAddress) || !adminToken || !adminLeasePublished) return false;
  const actual = Buffer.from(String(request.headers['x-cmr-admin'] ?? ''));
  const expected = Buffer.from(adminToken);
  return input?.instanceId === instanceId && actual.length === expected.length && timingSafeEqual(actual, expected);
}

async function body(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 2048) throw new Error('Request too large');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}

function canPair(ip) {
  const entry = pairingAttempts.get(ip);
  return !entry || entry.lockedUntil < Date.now();
}

function failedPair(ip) {
  const entry = pairingAttempts.get(ip) ?? { count: 0, lockedUntil: 0 };
  entry.count += 1;
  if (entry.count >= 8) entry.lockedUntil = Date.now() + 5 * 60 * 1000;
  pairingAttempts.set(ip, entry);
}

async function voice(action = 'status', value) {
  const run = async () => {
    try {
      const args = value ? [action, value] : [action];
      // The macOS launcher owns the Accessibility permission. In the packaged
      // app, ask that launcher to spawn the helper so TCC associates the
      // request with Codex Mic Remote rather than the external Node runtime.
      if (process.env.CMR_BRIDGE_URL && process.env.CMR_BRIDGE_TOKEN) {
        const response = await fetch(process.env.CMR_BRIDGE_URL, {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-cmr-bridge': process.env.CMR_BRIDGE_TOKEN },
          body: JSON.stringify({ args }),
          signal: AbortSignal.timeout(5000),
        });
        if (!response.ok) throw new Error(`Mac helper bridge returned ${response.status}`);
        return await response.json();
      }
      const { stdout } = await execFileAsync(helperPath, args, { timeout: 5000 });
      return JSON.parse(stdout);
    } catch (error) {
      const stdout = error.stdout?.toString();
      if (stdout) return JSON.parse(stdout);
      return { ok: false, available: false, error: `Mac helper failed: ${error.message}` };
    }
  };
  // Every read or action shares one AX helper lane. This prevents a status
  // lookup or a second phone tap from racing an open Codex picker.
  const queued = controlQueue.then(run, run);
  controlQueue = queued.catch(() => {});
  return queued;
}

function selectedValue(input, key, allowed, label) {
  const value = String(input?.[key] ?? '').trim().toLowerCase();
  if (!allowed.has(value)) throw new Error(`Unsupported ${label}.`);
  return value;
}

const app = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? 'localhost'}`);
    if (request.method === 'GET' && url.pathname === '/') {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      response.end(await readFile(join(here, 'public', 'index.html')));
      return;
    }
    if (request.method === 'GET' && staticFiles.has(url.pathname)) {
      const [type, file] = staticFiles.get(url.pathname);
      await serveFile(response, type, file);
      return;
    }
    // Once a managed shutdown begins, requests already in flight can finish,
    // but no newly arriving mutation is accepted. The shutdown endpoint itself
    // stays reachable only to return its explicit 409 on a repeat request.
    if (shutdownRequested && request.method !== 'GET' && url.pathname !== '/api/admin/shutdown') {
      return json(response, 503, { error: 'Server shutdown is in progress.' });
    }
    if (request.method === 'POST' && url.pathname === '/api/pair') {
      const ip = request.socket.remoteAddress;
      if (pairingExpiresAt < Date.now()) return json(response, 410, { error: 'This pairing code has expired. Restart Codex Mic Remote to create a new one.' });
      if (!canPair(ip)) return json(response, 429, { error: 'Too many pairing attempts. Wait five minutes and try again.' });
      const input = await body(request);
      const candidate = Buffer.from(String(input.code ?? ''));
      const expected = Buffer.from(pairingCode);
      if (candidate.length !== expected.length || !timingSafeEqual(candidate, expected)) {
        failedPair(ip);
        return json(response, 401, { error: 'Pairing code is incorrect.' });
      }
      const token = randomBytes(32).toString('base64url');
      pairingAttempts.delete(ip);
      sessions.set(token, { ip, expires: Date.now() + 30 * 24 * 60 * 60 * 1000 });
      await saveSessions();
      response.setHeader('set-cookie', `cmr=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000`);
      return json(response, 200, { ok: true });
    }
    // PID and instance ID are discovery data only. The matching admin token is
    // stored 0600 locally and is required for a launcher-managed restart.
    if (request.method === 'GET' && url.pathname === '/api/identity') {
      const local = isLoopback(request.socket.remoteAddress);
      return json(response, 200, { kind: 'codex-mic-remote', protocol: 1, version: '0.3.0', pid: local ? process.pid : undefined, instanceId });
    }
    if (request.method === 'POST' && url.pathname === '/api/admin/shutdown') {
      const input = await body(request);
      if (!adminAuthorized(request, input)) return json(response, 403, { error: 'Admin authentication failed.' });
      if (shutdownRequested) return json(response, 409, { error: 'Shutdown is already in progress.' });
      shutdownRequested = true;
      // Finish the authenticated response first. Then stop accepting sockets;
      // app.close waits for in-flight HTTP handlers, and the queues guarantee
      // any accepted AX or pairing persistence work is settled before lease
      // removal and process exit.
      await json(response, 200, { ok: true });
      setTimeout(() => app.close(async () => {
        await Promise.allSettled([saveQueue, controlQueue]);
        await removeAdminLease();
        process.exit(0);
      }), 20).unref();
      return;
    }
    if (!isAuthorized(request)) return json(response, 401, { error: 'Pair this phone first.' });
    if (request.method === 'GET' && url.pathname === '/api/status') return json(response, 200, await voice());
    if (request.method === 'POST' && url.pathname === '/api/toggle') return json(response, 200, await voice('toggle'));
    // These actions are always an explicit, authenticated request from the
    // paired phone.  In particular, status checks never create a chat or
    // activate Voice.
    if (request.method === 'POST' && url.pathname === '/api/new-chat') return json(response, 200, await voice('new-chat'));
    if (request.method === 'POST' && url.pathname === '/api/start-voice') return json(response, 200, await voice('start-voice'));
    // Permission prompting is opt-in. Status polling never opens System
    // Settings or shows a macOS accessibility prompt.
    if (request.method === 'POST' && url.pathname === '/api/request-accessibility') return json(response, 200, await voice('request-accessibility'));
    if (request.method === 'POST' && url.pathname === '/api/choices') return json(response, 200, await voice('choices'));
    if (request.method === 'POST' && url.pathname === '/api/set-model') {
      const input = await body(request);
      return json(response, 200, await voice('set-model', selectedValue(input, 'model', models, 'model')));
    }
    if (request.method === 'POST' && url.pathname === '/api/set-effort') {
      const input = await body(request);
      return json(response, 200, await voice('set-effort', selectedValue(input, 'effort', efforts, 'reasoning effort')));
    }
    if (request.method === 'POST' && url.pathname === '/api/unpair') {
      sessions.delete(parseCookies(request).cmr);
      await saveSessions();
      response.setHeader('set-cookie', 'cmr=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
      return json(response, 200, { ok: true });
    }
    return json(response, 404, { error: 'Not found' });
  } catch (error) {
    return json(response, 400, { error: error.message });
  }
});

setInterval(() => {
  let changed = false;
  for (const [token, session] of sessions) if (session.expires < Date.now()) { sessions.delete(token); changed = true; }
  if (changed) saveSessions().catch(error => console.warn(`Could not save pairings: ${error.message}`));
  for (const [ip, entry] of pairingAttempts) if (entry.lockedUntil && entry.lockedUntil < Date.now()) pairingAttempts.delete(ip);
}, 60_000).unref();
app.once('error', error => {
  // In particular, EADDRINUSE can happen before this process owns the port.
  // Do not touch a lease unless this process published it after listening.
  process.exitCode = 1;
  removeAdminLease().finally(() => console.error(error.message));
});
app.listen(port, '0.0.0.0', async () => {
  try {
    await writeAdminLease();
  } catch (error) {
    console.error(`Could not publish launcher admin lease: ${error.message}`);
    app.close(() => process.exit(1));
    return;
  }
  const ip = localIPv4();
  console.log(`Codex Mic Remote is listening on http://${ip ?? 'YOUR-MAC-IP'}:${port}`);
  console.log(`Pairing code: ${pairingCode} (expires in 10 minutes; restart to create a new one)`);
  console.log(`Paired phones remain available for 30 days in ${stateFile}`);
  console.log('LAN-only design: do not expose this port to the internet.');
});
