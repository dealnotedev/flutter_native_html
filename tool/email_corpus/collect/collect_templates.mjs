// Collect caniemail feature tests and finished HTML from open-source email
// template repos into .email_test_store/corpus/pilot/{caniemail,templates}/.
//
// Usage: node collect_templates.mjs [--only caniemail|templates] [--no-clone]
//
// Repos are shallow-cloned into .email_test_store/corpus/_raw/<owner>_<repo>/
// and treated as untrusted data: nothing from them is executed; .mjml files
// are compiled with the mjml package installed in THIS directory.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import mjml2html from 'mjml';
import { Corpus } from './lib/corpus.mjs';
import { RAW_DIR } from './lib/paths.mjs';

const args = process.argv.slice(2);
const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null;
const noClone = args.includes('--no-clone');

function repoDir(repo) {
  return path.join(RAW_DIR, repo.replace('/', '_'));
}

function ensureClone(repo) {
  const dir = repoDir(repo);
  if (fs.existsSync(path.join(dir, '.git'))) return dir;
  if (noClone) return null;
  try {
    execFileSync('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'core.symlinks=false', 'clone', '--depth', '1', '--quiet', `https://github.com/${repo}.git`, dir], {
      stdio: 'inherit',
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
    });
    return dir;
  } catch (e) {
    console.error(`clone failed: ${repo}: ${e.message}`);
    return null;
  }
}

function listFiles(dir, re) {
  const out = [];
  const walk = (d) => {
    for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
      if (ent.name === '.git' || ent.name === 'node_modules') continue;
      const p = path.join(d, ent.name);
      if (ent.isDirectory()) walk(p);
      else if (ent.isFile() && re.test(p.replace(/\\/g, '/'))) out.push(p);
    }
  };
  if (fs.existsSync(dir)) walk(dir);
  return out.sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));
}

/** Evenly spread pick of n items from a sorted list (deterministic). */
function spread(list, n) {
  if (!n || list.length <= n) return list;
  const out = [];
  for (let i = 0; i < n; i++) out.push(list[Math.floor((i * list.length) / n)]);
  return out;
}

function compileMjml(file) {
  const src = fs.readFileSync(file, 'utf8');
  const res = mjml2html(src, { filePath: file, validationLevel: 'soft', keepComments: true });
  const errs = (res.errors || []).length;
  return { html: res.html, note: `compiled from .mjml with mjml@4${errs ? ` (${errs} soft validation warnings)` : ''}` };
}

// rel(dir, file) -> slug part
const rel = (dir, f) => path.relative(dir, f).replace(/\\/g, '/');

