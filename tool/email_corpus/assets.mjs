// Downloads every remote image a corpus references, once, into a shared cache.
// Both renderers read images only from this cache, so runs are deterministic
// and work offline. Usage: node assets.mjs <manifest.jsonl|dir> [--concurrency N]
import fs from 'node:fs';
import path from 'node:path';
import { assetsDir, imageUrls, loadCorpus, readJson, sha256, writeJson } from './common.mjs';

const source = process.argv[2];
if (!source) throw new Error('usage: node assets.mjs <manifest.jsonl|dir>');
const concurrency = Number(process.argv[process.argv.indexOf('--concurrency') + 1]) || 16;
const maxBytes = 8 * 1024 * 1024;
const indexFile = path.join(assetsDir, 'index.json');
const index = readJson(indexFile, {});
fs.mkdirSync(assetsDir, { recursive: true });

const urls = new Set();
for (const email of loadCorpus(source)) {
  for (const url of imageUrls(fs.readFileSync(email.file, 'utf8'))) urls.add(url);
}
const pending = [...urls].filter((url) => !index[url] || index[url].retry);
console.log(`${urls.size} image urls, ${pending.length} to fetch`);

async function fetchOne(url) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      redirect: 'follow',
      headers: { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) email-render-harness' },
    });
    const type = response.headers.get('content-type') ?? '';
    if (!response.ok) return { status: response.status };
    const chunks = [];
    let bytes = 0;
    if (!response.body) return { status: 'empty' };
    for await (const chunk of response.body) {
      bytes += chunk.length;
      if (bytes > maxBytes) return { status: 'too-large', bytes };
      chunks.push(chunk);
    }
    const body = Buffer.concat(chunks, bytes);
    const file = sha256(url) + '.bin';
    fs.writeFileSync(path.join(assetsDir, file), body);
    return { status: 200, type, bytes: body.length, file };
  } catch (error) {
    return { status: 'error', error: String(error.cause?.code ?? error.name), retry: true };
  } finally {
    clearTimeout(timer);
  }
}

let done = 0;
const queue = [...pending];
await Promise.all(
  Array.from({ length: concurrency }, async () => {
    while (queue.length) {
      const url = queue.shift();
      index[url] = await fetchOne(url);
      if (++done % 200 === 0) {
        console.log(`${done}/${pending.length}`);
        writeJson(indexFile, index);
      }
    }
  }),
);
writeJson(indexFile, index);
const ok = Object.values(index).filter((entry) => entry.file).length;
console.log(`cached ${ok}/${Object.keys(index).length} -> ${indexFile}`);
