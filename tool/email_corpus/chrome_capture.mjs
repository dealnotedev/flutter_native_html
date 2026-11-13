// Renders each corpus email in headless Chrome and writes a layout dump + PNG.
// Usage: node chrome_capture.mjs <manifest.jsonl|dir> --run <name>
//   [--scheme light|dark] [--auto-dark] [--concurrency 8] [--force] [--filter re]
import fs from 'node:fs';
import path from 'node:path';
import puppeteer from 'puppeteer-core';
import {
  assetFingerprint,
  assetsDir,
  captureJobs,
  captureKey,
  captureSettings,
  chromePath,
  chromeShimCss,
  clearCapture,
  fingerprintFiles,
  fontsManifest,
  harnessDir,
  hasCachedCapture,
  loadCorpus,
  readJson,
  runDir,
  sha256,
} from './common.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const source = args[0];
const run = option('--run', 'pilot');
const concurrency = Number(option('--concurrency', '8'));
if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
  throw new Error('--concurrency must be a positive integer');
}
const force = args.includes('--force');
const filter = option('--filter') ? new RegExp(option('--filter')) : null;
// Dark-mode references: `--scheme dark` emulates prefers-color-scheme (the
// CSS standard: author dark styles, `color-scheme` canvas); `--auto-dark`
// adds Chromium's algorithmic darkening (Android WebView's force dark),
// which applies at paint time, so only the screenshot shows its colors.
const scheme = option('--scheme', null);
const autoDark = args.includes('--auto-dark');
if (args.includes('--scheme') && !['light', 'dark'].includes(scheme)) {
  throw new Error('--scheme must be light or dark');
}
const outDir = path.join(runDir(run), 'chrome');
const assetIndex = readJson(path.join(assetsDir, 'index.json'), {});
const assetsFor = assetFingerprint(assetIndex);
const chrome = fs.statSync(chromePath);
const settingsKey = captureSettings(outDir, {
  scheme, autoDark, chromePath, chromeShimCss,
  chromeSize: chrome.size, chromeModified: chrome.mtimeMs,
  inputs: fingerprintFiles([
    fontsManifest,
    ...Object.values(readJson(fontsManifest, {}).families ?? {})
      .flatMap((family) => family.faces.map((face) => face.file)),
    path.join(harnessDir, 'common.mjs'),
    path.join(harnessDir, 'chrome_capture.mjs'),
    path.join(harnessDir, 'package-lock.json'),
  ]),
});
const ORIGIN = 'http://email.test/';

/** Keeps the author's doctype (forcing standards mode, like webmail) and puts the UA shim first. */
export function prepareHtml(html) {
  let out = html.replace(/^﻿/, '');
  if (!/^\s*(<!--[\s\S]*?-->\s*)*<!doctype/i.test(out)) out = '<!DOCTYPE html>\n' + out;
  const shim = `<style data-harness-shim>${chromeShimCss}</style>`;
  if (/<head\b[^>]*>/i.test(out)) return out.replace(/<head\b[^>]*>/i, (m) => m + shim);
  if (/<html\b[^>]*>/i.test(out)) return out.replace(/<html\b[^>]*>/i, (m) => `${m}<head>${shim}</head>`);
  return out.replace(/<!doctype[^>]*>/i, (m) => m + shim);
}