const TEMPLATE_REPOS = [
  {
    repo: 'ActiveCampaign/postmark-templates', prefix: 'postmark', license: 'MIT', cap: 16,
    pick: (d) => listFiles(path.join(d, 'templates-inlined'), /\/content\.html$/),
    slug: (d, f) => rel(path.join(d, 'templates-inlined'), f).replace(/\/content\.html$/, ''),
    note: 'templates-inlined (CSS-inlined) variant',
  },
  {
    repo: 'mailpace/templates', prefix: 'mailpace', license: 'MIT',
    pick: (d) => listFiles(path.join(d, 'dist'), /\.html$/),
    slug: (d, f) => path.basename(f, '.html'),
    note: 'prebuilt dist/ output',
  },
  {
    repo: 'mjmlio/email-templates', prefix: 'mjml', license: 'unknown (no LICENSE file in repo)',
    pick: (d) => listFiles(path.join(d, 'templates'), /\.mjml$/),
    slug: (d, f) => path.basename(f, '.mjml'),
    mjml: true,
  },
  {
    repo: 'recontentapp/mjml-templates', prefix: 'recontent', license: 'MIT',
    pick: (d) => listFiles(path.join(d, 'templates'), /\/template\.mjml$/),
    slug: (d, f) => path.basename(path.dirname(f)),
    mjml: true,
  },
  {
    repo: 'sendwithus/templates', prefix: 'sendwithus', license: 'Apache-2.0', cap: 30,
    pick: (d) => listFiles(path.join(d, 'templates'), /\.html$/),
    slug: (d, f) => rel(path.join(d, 'templates'), f).replace(/\.html$/, ''),
  },
  {
    repo: 'leemunroe/responsive-html-email-template', prefix: 'leemunroe', license: 'MIT',
    pick: (d) => listFiles(d, /\/email(-inlined)?\.html$/),
    slug: (d, f) => path.basename(f, '.html'),
  },
  {
    repo: 'TedGoas/Cerberus', prefix: 'cerberus', license: 'MIT',
    pick: (d) => [...listFiles(d, /\/cerberus-[a-z]+\.html$/).filter((f) => path.dirname(f) === d), ...listFiles(path.join(d, 'archived-versions'), /\.html$/)],
    slug: (d, f) => rel(d, f).replace(/^archived-versions\//, '').replace(/^cerberus-/, '').replace(/\.html$/, ''),
  },
  {
    repo: 'usewaypoint/responsive-transactional-email-templates', prefix: 'waypoint', license: 'MIT', cap: 20,
    pick: (d) => listFiles(path.join(d, 'templates'), /\.html$/),
    slug: (d, f) => path.basename(f, '.html'),
  },
  {
    repo: 'konsav/email-templates', prefix: 'konsav', license: 'MIT',
    pick: (d) => listFiles(d, /\.html$/).filter((f) => path.dirname(f) === d),
    slug: (d, f) => path.basename(f, '.html'),
  },
  {
    repo: 'ColorlibHQ/email-templates', prefix: 'colorlib', license: 'MIT',
    // Numbered folders hold the prebuilt (MJML-compiled) index.html of each template.
    pick: (d) => listFiles(d, /\/\d+\/index\.html$/),
    slug: (d, f) => path.basename(path.dirname(f)),
    note: 'prebuilt <n>/index.html',
  },
  {
    repo: 'sendgrid/email-templates', prefix: 'sendgrid', license: 'MIT',
    pick: (d) => listFiles(d, /\.html$/),
    slug: (d, f) => rel(d, f).replace(/\.html$/, ''),
  },
  {
    repo: 'mailgun/transactional-email-templates', prefix: 'mailgun', license: 'MIT',
    // Both the <style>-block originals and the inlined builds.
    pick: (d) => listFiles(path.join(d, 'templates'), /\.html$/),
    slug: (d, f) => rel(path.join(d, 'templates'), f).replace(/\.html$/, ''),
  },
  {
    repo: 'InterNations/antwort', prefix: 'antwort', license: 'MIT',
    pick: (d) => listFiles(d, /\/build\.html$/),
    slug: (d, f) => path.basename(path.dirname(f)),
    note: 'inlined build.html',
  },
  {
    repo: 'mailchimp/email-blueprints', prefix: 'blueprints', license: 'CC BY-SA 3.0',
    pick: (d) => listFiles(d, /\.html$/),
    slug: (d, f) => rel(d, f).replace(/\.html$/, ''),
    note: 'classic Mailchimp table layouts with *|MERGE|* tags',
  },
  {
    repo: 'foundation/foundation-emails', prefix: 'foundation', license: 'MIT',
    // templates/ and test/visual/pages are Inky source (needs the Inky+Sass build); no prebuilt HTML in repo.
    pick: () => [],
    skipReason: 'only Inky source templates in repo (needs inky + sass build); no prebuilt HTML',
  },
];

const corpus = new Corpus();
const report = {};

if (!only || only === 'caniemail') {
  const repo = 'hteumeuleu/caniemail';
  const d = ensureClone(repo);
  corpus.resetSource('caniemail');
  const r = (report[repo] = { files: 0 });
  if (d) {
    for (const f of listFiles(path.join(d, 'tests'), /\.html$/)) {
      r.files++;
      // Feature tests differ mostly in CSS/attributes, which the structure hash
      // ignores, so only exact (sha256) dedupe is applied to this source, and the
      // brief says to take all tests, so small ones (<1 KB) are kept too.
      const res = corpus.add({
        source: 'caniemail',
        slug: path.basename(f, '.html').replace(/^_/, ''),
        html: fs.readFileSync(f, 'utf8'),
        origin: `github.com/${repo}/${rel(d, f)}`,
        license: 'MIT',
        structureDedupe: false,
        sizeAndMarkupFilter: false,
      });
      r[res.status] = (r[res.status] || 0) + 1;
    }
  } else r.error = 'clone failed';
}

if (!only || only === 'templates') {
  corpus.resetSource('templates');
  for (const spec of TEMPLATE_REPOS) {
    const r = (report[spec.repo] = { files: 0 });
    const d = ensureClone(spec.repo);
    if (!d) {
      r.error = 'clone failed / missing';
      continue;
    }
    if (spec.skipReason) {
      r.skipped = spec.skipReason;
      continue;
    }
    const files = spread(spec.pick(d), spec.cap);
    for (const f of files) {
      r.files++;
      let html;
      const notes = [];
      if (spec.note) notes.push(spec.note);
      try {
        if (spec.mjml) {
          const c = compileMjml(f);
          html = c.html;
          notes.push(c.note);
        } else {
          html = fs.readFileSync(f, 'utf8');
        }
      } catch (e) {
        r.compileErrors = (r.compileErrors || 0) + 1;
        console.error(`  ${spec.repo}: ${rel(d, f)}: ${e.message}`);
        continue;
      }
      const res = corpus.add({
        source: 'templates',
        slug: `${spec.prefix}-${spec.slug(d, f)}`,
        html,
        origin: `github.com/${spec.repo}/${rel(d, f)}`,
        license: spec.license,
        notes: notes.join('; ') || undefined,
      });
      r[res.status] = (r[res.status] || 0) + 1;
    }
  }
}

corpus.save();
for (const [k, v] of Object.entries(report)) console.log(k.padEnd(56), JSON.stringify(v));
console.log(`caniemail: ${corpus.countSource('caniemail')}  templates: ${corpus.countSource('templates')}`);
