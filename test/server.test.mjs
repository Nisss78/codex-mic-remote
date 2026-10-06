import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { readFile, stat } from 'node:fs/promises';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const port = 18_787;
const fakeHelper = fileURLToPath(new URL('./fake-helper.mjs', import.meta.url));

async function startServer(existingStateDir, environment = {}) {
  const stateDir = existingStateDir ?? await mkdtemp(join(tmpdir(), 'codex-mic-remote-test-'));
  const adminFile = join(stateDir, 'launcher-admin.json');
  const child = spawn(process.execPath, ['server.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: { ...process.env, PORT: String(port), CMR_STATE_DIR: stateDir, CMR_ADMIN_FILE: adminFile, CMR_HELPER: fakeHelper, ...environment },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  const ready = new Promise((resolve, reject) => {
    child.stdout.on('data', chunk => {
      output += chunk;
      const match = output.match(/Pairing code: (\d{6})/);
      if (match) resolve(match[1]);
    });
    child.once('error', reject);
    child.stderr.on('data', chunk => reject(new Error(chunk.toString())));
  });
  return { child, ready, stateDir, adminFile };
}

async function stopServer(child) {
  child.kill('SIGTERM');
  await once(child, 'exit');
}

function rawRequest(request) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1');
    let response = '';
    socket.on('connect', () => socket.end(request));
    socket.on('data', chunk => { response += chunk; });
    socket.on('end', () => resolve(response));
    socket.on('error', reject);
  });
}

test('HTTP pairing gates status, rejects an invalid code, and permits a paired phone', async t => {
  const { child, ready, adminFile } = await startServer();
  t.after(() => stopServer(child));
  const code = await ready;
  const base = `http://127.0.0.1:${port}`;

  const unpaired = await fetch(`${base}/api/status`);
  assert.equal(unpaired.status, 401);

  const identity = await fetch(`${base}/api/identity`);
  assert.equal(identity.status, 200);
  const marker = await identity.json();
  assert.equal(marker.kind, 'codex-mic-remote');
  assert.equal(marker.protocol, 1);
  assert.equal(marker.version, '0.3.0');
  assert.equal(marker.pid, child.pid);
  assert.match(marker.instanceId, /^[a-f0-9]{32}$/);
  const lease = JSON.parse(await readFile(adminFile, 'utf8'));
  assert.equal(lease.instanceId, marker.instanceId);
  assert.equal(lease.pid, child.pid);
  assert.match(lease.token, /^[A-Za-z0-9_-]{40,}$/);
  assert.equal((await stat(adminFile)).mode & 0o777, 0o600);

  const badPair = await fetch(`${base}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"code":"000000"}' });
  assert.equal(badPair.status, 401);

  const paired = await fetch(`${base}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code }) });
  assert.equal(paired.status, 200);
  const cookie = paired.headers.get('set-cookie');
  assert.match(cookie ?? '', /HttpOnly/);
  assert.match(cookie ?? '', /SameSite=Strict/);

  const status = await fetch(`${base}/api/status`, { headers: { cookie } });
  assert.equal(status.status, 200);
  const result = await status.json();
  assert.equal(result.ok, true);
  if (result.available) assert.equal(typeof result.muted, 'boolean');
  else assert.equal(typeof result.error, 'string');

  const forged = await fetch(`${base}/api/status`, { headers: { cookie: 'cmr=forged' } });
  assert.equal(forged.status, 401);

  const malformedHost = await rawRequest('GET /api/status HTTP/1.1\r\nHost: [\r\nConnection: close\r\n\r\n');
  assert.match(malformedHost, /^HTTP\/1\.1 400 /);
});

