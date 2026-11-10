// Shared paths and settings for the browser-parity harness.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const harnessDir = path.dirname(fileURLToPath(import.meta.url));
export const repoDir = path.resolve(harnessDir, '..', '..');
export const storeDir = path.join(repoDir, '.email_test_store', 'corpus');
export const assetsDir = path.join(storeDir, 'assets');
export const fontsManifest = path.join(storeDir, 'fonts.json');

export const chromePath =
  process.env.CHROME_PATH ?? 'C:/Program Files/Google/Chrome/Application/chrome.exe';

/** Viewport widths each email is rendered at. */
export const widths = (process.env.WIDTHS ?? '375,680').split(',').map(Number);

/**
 * Email-client user-agent shim injected before author styles in Chrome.
 * Every rule mirrors a deliberate default of flutter_native_html, so the diff
 * shows renderer bugs rather than known product choices. Zero specificity
 * keeps all author rules winning, as the renderer's UA layer does.
 */
const systemFontFaces = ['-apple-system', 'BlinkMacSystemFont']
  .flatMap((family) =>
    [
      ['400', 'normal', 'Segoe UI'],
      ['400', 'italic', 'Segoe UI Italic'],
      ['300', 'normal', 'Segoe UI Light'],
      ['600', 'normal', 'Segoe UI Semibold'],
      ['700', 'normal', 'Segoe UI Bold'],
      ['700', 'italic', 'Segoe UI Bold Italic'],
      ['900', 'normal', 'Segoe UI Black'],
    ].map(([weight, style, face]) => `@font-face{font-family:"${family}";font-weight:${weight};font-style:${style};src:local("${face}")}`),
  )
  .join('');

export const chromeShimCss = [
  // The renderer maps Apple system-font aliases to the platform UI font, as
  // Safari does; Chrome on Windows ignores them. Alias them to Segoe UI.
  systemFontFaces,
  ':where(body){margin:0}', // email clients render the body without UA margin
  ':where(html){line-height:1.35}', // renderer root line-height (browser: normal)
  ':where(a){color:#1a0dab}', // renderer UA link color
  ':where(img){max-width:100%}', // renderer emulates the near-universal email reset
].join('');

/** Renderer settings matching the Chrome defaults (see flutter_capture_test.dart). */
export const flutterConfig = {
  baseFontSize: 16,
  defaultTableCellSpacing: Number(process.env.TABLE_SPACING ?? 2),
  defaultFontFamily: 'Times New Roman',
};

export const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');

export function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    if (fallback !== undefined) return fallback;
    throw error;
  }
}

export function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 1));
}

/**
 * Loads a corpus: a manifest.jsonl (lines {id, path}) relative to its folder,
 * or a directory scanned recursively for .html files.
 */
export function loadCorpus(source) {
  const resolved = path.resolve(source);
  const stat = fs.statSync(resolved);
  if (stat.isFile()) {
    const base = path.dirname(resolved);
    return fs
      .readFileSync(resolved, 'utf8')
      .split(/\r?\n/)
      .filter((line) => line.trim())
      .map((line) => JSON.parse(line))
      .map((entry) => ({ ...entry, file: path.resolve(base, entry.path) }));
  }
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (/\.html?$/i.test(entry.name)) {
        out.push({
          id: path.relative(resolved, full).replace(/\\/g, '/').replace(/\.html?$/i, ''),
          file: full,
        });
      }
    }
  };
  walk(resolved);
  return out;
}

/** Filesystem-safe key for an email id + width. */
export const jobKey = (id, width) => `${id.replace(/[^A-Za-z0-9._-]+/g, '_')}@${width}`;

export function runDir(name) {
  return path.join(storeDir, 'runs', name);
}

/** Absolute http(s) URLs an email references as images (img, backgrounds, CSS url()). */
export function imageUrls(html) {
  const urls = new Set();
  const add = (raw) => {
    const value = raw
      .trim()
      .replace(/^['"]|['"]$/g, '')
      .replace(/&amp;/g, '&')
      .trim();
    if (/^https?:\/\//i.test(value)) urls.add(value);
    else if (value.startsWith('//')) urls.add('https:' + value);
  };
  for (const m of html.matchAll(/<img\b[^>]*?\bsrc\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi)) add(m[1]);
  for (const m of html.matchAll(/\bbackground\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi)) add(m[1]);
  for (const m of html.matchAll(/url\(\s*("[^"]*"|'[^']*'|[^)]*)\s*\)/gi)) add(m[1]);
  return [...urls];
}

/** Lower-cased font family names an email asks for. */
export function fontFamilies(html) {
  const names = new Set();
  const addList = (list) => {
    for (const part of list.split(',')) {
      const name = part
        .trim()
        .replace(/!important$/i, '')
        .trim()
        .replace(/^['"]|['"]$/g, '')
        .replace(/&quot;|&#39;/g, '')
        .trim()
        .toLowerCase();
      if (name && name.length < 64) names.add(name);
    }
  };
  for (const m of html.matchAll(/font-family\s*:\s*([^;}"<>]+)/gi)) addList(m[1]);
  for (const m of html.matchAll(/font-family\s*:\s*([^;}<>]+?)(?=;|}|"|$)/gim)) addList(m[1]);
  for (const m of html.matchAll(/\bface\s*=\s*("[^"]*"|'[^']*')/gi)) addList(m[1].slice(1, -1));
  return [...names];
}
