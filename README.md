# flutter_native_html

A **native (no-WebView) HTML renderer** for displaying **email bodies** in Flutter.
It parses HTML + CSS and builds a real Flutter widget tree (`RichText`, `Column`,
`Table`-style rows, inline images) — no `WebView`, no JavaScript, no remote code
execution.

Built for the constraints of email rendering:

- **No scripting.** `<script>`, `on*` handlers and `javascript:` URLs are stripped.
- **Privacy-first images.** Remote images are **blocked by default** (no tracking
  pixels); `data:` and `cid:` inline images render. The host opts into remote loads.
- **Links never auto-open.** Taps are surfaced via `onLinkTap` — the app decides.
- **Inline + `<style>` CSS** with a real cascade (specificity + source order).

## Usage

```dart
import 'package:flutter_native_html/flutter_native_html.dart';

HtmlEmailView(
  html: emailBody,
  config: HtmlRenderConfig(
    onLinkTap: (url, attrs) => launchUrl(Uri.parse(url)),
    onImageTap: (src, attrs) => openViewer(src),
    imageResolver: const DefaultHtmlImageResolver(
      allowRemoteImages: false,           // flip to true on user consent
      inlineAttachments: {/* cid -> bytes */},
    ),
  ),
)
```

Place it inside a width-bounded parent (e.g. `ListView`/`Padding`); it sizes its
height to content. Run the demo with `cd example && flutter run` to browse sample
emails, or open a real `.eml`/`.html` file from disk (📂 in the app bar) — `.eml` files are
MIME-decoded to their HTML body (quoted-printable/base64 + inline `cid:` images).

For legacy fixed-width mail, enable `fitToWidth`. Responsive `@media` rules are
applied first; only a layout that remains oversized is scaled. The minimum
scale is a readability floor, after which extreme layouts reflow instead of
painting unreachable content beyond the viewport.

Untrusted inputs are bounded by `maxHtmlCharacters`, `maxDomNodes`,
`maxCssCharacters`, and `maxCssRules`. The default resolver also caps encoded
payloads and decoded image dimensions.

## Architecture

A linear pipeline, each stage isolated and replaceable:

```
HTML string
  │
  ├─▶ HtmlEmailParser            parse (package:html) → collect <style> CSS
  │     └─ HtmlSanitizer         strip <script>/forms/plugins, on* attrs, js: URLs
  │
  ├─▶ CssParser → CssStylesheet  in-tree CSS parser (email subset)
  │     └─ CssSelector           selector matching (tag/.class/#id, descendant/child)
  │
  ├─▶ StyleResolver              cascade: inherited → UA defaults → presentational
  │     └─ CssDeclarationMapper    attrs → author <style> → inline style="" → HtmlStyle
  │
  └─▶ HtmlTreeBuilder            DOM → InlineSpan + widgets
        ├─ ElementRegistry       tag → HtmlElementHandler  ← extension point
        └─ flow()                coalesce inline runs into paragraphs, stack blocks
```

### Folder layout (`lib/src/`)

| Folder       | Responsibility |
|--------------|----------------|
| `parsing/`   | `HtmlEmailParser`, `HtmlSanitizer` |
| `css/`       | length/color value parsing, `HtmlStyle`, selector engine, CSS parser, cascade resolver |
| `config/`    | `HtmlRenderConfig`, `HtmlImageResolver` (loading policy) |
| `rendering/` | `HtmlTreeBuilder`, `ElementRegistry`, `HtmlRenderContext`, and per-tag `handlers/` |
| `widget/`    | `HtmlEmailView` (the public widget) |

## Extending it

**Add or override a tag.** Implement `HtmlElementHandler` and pass it in
`HtmlRenderConfig.handlers` — custom handlers win over built-ins for the same tag:

```dart
class CalloutHandler extends HtmlElementHandler {
  const CalloutHandler();
  @override
  Set<String> get tags => const {'callout'};

  @override
  List<HtmlBuildResult> build(dom.Element el, HtmlRenderContext ctx) {
    final body = ctx.builder.flow(ctx.buildChildren(el), ctx.style);
    return [BlockResult(DecoratedBox(/* ... */, child: body))];
  }
}

// HtmlRenderConfig(handlers: [const CalloutHandler()])
```

The context gives handlers everything they need: `buildChildren`, `flow`,
`decorate`, `contextFor`, the resolved `style`, and the `imageResolver`.

**Other seams:**
- Custom image loading / caching → implement `HtmlImageResolver`.
- Custom blocked-image UI → `HtmlRenderConfig.blockedImageBuilder`.
- Tighter/looser sanitization → custom `HtmlSanitizer`.
- The CSS parser is hidden behind `CssStylesheet`, so a fuller engine can replace
  `CssParser` without touching callers.

## Scope & limits

Supported: block/inline flow, headings, definition/ordered/unordered lists,
links and auto-links, selectable text, tables with `colspan` and `rowspan`,
responsive stacked columns, email-style floats, RTL, inline and CSS background
images, box sizing, visibility/opacity/overflow clipping, white-space modes,
`object-fit`, attribute/structural/sibling selectors, `!important`, and
width-based `@media` rules using `px`, `em`, or `rem`.

This remains an **email CSS** engine, not a browser. JavaScript, forms,
iframe/plugin content, flex/grid, arbitrary positioning, generated content,
web fonts, animation, print CSS, and interactive pseudo-classes are not
executed. Unsupported declarations are ignored. Complex table column sizing is
best-effort rather than a complete browser table-layout implementation.

For repeated rendering, prepare once with `HtmlEmailParser` and pass the result
to `HtmlEmailView.document`.
The parser applies that document's sanitization and resource limits; the view
does not apply the preparation settings from its config again. Treat the parsed
DOM as immutable and prepare a new document after changing HTML or its policy.
Default image resolution reuses providers and inline bytes within a rendering
document, with an LRU cache bounded to 10 MiB and 256 entries. Custom resolvers
keep their attribute-dependent behaviour. The demo starts with remote images
blocked; incoming Android EML reads are asynchronous and limited to 20 MiB.

## Development

The root package contains the renderer and its synthetic regression tests. Its
runtime dependencies are limited to the Flutter SDK and `html`.

The runnable demo is a separate app in `example/`, with its own platform projects,
tests, and `pubspec.yaml`. It depends on the renderer through `path: ../`;
`file_picker` and `desktop_drop` are dependencies of the example app only.

Use Flutter 3.47.7 (bundled Dart 3.13.5), matching the CI setup. The package
requires Dart 3.12.2 or later within the 3.x series.

```sh
flutter pub get --no-example
cd example
flutter pub get
flutter run
```

Run the same checks used by CI before submitting changes:

```sh
# From the repository root:
flutter pub get --no-example
dart format --output=none --set-exit-if-changed lib test example/lib example/test
flutter analyze --no-pub
flutter test --no-pub --coverage

cd example
flutter pub get
flutter analyze --no-pub
flutter test --no-pub --coverage
flutter build apk --debug --no-pub
```

Android input tests also run in CI with `./gradlew :app:testDebugUnitTest` from
the `example/android/` directory (`gradlew.bat` on Windows). Test inputs use
synthetic content and placeholder addresses. Keep personal email files,
credentials, and screenshots out of version control.
