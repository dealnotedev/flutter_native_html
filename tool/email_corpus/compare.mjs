// Compares Chrome and Flutter layout dumps of a run and writes metrics,
// root-cause clusters and an HTML report.
// Usage: node compare.mjs --run <name> [--corpus <manifest|dir>]
import fs from 'node:fs';
import path from 'node:path';
import { diffArrays } from 'diff';
import { currentCaptureSettings, harnessDir, loadCorpus, matchesCaptureSettings, readJson, repoDir, runDir, writeJson } from './common.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const run = option('--run', 'pilot');
const dir = runDir(run);
const reportDir = path.join(dir, 'report');
fs.mkdirSync(path.join(reportDir, 'jobs'), { recursive: true });

const ZERO_WIDTH = /[­͏؜ᅟᅠ឴឵᠎​-‏‪-‮⁠-⁯ㅤ﻿ﾠ]/g;
const norm = (t) => t.normalize('NFKC').replace(ZERO_WIDTH, '').toLowerCase();
const MARKER = /^([•◦▪▫■□‣⁃-]|\d+\.|[a-z]\.|[ivxlc]+\.)$/i;
const parseColor = (c) => {
  const m = String(c).match(/rgba?\(([^)]+)\)/);
  if (!m) return [0, 0, 0, 1];
  const p = m[1].split(',').map((v) => parseFloat(v));
  return [p[0], p[1], p[2], p[3] ?? 1];
};
const colorDelta = (a, b) => {
  const x = parseColor(a);
  const y = parseColor(b);
  return Math.max(Math.abs(x[0] - y[0]), Math.abs(x[1] - y[1]), Math.abs(x[2] - y[2]), Math.abs(x[3] - y[3]) * 255);
};
const median = (values) => {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};

/** Aligns two word streams; returns pairs [chromeIdx[], flutterIdx[]] plus unmatched indices. */
function align(cw, fw) {
  const a = cw.map((w) => w.n);
  const b = fw.map((w) => w.n);
  const parts = diffArrays(a, b, { timeout: 5000 }) ?? [];
  const pairs = [];
  const missing = [];
  const extra = [];
  let i = 0;
  let j = 0;
  for (let k = 0; k < parts.length; k++) {
    const part = parts[k];
    if (!part.added && !part.removed) {
      for (let n = 0; n < part.count; n++) pairs.push([[i++], [j++]]);
      continue;
    }
    // Collect one removed+added hunk and try to match it by concatenation.
    let removed = [];
    let added = [];
    while (k < parts.length && (parts[k].added || parts[k].removed)) {
      const p = parts[k];
      const idx = Array.from({ length: p.count }, (_, n) => (p.removed ? i : j) + n);
      if (p.removed) {
        removed = removed.concat(idx);
        i += p.count;
      } else {
        added = added.concat(idx);
        j += p.count;
      }
      k++;
    }
    k--;
    const joinA = removed.map((x) => a[x]).join('');
    const joinB = added.map((x) => b[x]).join('');
    if (removed.length && added.length && joinA === joinB) {
      pairs.push([removed, added]);
    } else {
      missing.push(...removed);
      extra.push(...added);
    }
  }
  return { pairs, missing, extra };
}

const unionRect = (words) => {
  const l = Math.min(...words.map((w) => w.x));
  const t = Math.min(...words.map((w) => w.y));
  const r = Math.max(...words.map((w) => w.x + w.w));
  const b = Math.max(...words.map((w) => w.y + w.h));
  return { x: l, y: t, w: r - l, h: b - t, cy: (t + b) / 2 };
};

/** Splits a word stream into visual lines (y-center jumps). */
function lineIndex(words) {
  let line = 0;
  let prev = null;
  return words.map((w) => {
    const cy = w.y + w.h / 2;
    if (prev && (cy - prev.cy > Math.min(w.h, prev.h) * 0.6 || w.x < prev.x - 1)) line++;
    prev = { cy, x: w.x + w.w, h: w.h };
    return line;
  });
}

