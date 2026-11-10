// Fetch single WARC records from data.commoncrawl.org with HTTP Range requests,
// gunzip the member and split WARC headers / HTTP headers / body.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { sleep } from './cdx.mjs';

const DATA_BASE = 'https://data.commoncrawl.org';

/** Simple concurrency limiter + global back-off when CloudFront throttles. */
export class Pool {
  constructor(concurrency = 3, minIntervalMs = 250) {
    this.concurrency = concurrency;
    this.minIntervalMs = minIntervalMs;
    this.active = 0;
    this.queue = [];
    this.pausedUntil = 0;
    this.lastStart = 0;
  }
  run(fn) {
    return new Promise((resolve, reject) => {
      this.queue.push({ fn, resolve, reject });
      this._next();
    });
  }
  pause(ms) {
    this.pausedUntil = Math.max(this.pausedUntil, Date.now() + ms);
  }
  async _next() {
    if (this.active >= this.concurrency || !this.queue.length) return;
    const job = this.queue.shift();
    this.active++;
    try {
      for (;;) {
        const wait = Math.max(this.pausedUntil - Date.now(), this.lastStart + this.minIntervalMs - Date.now());
        if (wait <= 0) break;
        await sleep(wait);
      }
      this.lastStart = Date.now();
      job.resolve(await job.fn());
    } catch (e) {
      job.reject(e);
    } finally {
      this.active--;
      this._next();
    }
  }
}

export class ThrottledError extends Error {}

/**
 * Fetch raw (gzipped) bytes of one record. Caches to cacheDir by key.
 * Retries with back-off; on 403/429/503 pauses the whole pool.
 */
export async function fetchRecordBytes(pool, rec, { cacheDir, tries = 6 } = {}) {
  const key = crypto.createHash('sha1').update(`${rec.warc_filename}:${rec.warc_record_offset}`).digest('hex');
  const cacheFile = cacheDir ? path.join(cacheDir, key.slice(0, 2), `${key}.warc.gz`) : null;
  if (cacheFile && fs.existsSync(cacheFile)) return fs.readFileSync(cacheFile);
  const start = Number(rec.warc_record_offset);
  const end = start + Number(rec.warc_record_length) - 1;
  const url = `${DATA_BASE}/${rec.warc_filename}`;
  let delay = 5000;
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      const buf = await pool.run(async () => {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 90000);
        try {
          const res = await fetch(url, {
            headers: { Range: `bytes=${start}-${end}`, 'user-agent': 'flutter_html-email-corpus/0.1 (research)' },
            signal: ctrl.signal,
          });
          if (res.status === 206 || res.status === 200) return Buffer.from(await res.arrayBuffer());
          await res.arrayBuffer().catch(() => {});
          if ([403, 429, 503].includes(res.status)) {
            pool.pause(60000 * (i + 1));
            throw new ThrottledError(`HTTP ${res.status} (throttled)`);
          }
          throw new Error(`HTTP ${res.status}`);
        } finally {
          clearTimeout(t);
        }
      });
      if (cacheFile) {
        fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
        fs.writeFileSync(cacheFile, buf);
      }
      return buf;
    } catch (e) {
      lastErr = e;
      process.stderr.write(`  fetch retry ${i + 1}/${tries} ${rec.url.slice(0, 100)}: ${e.message}\n`);
      await sleep(delay);
      delay = Math.min(delay * 2, 120000);
    }
  }
  throw lastErr;
}

function parseHeaderBlock(text) {
  const lines = text.split(/\r?\n/);
  const first = lines.shift();
  const headers = {};
  for (const l of lines) {
    const i = l.indexOf(':');
    if (i <= 0) continue;
    const k = l.slice(0, i).trim().toLowerCase();
    const v = l.slice(i + 1).trim();
    headers[k] = headers[k] ? `${headers[k]}, ${v}` : v;
  }
  return { first, headers };
}

function indexOfCrlf2(buf, from = 0) {
  const a = buf.indexOf('\r\n\r\n', from, 'latin1');
  return a;
}

