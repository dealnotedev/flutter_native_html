// Per-ESP rules: decide whether a Common Crawl capture is a real single
// campaign page, and strip ESP archive chrome that is not part of the sent
// email. All edits are offset-based removals on the original source, so the
// remaining markup is byte-for-byte what the ESP served. <script> elements are
// removed later by the generic normalizer (corpus.add).
import { parseDoc, walkElements, attr, textContent, elementRange, removeRanges } from './html.mjs';

const ESP_HOST_RE =
  /(campaign-archive\d?\.com|list-manage\.com|mailchi\.mp|mcusercontent\.com|mailchimp\.com|eepurl\.com|createsend\d*\.com|cmail\d+\.com|cmcdn|convertkit|ckarchive|kit\.com|ck\.page|eocampaign\d*\.com|eomail\d*\.com|emailoctopus|constantcontact\.com|rs6\.net|ctctcdn|klaviyo|kmail-lists|mailerlite|mlsend|sendinblue|brevo|sendib|flodesk|google|gstatic|googleapis|facebook|fb\.com|twitter|x\.com|instagram|linkedin|youtube|youtu\.be|pinterest|tiktok|cloudfront\.net|amazonaws\.com|w3\.org|schemas\.microsoft|apple\.com|wp\.com|squarespace-cdn|imgur|bit\.ly|tinyurl|goo\.gl|bing\.com|ow\.ly|buff\.ly|amzn|forwardtomyfriend|rebrand\.ly|^t\.co$|lnkd\.in|forms\.gle|amazon\.|paypal|eventbrite|zoom\.us|spotify|medium\.com|substack\.com|wikipedia|reuters\.com|whatsapp|wa\.me|vimeo|soundcloud|threads\.net|bsky)/i;

/** Most frequent non-ESP, non-social link host: used as a sender key when the URL has none. */
export function senderHintFromLinks(doc) {
  const counts = new Map();
  for (const el of walkElements(doc)) {
    if (el.tagName !== 'a') continue;
    const href = attr(el, 'href') || '';
    let host;
    try {
      host = new URL(href).hostname.toLowerCase().replace(/^www\./, '');
    } catch {
      continue;
    }
    if (!host || ESP_HOST_RE.test(host)) continue;
    counts.set(host, (counts.get(host) || 0) + 1);
  }
  let best = null;
  for (const [h, n] of counts) if (!best || n > best[1]) best = [h, n];
  return best ? best[0] : null;
}

function findAll(doc, pred) {
  const out = [];
  for (const el of walkElements(doc)) if (pred(el)) out.push(el);
  return out;
}

function headOf(doc) {
  for (const el of walkElements(doc)) if (el.tagName === 'head') return el;
  return null;
}
function bodyOf(doc) {
  for (const el of walkElements(doc)) if (el.tagName === 'body') return el;
  return null;
}

/** Archive-injected sharing/SEO metas: og:*, twitter:*, robots. Not part of the sent email. */
function shareMetas(doc) {
  return findAll(doc, (el) => {
    if (el.tagName !== 'meta') return false;
    const p = (attr(el, 'property') || attr(el, 'name') || '').toLowerCase();
    return /^(og:|twitter:|fb:)/.test(p) || p === 'robots';
  });
}