function compareJob(key, chrome, flutter) {
  const width = chrome.width;
  const cw = chrome.words.map((w) => ({ ...w, n: norm(w.t) })).filter((w) => w.n);
  const fw = flutter.words.map((w) => ({ ...w, n: norm(w.t) })).filter((w) => w.n);
  const { pairs, missing, extra } = align(cw, fw);
  const extraReal = extra.filter((i) => !MARKER.test(fw[i].t));
  const missingReal = missing.filter((i) => !MARKER.test(cw[i].t));

  const cLines = lineIndex(cw);
  const fLines = lineIndex(fw);
  const blocks = new Map();
  let prev = null;
  for (const [ci, fi] of pairs) {
    const c = unionRect(ci.map((i) => cw[i]));
    const f = unionRect(fi.map((i) => fw[i]));
    const cWord = cw[ci[0]];
    const fWord = fw[fi[0]];
    const block = cWord.b;
    if (!blocks.has(block)) {
      blocks.set(block, { id: block, words: 0, dx: [], lineStartDx: [], gap: null, cLines: new Set(), fLines: new Set(), wr: [], style: {}, lineBreakDiff: 0, pitch: [] });
    }
    const s = blocks.get(block);
    s.words++;
    const dx = f.x - c.x;
    s.dx.push(dx);
    const cStart = ci[0] === 0 || cLines[ci[0]] !== cLines[ci[0] - 1];
    const fStart = fi[0] === 0 || fLines[fi[0]] !== fLines[fi[0] - 1];
    if (cStart && fStart) s.lineStartDx.push(dx);
    if (cStart !== fStart) s.lineBreakDiff++;
    s.cLines.add(cLines[ci[0]]);
    s.fLines.add(fLines[fi[0]]);
    if (ci.length === 1 && fi.length === 1 && c.w > 4) s.wr.push(f.w / c.w);
    if (prev) {
      const delta = f.cy - prev.f.cy - (c.cy - prev.c.cy);
      if (prev.block !== block && s.gap === null) {
        s.gap = delta;
        s.prevBlock = prev.block;
      }
      else if (prev.block === block && cStart && fStart) s.pitch.push(delta);
    } else if (s.gap === null) {
      s.gap = f.cy - c.cy;
    }
    const mark = (name) => (s.style[name] = (s.style[name] ?? 0) + 1);
    if (Math.abs(fWord.fs - cWord.fs) > 0.5) mark('font-size');
    if (fWord.fw >= 600 !== cWord.fw >= 600) mark('weight');
    if (fWord.it !== cWord.it) mark('italic');
    if (colorDelta(fWord.c, cWord.c) > 40) mark('color');
    if (fWord.u !== cWord.u) mark('underline');
    prev = { c, f, block };
  }

  const blockIssues = [];
  const issueWords = {};
  const add = (name, n) => (issueWords[name] = (issueWords[name] ?? 0) + n);
  for (const s of blocks.values()) {
    const issues = [];
    const startDx = median(s.lineStartDx.length ? s.lineStartDx : s.dx);
    if (Math.abs(startDx) > 3) issues.push('x');
    if (s.cLines.size !== s.fLines.size || s.lineBreakDiff > 0) issues.push('wrap');
    if (s.gap !== null && Math.abs(s.gap) > 4) issues.push('vgap');
    if (s.pitch.length && Math.abs(median(s.pitch)) > 1.5) issues.push('line-height');
    const wr = median(s.wr);
    if (s.wr.length >= 2 && Math.abs(wr - 1) > 0.06) issues.push('glyph-width');
    for (const [name, count] of Object.entries(s.style)) if (count / s.words > 0.3) issues.push(name);
    for (const issue of issues) add(issue, s.words);
    if (issues.length) {
      blockIssues.push({
        block: s.id,
        issues,
        words: s.words,
        dx: Math.round(startDx * 10) / 10,
        gap: s.gap === null ? null : Math.round(s.gap * 10) / 10,
        prev: s.prevBlock ?? null,
        lines: [s.cLines.size, s.fLines.size],
        wr: Math.round(wr * 100) / 100,
      });
    }
  }
  // Missing/extra words per block (Chrome side) for clustering.
  const missingByBlock = {};
  for (const i of missingReal) missingByBlock[cw[i].b] = (missingByBlock[cw[i].b] ?? 0) + 1;
  for (const [block, count] of Object.entries(missingByBlock)) {
    const existing = blockIssues.find((b) => b.block === Number(block));
    if (existing) existing.issues.push('missing');
    else blockIssues.push({ block: Number(block), issues: ['missing'], words: count });
  }
  if (missingReal.length) add('missing', missingReal.length);
  if (extraReal.length) add('extra', extraReal.length);

  // Images: match by src.
  const fImages = new Map();
  for (const img of flutter.images ?? []) if (img.src) (fImages.get(img.src) ?? fImages.set(img.src, []).get(img.src)).push(img);
  const imageIssues = [];
  for (const img of chrome.images ?? []) {
    if (!img.src || img.w < 2 || img.h < 2) continue;
    const list = fImages.get(img.src);
    const match = list?.shift();
    if (!match) {
      imageIssues.push({ kind: img.bg ? 'bg-missing' : 'img-missing', src: img.src, c: img });
      continue;
    }
    if (!img.bg && (Math.abs(match.w - img.w) > 2 || Math.abs(match.h - img.h) > 2)) {
      imageIssues.push({ kind: 'img-size', src: img.src, c: img, f: match });
    } else if (!img.bg && Math.abs(match.x - img.x) > 3) {
      imageIssues.push({ kind: 'img-x', src: img.src, c: img, f: match });
    }
  }
  for (const issue of imageIssues) add(issue.kind, 1);

  const contentBottom = (dump) => Math.max(0, ...dump.words.map((w) => w.y + w.h), ...(dump.images ?? []).map((i) => i.y + i.h));
  const cBottom = contentBottom(chrome);
  const fBottom = contentBottom(flutter);
  const heightRatio = cBottom > 0 ? fBottom / cBottom : 1;
  const cOverflow = chrome.docWidth > width + 1;
  const fOverflow = flutter.docWidth > width + 1;
  const total = cw.length || 1;
  const frac = (name) => (issueWords[name] ?? 0) / total;
  const layoutFrac = Math.min(1, frac('x') + frac('wrap') + frac('vgap') + frac('line-height'));
  const styleFrac = Math.min(1, frac('font-size') + frac('weight') + frac('color') + frac('italic') + frac('underline') + frac('glyph-width'));
  const score =
    3 * Math.min(1, missingReal.length / total) +
    3 * Math.min(1, extraReal.length / total) +
    layoutFrac +
    0.5 * styleFrac +
    Math.min(1, Math.abs(Math.log(heightRatio || 1))) +
    (fOverflow !== cOverflow ? 0.5 : 0) +
    (flutter.errors?.length ? 0.5 : 0) +
    0.2 * Math.min(5, imageIssues.length);
  return {
    key,
    id: chrome.id,
    width,
    score: Math.round(score * 1000) / 1000,
    words: cw.length,
    flutterWords: fw.length,
    missing: missingReal.length,
    extra: extraReal.length,
    issueWords,
    heightRatio: Math.round(heightRatio * 1000) / 1000,
    overflow: { chrome: cOverflow, flutter: fOverflow },
    errors: flutter.errors ?? [],
    ms: flutter.ms,
    blockIssues,
    imageIssues,
    missingWords: missingReal.slice(0, 60).map((i) => cw[i]),
    extraWords: extraReal.slice(0, 60).map((i) => fw[i]),
  };
}