// Runs inside the page. Must be self-contained.
function dumpLayout() {
  const W = window.innerWidth;
  const out = { words: [], blocks: [], images: [] };
  const blockIds = new Map();
  const clipCache = new Map();
  const opacityCache = new Map();

  const isInline = (d) => d.startsWith('inline') && d !== 'inline-block' && d !== 'inline-table' && d !== 'inline-flex';
  const clipOf = (el) => {
    if (!el || el === document.documentElement) return null;
    if (clipCache.has(el)) return clipCache.get(el);
    let clip = clipOf(el.parentElement);
    const cs = getComputedStyle(el);
    if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible') {
      const r = el.getBoundingClientRect();
      const own = { l: r.left, t: r.top, r: r.right, b: r.bottom };
      clip = clip
        ? { l: Math.max(clip.l, own.l), t: Math.max(clip.t, own.t), r: Math.min(clip.r, own.r), b: Math.min(clip.b, own.b) }
        : own;
    }
    clipCache.set(el, clip);
    return clip;
  };
  const opacityOf = (el) => {
    if (!el) return 1;
    if (opacityCache.has(el)) return opacityCache.get(el);
    const value = Number(getComputedStyle(el).opacity) * opacityOf(el.parentElement);
    opacityCache.set(el, value);
    return value;
  };
  const visibleRect = (rect, el) => {
    if (rect.width <= 0 || rect.height <= 0) return false;
    if (rect.right <= 0 || rect.bottom <= 0) return false;
    const clip = clipOf(el);
    if (clip) {
      const w = Math.min(rect.right, clip.r) - Math.max(rect.left, clip.l);
      const h = Math.min(rect.bottom, clip.b) - Math.max(rect.top, clip.t);
      if (w <= 0 || h <= 0 || (w * h) / (rect.width * rect.height) < 0.5) return false;
    }
    return opacityOf(el) > 0.1;
  };

  // Elements styled by an @media rule that currently matches.
  const mediaStyled = new Set();
  const collect = (rules, inMedia) => {
    for (const rule of rules) {
      if (rule instanceof CSSMediaRule) {
        if (matchMedia(rule.media.mediaText).matches) collect(rule.cssRules, true);
      } else if (rule instanceof CSSStyleRule && inMedia) {
        try {
          for (const el of document.querySelectorAll(rule.selectorText)) mediaStyled.add(el);
        } catch {}
      }
    }
  };
  for (const sheet of document.styleSheets) {
    try {
      collect(sheet.cssRules, false);
    } catch {}
  }

  const featuresOf = (el) => {
    const f = [];
    const cs = getComputedStyle(el);
    const tag = el.localName;
    f.push(`${tag}:${cs.display}`);
    if (cs.float !== 'none') f.push('float');
    if (cs.position !== 'static') f.push(`pos:${cs.position}`);
    if (cs.maxWidth !== 'none') f.push('max-width');
    if (cs.minWidth !== '0px' && cs.minWidth !== 'auto') f.push('min-width');
    const w = el.style.width || el.getAttribute('width') || '';
    if (w.endsWith('%')) f.push('width:%');
    else if (w) f.push('width:px');
    const h = el.style.height || el.getAttribute('height') || '';
    if (h && tag !== 'img') f.push('height');
    if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible') f.push('overflow');
    if (cs.whiteSpace !== 'normal') f.push(`ws:${cs.whiteSpace}`);
    if (cs.textTransform !== 'none') f.push('text-transform');
    if (cs.letterSpacing !== 'normal') f.push('letter-spacing');
    if (el.style.lineHeight) f.push('line-height');
    if (cs.direction === 'rtl') f.push('rtl');
    if (cs.transform !== 'none') f.push('transform');
    if (cs.backgroundImage !== 'none') f.push(cs.backgroundImage.includes('gradient') ? 'bg-gradient' : 'bg-image');
    if (cs.boxSizing === 'border-box') f.push('border-box');
    if (cs.tableLayout === 'fixed') f.push('table-fixed');
    if (cs.display.includes('flex')) f.push(`flex:${cs.flexDirection}`);
    if (cs.display.includes('grid')) f.push('grid');
    if (cs.textAlign !== 'start' && cs.textAlign !== 'left') f.push(`text-align:${cs.textAlign}`);
    if (cs.display === 'table-cell' && cs.verticalAlign !== 'middle') f.push(`valign:${cs.verticalAlign}`);
    if (['top', 'bottom', 'text-top', 'text-bottom', 'super', 'sub'].includes(cs.verticalAlign) && cs.display !== 'table-cell') f.push(`va:${cs.verticalAlign}`);
    for (const attr of ['align', 'colspan', 'rowspan', 'cellpadding', 'cellspacing', 'bgcolor', 'background', 'dir']) {
      if (el.hasAttribute(attr)) f.push(`@${attr}`);
    }
    if (['font', 'center', 'sup', 'sub', 'blockquote', 'pre', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'button'].includes(tag)) f.push(`<${tag}>`);
    const pad = ['Top', 'Right', 'Bottom', 'Left'].some((s) => cs[`padding${s}`] !== '0px');
    if (pad) f.push('padding');
    const margin = ['Top', 'Right', 'Bottom', 'Left'].map((s) => cs[`margin${s}`]);
    if (margin.some((m) => m.startsWith('-'))) f.push('negative-margin');
    if (el.style.marginLeft === 'auto' || el.style.marginRight === 'auto' || /margin\s*:[^;]*auto/.test(el.getAttribute('style') ?? '')) f.push('margin-auto');
    if (['Top', 'Right', 'Bottom', 'Left'].some((s) => cs[`border${s}Width`] !== '0px' && cs[`border${s}Style`] !== 'none')) f.push('border');
    if (cs.borderTopLeftRadius !== '0px') f.push('radius');
    if (mediaStyled.has(el)) f.push('@media');
    return f;
  };

  const blockOf = (el) => {
    let block = el;
    while (block.parentElement && block !== document.body && isInline(getComputedStyle(block).display)) block = block.parentElement;
    if (blockIds.has(block)) return blockIds.get(block);
    const sig = new Set();
    const chain = [];
    for (let a = el, depth = 0; a && a !== document.documentElement && depth < 10; a = a.parentElement, depth++) {
      for (const f of featuresOf(a)) sig.add(f);
      chain.push(a.localName + (a.className && typeof a.className === 'string' ? '.' + a.className.trim().split(/\s+/)[0] : ''));
    }
    const r = block.getBoundingClientRect();
    const id = out.blocks.length;
    out.blocks.push({
      tag: block.localName,
      path: chain.reverse().join('>'),
      sig: [...sig],
      x: r.left + scrollX,
      y: r.top + scrollY,
      w: r.width,
      h: r.height,
    });
    blockIds.set(block, id);
    return id;
  };

  const underlined = (el) => {
    for (let a = el; a && a !== document.body; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (cs.textDecorationLine.includes('underline')) return true;
      if (!isInline(cs.display)) break;
    }
    return false;
  };

  const range = document.createRange();
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const el = node.parentElement;
    if (!el || el.closest('style,script,title,noscript,template,head')) continue;
    const text = node.data;
    if (!/\S/.test(text)) continue;
    const cs = getComputedStyle(el);
    const fontSize = parseFloat(cs.fontSize);
    const hidden = cs.visibility !== 'visible' || fontSize < 2 || /rgba\(.*,\s*0\)$/.test(cs.color) || cs.color === 'transparent';
    let block = null;
    let underline = null;
    for (const m of text.matchAll(/\S+/g)) {
      range.setStart(node, m.index);
      range.setEnd(node, m.index + m[0].length);
      const rects = [...range.getClientRects()].filter((r) => r.width > 0 && r.height > 0);
      if (!rects.length) continue;
      const left = Math.min(...rects.map((r) => r.left));
      const top = Math.min(...rects.map((r) => r.top));
      const right = Math.max(...rects.map((r) => r.right));
      const bottom = Math.max(...rects.map((r) => r.bottom));
      const rect = { left, top, right, bottom, width: right - left, height: bottom - top };
      const visible = !hidden && visibleRect(rect, el);
      if (!visible) continue;
      block ??= blockOf(el);
      underline ??= underlined(el);
      out.words.push({
        t: m[0],
        x: left + scrollX,
        y: top + scrollY,
        w: rect.width,
        h: rect.height,
        lines: rects.length,
        fs: fontSize,
        fw: Number(cs.fontWeight),
        it: cs.fontStyle !== 'normal',
        c: cs.color,
        u: underline,
        ff: cs.fontFamily,
        b: block,
        glue: m.index === 0 && !/^\s/.test(text),
      });
    }
  }

  for (const img of document.images) {
    const r = img.getBoundingClientRect();
    if (!visibleRect(r, img)) continue;
    out.images.push({
      src: img.currentSrc || img.src,
      x: r.left + scrollX,
      y: r.top + scrollY,
      w: r.width,
      h: r.height,
      nw: img.naturalWidth,
      nh: img.naturalHeight,
    });
  }
  for (const el of document.body.querySelectorAll('*')) {
    const bg = getComputedStyle(el).backgroundImage;
    if (!bg.includes('url(')) continue;
    const r = el.getBoundingClientRect();
    if (!visibleRect(r, el)) continue;
    out.images.push({ src: bg.match(/url\("?(.*?)"?\)/)?.[1], bg: true, x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height });
  }
  const docEl = document.documentElement;
  out.width = W;
  out.docWidth = Math.max(docEl.scrollWidth, document.body.scrollWidth);
  out.docHeight = Math.max(docEl.scrollHeight, document.body.scrollHeight);
  out.compatMode = document.compatMode;
  out.colorScheme = getComputedStyle(docEl).colorScheme;
  return out;
}

