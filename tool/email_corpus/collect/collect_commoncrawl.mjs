// Collect real sent newsletters from Common Crawl captures of ESP
// "view in browser" / archive pages. Fetches ONLY from Common Crawl.
//
// Usage:
//   node collect_commoncrawl.mjs [--count 150] [--crawls CC-MAIN-2026-43,CC-MAIN-2026-39]
//                                [--per-sender 2] [--concurrency 3] [--index parquet|cdx]
//                                [--samples N]   (only dump N raw pages per ESP for inspection)
//                                [--reset]       (drop commoncrawl entries + seen log first)
//                                [--skip-esps flodesk,klaviyo]
//
// --count is the TARGET number of commoncrawl entries in the corpus (existing
// entries are kept; re-runs continue where the last run stopped; captures
// already tried are listed in _raw/commoncrawl/seen.jsonl and skipped).
// Scaling up: e.g. --count 3000 --crawls CC-MAIN-2026-43,CC-MAIN-2023-06,CC-MAIN-2022-49
// (each new crawl costs one ~5 min pass over 300 parquet footers, cached afterwards).
//
// Index: hits come from <_raw>/commoncrawl/index/<crawl>/hits.jsonl, produced by
// cc_parquet_index.py (columnar index via DuckDB; run automatically if missing),
// or from the CDX server with --index cdx.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { Corpus, slugify } from './lib/corpus.mjs';
import { RAW_DIR, COLLECT_DIR } from './lib/paths.mjs';
import { classify, ESPS } from './lib/esp.mjs';
import { Pool, fetchRecordBytes, parseWarcRecord, decodeBody } from './lib/warc.mjs';
import { forceUtf8Meta } from './lib/html.mjs';
import { cleanCapture } from './lib/strip.mjs';
import { queryCdx } from './lib/cdx.mjs';

const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : def;
};
const COUNT = Number(opt('count', 150));
const CRAWLS = opt('crawls', 'CC-MAIN-2026-43').split(',').filter(Boolean);
const PER_SENDER = Number(opt('per-sender', 2));
const CONCURRENCY = Math.min(4, Number(opt('concurrency', 3)));
const INDEX = opt('index', 'parquet');
const SAMPLES = Number(opt('samples', 0));
const RESET = argv.includes('--reset');
// ESPs not to collect (e.g. flodesk: its web view lays out with view.js, so the
// static HTML is not what subscribers saw; compare.mjs excludes it anyway).
const SKIP_ESPS = new Set(opt('skip-esps', '').split(',').filter(Boolean));

const CC_DIR = path.join(RAW_DIR, 'commoncrawl');
const INDEX_DIR = path.join(CC_DIR, 'index');
const WARC_CACHE = path.join(CC_DIR, 'records');
const SEEN_FILE = path.join(CC_DIR, 'seen.jsonl');

const hashOf = (s) => crypto.createHash('sha1').update(s).digest('hex');

// ---------------------------------------------------------------- index ----
const KNOWN_DOMAINS = [
  'campaign-archive.com', 'campaign-archive1.com', 'campaign-archive2.com', 'mailchi.mp',
  'createsend.com', 'createsend1.com', 'cmail1.com', 'cmail2.com', 'cmail19.com', 'cmail20.com',
  'ckarchive.com', 'ck.page', 'kit.com', 'eocampaign1.com', 'mailerlite.com', 'mailerlite.io', 'mlsend.com',
  'klaviyo.com', 'kmail-lists.com', 'klaviyomail.com', 'sendinblue.com', 'brevo.com', 'sendibt2.com',
  'sendibt3.com', 'sendibm1.com', 'constantcontact.com', 'mjt.lu', 'flodesk.com', 'getresponse.com', 'aweber.com',
];
const CDX_PATTERNS = [
  '*.campaign-archive.com', 'mailchi.mp/*', '*.createsend.com', '*.createsend1.com', '*.cmail19.com', '*.cmail20.com',
  'ckarchive.com/*', 'eocampaign1.com/*', 'preview.mailerlite.io/*', 'myemail.constantcontact.com/*',
];

