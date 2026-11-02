import 'package:flutter/widgets.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

bool unstyled(
  String html, {
  double width = 360,
  HtmlRenderConfig config = const HtmlRenderConfig(),
}) => hasNoHtmlPageLayout(
  HtmlEmailParser().parse(html),
  availableWidth: width,
  config: config,
);

void main() {
  test('GitHub-style review has content formatting but no page layout', () {
    // Reduced notification fixture. Keep the avatar row, Markdown headings,
    // semantic data table, footer and hidden metadata, without private URLs.
    const html = '''
<div style="display:flex;flex-wrap:wrap;white-space:pre-wrap;align-items:center">
  <img height="20" width="20" style="border-radius:50%;margin-right:4px"
       src="https://example.com/avatar.png">
  <strong>reviewer[bot]</strong> left a comment
  <a href="https://example.com/review">(project#205)</a>
</div>
<h2 dir="auto">AI review summary</h2>
<p dir="auto"><strong>Status:</strong> No findings</p>
<p>No high-confidence actionable regressions found in the changed behavior
or affected code. Flutter tests could not be run because the SDK is unavailable
in this environment.</p>
<h3>Review scope</h3>
<ul><li>Strategy: clustered</li><li>Confidence: normal</li>
<li>Coverage plan: 15 files prioritized; 0 sampled; 0 skipped</li>
<li>Prioritized clusters: docs, frontend, unknown</li></ul>
<h3>Top findings</h3><p>No findings reported.</p>
<h3>Severity counts</h3>
<markdown-accessiblity-table><table role="table">
<thead><tr><th>Severity</th><th align="right">Count</th></tr></thead>
<tbody><tr><td>Critical</td><td align="right">0</td></tr>
<tr><td>High</td><td align="right">0</td></tr>
<tr><td>Medium</td><td align="right">0</td></tr>
<tr><td>Low</td><td align="right">0</td></tr></tbody>
</table></markdown-accessiblity-table>
<h3>Finding publication</h3>
<ul><li>Model findings reviewed: 0</li><li>Inline comments published: 0</li>
<li>Findings discarded outside PR diff: 0</li>
<li>Valid findings not posted inline: 0</li>
<li>Inline policy: inline comments are posted only for findings at or above
medium severity, up to 10 comments.</li>
<li>Suggestions attempted: 0</li><li>Suggestions published: 0</li></ul>
<h3>Review details</h3><ul><li>Job: #1234</li></ul>
<p style="font-size:small;color:#666">Reply directly or
<a href="https://example.com/review">view on GitHub</a>.
<img src="https://example.com/pixel.gif" height="1" width="1">
<span style="color:transparent;font-size:0;display:none;visibility:hidden;
overflow:hidden;opacity:0;width:0;height:0;max-width:0;max-height:0">
Message ID: private metadata</span></p>
<script type="application/ld+json">{"@type":"EmailMessage"}</script>
''';
    expect(unstyled(html), isTrue);
  });

  test('ordinary text formatting and data tables do not imply page design', () {
    for (final html in [
      'Hello reader',
      '<p>Hello <a href="https://example.com">reader</a></p>',
      '<h2>Title</h2><p>Body</p><ul><li>Item</li></ul>',
      '<body style="margin:0;padding:0"><p>Hello</p></body>',
      '<blockquote style="padding:20px;border-left:2px solid gray">Quote</blockquote>',
      '<table><tr><td>First</td><td>Second</td></tr></table>',
      '<table role="table"><tr><td>First</td><td>Second</td></tr></table>',
      '<table><tr><th>Value</th></tr><tr><td>42</td></tr></table>',
    ]) {
      expect(unstyled(html), isTrue, reason: html);
    }
  });

  test('page spacing, decoration and sizing preserve authored layout', () {
    for (final html in [
      '<body style="padding:16px"><p>Hello</p></body>',
      '<body style="margin:8px"><p>Hello</p></body>',
      '<body style="margin-top:8px"><p>Hello</p></body>',
      '<div style="padding:0 4%"><p>Hello</p></div>',
      '<div style="margin-left:-10px">Hello</div>',
      '<div style="margin:0 auto;max-width:600px">Hello</div>',
      '<div style="width:100%">Hello</div>',
      '<div style="display:inline-block;padding:24px">Hello</div>',
      '<div style="background-color:#fff">Hello</div>',
      '<div style="background-image:url(https://example.com/bg.png)">Hello</div>',
      '<div style="border:1px solid gray">Hello</div>',
      '<body bgcolor="#eeeeee"><p>Hello</p></body>',
      '<table width="600"><tr><td>Hello</td></tr></table>',
      '<table cellpadding="16"><tr><td>Hello</td></tr></table>',
      '<table role="presentation"><tr><td>Hello</td></tr></table>',
      '<table><tr><td><table><tr><td>Hello</td></tr></table></td></tr></table>',
      '<div style="display:flex"><div>First</div><div>Second</div></div>',
    ]) {
      expect(unstyled(html), isFalse, reason: html);
    }
  });

  test('local button and footer styling do not define the main page', () {
    expect(
      unstyled('''
<p>This is the main message with ordinary text and no designed page wrapper.
The author wrote a long message with some links and a small signature.</p>
<a style="display:inline-block;padding:24px;background:#2383e2">Reply</a>
<div style="padding:4px;background:#eee">Footer</div>
'''),
      isTrue,
    );
  });

  test('a shared designed wrapper still wins over local formatting', () {
    expect(
      unstyled('''
<div style="padding:24px;background:white">
<h2>Title</h2><p>Body</p><blockquote>Quote</blockquote>
<table role="table"><tr><th>Value</th></tr><tr><td>42</td></tr></table>
<a style="padding:10px">Reply</a></div>
'''),
      isFalse,
    );
  });

  test('separate designed sections collectively define the page', () {
    expect(
      unstyled('''
<div style="padding:16px">First section</div>
<div style="padding:16px">Middle section</div>
<div style="padding:16px">Final section</div>
'''),
      isFalse,
    );
  });

  test('nested local decoration is counted once, not once per wrapper', () {
    expect(
      unstyled('''
<p>The main message has ordinary content formatting without any page design.</p>
<div style="padding:2px"><div style="padding:2px"><div style="padding:2px">
<div style="padding:2px"><div style="padding:2px">Small footer</div></div>
</div></div></div>
'''),
      isTrue,
    );
  });

  test(
    'ignores hidden layout, tracking pixels and sanitized active content',
    () {
      expect(
        unstyled('''
<div style="display:none;width:600px;padding:80px">Hidden preheader</div>
<div style="visibility:hidden;background:red">Hidden content</div>
<div style="max-height:0;overflow:hidden;padding:20px">Preview</div>
<p>Readable message</p><img src="https://example.com/pixel" width="1" height="1">
<script>not visible</script><iframe width="600">not visible</iframe>
'''),
        isTrue,
      );
    },
  );

  test('small avatars are content, a main banner or unknown image is not', () {
    expect(unstyled('<img width="20" height="20" src="cid:avatar">'), isTrue);
    expect(
      unstyled('<img width="600" height="200" src="cid:banner">'),
      isFalse,
    );
    expect(unstyled('<img src="cid:unknown">'), isFalse);
    expect(
      unstyled('''
<a href="https://example.com"><img width="600" height="200" src="cid:banner"></a>
'''),
      isFalse,
    );
  });

  test(
    'uses matching CSS, media width, specificity and important overrides',
    () {
      const html = '''
<style>
.page { padding:24px }
.unused { width:600px; background:red }
@media (max-width:400px) { .page { padding:0!important } }
</style>
<div class="page" style="padding:16px"><p>Hello</p></div>
''';
      expect(unstyled(html, width: 360), isTrue);
      expect(unstyled(html, width: 600), isFalse);
      expect(
        unstyled('''
<style>.page { padding:24px!important }</style>
<div class="page" style="padding:0">Hello</div>
'''),
        isFalse,
      );
      expect(
        unstyled('''
<style>div { background:red; border:2px solid black }</style>
<div style="background:transparent;border:0">Hello</div>
'''),
        isTrue,
      );
    },
  );

  test('empty documents cannot recommend adding padding', () {
    for (final html in [
      '',
      '  ',
      '<div></div>',
      '<img width="1" height="1">',
    ]) {
      expect(unstyled(html), isFalse, reason: html);
    }
  });

  test('does not guess the layout of custom handlers', () {
    expect(
      unstyled(
        '<p>Hello</p>',
        config: HtmlRenderConfig(handlers: [_CustomParagraph()]),
      ),
      isFalse,
    );
  });

  test('does not mutate a prepared document reused by the renderer', () {
    final document = HtmlEmailParser().parse(
      '<p>Hello <strong>reader</strong></p>',
    );
    final before = document.root.outerHtml;
    expect(hasNoHtmlPageLayout(document, availableWidth: 360), isTrue);
    expect(
      hasNoHtmlPageLayout(
        document,
        availableWidth: 600,
        textDirection: TextDirection.rtl,
      ),
      isTrue,
    );
    expect(document.root.outerHtml, before);
  });

  test('rejects invalid viewport widths', () {
    for (final width in [0.0, -1.0, double.infinity, double.nan]) {
      expect(() => unstyled('<p>Hello</p>', width: width), throwsArgumentError);
    }
  });
}

class _CustomParagraph extends HtmlElementHandler {
  @override
  Set<String> get tags => {'p'};

  @override
  List<HtmlBuildResult> build(element, context) => [
    const BlockResult(SizedBox(width: 600)),
  ];
}
