// Dark-mode comparison from screenshots: for every word on each side, the
// text and background colours are sampled from the PNG (Chrome's algorithmic
// dark mode exists only in pixels), then words are aligned by text.
//
// Usage: node dark_compare.mjs --run <name> --corpus <manifest.jsonl>
//                              [--sbs <job key> [--y0 0] [--y1 1600]]
// Reads runs/<name>/{chrome,flutter}/<key>.{json,png}; writes
// runs/<name>/dark_results.json and prints a summary.
import fs from 'node:fs';
import path from 'node:path';
import { diffArrays } from 'diff';
import { PNG } from 'pngjs';
import { currentCaptureSettings, loadCorpus, matchesCaptureSettings, readJson, runDir } from './common.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const dir = runDir(option('--run', 'dk_css'));
const corpus = new Map(loadCorpus(option('--corpus')).map((e) => [e.id, e]));
const chromeDir = path.join(dir, 'chrome');
const flutterDir = path.join(dir, 'flutter');
const chromeSettings = currentCaptureSettings(chromeDir);
const flutterSettings = currentCaptureSettings(flutterDir);

const lin = (v) => {
  const c = v / 255;
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
};
const luminance = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
const contrast = (a, b) => {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};
const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
const norm = (t) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');

/** Text and background colour of [word] in [png] (null when off-image). */
function sample(png, word) {
  if (word.lines > 1 || ![word.x, word.y, word.w, word.h].every(Number.isFinite)) return null;
  const x0 = Math.floor(word.x);
  const y0 = Math.floor(word.y);
  const x1 = Math.ceil(word.x + word.w);
  const y1 = Math.ceil(word.y + word.h);
  if (x0 < 2 || y0 < 2 || x1 >= png.width - 2 || y1 >= png.height - 2 || x1 <= x0 || y1 <= y0) return null;
  const at = (x, y) => {
    const i = (y * png.width + x) * 4;
    return [png.data[i], png.data[i + 1], png.data[i + 2]];
  };
  // Background: the ring just outside the word box.
  const ring = [];
  for (let x = x0; x < x1; x += 2) ring.push(at(x, y0 - 2), at(x, y1 + 1));
  for (let y = y0; y < y1; y += 2) ring.push(at(x0 - 2, y), at(x1 + 1, y));
  const median = (k) => ring.map((p) => p[k]).sort((a, b) => a - b)[ring.length >> 1];
  const bg = [median(0), median(1), median(2)];
  // Text: the 10% of inner pixels farthest from the background.
  const inner = [];
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) inner.push(at(x, y));
  inner.sort((a, b) => dist(b, bg) - dist(a, bg));
  const top = inner.slice(0, Math.max(1, Math.round(inner.length * 0.1)));
  const fg = [0, 1, 2].map((k) => Math.round(top.reduce((s, p) => s + p[k], 0) / top.length));
  return { fg, bg, contrast: contrast(fg, bg), dark: luminance(bg) < 0.2 };
}

function sides(key) {
  const read = (sideDir, settings) => {
    const base = path.join(sideDir, key);
    const dump = readJson(base + '.json', null);
    if (!Array.isArray(dump?.words) || !matchesCaptureSettings(dump, settings) ||
        dump.capture?.complete === false || dump.capture?.png === false) return null;
    try {
      return { dump, png: PNG.sync.read(fs.readFileSync(base + '.png')) };
    } catch (error) {
      if (error.code !== 'ENOENT') console.warn('Unreadable capture:', base, error.message);
      return null;
    }
  };
  return { chrome: read(chromeDir, chromeSettings), flutter: read(flutterDir, flutterSettings) };
}

if (option('--sbs')) {
  const key = option('--sbs');
  const { chrome, flutter } = sides(key);
  if (!chrome || !flutter) throw new Error('No matching PNG capture pair for ' + key);
  const y0 = Number(option('--y0', '0'));
  const y1 = Math.min(Number(option('--y1', '1600')), chrome.png.height, flutter.png.height);
  if (!Number.isInteger(y0) || !Number.isInteger(y1) || y0 < 0 || y1 <= y0) {
    throw new Error('--y0 and --y1 must describe a nonempty screenshot range');
  }
  const gap = 12;
  const out = new PNG({ width: chrome.png.width + gap + flutter.png.width, height: y1 - y0 });
  out.data.fill(128);
  PNG.bitblt(chrome.png, out, 0, y0, chrome.png.width, y1 - y0, 0, 0);
  PNG.bitblt(flutter.png, out, 0, y0, flutter.png.width, y1 - y0, chrome.png.width + gap, 0);
  const file = path.join(dir, 'report', 'sbs', `${key}_${y0}.png`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, PNG.sync.write(out));
  console.log(file);
  process.exit(0);
}

