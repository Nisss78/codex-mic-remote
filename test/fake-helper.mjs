#!/usr/bin/env node
const action = process.argv[2] ?? 'status';
const delay = Number(process.env.FAKE_HELPER_DELAY_MS ?? 0);
if (delay > 0) await new Promise(resolve => setTimeout(resolve, delay));
const base = {
  ok: true,
  available: true,
  muted: true,
  label: 'Unmute microphone',
  error: null,
  capabilities: {
    newChat: { available: true, error: null },
    startVoice: { available: true, error: null },
    model: { available: true, error: null },
    effort: { available: true, error: null },
  },
  current: { model: 'gpt-6.1-sol', effort: 'medium' },
  targetWindow: 'Test Codex chat',
};
if (action === 'choices') base.choices = { models: ['gpt-6.1-sol'], efforts: ['medium'] };
if (action !== 'status') base.action = action;
process.stdout.write(JSON.stringify(base));
