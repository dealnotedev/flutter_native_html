// Survey which ESP archive patterns have captures in a Common Crawl crawl.
// Usage: node survey_cdx.mjs [CRAWL-ID] [pattern ...]
import path from 'node:path';
import { queryCdx } from './lib/cdx.mjs';
import { RAW_DIR } from './lib/paths.mjs';

const crawl = process.argv[2] || 'CC-MAIN-2026-43';
const patterns = process.argv.slice(3);
const cacheDir = path.join(RAW_DIR, 'commoncrawl', 'cdx');

for (const pat of patterns) {
  const t0 = Date.now();
  try {
    const recs = await queryCdx(crawl, pat, { cacheDir, maxPages: 1 });
    const byStatus = {};
    for (const r of recs) byStatus[r.status] = (byStatus[r.status] || 0) + 1;
    const ok = recs.filter((r) => r.status === '200' && (r['mime-detected'] || r.mime || '').includes('html'));
    console.log(`${pat}: ${recs.length} recs ${JSON.stringify(byStatus)} html200=${ok.length} (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    for (const r of ok.slice(0, 6)) console.log(`   ${r.url.slice(0, 150)}`);
  } catch (e) {
    console.log(`${pat}: FAILED ${e.message}`);
  }
}
