// Per-job score delta between two compared runs (regression gate).
// Usage: node delta.mjs <baseline run> <candidate run> [--threshold 0.05]
import path from 'node:path';
import { readJson, runDir } from './common.mjs';

const [base, next] = process.argv.slice(2);
const i = process.argv.indexOf('--threshold');
const threshold = i > 0 ? Number(process.argv[i + 1]) : 0.05;
const load = (run) => new Map(readJson(path.join(runDir(run), 'results.json')).results.map((r) => [r.key, r]));
const a = load(base);
const b = load(next);
const rows = [];
for (const [key, after] of b) {
  const before = a.get(key);
  if (!before) continue;
  rows.push({ key, before: before.score, after: after.score, delta: Math.round((after.score - before.score) * 1000) / 1000, errors: [before.errors?.length ?? 0, after.errors?.length ?? 0] });
}
const worse = rows.filter((r) => r.delta > threshold).sort((x, y) => y.delta - x.delta);
const better = rows.filter((r) => r.delta < -threshold).sort((x, y) => x.delta - y.delta);
const sum = (run) => [...run.values()].reduce((s, r) => s + r.score, 0);
console.log(`jobs ${rows.length}; total score ${sum(a).toFixed(1)} -> ${sum(b).toFixed(1)}; better ${better.length}, worse ${worse.length}`);
console.log('worse:');
for (const r of worse.slice(0, 30)) console.log(`  +${r.delta}\t${r.before} -> ${r.after}\t${r.key}\terrors ${r.errors.join('->')}`);
console.log('better:');
for (const r of better.slice(0, 30)) console.log(`  ${r.delta}\t${r.before} -> ${r.after}\t${r.key}\terrors ${r.errors.join('->')}`);