// ---------- run over all jobs ----------
const chromeDir = path.join(dir, 'chrome');
const flutterDir = path.join(dir, 'flutter');
const chromeSettings = currentCaptureSettings(chromeDir);
const flutterSettings = currentCaptureSettings(flutterDir);
const results = [];
const blocksByJob = new Map();
let skipped = 0;
// Sources whose public web view is not the sent email (e.g. Flodesk renders
// text in SVG foreignObject on the web, as images in the email).
const exclude = new RegExp(option('--exclude', '_flodesk-'));
for (const file of fs.readdirSync(chromeDir)) {
  if (!file.endsWith('.json') || file.startsWith('_')) continue;
  const key = file.slice(0, -5);
  if (exclude.test(key)) continue;
  const chrome = readJson(path.join(chromeDir, file), null);
  const flutter = readJson(path.join(flutterDir, file), null);
  if (!chrome || !flutter ||
      !matchesCaptureSettings(chrome, chromeSettings) ||
      !matchesCaptureSettings(flutter, flutterSettings)) {
    skipped++;
    continue;
  }
  if (!flutter.words) {
    results.push({ key, id: chrome.id, width: chrome.width, score: 9, crashed: true, errors: flutter.errors, words: chrome.words.length, issueWords: {}, blockIssues: [], imageIssues: [] });
    continue;
  }
  const result = compareJob(key, chrome, flutter);
  results.push(result);
  blocksByJob.set(key, chrome.blocks);
}
results.sort((a, b) => b.score - a.score);