const NOT_FOUND_RE =
  /^(404|not found|error|redirecting|access denied)\b|\b404\b|page not found|page (does not|doesn't) exist|campaign (not found|has been removed|was removed)|no longer available|redirecting\.\.\./i;

/** Generic sanity checks on the decoded page. */
function genericReject(doc, html) {
  const title = (findAll(doc, (e) => e.tagName === 'title')[0] && textContent(findAll(doc, (e) => e.tagName === 'title')[0])) || '';
  if (NOT_FOUND_RE.test(title.trim()) && title.length < 80) return `error-title:${title.trim().slice(0, 40)}`;
  const body = bodyOf(doc);
  if (!body) return 'no-body';
  const text = textContent(body).replace(/\s+/g, ' ').trim();
  if (text.length < 150) return 'too-little-text';
  if (/^(404|page not found)/i.test(text)) return 'error-body';
  const forms = findAll(body, (e) => e.tagName === 'form');
  const emailInputs = findAll(body, (e) => e.tagName === 'input' && /email/i.test(`${attr(e, 'type')} ${attr(e, 'name')}`));
  const tables = findAll(body, (e) => e.tagName === 'table').length;
  if (forms.length && emailInputs.length && tables < 3) return 'signup-form';
  return null;
}

function finish(html, ranges, notes, doc, extra = {}) {
  return { ok: true, html: ranges.length ? removeRanges(html, ranges) : html, notes, senderHint: senderHintFromLinks(doc), ...extra };
}

// ------------------------------------------------------------- Mailchimp ---
// Archive pages (usN.campaign-archive.com/?u=..&id=.., mailchi.mp/<acct>/<slug>)
// add, around the sent email:
//  * a wrapper <body id="archivebody"> start tag placed before the email's own
//    <body ...> tag (browsers merge the two; we drop the wrapper tag so the
//    email's body attributes win, or just its id when the email had no <body>),
//  * <div id="awesomewrap"> (#awesomeshare + ul#awesomebar: Campaign URL /
//    Subscribe / Past Issues / RSS / Translate) at the top of <body>,
//  * <link rel=stylesheet href="https://usN.campaign-archive.com/css/archivebar-desktop.css">
//    (and any <style> block that only styles the bar),
//  * head metas: og:*, twitter:*, fb:page_id, referrer, and an extra
//    viewport "width=device-width, initial-scale=1, maximum-scale=1" when the
//    email declares its own viewport,
//  * <script>s after </body> (jQuery, clipboard/translate JS, Google Analytics) - removed generically.
function cleanMailchimp(doc, html) {
  const notes = [];
  const ranges = [];
  const body = bodyOf(doc);
  if (body && attr(body, 'id') === 'archivebody') {
    const st = body.sourceCodeLocation.startTag;
    const rest = html.slice(st.endOffset);
    const m = /<body[\s>]/i.exec(rest);
    const firstCenterOrTable = rest.search(/<(center|table)[\s>]/i);
    if (m && (firstCenterOrTable < 0 || m.index < firstCenterOrTable)) {
      ranges.push([st.startOffset, st.endOffset]);
      notes.push('removed wrapper <body id="archivebody"> (email\'s own <body> kept)');
    } else if (st.attrs && st.attrs.id) {
      // Remove ` id="archivebody"` including the preceding whitespace.
      let s0 = st.attrs.id.startOffset;
      while (s0 > st.startOffset && /\s/.test(html[s0 - 1])) s0--;
      ranges.push([s0, st.attrs.id.endOffset]);
      notes.push('removed id="archivebody" from <body>');
    }
  }
  const extraMetas = findAll(doc, (el) => el.tagName === 'meta' && (attr(el, 'name') || '').toLowerCase() === 'referrer');
  const viewports = findAll(doc, (el) => el.tagName === 'meta' && (attr(el, 'name') || '').toLowerCase() === 'viewport');
  if (viewports.length > 1 && /maximum-scale=1\s*$/.test(attr(viewports[0], 'content') || '')) extraMetas.push(viewports[0]);
  for (const m of extraMetas) ranges.push(elementRange(m, html));
  if (extraMetas.length) notes.push(`removed archive referrer/viewport meta (${extraMetas.length})`);
  const bars = findAll(doc, (el) => ['awesomewrap', 'awesomebar', 'archivebar', 'mc-archive-bar'].includes(attr(el, 'id') || ''));
  // Keep only outermost
  const outer = bars.filter((b) => !bars.some((o) => o !== b && elementRange(o, html)[0] <= elementRange(b, html)[0] && elementRange(o, html)[1] >= elementRange(b, html)[1]));
  for (const b of outer) ranges.push(elementRange(b, html));
  if (outer.length) notes.push(`removed archive bar (${outer.map((b) => '#' + attr(b, 'id')).join(',')})`);
  const links = findAll(doc, (el) => el.tagName === 'link' && /archivebar|awesomebar|campaign-archive\d?\.com\/css|mailchi\.mp\/css|\/css\/archive/i.test(attr(el, 'href') || ''));
  for (const l of links) ranges.push(elementRange(l, html));
  if (links.length) notes.push(`removed ${links.length} archive-bar stylesheet link(s)`);
  const barStyles = findAll(doc, (el) => {
    if (el.tagName !== 'style') return false;
    const css = textContent(el);
    if (!/#awesome(wrap|bar)|#archivebar|\.awesome/i.test(css)) return false;
    // Only drop style blocks that are exclusively about the bar.
    const selectors = css.replace(/\/\*[\s\S]*?\*\//g, '').match(/[^{}]+(?=\{)/g) || [];
    const nonBar = selectors.map((s) => s.trim()).filter((s) => s && !s.startsWith('@') && !/#awesome|#archivebar|\.awesome|#mc-|translate/i.test(s));
    return nonBar.length === 0;
  });
  for (const s of barStyles) ranges.push(elementRange(s, html));
  if (barStyles.length) notes.push(`removed ${barStyles.length} archive-bar <style> block(s)`);
  const metas = shareMetas(doc);
  for (const m of metas) ranges.push(elementRange(m, html));
  if (metas.length) notes.push(`removed ${metas.length} og/twitter/robots meta`);
  return finish(html, ranges, notes, doc);
}

function isMailchimpLandingPage(doc, html) {
  // mailchi.mp also hosts landing pages and signup forms.
  if (/mcjs|landing[- ]?page/i.test(findAll(doc, (e) => e.tagName === 'meta' && /generator/i.test(attr(e, 'name') || '')).map((m) => attr(m, 'content')).join(' '))) return true;
  if (/class="[^"]*\bmcnLanding|data-block-type|mc-landing/i.test(html.slice(0, 200000)) && !/mcnTextContent|bodyTable|templateBody|mcTemplate|mceText/i.test(html)) return true;
  return false;
}

// ------------------------------------------------------- Campaign Monitor ---
// createsend.com/t/d-<ID> (web version share link) and *.createsend1.com/t/ViewEmail/...:
// the sent email plus og:/robots metas; older pages also get the social
// "Like/Tweet" kit: <link href="http://css.createsend1.com/css/social.min.css">,
// an empty <div id="fb-root"> and jQuery/Facebook/track.min.js scripts (removed generically).
function cleanCampaignMonitor(doc, html) {
  const notes = [];
  const ranges = [];
  const metas = shareMetas(doc);
  for (const m of metas) ranges.push(elementRange(m, html));
  if (metas.length) notes.push(`removed ${metas.length} og/twitter/robots meta`);
  const links = findAll(doc, (el) => el.tagName === 'link' && /(^|\/\/)css\.createsend\d*\.com\//i.test(attr(el, 'href') || ''));
  for (const l of links) ranges.push(elementRange(l, html));
  if (links.length) notes.push(`removed ${links.length} css.createsend*.com stylesheet link(s) (social bar)`);
  const fbRoot = findAll(doc, (el) => attr(el, 'id') === 'fb-root' && !textContent(el).trim());
  for (const d of fbRoot) ranges.push(elementRange(d, html));
  if (fbRoot.length) notes.push('removed empty div#fb-root');
  return finish(html, ranges, notes, doc);
}

// --------------------------------------------------------- Constant Contact ---
// myemail.constantcontact.com/<title>.html?soid=..&aid=..: the email plus
// og:/twitter: metas (dozens of og:image) and scripts (campaignPage.js,
// __plink_targets, iframe resizer) — scripts are removed generically.
function cleanConstantContact(doc, html) {
  const notes = [];
  const ranges = [];
  const metas = shareMetas(doc);
  for (const m of metas) ranges.push(elementRange(m, html));
  if (metas.length) notes.push(`removed ${metas.length} og/twitter meta`);
  // Legacy archive pages: "archive" header/footer bars injected around the email.
  const bars = findAll(doc, (el) => /^(cc-archive-header|archive-header|archive-footer|header_archive)$/i.test(attr(el, 'id') || ''));
  for (const b of bars) ranges.push(elementRange(b, html));
  if (bars.length) notes.push(`removed legacy archive bar(s) ${bars.map((b) => '#' + attr(b, 'id')).join(',')}`);
  return finish(html, ranges, notes, doc);
}

// -------------------------------------------------------------- EmailOctopus ---
// eocampaign1.com/web-version?p=.. and /preview?p=..: the email plus
// og/twitter/robots metas and Cloudflare / iframe-resizer / link-target
// <script>s (removed generically). Cloudflare email obfuscation
// ([email protected] + data-cfemail) is left as served and flagged in notes.
function cleanEmailOctopus(doc, html) {
  const res = cleanCampaignMonitor(doc, html);
  if (/data-cfemail=|\/cdn-cgi\/l\/email-protection/.test(html)) res.notes.push('contains Cloudflare email obfuscation (left as served)');
  return res;
}

// ------------------------------------------------------------------ Flodesk ---
// view.flodesk.com/emails/<id>: Flodesk prepends its own head block before the
// email's head: <meta charset>, X-UA-Compatible, viewport
// "...user-scalable=0,shrink-to-fit=no", <title>"<subject> | Flodesk"</title>,
// meta description, og:/twitter: metas, <link rel="shortcut icon" href="/favicon.ico">;
// plus <script src="https://assets.flodesk.com/view.js"> (removed generically).
function cleanFlodesk(doc, html) {
  const notes = [];
  const ranges = [];
  const head = headOf(doc);
  const titles = findAll(doc, (el) => el.tagName === 'title');
  if (titles.length > 1 && / \| Flodesk\s*$/.test(textContent(titles[0]))) {
    ranges.push(elementRange(titles[0], html));
    notes.push('removed wrapper <title> "... | Flodesk"');
  }
  const wrap = findAll(head || doc, (el) => {
    if (el.tagName === 'meta') {
      const n = (attr(el, 'name') || '').toLowerCase();
      if (n === 'description' && /flodesk/i.test(attr(el, 'content') || '')) return true;
      if (n === 'viewport' && /shrink-to-fit=no/.test(attr(el, 'content') || '')) return true;
    }
    if (el.tagName === 'link' && /icon/i.test(attr(el, 'rel') || '') && /^\/favicon/.test(attr(el, 'href') || '')) return true;
    return false;
  });
  for (const w of wrap) ranges.push(elementRange(w, html));
  if (wrap.length) notes.push(`removed ${wrap.length} wrapper head element(s) (description/viewport/favicon)`);
  const metas = shareMetas(doc);
  for (const m of metas) ranges.push(elementRange(m, html));
  if (metas.length) notes.push(`removed ${metas.length} og/twitter meta`);
  return finish(html, ranges, notes, doc);
}

// ---------------------------------------------------------------------- Kit ---
// ckarchive.com/b/<id>: an archive wrapper (subject header .email-archive__header,
// wrapper CSS, iframe resizer script) whose iframe#archive_iframe carries the
// sent email in its srcdoc attribute. Output = the decoded srcdoc document.
function cleanKit(doc, html) {
  const iframe = findAll(doc, (el) => el.tagName === 'iframe' && attr(el, 'srcdoc'))[0];
  if (!iframe) return { ok: false, reason: 'kit-no-srcdoc' };
  const inner = attr(iframe, 'srcdoc');
  const innerDoc = parseDoc(inner);
  return {
    ok: true,
    html: inner,
    notes: ['extracted email from iframe#archive_iframe srcdoc; dropped ckarchive wrapper (subject header, wrapper CSS, scripts)'],
    senderHint: senderHintFromLinks(innerDoc),
    innerDoc,
  };
}

// ------------------------------------------------------------------ Klaviyo ---
// manage.kmail-lists.com/subscriptions/web-view?..: the email plus a web-view
// stylesheet link (/media/css/subscriptions/wvc.css).
function cleanKlaviyo(doc, html) {
  const notes = [];
  const ranges = [];
  const links = findAll(doc, (el) => el.tagName === 'link' && /\/media\/css\/subscriptions\//i.test(attr(el, 'href') || ''));
  for (const l of links) ranges.push(elementRange(l, html));
  if (links.length) notes.push('removed web-view stylesheet link (/media/css/subscriptions/wvc.css)');
  const metas = shareMetas(doc);
  for (const m of metas) ranges.push(elementRange(m, html));
  if (metas.length) notes.push(`removed ${metas.length} og/twitter/robots meta`);
  return finish(html, ranges, notes, doc);
}

/**
 * @returns {{ok:true, html:string, notes:string[], senderHint:string|null} | {ok:false, reason:string}}
 */
export function cleanCapture(esp, html, url) {
  let doc = parseDoc(html);
  let res;
  switch (esp) {
    case 'mailchimp':
      if (isMailchimpLandingPage(doc, html)) return { ok: false, reason: 'mc-landing-page' };
      res = cleanMailchimp(doc, html);
      break;
    case 'campaignmonitor':
      res = cleanCampaignMonitor(doc, html);
      break;
    case 'constantcontact':
      res = cleanConstantContact(doc, html);
      break;
    case 'emailoctopus':
      res = cleanEmailOctopus(doc, html);
      break;
    case 'kit':
      if (/\.kit\.com|ck\.page/.test(new URL(url).hostname)) return { ok: false, reason: 'kit-profile-post-not-email-html' };
      res = cleanKit(doc, html);
      break;
    case 'flodesk':
      res = cleanFlodesk(doc, html);
      break;
    case 'mailerlite':
      // preview.mailerlite.{io,com}: the email as sent; only scripts (removed generically).
      res = { ok: true, html, notes: [], senderHint: senderHintFromLinks(doc) };
      break;
    case 'aweber':
      // archive.aweber.com re-wraps only a body fragment in AWeber's "newsletter hub" site
      // (header/nav/footer + toolkit CSS); no complete email document to recover.
      return { ok: false, reason: 'aweber-hub-fragment' };
    case 'klaviyo':
      if (!url.includes('/subscriptions/web-view')) return { ok: false, reason: 'klaviyo-not-web-view' };
      res = cleanKlaviyo(doc, html);
      break;
    default:
      res = { ok: true, html, notes: [], senderHint: senderHintFromLinks(doc) };
  }
  if (!res.ok) return res;
  const outDoc = res.innerDoc || (res.html === html ? doc : parseDoc(res.html));
  const rej = genericReject(outDoc, res.html);
  if (rej) return { ok: false, reason: rej };
  return res;
}