async function captureOne(page, { email, width, key, sourceHash }) {
  const base = path.join(outDir, key);
  const source = fs.readFileSync(email.file, 'utf8');
  if (sha256(source) !== sourceHash) throw new Error('HTML changed during capture');
  const html = prepareHtml(source);
  const cacheKey = captureKey(settingsKey, sourceHash, assetsFor(html));
  if (!force && hasCachedCapture(base, cacheKey)) return 'cached';
  clearCapture(base);
  page.removeAllListeners('request');
  page.on('request', (request) => {
    const url = request.url();
    if (url === ORIGIN) {
      return request.respond({ status: 200, contentType: 'text/html; charset=utf-8', body: html });
    }
    const type = request.resourceType();
    if (type === 'image' || /\.(png|jpe?g|gif|webp|svg|bmp|ico)(\?|$)/i.test(url)) {
      const entry = assetIndex[url];
      if (entry?.file) {
        return request.respond({
          status: 200,
          contentType: entry.type || 'application/octet-stream',
          body: fs.readFileSync(path.join(assetsDir, entry.file)),
        });
      }
      return request.respond({ status: 404, body: '' });
    }
    // No external stylesheets, web fonts, frames or scripts: the renderer has none.
    return request.abort('blockedbyclient');
  });
  await page.setViewport({ width, height: 900, deviceScaleFactor: 1 });
  const started = Date.now();
  await page.goto(ORIGIN, { waitUntil: 'load', timeout: 30000 });
  const dump = await page.evaluate(dumpLayout);
  dump.id = email.id;
  dump.ms = Date.now() - started;
  const height = Math.min(Math.max(dump.docHeight, 1), 16000);
  await page.screenshot({
    path: base + '.png',
    clip: { x: 0, y: 0, width, height },
    captureBeyondViewport: true,
  });
  dump.capture = { key: cacheKey, settingsKey, sourceHash, complete: true, png: true };
  fs.writeFileSync(base + '.json', JSON.stringify(dump));
  return 'ok';
}