// ---------- feature lift clustering (unit: Chrome block with words) ----------
const featureStats = new Map();
const categoryTotals = {};
let totalBlocks = 0;
for (const result of results) {
  const blocks = blocksByJob.get(result.key);
  if (!blocks) continue;
  const issuesByBlock = new Map(result.blockIssues.map((b) => [b.block, b.issues]));
  blocks.forEach((block, id) => {
    totalBlocks++;
    const issues = issuesByBlock.get(id) ?? [];
    for (const issue of new Set(issues)) categoryTotals[issue] = (categoryTotals[issue] ?? 0) + 1;
    for (const feature of block.sig) {
      let s = featureStats.get(feature);
      if (!s) featureStats.set(feature, (s = { feature, blocks: 0, emails: new Set(), issues: {} }));
      s.blocks++;
      s.emails.add(result.id);
      for (const issue of new Set(issues)) {
        const t = (s.issues[issue] ??= { blocks: 0, emails: new Set() });
        t.blocks++;
        t.emails.add(result.id);
      }
    }
  });
}
const clusters = {};
for (const [issue, count] of Object.entries(categoryTotals)) {
  const base = count / totalBlocks;
  clusters[issue] = [...featureStats.values()]
    .filter((s) => s.issues[issue] && s.blocks >= 5)
    .map((s) => {
      const hit = s.issues[issue];
      const rate = hit.blocks / s.blocks;
      return { feature: s.feature, lift: Math.round((rate / base) * 100) / 100, rate: Math.round(rate * 1000) / 1000, blocks: s.blocks, issueBlocks: hit.blocks, emails: hit.emails.size };
    })
    .filter((c) => c.lift > 1.3 && c.emails >= 2)
    .sort((a, b) => b.emails * (b.lift - 1) - a.emails * (a.lift - 1))
    .slice(0, 25);
}