const results = [];
let skipped = 0;
for (const file of fs.readdirSync(flutterDir)) {
  if (!file.endsWith('.json') || file.startsWith('_')) continue;
  const key = file.slice(0, -5);
  const { chrome, flutter } = sides(key);
  if (!chrome || !flutter) {
    skipped++;
    continue;
  }
  const measure = (side) =>
    side.dump.words
      .map((w) => ({ n: norm(w.t), s: sample(side.png, w) }))
      .filter((w) => w.n && w.s);
  const c = measure(chrome);
  const f = measure(flutter);
  // Align by text; equal runs pair word for word.
  const pairs = [];
  let ci = 0;
  let fi = 0;
  for (const part of diffArrays(c.map((w) => w.n), f.map((w) => w.n))) {
    if (part.added) fi += part.count;
    else if (part.removed) ci += part.count;
    else for (let k = 0; k < part.count; k++) pairs.push([c[ci++], f[fi++]]);
  }
  const share = (list, pred) => (list.length ? list.filter(pred).length / list.length : null);
  const mean = (list, fn) => (list.length ? list.reduce((s, x) => s + fn(x), 0) / list.length : null);
  const id = chrome.dump.id;
  results.push({
    key,
    id,
    darkSupport: corpus.get(id)?.darkSupport ?? false,
    words: pairs.length,
    chromeDark: share(c, (w) => w.s.dark),
    flutterDark: share(f, (w) => w.s.dark),
    polarityAgree: share(pairs, ([a, b]) => a.s.dark === b.s.dark),
    bgDelta: mean(pairs, ([a, b]) => dist(a.s.bg, b.s.bg)),
    fgDelta: mean(pairs, ([a, b]) => dist(a.s.fg, b.s.fg)),
    // WCAG: < 3 is hard to read even for large text.
    chromeLow: share(c, (w) => w.s.contrast < 3),
    flutterLow: share(f, (w) => w.s.contrast < 3),
    flutterLowWords: f.filter((w) => w.s.contrast < 3).slice(0, 8).map((w) => ({
      t: w.n,
      fg: w.s.fg,
      bg: w.s.bg,
      contrast: Math.round(w.s.contrast * 100) / 100,
    })),
  });
}
fs.writeFileSync(path.join(dir, 'dark_results.json'), JSON.stringify(results, null, 1));
if (skipped) console.warn('Jobs without a matching capture pair:', skipped);

const groups = {};
for (const r of results) {
  const appearance = r.flutterDark == null ? 'unsampled' : r.flutterDark > 0.5 ? 'dark' : 'light';
  const g = `${r.darkSupport ? 'dark-support' : 'no-support'} / flutter ${appearance}`;
  (groups[g] ??= []).push(r);
}
const pct = (v) => v == null ? '—' : `${Math.round(v * 100)}%`;
const med = (list, fn) => {
  const v = list.map(fn).filter((value) => value != null).sort((a, b) => a - b);
  return v.length ? v[v.length >> 1] : null;
};
const delta = (value) => value == null ? '—' : Math.round(value);
const rows = {};
for (const [g, list] of Object.entries(groups)) {
  rows[g] = {
    emails: list.length,
    'with matched words': list.filter((r) => r.words > 0).length,
    'chrome dark bg': pct(med(list, (r) => r.chromeDark)),
    'polarity agree': pct(med(list, (r) => r.polarityAgree)),
    'agree <80%': list.filter((r) => r.polarityAgree != null && r.polarityAgree < 0.8).length,
    'bg Δ': delta(med(list, (r) => r.bgDelta)),
    'fg Δ': delta(med(list, (r) => r.fgDelta)),
    'flutter unreadable >5%': list.filter((r) => r.flutterLow > 0.05).length,
    'chrome unreadable >5%': list.filter((r) => r.chromeLow > 0.05).length,
  };
}
console.table(rows);
