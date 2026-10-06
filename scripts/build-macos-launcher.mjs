import { execFileSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const app = join(root, 'dist', 'Codex Mic Remote.app');
const contents = join(app, 'Contents');
const macOS = join(contents, 'MacOS');
const resources = join(contents, 'Resources');
const runtime = join(resources, 'codex-mic-remote');

// Build the helper before copying it into the app so the launcher never needs npm.
execFileSync('npm', ['run', 'build:helper'], { cwd: root, stdio: 'inherit' });
rmSync(app, { recursive: true, force: true });
mkdirSync(macOS, { recursive: true });
mkdirSync(runtime, { recursive: true });

for (const source of ['server.mjs', 'public', 'build']) {
  cpSync(join(root, source), join(runtime, source), { recursive: true });
}
cpSync(join(root, 'macos', 'AppIcon.icns'), join(resources, 'AppIcon.icns'));
writeFileSync(join(runtime, 'node-path.txt'), `${process.execPath}\n`, { mode: 0o600 });
writeFileSync(join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleDisplayName</key><string>Codex Mic Remote</string>
  <key>CFBundleExecutable</key><string>Codex Mic Remote</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.codex.mic-remote</string>
  <key>CFBundleName</key><string>Codex Mic Remote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.2</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
`);

execFileSync('swiftc', [
  join(root, 'macos', 'launcher.swift'),
  '-parse-as-library',
  '-o', join(macOS, 'Codex Mic Remote'),
  '-framework', 'Cocoa',
  '-framework', 'CoreImage',
  '-framework', 'Network',
], { stdio: 'inherit' });
chmodSync(join(macOS, 'Codex Mic Remote'), 0o755);
chmodSync(join(runtime, 'build', 'codex-voice-ax'), 0o755);

if (!existsSync(join(runtime, 'server.mjs'))) throw new Error('Launcher runtime is incomplete.');
console.log(`Built ${app}`);
