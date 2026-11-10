// HTML helpers that edit the ORIGINAL source string by offsets (parse5 with
// source locations), so everything that is not explicitly removed stays
// byte-for-byte as it was.
import crypto from 'node:crypto';
import { parse } from 'parse5';

export function parseDoc(html) {
  return parse(html, { sourceCodeLocationInfo: true });
}

/** Depth-first walk over element nodes (including <template> content). */
export function* walkElements(node) {
  const stack = [node];
  while (stack.length) {
    const n = stack.pop();
    if (n.tagName) yield n;
    const kids = [];
    if (n.childNodes) kids.push(...n.childNodes);
    if (n.content && n.content.childNodes) kids.push(...n.content.childNodes);
    for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
  }
}

export function attr(el, name) {
  const a = el.attrs && el.attrs.find((x) => x.name === name);
  return a ? a.value : undefined;
}

export function textContent(node) {
  let s = '';
  const stack = [node];
  while (stack.length) {
    const n = stack.pop();
    if (n.nodeName === '#text') s += n.value;
    if (n.childNodes) for (let i = n.childNodes.length - 1; i >= 0; i--) stack.push(n.childNodes[i]);
  }
  return s;
}

/** [start, end) source range of an element including its end tag (if any). */
export function elementRange(el, html) {
  const loc = el.sourceCodeLocation;
  if (!loc) return null;
  const start = loc.startOffset;
  let end = loc.endOffset;
  if (end == null || end <= start) {
    end = loc.startTag ? loc.startTag.endOffset : start;
  }
  // parse5 reports implied end tags at the start of the next token; that is fine.
  return [start, Math.min(end, html.length)];
}

/** Remove a set of [start,end) ranges from a string. Overlaps are merged. */
export function removeRanges(html, ranges) {
  const rs = ranges.filter(Boolean).sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const r of rs) {
    const last = merged[merged.length - 1];
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
    else merged.push([r[0], r[1]]);
  }
  let out = '';
  let pos = 0;
  for (const [s, e] of merged) {
    out += html.slice(pos, s);
    pos = e;
  }
  return out + html.slice(pos);
}

/** Apply replacements [{start,end,text}] (non-overlapping). */
export function applyEdits(html, edits) {
  const es = [...edits].sort((a, b) => b.start - a.start);
  let out = html;
  for (const e of es) out = out.slice(0, e.start) + e.text + out.slice(e.end);
  return out;
}

/** Remove all <script> elements. Returns {html, removed}. */
export function stripScripts(html) {
  const doc = parseDoc(html);
  const ranges = [];
  for (const el of walkElements(doc)) if (el.tagName === 'script') ranges.push(elementRange(el, html));
  if (!ranges.length) return { html, removed: 0 };
  return { html: removeRanges(html, ranges), removed: ranges.length };
}

/**
 * Structure hash: sequence of tag names + class attributes in document order,
 * no text and no other attributes.
 */
export function structureHash(html) {
  const doc = parseDoc(html);
  const h = crypto.createHash('sha1');
  for (const el of walkElements(doc)) {
    const cls = (attr(el, 'class') || '').trim().split(/\s+/).filter(Boolean).join(' ');
    h.update(`${el.tagName}.${cls}\n`);
  }
  return h.digest('hex');
}

const MARKUP_TAGS = new Set(['table', 'td', 'div', 'p', 'img', 'a', 'span', 'tr', 'center', 'h1', 'h2', 'h3', 'font', 'section', 'ul', 'li', 'br', 'b', 'strong']);

/** Rough check that the document contains real HTML markup in its body. */
export function hasRealMarkup(html) {
  const doc = parseDoc(html);
  let n = 0;
  let body = null;
  for (const el of walkElements(doc)) {
    if (el.tagName === 'body') body = el;
  }
  if (!body) return false;
  for (const el of walkElements(body)) {
    if (MARKUP_TAGS.has(el.tagName) && el.sourceCodeLocation) n++;
    if (n >= 5) return true;
  }
  return false;
}

export function sha256(str) {
  return crypto.createHash('sha256').update(Buffer.from(str, 'utf8')).digest('hex');
}

/**
 * Make a declared non-UTF-8 charset consistent with the UTF-8 output file:
 * rewrite <meta charset> / <meta http-equiv=content-type content=...charset=>.
 * Returns {html, changed:[old charsets]}.
 */
export function forceUtf8Meta(html) {
  const doc = parseDoc(html);
  const edits = [];
  const changed = [];
  for (const el of walkElements(doc)) {
    if (el.tagName !== 'meta') continue;
    const loc = el.sourceCodeLocation;
    if (!loc || !loc.attrs) continue;
    const cs = attr(el, 'charset');
    if (cs != null && !/^\s*utf-?8\s*$/i.test(cs) && loc.attrs.charset) {
      const a = loc.attrs.charset;
      edits.push({ start: a.startOffset, end: a.endOffset, text: 'charset="utf-8"' });
      changed.push(cs);
    }
    const he = attr(el, 'http-equiv');
    const content = attr(el, 'content');
    if (he && he.toLowerCase() === 'content-type' && content && loc.attrs.content) {
      const m = content.match(/charset\s*=\s*["']?([^;"'\s]+)/i);
      if (m && !/^utf-?8$/i.test(m[1])) {
        const a = loc.attrs.content;
        const newContent = content.replace(/charset\s*=\s*["']?[^;"'\s]+["']?/i, 'charset=utf-8');
        edits.push({ start: a.startOffset, end: a.endOffset, text: `content="${newContent.replace(/"/g, '&quot;')}"` });
        changed.push(m[1]);
      }
    }
  }
  return { html: edits.length ? applyEdits(html, edits) : html, changed };
}

/** Find a charset declared in a <meta> in the first bytes of a (latin1-decoded) document. */
export function sniffMetaCharset(headStr) {
  const m1 = headStr.match(/<meta[^>]+charset\s*=\s*["']?\s*([a-zA-Z0-9_:.-]+)/i);
  return m1 ? m1[1] : null;
}