// ---------- static CSS coverage ----------
const supported = new Set();
for (const file of fs.readdirSync(path.join(repoDir, 'lib/src/css'))) {
  for (const m of fs.readFileSync(path.join(repoDir, 'lib/src/css', file), 'utf8').matchAll(/'([a-z][a-z-]+)'/g)) supported.add(m[1]);
}
const cssUsage = new Map();
const corpusSource = option('--corpus');
if (corpusSource) {
  for (const email of loadCorpus(corpusSource)) {
    if (!fs.existsSync(email.file)) continue;
    const html = fs.readFileSync(email.file, 'utf8');
    const css = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1]).join('\n');
    const inline = [...html.matchAll(/\sstyle\s*=\s*("([^"]*)"|'([^']*)')/gi)].map((m) => m[2] ?? m[3]).join(';');
    const props = new Set();
    for (const m of (css.replace(/\/\*[\s\S]*?\*\//g, '') + ';' + inline).matchAll(/(?:^|[;{\s])(-?[a-z][a-z-]*)\s*:(?!:)/gi)) props.add(m[1].toLowerCase());
    for (const m of css.matchAll(/@([a-z-]+)/gi)) props.add('@' + m[1].toLowerCase());
    for (const prop of props) {
      if (supported.has(prop)) continue;
      cssUsage.set(prop, (cssUsage.get(prop) ?? 0) + 1);
    }
  }
}
const unsupportedCss = [...cssUsage]
  .filter(([p]) => !p.startsWith('mso-') && !p.startsWith('-ms-') && !p.startsWith('-webkit-text-size') && !/^(http|https|mailto)$/.test(p))
  .sort((a, b) => b[1] - a[1])
  .slice(0, 80);

// ---------- totals ----------
const totals = { jobs: results.length, skipped, crashed: results.filter((r) => r.crashed).length };
for (const r of results) {
  for (const [issue, words] of Object.entries(r.issueWords ?? {})) {
    const t = (totals[issue] ??= { jobs: 0, words: 0 });
    t.jobs++;
    t.words += words;
  }
  if (r.errors?.length) totals.flutterErrors = (totals.flutterErrors ?? 0) + 1;
  if (r.overflow && r.overflow.flutter && !r.overflow.chrome) totals.flutterOnlyOverflow = (totals.flutterOnlyOverflow ?? 0) + 1;
  if (r.heightRatio && Math.abs(Math.log(r.heightRatio)) > 0.1) totals.heightOff10 = (totals.heightOff10 ?? 0) + 1;
}
const errorKinds = {};
// The first error is the root cause; "not laid out" follow-ups cascade from it.
const errorKind = (e) => e.replace(/#[0-9a-f]+/g, '').replace(/[\d.]+/g, 'N').replace(/ relayoutBoundary.*| NEEDS-.*/, '').slice(0, 120);
for (const r of results) {
  const root = (r.errors ?? []).find((e) => !e.startsWith('RenderBox was not laid out')) ?? r.errors?.[0];
  if (root) errorKinds[errorKind(root)] = (errorKinds[errorKind(root)] ?? 0) + 1;
}
writeJson(path.join(dir, 'results.json'), { totals, clusters, unsupportedCss, errorKinds, results });

// ---------- HTML report ----------
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const style = `<style>body{font:13px/1.4 system-ui,sans-serif;margin:16px;color:#222}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:3px 6px;vertical-align:top}th{background:#f4f4f4;text-align:left}.num{text-align:right}code{font-size:12px}h2{margin-top:28px}.pair{display:flex;gap:12px;align-items:flex-start}.pane{position:relative;border:1px solid #999}.pane img{display:block}.box{position:absolute;border:1.5px solid}.m{border-color:#e00;background:#e002}.e{border-color:#a0f;background:#a0f2}.b{border-color:#f80}.i{border-color:#08f}</style>`;
const issueCols = ['missing', 'extra', 'x', 'wrap', 'vgap', 'line-height', 'glyph-width', 'font-size', 'weight', 'color', 'underline', 'italic', 'img-missing', 'img-size', 'img-x', 'bg-missing'];
let html = `<!doctype html><meta charset=utf-8><title>Parity report ${esc(run)}</title>${style}<h1>Browser parity: ${esc(run)}</h1>`;
html += `<h2>Totals</h2><pre>${esc(JSON.stringify(totals, null, 1))}</pre>`;
html += `<h2>Flutter errors</h2><table><tr><th>jobs</th><th>error</th></tr>${Object.entries(errorKinds).sort((a, b) => b[1] - a[1]).map(([e, n]) => `<tr><td class=num>${n}</td><td><code>${esc(e)}</code></td></tr>`).join('')}</table>`;
html += `<h2>Clusters (feature lift per issue)</h2>`;
for (const [issue, list] of Object.entries(clusters)) {
  if (!list.length) continue;
  html += `<h3>${esc(issue)} — ${categoryTotals[issue]} blocks</h3><table><tr><th>feature</th><th>lift</th><th>rate</th><th>issue blocks</th><th>emails</th><th>blocks with feature</th></tr>${list.map((c) => `<tr><td><code>${esc(c.feature)}</code></td><td class=num>${c.lift}</td><td class=num>${c.rate}</td><td class=num>${c.issueBlocks}</td><td class=num>${c.emails}</td><td class=num>${c.blocks}</td></tr>`).join('')}</table>`;
}
if (unsupportedCss.length) {
  html += `<h2>CSS not mentioned by the renderer (emails using it)</h2><table><tr><th>property / at-rule</th><th>emails</th></tr>${unsupportedCss.map(([p, n]) => `<tr><td><code>${esc(p)}</code></td><td class=num>${n}</td></tr>`).join('')}</table>`;
}
html += `<h2>Jobs by score</h2><table><tr><th>job</th><th>score</th><th>words</th><th>h ratio</th>${issueCols.map((c) => `<th>${c}</th>`).join('')}<th>errors</th></tr>`;
for (const r of results) {
  html += `<tr><td><a href="jobs/${encodeURIComponent(r.key)}.html">${esc(r.key)}</a>${r.crashed ? ' <b>CRASH</b>' : ''}</td><td class=num>${r.score}</td><td class=num>${r.words}</td><td class=num>${r.heightRatio ?? ''}</td>${issueCols.map((c) => `<td class=num>${r.issueWords?.[c] ?? ''}</td>`).join('')}<td>${esc((r.errors ?? []).slice(0, 2).join(' | ').slice(0, 160))}</td></tr>`;
}
html += `</table>`;
fs.writeFileSync(path.join(reportDir, 'index.html'), html);

// Per-job pages with overlays.
for (const r of results) {
  const blocks = blocksByJob.get(r.key) ?? [];
  const rect = (b, cls, title) => `<div class="box ${cls}" title="${esc(title)}" style="left:${b.x}px;top:${b.y}px;width:${Math.max(2, b.w)}px;height:${Math.max(2, b.h)}px"></div>`;
  const chromeBoxes = [
    ...r.blockIssues.map((bi) => blocks[bi.block] && rect(blocks[bi.block], 'b', `${bi.issues.join(',')} dx=${bi.dx} gap=${bi.gap} lines=${bi.lines}`)),
    ...(r.missingWords ?? []).map((w) => rect(w, 'm', 'missing: ' + w.t)),
    ...r.imageIssues.map((ii) => rect(ii.c, 'i', ii.kind)),
  ].filter(Boolean);
  const flutterBoxes = [...(r.extraWords ?? []).map((w) => rect(w, 'e', 'extra: ' + w.t)), ...r.imageIssues.filter((ii) => ii.f).map((ii) => rect(ii.f, 'i', ii.kind))];
  let page = `<!doctype html><meta charset=utf-8><title>${esc(r.key)}</title>${style}<p><a href="../index.html">← report</a></p><h1>${esc(r.key)} — score ${r.score}</h1>`;
  page += `<pre>${esc(JSON.stringify({ words: r.words, missing: r.missing, extra: r.extra, issueWords: r.issueWords, heightRatio: r.heightRatio, overflow: r.overflow, errors: r.errors, ms: r.ms }, null, 1))}</pre>`;
  page += `<table><tr><th>block</th><th>issues</th><th>words</th><th>dx</th><th>gap</th><th>lines c/f</th><th>glyph w</th><th>path</th><th>features</th></tr>${r.blockIssues.map((bi) => `<tr><td>${bi.block}</td><td>${esc(bi.issues.join(', '))}</td><td class=num>${bi.words}</td><td class=num>${bi.dx ?? ''}</td><td class=num>${bi.gap ?? ''}</td><td>${esc(bi.lines?.join('/'))}</td><td>${bi.wr ?? ''}</td><td><code>${esc(blocks[bi.block]?.path)}</code></td><td><code>${esc(blocks[bi.block]?.sig.join(' '))}</code></td></tr>`).join('')}</table>`;
  page += `<div class=pair><div><b>Chrome</b><div class=pane><img src="../../chrome/${encodeURIComponent(r.key)}.png">${chromeBoxes.join('')}</div></div><div><b>Flutter</b><div class=pane><img src="../../flutter/${encodeURIComponent(r.key)}.png">${flutterBoxes.join('')}</div></div></div>`;
  fs.writeFileSync(path.join(reportDir, 'jobs', r.key + '.html'), page);
}
console.log(JSON.stringify(totals));
console.log(`report: ${path.join(reportDir, 'index.html')}`);
