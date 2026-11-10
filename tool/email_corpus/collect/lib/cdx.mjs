// Common Crawl CDX index client with retry/backoff and on-disk caching.
// Only talks to index.commoncrawl.org.
import fs from 'node:fs';
import path from 'node:path';

const CDX_BASE = 'https://index.commoncrawl.org';

export async function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

export async function fetchWithRetry(url, { tries = 6, timeoutMs = 120000, headers = {}, okStatuses = [200], log = true } = {}) {
  let delay = 2000;
  let lastErr;
  for (let i = 0; i < tries; i++) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await fetch(url, { headers: { 'user-agent': 'flutter_html-email-corpus/0.1 (research; contact via github)', ...headers }, signal: ctrl.signal });
      if (okStatuses.includes(res.status)) {
        const buf = Buffer.from(await res.arrayBuffer());
        clearTimeout(t);
        return { status: res.status, buf, headers: res.headers };
      }
      // CDX returns 404 with a JSON message when there are no captures.
      if (res.status === 404) {
        const body = await res.text();
        clearTimeout(t);
        return { status: 404, buf: Buffer.from(body), headers: res.headers };
      }
      lastErr = new Error(`HTTP ${res.status}`);
      await res.arrayBuffer().catch(() => {});
    } catch (e) {
      lastErr = e;
    } finally {
      clearTimeout(t);
    }
    if (log) process.stderr.write(`  retry ${i + 1}/${tries} ${url.slice(0, 140)}: ${lastErr.message}\n`);
    await sleep(delay + Math.random() * 1000);
    delay = Math.min(delay * 2, 60000);
  }
  throw lastErr;
}

let collinfoCache;
export async function listCrawls() {
  if (collinfoCache) return collinfoCache;
  const { buf } = await fetchWithRetry(`${CDX_BASE}/collinfo.json`);
  collinfoCache = JSON.parse(buf.toString('utf8'));
  return collinfoCache;
}

function safeName(s) {
  return s.replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 120);
}

/**
 * Query one CDX pattern on one crawl. Results are cached under cacheDir.
 * Returns array of records (objects). Iterates all pages up to maxPages.
 */
export async function queryCdx(crawl, urlPattern, { cacheDir, maxPages = 3, filters = [], fl = 'url,status,mime,mime-detected,filename,offset,length,timestamp,digest,languages,charset' } = {}) {
  const key = safeName(`${crawl}__${urlPattern}__${filters.join('_')}`);
  const cacheFile = cacheDir ? path.join(cacheDir, `${key}.jsonl`) : null;
  if (cacheFile && fs.existsSync(cacheFile)) {
    return fs.readFileSync(cacheFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  }
  const api = `${CDX_BASE}/${crawl}-index`;
  const qs = (extra) => {
    const p = new URLSearchParams({ url: urlPattern, output: 'json', ...extra });
    for (const f of filters) p.append('filter', f);
    return `${api}?${p.toString()}`;
  };
  let pages = 1;
  try {
    const { status, buf } = await fetchWithRetry(qs({ showNumPages: 'true' }));
    if (status === 200) pages = JSON.parse(buf.toString('utf8')).pages || 1;
  } catch (e) {
    process.stderr.write(`  showNumPages failed for ${crawl} ${urlPattern}: ${e.message}\n`);
  }
  const out = [];
  for (let p = 0; p < Math.min(pages, maxPages); p++) {
    const { status, buf } = await fetchWithRetry(qs({ page: String(p), fl }));
    if (status === 404) break;
    for (const line of buf.toString('utf8').split('\n')) {
      if (!line.trim()) continue;
      try {
        out.push(JSON.parse(line));
      } catch {
        /* ignore */
      }
    }
  }
  if (cacheFile) {
    fs.mkdirSync(cacheDir, { recursive: true });
    fs.writeFileSync(cacheFile, out.map((r) => JSON.stringify(r)).join('\n') + '\n');
  }
  return out;
}
