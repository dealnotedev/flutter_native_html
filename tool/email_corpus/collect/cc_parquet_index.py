"""Query the Common Crawl columnar (parquet) URL index for ESP archive pages.

Fallback for when the CDX server (index.commoncrawl.org) times out.
Deliberately gentle, because data.commoncrawl.org (CloudFront) blocks bursty
clients with 403 "Request blocked":
  1. For every parquet file of the crawl, read only the footer row-group stats
     of url_surtkey (one file per --delay seconds, cached on disk in
     <cache>/<crawl>/meta/<part>.surt.json, so this is a one-off per crawl).
  2. For every target domain, query only the files whose row-group surtkey
     range overlaps the domain's SURT prefix, with a url_surtkey range filter so
     DuckDB reads just that row group (httpfs, threads=4 => <=4 concurrent requests).
Any HTTP 403/429/503 pauses everything with exponential back-off.

Usage (run with the collect venv, isolated mode):
  .venv/Scripts/python.exe -I cc_parquet_index.py <cache-dir> <CRAWL-ID> [<CRAWL-ID> ...]
      [--domains d1,d2,...] [--delay 1.0]

Output: <cache-dir>/<crawl>/hits.jsonl (one JSON per capture with
fetch_status=200 and content_mime_detected=text/html); per (domain, file)
partial results are cached in <cache-dir>/<crawl>/hits-surt/ so re-runs and
added domains only query what is missing.
"""

import gzip
import json
import os
import sys
import time
import urllib.request

import duckdb

DATA = "https://data.commoncrawl.org/"

DEFAULT_DOMAINS = [
    # Mailchimp
    "campaign-archive.com", "campaign-archive1.com", "campaign-archive2.com", "mailchi.mp",
    # Campaign Monitor
    "createsend.com", "createsend1.com", "cmail1.com", "cmail2.com", "cmail19.com", "cmail20.com",
    # Kit / ConvertKit
    "ckarchive.com", "ck.page", "kit.com", "convertkit-mail.com", "convertkit-mail2.com",
    # EmailOctopus
    "eocampaign1.com",
    # MailerLite
    "mailerlite.com", "mailerlite.io", "mlsend.com", "mlsend2.com", "mailerlite.co",
    # Klaviyo
    "klaviyo.com", "kmail-lists.com", "klaviyomail.com",
    # Brevo / Sendinblue
    "sendinblue.com", "brevo.com", "sendibt2.com", "sendibt3.com", "sendibm1.com", "sendibm2.com",
    "brevosend.com", "sendib.com",
    # Other ESPs with public "view as web page" pages
    "constantcontact.com", "mjt.lu", "flodesk.com", "getresponse.com", "aweber.com",
]

COLUMNS = [
    "url", "url_host_name", "url_host_registered_domain", "url_path", "url_query", "fetch_time",
    "content_charset", "content_languages", "content_truncated", "content_digest",
    "warc_filename", "warc_record_offset", "warc_record_length",
]


class Throttled(Exception):
    pass


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def is_throttle(e):
    s = str(e)
    return any(code in s for code in ("403", "429", "503", "Forbidden", "Slow Down"))


def with_backoff(fn, what, tries=8):
    delay = 30
    for i in range(tries):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001
            if i == tries - 1:
                raise
            wait = delay if is_throttle(e) else 5
            log(f"  {what}: {str(e)[:160]} -> sleep {wait}s ({i + 1}/{tries})")
            time.sleep(wait)
            if is_throttle(e):
                delay = min(delay * 2, 900)


