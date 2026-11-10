// Corpus writer: normalization (script removal, size/markup filters), exact and
// near-duplicate (structure hash) dedupe, file output and manifest.jsonl.
import fs from 'node:fs';
import path from 'node:path';
import { PILOT_DIR } from './paths.mjs';
import { stripScripts, structureHash, hasRealMarkup, sha256 } from './html.mjs';

export const MIN_BYTES = 1024;
export const MAX_BYTES = Math.floor(1.5 * 1024 * 1024);
export const MAX_PER_STRUCTURE = 2;

export function slugify(s, max = 80) {
  return (
    String(s)
      .normalize('NFKD')
      .replace(/[̀-ͯ]/g, '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, max)
      .replace(/-+$/g, '') || 'x'
  );
}

export class Corpus {
  constructor(dir = PILOT_DIR) {
    this.dir = dir;
    this.manifestPath = path.join(dir, 'manifest.jsonl');
    this.entries = new Map(); // id -> entry
    if (fs.existsSync(this.manifestPath)) {
      for (const line of fs.readFileSync(this.manifestPath, 'utf8').split('\n')) {
        if (!line.trim()) continue;
        const e = JSON.parse(line);
        this.entries.set(e.id, e);
      }
    }
    this.reindex();
  }

  reindex() {
    this.bySha = new Map();
    this.structCount = new Map();
    for (const e of this.entries.values()) {
      this.bySha.set(e.sha256, e.id);
      if (e.structure_hash) this.structCount.set(e.structure_hash, (this.structCount.get(e.structure_hash) || 0) + 1);
    }
  }

  /** Delete all entries (and files) for a source, e.g. before a deterministic re-run. */
  resetSource(source) {
    for (const [id, e] of [...this.entries]) {
      if (e.source !== source) continue;
      const f = path.join(this.dir, e.path);
      if (fs.existsSync(f)) fs.unlinkSync(f);
      this.entries.delete(id);
    }
    this.reindex();
  }

  countSource(source, pred = () => true) {
    let n = 0;
    for (const e of this.entries.values()) if (e.source === source && pred(e)) n++;
    return n;
  }

  hasOrigin(origin) {
    for (const e of this.entries.values()) if (e.origin === origin) return true;
    return false;
  }

  uniqueId(source, slug) {
    let id = `${source}/${slug}`;
    let i = 2;
    while (this.entries.has(id)) id = `${source}/${slug}-${i++}`;
    return id;
  }

  /**
   * Normalize and add one document. Returns {status, id?}.
   * status: added | dup-sha | dup-structure | too-small | too-large | no-markup
   */
  add({ source, slug, html, origin, license, notes, extra = {}, structureDedupe = true, sizeAndMarkupFilter = true }) {
    const s = stripScripts(html);
    let out = s.html;
    const noteParts = [];
    if (notes) noteParts.push(notes);
    if (s.removed) noteParts.push(`removed ${s.removed} <script>`);
    if (out.charCodeAt(0) === 0xfeff) out = out.slice(1);
    const bytes = Buffer.byteLength(out, 'utf8');
    if (bytes > MAX_BYTES) return { status: 'too-large' };
    if (sizeAndMarkupFilter) {
      if (bytes < MIN_BYTES) return { status: 'too-small' };
      if (!hasRealMarkup(out)) return { status: 'no-markup' };
    } else if (bytes < MIN_BYTES || !hasRealMarkup(out)) {
      noteParts.push(bytes < MIN_BYTES ? 'kept despite <1 KB (curated feature test)' : 'kept despite minimal markup (curated feature test)');
    }
    const sha = sha256(out);
    if (this.bySha.has(sha)) return { status: 'dup-sha', of: this.bySha.get(sha) };
    const sh = structureHash(out);
    if (structureDedupe && (this.structCount.get(sh) || 0) >= MAX_PER_STRUCTURE) return { status: 'dup-structure' };
    const id = this.uniqueId(source, slugify(slug));
    const rel = `${id}.html`;
    const file = path.join(this.dir, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, out, 'utf8');
    const entry = {
      id,
      source,
      origin,
      license: license || 'unknown',
      path: rel,
      bytes,
      sha256: sha,
      ...(noteParts.length ? { notes: noteParts.join('; ') } : {}),
      structure_hash: sh,
      ...extra,
    };
    this.entries.set(id, entry);
    this.bySha.set(sha, id);
    this.structCount.set(sh, (this.structCount.get(sh) || 0) + 1);
    return { status: 'added', id };
  }

  save() {
    fs.mkdirSync(this.dir, { recursive: true });
    const lines = [...this.entries.values()]
      .sort((a, b) => a.id.localeCompare(b.id))
      .map((e) => JSON.stringify(e));
    fs.writeFileSync(this.manifestPath, lines.join('\n') + (lines.length ? '\n' : ''), 'utf8');
  }
}
