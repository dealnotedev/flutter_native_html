// Dev helper: print an outline of an HTML file (head children, body tree to depth N with id/class
// and text snippets) to inspect ESP archive chrome.  Usage: node inspect_outline.mjs <file.html> [depth]
import fs from 'node:fs';
import { parseDoc, walkElements, attr, textContent } from './lib/html.mjs';
const [file, depthArg] = process.argv.slice(2);
const html = fs.readFileSync(file, 'utf8');
const doc = parseDoc(html);
const depth = Number(depthArg || 3);
let head, body;
for (const el of walkElements(doc)) { if (el.tagName === 'head' && !head) head = el; if (el.tagName === 'body' && !body) body = el; }
const desc = (el) => {
  const a = (el.attrs || []).filter(x => ['id','class','src','href','rel','name','property','type','http-equiv','content','charset'].includes(x.name)).map(x => `${x.name}="${x.value.slice(0,70)}"`).join(' ');
  return `<${el.tagName}${a ? ' ' + a : ''}>`;
};
console.log('HEAD:');
for (const c of head?.childNodes || []) {
  if (c.tagName) console.log('  ' + desc(c) + (c.tagName === 'style' ? ` [${textContent(c).length} chars] ${textContent(c).replace(/\s+/g,' ').slice(0,100)}` : '') + (c.tagName === 'script' ? ` [${textContent(c).replace(/\s+/g,' ').slice(0,80)}]` : ''));
  else if (c.nodeName === '#comment') console.log('  <!--' + c.data.replace(/\s+/g,' ').slice(0, 80) + '-->');
}
console.log('BODY: ' + (body ? desc(body) : 'none'));
const rec = (el, d) => {
  if (d > depth) return;
  for (const c of el.childNodes || []) {
    if (c.tagName) {
      const t = textContent(c).replace(/\s+/g, ' ').trim();
      console.log('  '.repeat(d) + desc(c) + ` {${t.length}} ` + t.slice(0, 90));
      if (!['table'].includes(c.tagName) || d < 2) rec(c, d + 1);
    } else if (c.nodeName === '#comment') console.log('  '.repeat(d) + '<!--' + c.data.replace(/\s+/g,' ').slice(0, 80) + '-->');
  }
};
if (body) rec(body, 1);
