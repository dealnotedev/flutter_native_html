// Renders the corpus with flutter_native_html via generated `flutter test` shards.
// Usage: node run_flutter.mjs <manifest.jsonl|dir> --run <name> [--shards 8] [--force] [--filter re]
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import {
  assetsDir,
  flutterConfig,
  fontsManifest,
  harnessDir,
  imageUrls,
  jobKey,
  loadCorpus,
  readJson,
  repoDir,
  runDir,
  widths,
} from './common.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const source = args[0];
const run = option('--run', 'pilot');
const shards = Number(option('--shards', '8'));
const force = args.includes('--force');
const filter = option('--filter') ? new RegExp(option('--filter')) : null;
const outDir = path.join(runDir(run), 'flutter');
const specDir = path.join(outDir, '_jobs');
const genDir = path.join(harnessDir, '_gen');
fs.mkdirSync(specDir, { recursive: true });
fs.rmSync(genDir, { recursive: true, force: true });
fs.mkdirSync(genDir, { recursive: true });

const fonts = readJson(fontsManifest);
const assetIndex = readJson(path.join(assetsDir, 'index.json'), {});
const baseFamilies = ['Arial', 'Times New Roman', 'Courier New', 'Segoe UI', 'Segoe UI Emoji', 'Segoe UI Symbol'];
// Chrome's Windows defaults for generics the renderer leaves unresolved.
const genericFaces = { cursive: 'comic sans ms', fantasy: 'impact' };
// Generics the renderer itself resolves on Windows (HtmlStyle._resolvedFontFamilies).
const rendererGenerics = {
  serif: 'times new roman',
  'sans-serif': 'arial',
  monospace: 'courier new',
  'system-ui': 'segoe ui',
  '-apple-system': 'segoe ui',
  blinkmacsystemfont: 'segoe ui',
};

/** Installed family key (lower case) Chrome resolves [name] to, or null. */
function installedKey(name) {
  const lower = name.toLowerCase();
  for (const key of [lower, fonts.aliases[lower], genericFaces[lower]]) {
    if (key && fonts.families[key]) return key;
  }
  return null;
}

