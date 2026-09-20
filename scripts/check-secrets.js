#!/usr/bin/env node
/*
 * Guard against committing personal data or secrets. Run it before every commit / PR:
 *
 *     node scripts/check-secrets.js            # checks every tracked file (what is in the repo)
 *     node scripts/check-secrets.js --staged   # checks only what is staged for commit
 *
 * Exit code 1 if anything looks wrong, 0 if clean. It prints where, and a masked snippet - never the full value.
 *
 * Why it exists: this repo once shipped a real Google Sheet id, credential ids and a Telegram chat id because a
 * live export from n8n was committed over the sanitized template. Every check here is generic (patterns and
 * structure), so this file itself never contains anyone's real values. It is a cheap safety net, not a scanner
 * you can rely on alone: read your diff too.
 *
 * To silence a deliberate false positive, put `check-secrets:ignore` on the same line.
 */
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const staged = process.argv.includes('--staged');
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
const root = git('rev-parse', '--show-toplevel').trim();

const files = (staged ? git('diff', '--cached', '--name-only', '--diff-filter=ACM') : git('ls-files'))
  .split('\n').map(s => s.trim()).filter(Boolean);
const read = f => {
  try { return staged ? git('show', ':' + f) : fs.readFileSync(path.join(root, f), 'utf8'); } catch { return null; }
};

const BINARY = /\.(png|jpe?g|gif|ico|webp|pdf|zip|gz|tgz|woff2?|ttf|eot)$/i;
const findings = [];
const add = (file, line, rule, snippet) => findings.push({ file, line, rule, snippet });
const mask = s => (s.length <= 12 ? '****' : s.slice(0, 4) + '…' + s.slice(-2) + ` (${s.length} chars)`);

// ---- 1. Secrets that look like secrets, in any text file ----------------------------------------------------------
const PATTERNS = [
  ['telegram-bot-token', /\b\d{8,10}:[A-Za-z0-9_-]{35}\b/],
  ['google-api-key', /\bAIza[0-9A-Za-z_-]{35}\b/],
  ['google-oauth-client-secret', /\bGOCSPX-[0-9A-Za-z_-]{20,}\b/],
  ['aws-access-key-id', /\bAKIA[0-9A-Z]{16}\b/],
  ['github-token', /\bgh[pousr]_[A-Za-z0-9]{36,}\b/],
  ['jwt-like-token (n8n API key?)', /\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b/],
  ['private-key-block', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
];
// hard-coded public IPs in code/config (docs use example IPs, so .md is skipped); loopback, link-local metadata and
// documentation-style placeholders are fine
const IP_URL = /https?:\/\/(\d{1,3}(?:\.\d{1,3}){3})\b/g;
const IP_OK = new Set(['127.0.0.1', '0.0.0.0', '169.254.169.254']);
const CODE_FILE = /\.(js|cjs|mjs|sh|py|yml|yaml|gs|json|conf|Caddyfile)$|(^|\/)Caddyfile$|(^|\/)Dockerfile$/;

// files that must never be tracked at all
const FORBIDDEN_PATH = /(^|\/)(\.env|id_rsa[^/]*|[^/]*\.pem|[^/]*\.key|[^/]*\.p12|[^/]*\.pfx)$|(^|\/)\.env\.(?!example$)[^/]+$/;

for (const f of files) {
  if (FORBIDDEN_PATH.test(f)) { add(f, 0, 'forbidden-file', 'this kind of file should not be tracked'); continue; }
  if (BINARY.test(f)) continue;
  const text = read(f);
  if (text == null) continue;
  const lines = text.split('\n');
  lines.forEach((line, i) => {
    if (line.includes('check-secrets:ignore')) return;
    for (const [rule, re] of PATTERNS) { const m = line.match(re); if (m) add(f, i + 1, rule, mask(m[0])); }
    if (CODE_FILE.test(f) && f !== 'scripts/check-secrets.js') {
      for (const m of line.matchAll(IP_URL)) if (!IP_OK.has(m[1])) add(f, i + 1, 'hard-coded-ip-url', mask(m[0]));
    }
  });
}

// ---- 2. The shipped n8n workflows must stay sanitized templates -----------------------------------------------------
const PLACEHOLDER_DOC = 'YOUR_GOOGLE_SHEET_DOCUMENT_ID';
for (const f of files.filter(x => /^n8n_[^/]*\.json$/.test(x))) {
  const text = read(f);
  let wf;
  try { wf = JSON.parse(text); } catch (e) { add(f, 0, 'invalid-json', e.message); continue; }
  const where = n => `node "${n.name}"`;
  for (const n of wf.nodes || []) {
    for (const [kind, cred] of Object.entries(n.credentials || {})) {
      if (!cred || cred.id !== 'CONFIGURE_ME') add(f, 0, 'credential-id-not-placeholder', `${where(n)} ${kind} id=${mask(String(cred && cred.id))} (expected CONFIGURE_ME)`);
    }
    const p = n.parameters || {};
    if (p.documentId !== undefined) {
      const v = typeof p.documentId === 'object' ? p.documentId.value : p.documentId;
      if (v !== PLACEHOLDER_DOC) add(f, 0, 'google-sheet-id-not-placeholder', `${where(n)} documentId=${mask(String(v))} (expected ${PLACEHOLDER_DOC})`);
      const url = typeof p.documentId === 'object' ? p.documentId.cachedResultUrl : null;
      if (url && /\/spreadsheets\/d\/(?!YOUR_)/.test(url)) add(f, 0, 'google-sheet-url', `${where(n)} cachedResultUrl points at a real spreadsheet`);
    }
    if (typeof p.chatId === 'string' && /^-?\d{5,}$/.test(p.chatId.trim())) add(f, 0, 'telegram-chat-id-literal', `${where(n)} chatId=${mask(p.chatId)} (use an expression such as ={{ $env.TELEGRAM_CHAT_ID }})`);
    if (n.type === 'n8n-nodes-base.telegramTrigger' && n.webhookId) add(f, 0, 'telegram-trigger-webhook-id', `${where(n)} carries a webhookId from a live instance`);
  }
  if (wf.pinData && Object.keys(wf.pinData).length) add(f, 0, 'pinned-data', 'pinData holds real execution data');
  if (wf.staticData && Object.keys(wf.staticData).length) add(f, 0, 'static-data', 'staticData holds a live instance\'s state');
  if (wf.meta && wf.meta.instanceId) add(f, 0, 'instance-id', 'meta.instanceId identifies a live n8n instance');
}

// ---- report ---------------------------------------------------------------------------------------------------------
const scope = staged ? 'staged files' : 'tracked files';
if (!findings.length) { console.log(`check-secrets: OK (${files.length} ${scope} checked)`); process.exit(0); }
console.error(`check-secrets: ${findings.length} finding(s) in ${scope}:\n`);
for (const x of findings) console.error(`  ${x.file}${x.line ? ':' + x.line : ''}  [${x.rule}]  ${x.snippet}`);
console.error('\nFix these (or add `check-secrets:ignore` on a line that is a deliberate false positive) before committing.');
process.exit(1);