test('HTTP pairing rate-limits repeated incorrect codes', async t => {
  const { child, ready } = await startServer();
  t.after(() => stopServer(child));
  await ready;
  const base = `http://127.0.0.1:${port}`;
  for (let count = 0; count < 8; count += 1) {
    const response = await fetch(`${base}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"code":"000000"}' });
    assert.equal(response.status, 401);
  }
  const blocked = await fetch(`${base}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"code":"000000"}' });
  assert.equal(blocked.status, 429);
});

test('launcher admin shutdown requires the matching lease and accepts only one concurrent request', async () => {
  const { child, ready, adminFile } = await startServer();
  await ready;
  const lease = JSON.parse(await readFile(adminFile, 'utf8'));
  const base = `http://127.0.0.1:${port}`;
  const shutdown = (token, instanceId) => fetch(`${base}/api/admin/shutdown`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-cmr-admin': token },
    body: JSON.stringify({ instanceId }),
  });

  assert.equal((await shutdown('wrong-token', lease.instanceId)).status, 403);
  assert.equal((await shutdown(lease.token, 'a-different-service-instance')).status, 403);
  const responses = await Promise.all([shutdown(lease.token, lease.instanceId), shutdown(lease.token, lease.instanceId)]);
  assert.deepEqual((await Promise.all(responses.map(response => response.status))).sort(), [200, 409]);
  await once(child, 'exit');
  await assert.rejects(readFile(adminFile, 'utf8'));
});

