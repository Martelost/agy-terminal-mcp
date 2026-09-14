/**
 * prompt-parser.test.mjs
 * Unit tests for the auto-approve prompt matching and path validation logic.
 * Run: node tests/agy-terminal/prompt-parser.test.mjs
 */

import { createHash } from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';

// ── Replicate the path validation logic from agy-visible-input.ps1 ───────────
// These must stay in sync with the PowerShell implementation.

const APPROVE_PATTERNS = [
  /allow\s+file\s+creation/i,
  /allow\s+file\s+edit/i,
  /allow\s+file\s+write/i,
  /allow\s+modification/i
];

const BLOCK_PATTERNS = [
  /run\s+this\s+command/i,
  /\bshell\b/i,
  /\bbash\b/i,
  /\bpowershell\b/i,
  /\bdelete\b/i,
  /authorization\s+code/i,
  /\boauth\b/i,
  /\blog\s*in\b/i,
  /\blogin\b/i,
  /network\s+access/i,
  /workspace\s+trust/i,
  /accounts\.google\.com/i,
  /verification\s+code/i,
  /paste.*code/i
];

function normalizePath(rawPath, baseCwd) {
  let p = rawPath.trim().replace(/^["']|["']$/g, '');
  if (!path.isAbsolute(p)) {
    if (!baseCwd) return null;
    p = path.join(baseCwd, p);
  }
  // Reject .. escape
  if (/(?:^|[\\/])\.\.(?:[\\/]|$)/.test(p)) return null;
  try {
    return path.resolve(p).toLowerCase();
  } catch {
    return null;
  }
}

function isInScope(normalizedPath, normalizedCwd, normalizedEditables) {
  if (!normalizedPath) return false;
  const cwdPrefix = normalizedCwd.replace(/[\\/]+$/, '');
  if (!normalizedPath.startsWith(cwdPrefix + path.sep) &&
      !normalizedPath.startsWith(cwdPrefix + '/') &&
      normalizedPath !== cwdPrefix) return false;
  if (normalizedEditables.length === 0) return false;
  if (!normalizedEditables.includes(normalizedPath)) return false;
  // Sensitive filename check
  const filename = path.basename(normalizedPath);
  if (/(^\.env|\.key$|secret|credential|password|token|auth)/i.test(filename)) return false;
  return true;
}

function shouldAutoApprove(promptText, cwd, editableFiles) {
  // Hard block check first
  for (const bp of BLOCK_PATTERNS) {
    if (bp.test(promptText)) return { approved: false, reason: `blocked: ${bp}` };
  }
  // Must match a file-edit pattern
  const isFileEdit = APPROVE_PATTERNS.some((ap) => ap.test(promptText));
  if (!isFileEdit) return { approved: false, reason: 'no file-edit pattern matched' };

  // Path validation
  const normalizedCwd = cwd ? path.resolve(cwd).toLowerCase() : '';
  const normalizedEditables = editableFiles.map((f) => {
    try { return path.resolve(f).toLowerCase(); } catch { return null; }
  }).filter(Boolean);

  // Extract path from prompt line (simplified version of PS1 logic)
  const pathMatch =
    promptText.match(/"([^"]+)"/) ||
    promptText.match(/'([^']+)'/) ||
    promptText.match(/(?:^|[\s:])([A-Za-z]:[\\/][^\s"']+|[/\\][^\s"']+)/);

  if (!pathMatch) return { approved: false, reason: 'no path extracted from prompt' };
  const rawPath = pathMatch[1];
  const normalizedPath = normalizePath(rawPath, cwd);
  if (!normalizedPath) return { approved: false, reason: 'path normalization failed (possible .. escape)' };

  const inScope = isInScope(normalizedPath, normalizedCwd, normalizedEditables);
  return { approved: inScope, reason: inScope ? 'path in scope' : 'path out of scope' };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  ✓  ${name}`);
    passed++;
  } catch (e) {
    console.error(`  ✗  ${name}`);
    console.error(`     ${e.message}`);
    failed++;
  }
}

const CWD = 'C:\\project\\A';
const EDITABLE = [`${CWD}\\app.js`, `${CWD}\\styles.css`];

console.log('\nPrompt Parser Unit Tests\n');

// ── Approve cases ─────────────────────────────────────────────────────────────
test('approve: allow file edit — path in editableFiles', () => {
  const r = shouldAutoApprove(`Allow file edit to "${CWD}\\app.js"?`, CWD, EDITABLE);
  assert.equal(r.approved, true, `Expected approved but got: ${r.reason}`);
});

test('approve: allow file write — path in editableFiles', () => {
  const r = shouldAutoApprove(`Allow file write to "${CWD}\\styles.css"?`, CWD, EDITABLE);
  assert.equal(r.approved, true);
});

test('approve: allow file creation — path in editableFiles', () => {
  const r = shouldAutoApprove(`Allow file creation: "${CWD}\\app.js"`, CWD, EDITABLE);
  assert.equal(r.approved, true);
});

test('approve: allow modification — path in editableFiles', () => {
  const r = shouldAutoApprove(`Allow modification of "${CWD}\\styles.css"?`, CWD, EDITABLE);
  assert.equal(r.approved, true);
});

// ── Block cases ───────────────────────────────────────────────────────────────
test('block: shell command prompt', () => {
  const r = shouldAutoApprove(`Run this command: npm install`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: bash', () => {
  const r = shouldAutoApprove(`Allow bash execution?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: powershell', () => {
  const r = shouldAutoApprove(`Allow PowerShell command?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: delete operation', () => {
  const r = shouldAutoApprove(`Allow file edit and delete of "${CWD}\\app.js"?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: oauth prompt', () => {
  const r = shouldAutoApprove(`Authorization code: paste the OAuth token here`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: login prompt', () => {
  const r = shouldAutoApprove(`Please log in to continue. Allow file edit?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: network access', () => {
  const r = shouldAutoApprove(`Allow file write and network access?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: workspace trust', () => {
  const r = shouldAutoApprove(`Workspace trust required. Allow file edit?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: accounts.google.com oauth url', () => {
  const r = shouldAutoApprove(`Visit https://accounts.google.com/o/oauth2/auth to sign in`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: verification code prompt', () => {
  const r = shouldAutoApprove(`Enter verification code: Allow file edit?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: mixed file edit with shell command', () => {
  const r = shouldAutoApprove(`Allow file edit to "${CWD}\\app.js" and run this command: npm test`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

// ── Path out of scope ─────────────────────────────────────────────────────────
test('block: file not in editableFiles', () => {
  const r = shouldAutoApprove(`Allow file edit to "${CWD}\\risk-engine.js"?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: file outside cwd (different project)', () => {
  const r = shouldAutoApprove(`Allow file edit to "C:\\project\\B\\app.js"?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: .. path traversal', () => {
  const r = shouldAutoApprove(`Allow file edit to "${CWD}\\..\\..\\secret.txt"?`, CWD, EDITABLE);
  assert.equal(r.approved, false);
});

test('block: .env file', () => {
  const EDITABLE_WITH_ENV = [...EDITABLE, `${CWD}\\.env`];
  const r = shouldAutoApprove(`Allow file edit to "${CWD}\\.env"?`, CWD, EDITABLE_WITH_ENV);
  assert.equal(r.approved, false, '.env should never be auto-approved');
});

test('block: credentials file', () => {
  const r = shouldAutoApprove(`Allow file write to "${CWD}\\credentials.json"?`, CWD,
    [...EDITABLE, `${CWD}\\credentials.json`]);
  assert.equal(r.approved, false);
});

test('block: empty editableFiles → deny all', () => {
  const r = shouldAutoApprove(`Allow file edit to "${CWD}\\app.js"?`, CWD, []);
  assert.equal(r.approved, false);
});

// ── pipe name derivation ──────────────────────────────────────────────────────
test('pipe name: same cwd → same hash', () => {
  const hash = (cwd) => createHash('sha256')
    .update(cwd.toLowerCase())
    .digest('hex')
    .slice(0, 8);
  assert.equal(hash('C:\\project\\A'), hash('C:\\project\\A'));
  assert.equal(hash('C:\\project\\A'), hash('c:\\project\\a'));  // case-insensitive
  assert.notEqual(hash('C:\\project\\A'), hash('C:\\project\\B'));
});

// ── Summary ───────────────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed\n`);
if (failed > 0) process.exit(1);
