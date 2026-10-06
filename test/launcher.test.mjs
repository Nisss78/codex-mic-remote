import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('macOS launcher keeps the server local and QR payload free of session tokens', async () => {
  const source = await readFile(new URL('../macos/launcher.swift', import.meta.url), 'utf8');
  assert.match(source, /serverPort = 8787/);
  assert.match(source, /\"PORT\": String\(serverPort\)/);
  assert.match(source, /#pair=\\\(code\)/);
  assert.match(source, /pendingServerOutput/);
  assert.match(source, /consumeServerLine/);
  assert.match(source, /expirePairingCode/);
  assert.match(source, /window\.isReleasedWhenClosed = false/);
  assert.match(source, /アクセシビリティ設定を開く/);
  assert.match(source, /x-apple\.systempreferences:com\.apple\.preference\.security\?Privacy_Accessibility/);
  assert.match(source, /NSWorkspace\.shared\.open\(url\)/);
  assert.match(source, /Codex Mic Remote を再起動/);
  assert.match(source, /\/api\/identity/);
  assert.match(source, /CMR_ADMIN_FILE/);
  assert.match(source, /launcher-admin\.json/);
  assert.match(source, /\/api\/admin\/shutdown/);
  assert.match(source, /X-CMR-Admin/);
  assert.match(source, /readMatchingAdminLease/);
  assert.match(source, /確認できない、または旧版のプロセス.*安全のため停止しません/is);
  assert.doesNotMatch(source, /kill\(/);
  assert.doesNotMatch(source, /legacyCMRListeningPID/);
  assert.match(source, /process\?\.terminate\(\)/);
  assert.match(source, /pre-existing server.*never attempts to stop it/is);
  assert.match(source, /アップデートを確認/);
  assert.match(source, /api\.github\.com\/repos/);
  assert.match(source, /Nisss78\/codex-mic-remote/);
  assert.match(source, /SHA256/);
  assert.match(source, /name\.lowercased\(\)\.hasSuffix\("\.app\.zip"\)/);
  assert.match(source, /name\.uppercased\(\)\.contains\("SHA256"\)/);
  assert.match(source, /ダウンロードして更新/);
  assert.doesNotMatch(source, /cmr=/);
});

test('app build embeds the local server and helper instead of requiring npm at launch', async () => {
  const build = await readFile(new URL('../scripts/build-macos-launcher.mjs', import.meta.url), 'utf8');
  assert.match(build, /\['server\.mjs', 'public', 'build'\]/);
  assert.match(build, /build:helper/);
  assert.match(build, /node-path\.txt/);
  assert.match(build, /NSAllowsLocalNetworking/);
  assert.match(build, /LSMinimumSystemVersion<\/key><string>15\.0/);
  assert.match(build, /AppIcon\.icns/);
  assert.match(build, /CFBundleShortVersionString<\/key><string>0\.4\.1/);
});