const corpus = loadCorpus(source).filter((email) => !filter || filter.test(email.id));
const jobs = [...captureJobs(corpus, outDir).values()];
const browser = await puppeteer.launch({
  executablePath: chromePath,
  headless: true,
  args: ['--hide-scrollbars', '--font-render-hinting=none', '--disable-lcd-text', '--force-color-profile=srgb'],
});
const stats = { ok: 0, cached: 0, failed: 0 };
const failures = [];
let next = 0;
await Promise.all(
  Array.from({ length: concurrency }, async () => {
    const page = await browser.newPage();
    await page.setJavaScriptEnabled(false);
    await page.setRequestInterception(true);
    const client = await page.createCDPSession();
    // Monospace like the renderer's Windows mapping (Chrome's own default is Consolas).
    await client.send('Page.setFontFamilies', { fontFamilies: { fixed: 'Courier New' } });
    if (scheme) await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }]);
    if (autoDark) await client.send('Emulation.setAutoDarkModeOverride', { enabled: true });
    while (next < jobs.length) {
      const job = jobs[next++];
      try {
        stats[await captureOne(page, job)]++;
      } catch (error) {
        stats.failed++;
        failures.push({ id: job.email.id, width: job.width, error: String(error.message ?? error).slice(0, 300) });
      }
      const done = stats.ok + stats.cached + stats.failed;
      if (done % 50 === 0) console.log(`${done}/${jobs.length}`, stats);
    }
    await page.close();
  }),
);
await browser.close();
fs.writeFileSync(path.join(outDir, '_failures.json'), JSON.stringify(failures, null, 1));
console.log('chrome done', stats);
if (stats.failed) process.exitCode = 1;
