import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { captureJobs, captureKey, fingerprintFiles, jobKey, runDir, writeJson } from './common.mjs';

function tempDirectory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'email-capture-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('capture job names do not collide when email ids sanitize to the same name', () => {
  assert.notEqual(jobKey('source/mail', 375), jobKey('source_mail', 375));
  assert.notEqual(jobKey('source/mail', 375), jobKey('source/mail', 680));
});

test('capture keys vary with source, renderer settings and actual asset bytes', (t) => {
  const dir = tempDirectory(t);
  const input = path.join(dir, 'asset');
  fs.writeFileSync(input, 'old');
  const before = fingerprintFiles([input]);
  fs.writeFileSync(input, 'new');
  const after = fingerprintFiles([input]);
  const base = captureKey('settings', 'html', [before]);
  assert.notEqual(base, captureKey('settings', 'html', [after]));
  assert.notEqual(base, captureKey('updated', 'html', [before]));
  assert.notEqual(base, captureKey('settings', 'updated', [before]));
});

test('a manifest records all widths and rejects duplicate input ids', (t) => {
  const dir = tempDirectory(t);
  const file = path.join(dir, 'mail.html');
  fs.writeFileSync(file, '<p>Hello</p>');
  const email = { id: 'mail', file };
  const jobs = captureJobs([email], dir);
  assert.ok(jobs.size > 0);
  assert.throws(() => captureJobs([email, email], dir), /Duplicate capture job/);
  assert.throws(() => captureJobs([], dir), /No capture jobs/);
});

test('delta exits with an error for a regression or a missing capture', (t) => {
  const root = runDir('');
  fs.mkdirSync(root, { recursive: true });
  const dir = fs.mkdtempSync(path.join(root, 'test-delta-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const old = path.join(dir, 'old');
  const next = path.join(dir, 'next');
  const compare = () => spawnSync(process.execPath, [
    fileURLToPath(new URL('./delta.mjs', import.meta.url)),
    path.relative(runDir(''), old),
    path.relative(runDir(''), next),
  ], { encoding: 'utf8' });
  const oldResults = [{ key: 'a', score: 0 }, { key: 'b', score: 0 }];
  writeJson(path.join(old, 'results.json'), { results: oldResults });
  writeJson(path.join(next, 'results.json'), { results: oldResults });
  const clean = compare();
  assert.equal(clean.status, 0, clean.stderr);
  writeJson(path.join(next, 'results.json'), { results: [oldResults[0]] });
  assert.match(compare().stderr, /1 missing/);
  assert.equal(compare().status, 1);
  writeJson(path.join(next, 'results.json'), { results: [{ key: 'a', score: 1 }, oldResults[1]] });
  assert.equal(compare().status, 1);
});