const decodeEntities = (s) => s.replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&amp;/g, '&');
const cleanFamily = (part) =>
  part
    .trim()
    .replace(/!important$/i, '')
    .trim()
    .replace(/^['"]|['"]$/g, '')
    .trim();

/** Authored font-family lists, in declaration order, with authored spelling. */
function familyLists(html) {
  const css = [
    ...[...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1]),
    ...[...html.matchAll(/\sstyle\s*=\s*("([^"]*)"|'([^']*)')/gi)].map((m) => decodeEntities(m[2] ?? m[3])),
  ];
  const split = (value) => value.split(',').map(cleanFamily).filter(Boolean);
  const lists = [];
  for (const raw of css) {
    // An @font-face `font-family` names the face being declared, not a list
    // anything is rendered with (Constant Contact declares Roboto, Lato, ...
    // in every email).
    const text = raw.replace(/@font-face\s*\{[^}]*\}/gi, '');
    for (const m of text.matchAll(/font-family\s*:\s*([^;}]+)/gi)) lists.push(split(m[1]));
    for (const m of text.matchAll(/(?:^|[;{\s])font\s*:\s*[^;}]*?[\d.]+(?:px|pt|em|rem|%)(?:\s*\/\s*[\w.%]+)?\s+([^;}]+)/gi)) {
      lists.push(split(m[1]));
    }
  }
  for (const m of html.matchAll(/\bface\s*=\s*("[^"]*"|'[^']*')/gi)) lists.push(split(decodeEntities(m[1].slice(1, -1))));
  return lists;
}

/**
 * flutter_tester resolves *every* unknown family name to its test font, so a
 * missing first family never falls through to the next one as on a device.
 * Emulate the platform: alias each uninstalled name to the face Chrome picks
 * for that list (the first installed entry, else the default serif).
 * Returns authored name -> installed family key.
 */
function aliasMap(lists) {
  // One alias per name: when lists disagree (`Roboto, sans-serif` vs
  // `Roboto, serif`), the resolution most lists ask for wins. Flutter matches
  // family names case-insensitively, so votes are per lower-cased name and
  // every authored spelling gets the winner.
  const votes = new Map();
  const spellings = new Map();
  for (const list of lists) {
    let resolved = null;
    for (const name of list) {
      resolved = rendererGenerics[name.toLowerCase()] ?? installedKey(name);
      if (resolved) break;
    }
    resolved ??= 'times new roman';
    for (const name of list) {
      if (rendererGenerics[name.toLowerCase()] || installedKey(name)) break;
      const lower = name.toLowerCase();
      if (!votes.has(lower)) {
        votes.set(lower, new Map());
        spellings.set(lower, new Set());
      }
      spellings.get(lower).add(name);
      const count = votes.get(lower);
      count.set(resolved, (count.get(resolved) ?? 0) + 1);
    }
  }
  const out = new Map();
  for (const [lower, count] of votes) {
    const winner = [...count].sort((a, b) => b[1] - a[1])[0][0];
    for (const name of spellings.get(lower)) out.set(name, winner);
  }
  return out;
}

/** Font registrations: installed names under their authored spelling, plus aliases. */
function registrations(aliases, names) {
  const out = new Map();
  const faces = (key) => fonts.families[key].faces.map((face) => face.file);
  for (const name of [...baseFamilies, ...names]) {
    const key = installedKey(name);
    if (key) out.set(name, faces(key));
  }
  for (const [name, key] of aliases) out.set(name, faces(key));
  return out;
}

const corpus = loadCorpus(source).filter((email) => !filter || filter.test(email.id));
const emails = [];
for (const email of corpus) {
  if (!fs.existsSync(email.file)) continue;
  const html = fs.readFileSync(email.file, 'utf8');
  const images = imageUrls(html).filter((url) => assetIndex[url]?.file);
  const lists = familyLists(html);
  const jobs = [];
  for (const width of widths) {
    const key = jobKey(email.id, width);
    if (!force && fs.existsSync(path.join(outDir, key + '.json'))) continue;
    jobs.push({ id: email.id, file: email.file.replace(/\\/g, '/'), width, key, images });
  }
  if (jobs.length) emails.push({ jobs, aliases: aliasMap(lists), names: [...new Set(lists.flat())] });
}

// Aliases are process-global, so emails that need different faces for the
// same unknown name go to different shards.
const buckets = [];
const capacity = Math.ceil(emails.length / shards) + 1;
let conflicts = 0;
for (const email of emails) {
  // Conflicts are checked case-insensitively, as Flutter resolves families.
  const fits = (bucket) =>
    [...email.aliases].every(([name, key]) => (bucket.faces.get(name.toLowerCase()) ?? key) === key);
  let bucket = buckets.find((b) => b.emails.length < capacity && fits(b));
  if (!bucket && buckets.length < shards * 3) {
    buckets.push((bucket = { emails: [], aliases: new Map(), faces: new Map(), names: new Set() }));
  }
  if (!bucket) {
    bucket = buckets.reduce((a, b) => (a.emails.length <= b.emails.length ? a : b));
    conflicts++;
  }
  bucket.emails.push(email);
  for (const [name, key] of email.aliases) {
    const lower = name.toLowerCase();
    if (!bucket.faces.has(lower)) bucket.faces.set(lower, key);
    // A conflicting email that landed here anyway keeps the shard's face.
    if (!bucket.aliases.has(name)) bucket.aliases.set(name, bucket.faces.get(lower));
  }
  for (const name of email.names) bucket.names.add(name);
}
const jobCount = emails.reduce((n, e) => n + e.jobs.length, 0);
console.log(`${jobCount} flutter jobs in ${buckets.length} shards (${conflicts} emails with alias conflicts)`);
if (!jobCount) process.exit(0);

const testFiles = [];
buckets.forEach((bucket, shard) => {
  const name = `shard_${String(shard).padStart(2, '0')}`;
  const spec = {
    outDir: outDir.replace(/\\/g, '/'),
    assetsDir: assetsDir.replace(/\\/g, '/'),
    config: flutterConfig,
    // --no-png: layout dumps only (the report then shows no Flutter screenshot).
    png: !args.includes('--no-png'),
    fonts: [...registrations(bucket.aliases, bucket.names)].map(([family, files]) => ({ name: family, files })),
    jobs: bucket.emails.flatMap((email) => email.jobs),
  };
  const specFile = path.join(specDir, `${name}.json`).replace(/\\/g, '/');
  fs.writeFileSync(specFile, JSON.stringify(spec));
  const testFile = path.join(genDir, `${name}_test.dart`);
  fs.writeFileSync(testFile, `import '../flutter_capture.dart';\n\nvoid main() => runShard(${JSON.stringify(specFile)});\n`);
  testFiles.push(path.relative(repoDir, testFile).replace(/\\/g, '/'));
});

const started = Date.now();
const child = spawn(
  'flutter',
  ['test', `--concurrency=${shards}`, '--reporter=compact', '--no-pub', ...testFiles],
  { cwd: repoDir, shell: true, stdio: ['ignore', 'pipe', 'pipe'] },
);
const log = fs.createWriteStream(path.join(outDir, '_flutter.log'));
child.stdout.pipe(log);
child.stderr.pipe(log);
let last = 0;
child.stdout.on('data', (chunk) => {
  const match = String(chunk).match(/\+(\d+)(?: ~\d+)?(?: -(\d+))?:/g);
  if (match && Date.now() - last > 15000) {
    last = Date.now();
    console.log(`${match.at(-1)} of ${jobCount} (${Math.round((Date.now() - started) / 1000)}s)`);
  }
});
const code = await new Promise((resolve) => child.on('close', resolve));
console.log(`flutter done in ${Math.round((Date.now() - started) / 1000)}s, exit ${code}; log: ${path.join(outDir, '_flutter.log')}`);
// A compile error or a failing shard must fail the run (and stop a chained
// `&& node compare.mjs`); a null code means the child was killed.
process.exitCode = code ?? 1;