/** Decode chunked transfer-encoding if needed (CC usually stores de-chunked payloads). */
function dechunk(buf) {
  const out = [];
  let pos = 0;
  for (;;) {
    const lineEnd = buf.indexOf('\r\n', pos, 'latin1');
    if (lineEnd < 0) return null;
    const size = parseInt(buf.slice(pos, lineEnd).toString('latin1').split(';')[0].trim(), 16);
    if (Number.isNaN(size)) return null;
    if (size === 0) break;
    out.push(buf.slice(lineEnd + 2, lineEnd + 2 + size));
    pos = lineEnd + 2 + size + 2;
    if (pos > buf.length) return null;
  }
  return Buffer.concat(out);
}

/** Parse a gzipped WARC response record. */
export function parseWarcRecord(gz) {
  const raw = zlib.gunzipSync(gz);
  const e1 = indexOfCrlf2(raw);
  const warc = parseHeaderBlock(raw.slice(0, e1).toString('latin1'));
  const contentLen = Number(warc.headers['content-length'] || raw.length - e1 - 4);
  const block = raw.slice(e1 + 4, e1 + 4 + contentLen);
  const e2 = indexOfCrlf2(block);
  const http = parseHeaderBlock(block.slice(0, e2).toString('latin1'));
  let body = block.slice(e2 + 4);
  const te = (http.headers['transfer-encoding'] || '').toLowerCase();
  if (te.includes('chunked')) {
    const d = dechunk(body);
    if (d) body = d;
  }
  const ce = (http.headers['content-encoding'] || '').toLowerCase();
  try {
    if (ce.includes('gzip')) body = zlib.gunzipSync(body);
    else if (ce.includes('br')) body = zlib.brotliDecompressSync(body);
    else if (ce.includes('deflate')) body = zlib.inflateSync(body);
  } catch {
    /* CC usually stores decoded payloads; keep as is */
  }
  const statusMatch = /^HTTP\/\S+\s+(\d+)/.exec(http.first || '');
  return { warcHeaders: warc.headers, httpStatus: statusMatch ? Number(statusMatch[1]) : null, httpHeaders: http.headers, body };
}

const LABEL_ALIASES = {
  'iso-8859-1': 'windows-1252',
  latin1: 'windows-1252',
  'us-ascii': 'windows-1252',
  ascii: 'windows-1252',
  utf8: 'utf-8',
  'x-sjis': 'shift_jis',
};

function normLabel(l) {
  if (!l) return null;
  const s = l.trim().toLowerCase().replace(/^["']|["']$/g, '');
  return LABEL_ALIASES[s] || s;
}

/**
 * Decode body bytes: BOM > HTTP Content-Type charset > <meta> charset > CC detected > utf-8.
 * Returns {text, charset, source}.
 */
export function decodeBody(body, httpHeaders, ccCharset) {
  if (body[0] === 0xef && body[1] === 0xbb && body[2] === 0xbf) return { text: new TextDecoder('utf-8').decode(body.slice(3)), charset: 'utf-8', source: 'bom' };
  const candidates = [];
  const ct = httpHeaders['content-type'] || '';
  const m = /charset\s*=\s*["']?([^;"'\s]+)/i.exec(ct);
  if (m) candidates.push([normLabel(m[1]), 'http']);
  const head = body.slice(0, 4096).toString('latin1');
  const mm = /<meta[^>]+charset\s*=\s*["']?\s*([a-zA-Z0-9_:.-]+)/i.exec(head);
  if (mm) candidates.push([normLabel(mm[1]), 'meta']);
  if (ccCharset) candidates.push([normLabel(ccCharset), 'cc-detected']);
  candidates.push(['utf-8', 'default']);
  // A declared UTF-8 that does not decode cleanly (common on legacy pages whose
  // HTTP header says utf-8 while the bytes and <meta> are Latin-1) falls through
  // to the next declaration; non-UTF-8 single-byte labels always decode.
  for (const [label, src] of candidates) {
    try {
      const dec = new TextDecoder(label, { fatal: label === 'utf-8' && src !== 'default' });
      return { text: dec.decode(body), charset: label, source: src };
    } catch {
      /* unknown label or invalid UTF-8: try next */
    }
  }
  return { text: body.toString('utf8'), charset: 'utf-8', source: 'fallback' };
}