def list_parquet_files(crawl):
    url = f"{DATA}crawl-data/{crawl}/cc-index-table.paths.gz"

    def get():
        req = urllib.request.Request(url, headers={"User-Agent": "flutter_html-email-corpus/0.1 (research)"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return gzip.decompress(r.read()).decode("utf-8")

    text = with_backoff(get, "paths")
    return [DATA + p for p in text.split() if "/subset=warc/" in p]


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cache = argv[1]
    crawls, domains, delay = [], DEFAULT_DOMAINS, 1.0
    i = 2
    while i < len(argv):
        a = argv[i]
        if a == "--domains":
            domains = [d.strip() for d in argv[i + 1].split(",") if d.strip()]
            i += 2
        elif a == "--delay":
            delay = float(argv[i + 1])
            i += 2
        else:
            crawls.append(a)
            i += 1
    targets = sorted(set(domains))

    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute("SET threads=4;")
    con.execute("SET http_timeout=120000;")
    con.execute("SET http_retries=1;")
    con.execute("SET enable_http_metadata_cache=true;")

    for crawl in crawls:
        t0 = time.time()
        meta_dir = os.path.join(cache, crawl, "meta")
        os.makedirs(meta_dir, exist_ok=True)
        files = list_parquet_files(crawl)
        log(f"{crawl}: {len(files)} parquet files")

        # ---- 1. footer stats (cached): url_surtkey min/max per row group ----
        # Files are sorted by url_surtkey, so a registered domain lives in one
        # (rarely two) row groups; registered-domain stats are useless for
        # pruning because row groups crossing a TLD boundary span everything.
        n_req = 0
        metas = {}
        for k, f in enumerate(files):
            name = f.rsplit("/", 1)[1]
            mp = os.path.join(meta_dir, name + ".surt.json")
            if os.path.exists(mp):
                with open(mp, encoding="utf-8") as fh:
                    metas[f] = json.load(fh)
                continue

            def get_meta(f=f):
                return con.execute(
                    "SELECT row_group_id, stats_min_value, stats_max_value, num_values FROM parquet_metadata(?) "
                    "WHERE path_in_schema = 'url_surtkey' ORDER BY row_group_id",
                    [f],
                ).fetchall()

            rows = with_backoff(get_meta, f"meta {name}")
            n_req += 1
            m = [[r[0], r[1], r[2], r[3]] for r in rows]
            with open(mp, "w", encoding="utf-8") as fh:
                json.dump(m, fh)
            metas[f] = m
            if (k + 1) % 25 == 0:
                log(f"  meta {k + 1}/{len(files)} ({time.time() - t0:.0f}s)")
            time.sleep(delay)
        log(f"{crawl}: footer stats ready ({n_req} fetched, {time.time() - t0:.0f}s)")

        # ---- 2. (file, domain) pairs whose surt range overlaps a row group ----
        def surt_range(d):
            pre = ",".join(reversed(d.split(".")))
            # keys look like "com,campaign-archive)/..." or "com,campaign-archive,us5)/..."
            return pre + ")", pre + "-"   # ')' (0x29) .. ',' (0x2c) < '-' (0x2d)

        pairs = []  # (file, domain, lo, hi, rows_in_matching_row_groups)
        for f, m in metas.items():
            for d in targets:
                lo, hi = surt_range(d)
                n = sum(r[3] or 0 for r in m if r[1] is None or (r[1] < hi and r[2] >= lo))
                if n:
                    pairs.append((f, d, lo, hi, n))
        log(f"{crawl}: {len(pairs)} (file, domain) pairs in {len({p[0] for p in pairs})} files")

        # ---- 3. query pairs (resumable) ----
        hits_dir = os.path.join(cache, crawl, "hits-surt")
        os.makedirs(hits_dir, exist_ok=True)
        # fetch_time is TIMESTAMPTZ; cast so the Python client does not need pytz.
        cols = ", ".join("CAST(fetch_time AS VARCHAR) AS fetch_time" if c == "fetch_time" else c for c in COLUMNS)
        for k, (f, d, lo, hi, n) in enumerate(pairs):
            name = f.rsplit("/", 1)[1]
            hp = os.path.join(hits_dir, f"{d}__{name}.jsonl")
            if os.path.exists(hp):
                continue
            q = (
                f"SELECT {cols} FROM read_parquet(?) "
                "WHERE url_surtkey >= ? AND url_surtkey < ? "
                "AND fetch_status = 200 AND content_mime_detected = 'text/html'"
            )
            t1 = time.time()
            rows = with_backoff(lambda f=f, lo=lo, hi=hi: con.execute(q, [f, lo, hi]).fetchall(), f"query {d} {name}")
            with open(hp + ".tmp", "w", encoding="utf-8") as out:
                for row in rows:
                    rec = dict(zip(COLUMNS, row))
                    rec["crawl"] = crawl
                    rec["fetch_time"] = str(rec["fetch_time"])
                    out.write(json.dumps(rec, ensure_ascii=False) + "\n")
            os.replace(hp + ".tmp", hp)
            log(f"  query {k + 1}/{len(pairs)} {d} in {name} ({n} rows scanned): {len(rows)} hits ({time.time() - t1:.0f}s)")
            time.sleep(delay)

        # ---- 4. merge ----
        total = 0
        seen = set()
        with open(os.path.join(cache, crawl, "hits.jsonl"), "w", encoding="utf-8") as out:
            for name in sorted(os.listdir(hits_dir)):
                if not name.endswith(".jsonl") or name.split("__")[0] not in targets:
                    continue
                with open(os.path.join(hits_dir, name), encoding="utf-8") as fh:
                    for line in fh:
                        rec = json.loads(line)
                        key = (rec["warc_filename"], rec["warc_record_offset"])
                        if key in seen:
                            continue
                        seen.add(key)
                        out.write(line)
                        total += 1
        log(f"{crawl}: {total} hits in {time.time() - t0:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
