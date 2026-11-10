// Side-by-side PNG (Chrome | Flutter) of one job with issue overlays, for triage.
// Usage: node sbs.mjs --run <name> --key <job key> [--y0 0] [--y1 1600] [--out file.png]
import fs from 'node:fs';
import path from 'node:path';
import { PNG } from 'pngjs';
import { runDir } from './common.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const dir = runDir(option('--run', 'pilot'));
const key = option('--key');
const y0 = Number(option('--y0', '0'));
const y1 = Number(option('--y1', '1600'));
const out = option('--out', path.join(dir, 'report', 'sbs', key + `_${y0}.png`));
const results = JSON.parse(fs.readFileSync(path.join(dir, 'results.json'), 'utf8')).results;
const result = results.find((r) => r.key === key);
const chrome = JSON.parse(fs.readFileSync(path.join(dir, 'chrome', key + '.json'), 'utf8'));
const load = (side) => {
  const file = path.join(dir, side, key + '.png');
  return fs.existsSync(file) ? PNG.sync.read(fs.readFileSync(file)) : new PNG({ width: 10, height: 10 });
};
const c = load('chrome');
const f = load('flutter');
const gap = 12;
const height = Math.max(1, Math.min(y1, Math.max(c.height, f.height)) - y0);
const img = new PNG({ width: c.width + gap + f.width, height });
img.data.fill(255);
const blit = (src, dx) => {
  for (let y = 0; y < height; y++) {
    const sy = y + y0;
    if (sy >= src.height) break;
    src.data.copy(img.data, (y * img.width + dx) * 4, sy * src.width * 4, (sy * src.width + src.width) * 4);
  }
};
blit(c, 0);
blit(f, c.width + gap);
const box = (r, dx, rgb) => {
  const x0 = Math.round(r.x + dx);
  const x1 = Math.round(r.x + r.w + dx);
  const top = Math.round(r.y - y0);
  const bottom = Math.round(r.y + r.h - y0);
  const put = (x, y) => {
    if (x < 0 || y < 0 || x >= img.width || y >= height) return;
    const i = (y * img.width + x) * 4;
    img.data[i] = rgb[0];
    img.data[i + 1] = rgb[1];
    img.data[i + 2] = rgb[2];
    img.data[i + 3] = 255;
  };
  for (let x = x0; x <= x1; x++) {
    put(x, top);
    put(x, bottom);
  }
  for (let y = top; y <= bottom; y++) {
    put(x0, y);
    put(x1, y);
  }
};
for (const bi of result?.blockIssues ?? []) {
  const block = chrome.blocks[bi.block];
  if (block) box(block, 0, [255, 140, 0]);
}
for (const w of result?.missingWords ?? []) box(w, 0, [230, 0, 0]);
for (const w of result?.extraWords ?? []) box(w, c.width + gap, [160, 0, 255]);
for (const ii of result?.imageIssues ?? []) {
  box(ii.c, 0, [0, 120, 255]);
  if (ii.f) box(ii.f, c.width + gap, [0, 120, 255]);
}
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, PNG.sync.write(img));
console.log(out);