function cdxToHit(r, crawl) {
  let u;
  try {
    u = new URL(r.url);
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase();
  const dom = KNOWN_DOMAINS.find((d) => host === d || host.endsWith(`.${d}`));
  if (!dom) return null;
  return {
    url: r.url, url_host_name: host, url_host_registered_domain: dom, url_path: u.pathname,
    url_query: u.search.replace(/^\?/, '') || null, fetch_time: r.timestamp, content_charset: r.charset || null,
    content_languages: r.languages || null, content_digest: r.digest, warc_filename: r.filename,
    warc_record_offset: Number(r.offset), warc_record_length: Number(r.length), crawl,
    _status: r.status, _mime: r['mime-detected'] || r.mime,
  };
}

async function loadHits(crawl) {
  if (INDEX === 'cdx') {
    const out = [];
    for (const pat of CDX_PATTERNS) {
      try {
        const recs = await queryCdx(crawl, pat, { cacheDir: path.join(CC_DIR, 'cdx'), maxPages: 5 });
        for (const r of recs) {
          const h = cdxToHit(r, crawl);
          if (h && h._status === '200' && /html/.test(h._mime || '')) out.push(h);
        }
      } catch (e) {
        console.error(`CDX ${crawl} ${pat}: ${e.message}`);
      }
    }
    return out;
  }
  const f = path.join(INDEX_DIR, crawl, 'hits.jsonl');
  if (!fs.existsSync(f)) {
    const py = path.join(COLLECT_DIR, '.venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');
    console.error(`running cc_parquet_index.py for ${crawl} ...`);
    execFileSync(py, ['-I', path.join(COLLECT_DIR, 'cc_parquet_index.py'), INDEX_DIR, crawl], { stdio: 'inherit' });
  }
  return fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

// ------------------------------------------------------------- selection ----
function loadSeen() {
  const seen = new Map();
  if (fs.existsSync(SEEN_FILE)) {
    for (const l of fs.readFileSync(SEEN_FILE, 'utf8').split('\n')) {
      if (!l.trim()) continue;
      const r = JSON.parse(l);
      seen.set(r.key, r);
    }
  }
  return seen;
}

function recordSeen(entry) {
  fs.mkdirSync(path.dirname(SEEN_FILE), { recursive: true });
  fs.appendFileSync(SEEN_FILE, JSON.stringify(entry) + '\n');
}

const DROP_PERSONAL = new Set(['mailchimp', 'mailerlite']);

function buildCandidates(hits) {
  // One capture per (esp, campaign); prefer the most recent capture.
  const byCampaign = new Map();
  for (const h of hits) {
    const c = classify(h);
    if (!c || SKIP_ESPS.has(c.esp)) continue;
    if (h.content_truncated) continue;
    // Never collect captures whose URL carries an email address (subscriber-specific copies).
    if (/(%40|@)[a-z0-9-]+\.[a-z]/i.test(h.url_query || '') || /(%40|@)/.test(h.url_path || '')) continue;
    const key = `${c.esp}|${c.sender || ''}|${c.campaign}`;
    const prev = byCampaign.get(key);
    // Prefer a non-personalised capture of the same campaign, then the most recent one.
    const better =
      !prev ||
      (prev.personal && !c.personal) ||
      (!!prev.personal === !!c.personal && String(h.fetch_time) > String(prev.hit.fetch_time));
    if (better) byCampaign.set(key, { key, hit: h, ...c });
  }
  const byEsp = new Map();
  for (const c of byCampaign.values()) {
    // Personalised copies (URL carries a subscriber id/hash) may show the
    // recipient's merge fields; skip them where the ESP has plenty of public ones.
    if (c.personal && DROP_PERSONAL.has(c.esp)) continue;
    if (!byEsp.has(c.esp)) byEsp.set(c.esp, []);
    byEsp.get(c.esp).push(c);
  }
  // Deterministic shuffle so we sample across senders rather than alphabetically;
  // personalised URLs (where kept) go last.
  for (const list of byEsp.values()) {
    list.sort((a, b) => (!!a.personal - !!b.personal) || hashOf(a.key).localeCompare(hashOf(b.key)));
  }
  return byEsp;
}

// --------------------------------------------------------------- fetching ---
async function fetchCapture(pool, c) {
  const gz = await fetchRecordBytes(pool, c.hit, { cacheDir: WARC_CACHE });
  const rec = parseWarcRecord(gz);
  const dec = decodeBody(rec.body, rec.httpHeaders, c.hit.content_charset);
  return { rec, dec };
}

async function dumpSamples(byEsp, pool) {
  const dir = path.join(CC_DIR, 'samples');
  for (const [esp, list] of byEsp) {
    const d = path.join(dir, esp);
    fs.mkdirSync(d, { recursive: true });
    const picked = [];
    const senders = new Set();
    for (const c of list) {
      if (picked.length >= SAMPLES) break;
      if (c.sender && senders.has(c.sender)) continue;
      senders.add(c.sender);
      picked.push(c);
    }
    await Promise.all(
      picked.map(async (c, i) => {
        try {
          const { rec, dec } = await fetchCapture(pool, c);
          fs.writeFileSync(path.join(d, `${i}.html`), dec.text, 'utf8');
          fs.appendFileSync(path.join(d, 'urls.txt'), `${i}\t${rec.httpStatus}\t${dec.charset}/${dec.source}\t${c.hit.url}\n`);
        } catch (e) {
          console.error(`sample ${esp} ${c.hit.url}: ${e.message}`);
        }
      }),
    );
    console.log(`${esp}: ${list.length} candidates, dumped ${picked.length}`);
  }
}

// ------------------------------------------------------------------- main ---
const pool = new Pool(CONCURRENCY, 300);
let hits = [];
for (const crawl of CRAWLS) {
  const h = await loadHits(crawl);
  console.log(`${crawl}: ${h.length} index hits`);
  for (const x of h) hits.push(x);
}
const byEsp = buildCandidates(hits);
console.log('candidates per ESP:', Object.fromEntries([...byEsp].map(([k, v]) => [k, v.length])));

if (SAMPLES > 0) {
  await dumpSamples(byEsp, pool);
  process.exit(0);
}

const corpus = new Corpus();
if (RESET) {
  // Start the commoncrawl source over with the current rules; fetched WARC
  // records stay cached in _raw/commoncrawl/records, so this is cheap.
  corpus.resetSource('commoncrawl');
  corpus.save();
  fs.rmSync(SEEN_FILE, { force: true });
  console.log('reset: removed commoncrawl entries and seen log');
}
const seen = loadSeen();

// Re-validate existing entries against the current URL rules (rules may have
// been tightened since they were collected); drop those that no longer qualify.
{
  let dropped = 0;
  for (const e of [...corpus.entries.values()]) {
    if (e.source !== 'commoncrawl') continue;
    const h = cdxToHit({ url: e.origin, filename: '', offset: 0, length: 0 }, e.crawl);
    const c = h && classify(h);
    const emailInUrl = /(%40|@)/.test(e.origin);
    const personalDropped = c && c.personal && DROP_PERSONAL.has(c.esp);
    if (!c || emailInUrl || personalDropped) {
      fs.rmSync(path.join(corpus.dir, e.path), { force: true });
      corpus.entries.delete(e.id);
      dropped++;
      console.log(`  dropped existing ${e.id} (${!c ? 'no longer a campaign URL' : emailInUrl ? 'email address in URL' : 'personalised copy'})`);
    }
  }
  if (dropped) {
    corpus.reindex();
    corpus.save();
  }
}
const senderCount = new Map();
for (const e of corpus.entries.values()) {
  if (e.source === 'commoncrawl' && e.sender) senderCount.set(e.sender, (senderCount.get(e.sender) || 0) + 1);
}
const stats = {};
const bump = (esp, k) => {
  stats[esp] ??= {};
  stats[esp][k] = (stats[esp][k] || 0) + 1;
};

const queues = new Map([...byEsp].map(([esp, list]) => [esp, list.filter((c) => !seen.has(c.key))]));
const espOrder = ESPS.filter((e) => queues.has(e));
let need = () => COUNT - corpus.countSource('commoncrawl');
console.log(`commoncrawl entries: ${corpus.countSource('commoncrawl')} / target ${COUNT}`);

async function processOne(c) {
  if (c.sender && (senderCount.get(c.sender) || 0) >= PER_SENDER) return bump(c.esp, 'skip-sender');
  let fetched;
  try {
    fetched = await fetchCapture(pool, c);
  } catch (e) {
    bump(c.esp, 'fetch-error');
    return; // not recorded as seen: retry next run
  }
  const { rec, dec } = fetched;
  let status;
  let id;
  if (rec.httpStatus !== 200) status = `http-${rec.httpStatus}`;
  else {
    const cleaned = cleanCapture(c.esp, dec.text, c.hit.url);
    if (!cleaned.ok) status = `reject:${cleaned.reason}`;
    else {
      const sender = c.sender || (cleaned.senderHint ? `hint:${cleaned.senderHint}` : `campaign:${c.campaign}`);
      if ((senderCount.get(sender) || 0) >= PER_SENDER) status = 'skip-sender';
      else {
        let html = cleaned.html;
        const notes = [...cleaned.notes];
        if (c.personal) notes.push('URL carries a subscriber token (personalised web view)');
        const fx = forceUtf8Meta(html);
        if (fx.changed.length) {
          html = fx.html;
          notes.push(`meta charset ${[...new Set(fx.changed)].join(',')} rewritten to utf-8 (page decoded as ${dec.charset} per ${dec.source}; file is UTF-8)`);
        } else if (dec.charset !== 'utf-8') notes.push(`page decoded as ${dec.charset} per ${dec.source}; file is UTF-8`);
        const short = hashOf(c.hit.url).slice(0, 8);
        const senderSlug = slugify(sender.replace(/^[a-z]+:/, ''), 24);
        const res = corpus.add({
          source: 'commoncrawl',
          slug: `${c.esp}-${senderSlug}-${short}`,
          html,
          origin: c.hit.url,
          license: 'unknown (third-party content via Common Crawl; research use)',
          notes: notes.join('; '),
          extra: {
            esp: c.esp,
            sender,
            crawl: c.hit.crawl,
            warc: `${c.hit.warc_filename}#${c.hit.warc_record_offset}+${c.hit.warc_record_length}`,
            ...(c.hit.content_languages ? { languages: c.hit.content_languages } : {}),
          },
        });
        status = res.status;
        id = res.id;
        if (res.status === 'added') senderCount.set(sender, (senderCount.get(sender) || 0) + 1);
      }
    }
  }
  bump(c.esp, status);
  recordSeen({ key: c.key, url: c.hit.url, esp: c.esp, status, id, at: new Date().toISOString() });
}

// Round-robin across ESPs, a small batch at a time, until the target is reached.
const t0 = Date.now();
let fetchedTotal = 0;
while (need() > 0) {
  const batch = [];
  for (const esp of espOrder) {
    const qq = queues.get(esp);
    while (qq.length && batch.filter((b) => b.esp === esp).length < 1) {
      const c = qq.shift();
      if (c.sender && (senderCount.get(c.sender) || 0) >= PER_SENDER) {
        bump(esp, 'skip-sender');
        continue;
      }
      batch.push(c);
    }
  }
  if (!batch.length) break;
  await Promise.all(batch.map(processOne));
  fetchedTotal += batch.length;
  corpus.save();
  if (fetchedTotal % 20 < batch.length) {
    const secs = (Date.now() - t0) / 1000;
    console.log(`  fetched ${fetchedTotal} (${(fetchedTotal / secs).toFixed(2)}/s), commoncrawl entries ${corpus.countSource('commoncrawl')}/${COUNT}`);
  }
}
corpus.save();
const secs = (Date.now() - t0) / 1000;
console.log(`done: fetched ${fetchedTotal} records in ${secs.toFixed(0)}s; commoncrawl entries ${corpus.countSource('commoncrawl')}`);
for (const [esp, s] of Object.entries(stats)) console.log(`  ${esp.padEnd(16)} ${JSON.stringify(s)}`);
const perEsp = {};
for (const e of corpus.entries.values()) if (e.source === 'commoncrawl') perEsp[e.esp] = (perEsp[e.esp] || 0) + 1;
console.log('corpus per ESP:', perEsp);
