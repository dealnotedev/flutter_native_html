# Changelog

## Unreleased

- Treat table heights as minimums so zero-height email sections grow around
  their content; preserve single-row vertical alignment and divider backgrounds.
- Remove internal email collection and comparison utilities and agent notes
  from the public source tree.
- Use English regression examples and replace personal details with synthetic
  placeholders while preserving character-encoding coverage.
- Build nested inline/block content once and preserve percentage columns,
  linked columns, and direct text in lists.
- Correct shorthand/longhand and `!important` precedence for spacing and
  borders, relative text lengths, and explicit CSS resets.
- Preserve row-group styles and hidden groups, and apply computed RTL
  direction to native, wrapping, and spanning tables.
- Refresh custom handlers when inherited Flutter state changes; memoize
  inherited styles, selector declarations, and table content classification.
- Reuse inline image providers within a bounded document cache and decode
  binary percent-encoded image data correctly.
- Block demo remote images until consent, bound file reads before decoding,
  and perform MIME decoding and Android file I/O off the UI thread.
- Add regression tests and Android input tests and pin the CI Flutter SDK.

## 0.1.2

### Rendering
- Hardened CSS parsing and selector support for email-specific styles,
  including `!important`, `:not()`, `nth-child()` forms, CDO/CDC comments,
  color parsing, and safer URL handling.
- Improved table, percentage sizing, list, rule, linked-image, and CTA button
  layouts across Sentry, GitHub, DocuSign, LinkedIn, Microsoft, Google Cloud,
  Twitch, and ride-share style emails.
- Fixed repeated background rendering performance by painting tiled backgrounds
  with a shader-backed path and freezing animated repeated backgrounds after the
  first frame.
- Added LinkedIn card/button alignment fixes and more robust auto-button sizing
  for inline and table-based CTA patterns.

### Parsing & safety
- Added Windows-1251/RFC 2231 EML decoding coverage and bounded multipart
  parsing depth for malformed or deeply nested email input.
- Strengthened sanitizer coverage for malformed comments, URL schemes, and CSS
  edge cases.

### Tooling
- Added plain text measurement helpers for targeted layout fixes.
- Expanded regression coverage for render hardening, LinkedIn card layouts,
  linked images, repeated backgrounds, and sanitizer behavior.

## 0.1.1

### Rendering
- Improved responsive email table behavior, fixed-width/mobile adaptation, and
  `fitToWidth` regressions.
- Added support for dashed/dotted/double CSS border painting and fixed-height
  table-cell vertical centering.
- Hardened background image handling, repeated email card backgrounds, CTA
  sizing, overlay media tables, percentage chart bars, and common email
  button/card layouts.

### Demo & tooling
- Added `.eml` drag-and-drop/opening improvements for the demo app.
- Kept `file_picker` pinned to the latest Android-compatible 10.x line while
  Flutter tooling still disables Built-in Kotlin for plugin compatibility.

## 0.1.0

First release of `flutter_native_html` — a native (no-WebView, no-JavaScript)
Flutter widget that renders HTML email bodies into a real widget tree.

### Rendering
- HTML → native Flutter widgets / `InlineSpan`s (`RichText`, `Column`,
  `Table`), no WebView and no remote code execution.
- Tables via Flutter's `Table` with a Row-based fallback, including
  `colspan`/`rowspan` (CSS-grid-style cell occupancy).
- Inline `style=""` **and** `<style>` CSS with a real cascade (specificity +
  source order).
- Images: inline `data:`/`cid:` render; remote images are **blocked by
  default** (privacy) and opt-in via the resolver. `max-width:100%`,
  decoded-dimension caps.
- Links are never auto-opened — taps are surfaced via `onLinkTap`. Gmail-style
  auto-linkification of bare emails/URLs (http/https only).
- `fitToWidth`: legacy fixed-width mail is scaled to fit a narrow viewport;
  responsive `@media` is applied first, and a readability floor reflows extreme
  layouts instead of painting unreachable content.

### CSS (email subset)
- Selectors: type / `.class` / `#id`, descendant & child, adjacent (`+`) and
  general (`~`) siblings, attribute selectors, `:first/last/nth-child`, `:not()`.
- `@media (min/max-width)` with px and em breakpoints.
- Box model with `box-sizing`, `min`/`max` width & height, per-corner
  `border-radius`, `border`/`border-spacing`, `white-space` modes, `visibility`,
  `overflow:hidden`, `opacity`, backgrounds & sprites, `sub`/`sup`, RTL.
- Quote- and comment-aware parsing (commas/braces inside strings & `url()` no
  longer break rules).

### Safety & robustness
- Sanitizer strips `<script>`/forms/plugins, `on*` handlers, and non-allowlisted
  link schemes (`http`/`https`/`mailto`/`tel`/`sms`).
- Untrusted input is bounded by `maxHtmlCharacters`, `maxDomNodes`,
  `maxCssCharacters`, `maxCssRules`, with a graceful "too large to render"
  fallback. The default image resolver caps encoded payload and decode size.

### Demo
- Example app: browse sample emails, open `.eml`/`.html` from disk, and — on
  Android — open `.eml` files shared / "opened with" from other apps.
