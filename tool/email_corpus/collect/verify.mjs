// Verify pilot corpus: manifest <-> files (bytes, sha256), no <script>, size
// limits, structure-hash cap; print counts per source and per ESP.
// Usage: node verify.mjs
import fs from 'node:fs';
import path from 'node:path';
import { PILOT_DIR } from './lib/paths.mjs';
import { sha256, parseDoc, walkElements } from './lib/html.mjs';
import { MIN_BYTES, MAX_BYTES, MAX_PER_STRUCTURE } from './lib/corpus.mjs';

const lines = fs.readFileSync(path.join(PILOT_DIR, 'manifest.jsonl'), 'utf8').split('\n').filter(Boolean);
const entries = lines.map((l) => JSON.parse(l));
const problems = [];
const perSource = {};
const perEsp = {};
const struct = {};
const shas = new Set();
const listed = new Set();
for (const e of entries) {
  perSource[e.source] = (perSource[e.source] || 0) + 1;
  if (e.esp) perEsp[e.esp] = (perEsp[e.esp] || 0) + 1;
  const f = path.join(PILOT_DIR, e.path);
  listed.add(path.resolve(f));
  if (!fs.existsSync(f)) {
    problems.push(`${e.id}: missing file`);
    continue;
  }
  const html = fs.readFileSync(f, 'utf8');
  const bytes = fs.statSync(f).size;
  if (bytes !== e.bytes) problems.push(`${e.id}: bytes ${bytes} != ${e.bytes}`);
  if (sha256(html) !== e.sha256) problems.push(`${e.id}: sha mismatch`);
  if (shas.has(e.sha256)) problems.push(`${e.id}: duplicate sha`);
  shas.add(e.sha256);
  if (bytes > MAX_BYTES) problems.push(`${e.id}: too large`);
  if (bytes < MIN_BYTES && e.source !== 'caniemail') problems.push(`${e.id}: too small`);
  for (const el of walkElements(parseDoc(html))) if (el.tagName === 'script') problems.push(`${e.id}: has <script>`);
  if (e.source !== 'caniemail') struct[e.structure_hash] = (struct[e.structure_hash] || 0) + 1;
}
for (const [h, n] of Object.entries(struct)) if (n > MAX_PER_STRUCTURE) problems.push(`structure ${h} used ${n}x`);
// Orphan files
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((x) => (x.isDirectory() ? walk(path.join(d, x.name)) : [path.join(d, x.name)]));
for (const f of walk(PILOT_DIR)) if (f.endsWith('.html') && !listed.has(path.resolve(f))) problems.push(`orphan file ${path.relative(PILOT_DIR, f)}`);

console.log('per source:', perSource);
console.log('per ESP   :', perEsp);
console.log(`total ${entries.length}; problems: ${problems.length}`);
for (const p of problems.slice(0, 50)) console.log('  ' + p);
process.exit(problems.length ? 1 : 0);