test('a failed same-state bind never replaces or removes the listening server lease', async t => {
  const first = await startServer();
  t.after(() => stopServer(first.child));
  await first.ready;
  const originalLease = await readFile(first.adminFile, 'utf8');
  const contender = spawn(process.execPath, ['server.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: { ...process.env, PORT: String(port), CMR_STATE_DIR: first.stateDir, CMR_ADMIN_FILE: first.adminFile, CMR_HELPER: fakeHelper },
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  const [exitCode] = await once(contender, 'exit');
  assert.notEqual(exitCode, 0);
  assert.equal(await readFile(first.adminFile, 'utf8'), originalLease);
  const identity = await fetch(`http://127.0.0.1:${port}/api/identity`);
  assert.equal((await identity.json()).pid, first.child.pid);
});

test('managed shutdown waits for in-flight control work before removing its lease', async () => {
  const { child, ready, adminFile } = await startServer(undefined, { FAKE_HELPER_DELAY_MS: '350' });
  const code = await ready;
  const base = `http://127.0.0.1:${port}`;
  const lease = JSON.parse(await readFile(adminFile, 'utf8'));
  const paired = await fetch(`${base}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code }) });
  const cookie = paired.headers.get('set-cookie');
  const pendingStatus = fetch(`${base}/api/status`, { headers: { cookie } });
  await new Promise(resolve => setTimeout(resolve, 40));
  const shutdown = await fetch(`${base}/api/admin/shutdown`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-cmr-admin': lease.token },
    body: JSON.stringify({ instanceId: lease.instanceId }),
  });
  assert.equal(shutdown.status, 200);
  assert.equal((await pendingStatus).status, 200);
  await once(child, 'exit');
  await assert.rejects(readFile(adminFile, 'utf8'));
});

test('remote page restores a valid session instead of showing pairing on every reload', async () => {
  const page = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(page, /async function restore\(\)/);
  assert.match(page, /await request\('\/api\/status'\)/);
  assert.match(page, /restore\(\);/);
});

test('remote page presents an accessible dedicated microphone control', async () => {
  const page = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(page, /<html lang="ja">/);
  assert.match(page, /id="micVisual"/);
  assert.match(page, /id="state" class="state" role="status" aria-live="polite"/);
  assert.match(page, /Mac全体のマイク設定は変更しません/);
  assert.match(page, /setMicAppearance\(v\.muted\)/);
});

test('advanced controls are authenticated, validate values, and are only user-triggered', async t => {
  const { child, ready } = await startServer();
  t.after(() => stopServer(child));
  const code = await ready;
  const base = `http://127.0.0.1:${port}`;
  const paired = await fetch(`${base}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code }) });
  const cookie = paired.headers.get('set-cookie');

  const unpairedStart = await fetch(`${base}/api/start-voice`, { method: 'POST' });
  assert.equal(unpairedStart.status, 401);
  const invalidModel = await fetch(`${base}/api/set-model`, { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: JSON.stringify({ model: 'anything' }) });
  assert.equal(invalidModel.status, 400);
  const status = await fetch(`${base}/api/status`, { headers: { cookie } });
  const result = await status.json();
  assert.equal(result.choices, undefined, 'status never opens configuration menus or invents options');
  const unpairedChoices = await fetch(`${base}/api/choices`, { method: 'POST' });
  assert.equal(unpairedChoices.status, 401);
  const unpairedPermission = await fetch(`${base}/api/request-accessibility`, { method: 'POST' });
  assert.equal(unpairedPermission.status, 401);
  const choices = await fetch(`${base}/api/choices`, { method: 'POST', headers: { cookie } });
  assert.equal(choices.status, 200);
  const permission = await fetch(`${base}/api/request-accessibility`, { method: 'POST', headers: { cookie } });
  assert.equal(permission.status, 200);
});

test('remote page exposes explicit chat, voice, model, and effort controls', async () => {
  const page = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(page, /id="newChat"/);
  assert.match(page, /id="startVoice"/);
  assert.match(page, /\.utility\.voice:disabled\{border-color:#dfe3e9/);
  assert.match(page, /アクセシビリティは許可されています。現在のCodex画面には音声会話の開始コントロールがない/);
  assert.match(page, /現在のCodexウィンドウにはアクティブなVoiceマイクがありません/);
  assert.match(page, /id="model" disabled><option>読み込み中…/);
  assert.match(page, /id="effort" disabled><option>読み込み中…/);
  assert.match(page, /runAction\('\/api\/start-voice'\)/);
  assert.match(page, /\/api\/choices/);
  assert.match(page, /モデル・エフォート候補を読み込む/);
  assert.match(page, /id='requestAccessibility'/);
  assert.match(page, /アクセシビリティを許可する/);
  assert.match(page, /\/api\/request-accessibility/);
});

test('Voice absence does not disable independent controls or leave an action lock stale', async () => {
  const page = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  const worker = await readFile(new URL('../public/sw.js', import.meta.url), 'utf8');
  assert.match(page, /newChat\.disabled=actionBusy\|\|!isAvailable\(c\.newChat\)/);
  assert.match(page, /choiceButton\.disabled=actionBusy\|\|!canConfigure/);
  assert.match(page, /let polling=false,optionsLoaded=false,actionBusy=false,lastStatus=null/);
  assert.match(page, /actionBusy=false;lockActions\(false\);await refresh\(\)/);
  assert.match(worker, /codex-mic-remote-v2/);
  assert.match(worker, /caches\.delete/);
});

test('AX helper recognizes the current Codex tab/model popup without treating dictation as Voice', async () => {
  const helper = await readFile(new URL('../macos/codex-voice-ax.swift', import.meta.url), 'utf8');
  assert.match(helper, /"新しいタブ"/);
  assert.match(helper, /canonicalModel/);
  assert.match(helper, /GPT-5\.6 Terra 中/);
  assert.match(helper, /kAXFocusedWindowAttribute/);
  assert.match(helper, /request-accessibility/);
  assert.match(helper, /AXIsProcessTrustedWithOptions/);
  const voiceLabels = helper.match(/let startVoiceLabels = \[([^\]]+)\]/)?.[1] ?? '';
  assert.doesNotMatch(voiceLabels, /音声入力/);
});

test('a paired phone survives a server restart and can revoke itself', async () => {
  const first = await startServer();
  const code = await first.ready;
  const base = `http://127.0.0.1:${port}`;
  const paired = await fetch(`${base}/api/pair`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code }) });
  const cookie = paired.headers.get('set-cookie');
  await stopServer(first.child);

  const second = await startServer(first.stateDir);
  try {
    await second.ready;
    const restored = await fetch(`${base}/api/status`, { headers: { cookie } });
    assert.equal(restored.status, 200);
    const revoked = await fetch(`${base}/api/unpair`, { method: 'POST', headers: { cookie } });
    assert.equal(revoked.status, 200);
    const rejected = await fetch(`${base}/api/status`, { headers: { cookie } });
    assert.equal(rejected.status, 401);
  } finally {
    await stopServer(second.child);
  }
});

test('concurrent pairings persist without overwriting each other', async () => {
  const first = await startServer();
  const code = await first.ready;
  const base = `http://127.0.0.1:${port}`;
  const pairings = await Promise.all(Array.from({ length: 3 }, () => fetch(`${base}/api/pair`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code }),
  })));
  const cookies = pairings.map(response => response.headers.get('set-cookie'));
  assert.deepEqual(pairings.map(response => response.status), [200, 200, 200]);
  await stopServer(first.child);
  const second = await startServer(first.stateDir);
  try {
    await second.ready;
    for (const cookie of cookies) {
      const restored = await fetch(`${base}/api/status`, { headers: { cookie } });
      assert.equal(restored.status, 200);
    }
  } finally {
    await stopServer(second.child);
  }
});
