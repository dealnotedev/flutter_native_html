import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

HtmlDocumentInsetsEstimate estimate(String html, {double width = 360}) =>
    estimateHtmlDocumentInsets(
      HtmlEmailParser().parse(html),
      availableWidth: width,
      config: const HtmlRenderConfig(baseFontSize: 16),
    );

void main() {
  test(
    'bare text has no authored insets, including after a short final word',
    () {
      expect(estimate('<div>Hello</div>').insets, EdgeInsets.zero);
    },
  );

  test('reports each side independently and accumulates nested spacing', () {
    final result = estimate('''
<body style="margin:1px 2px 3px 4px;padding:5px 6px 7px 8px">
  <div style="padding:10px 11px 12px 13px">Hello</div>
</body>''');
    expect(result.insets, const EdgeInsets.fromLTRB(25, 16, 19, 22));
  });

  test('paragraph defaults provide vertical spacing only', () {
    expect(
      estimate('<p>Hello</p>').insets,
      const EdgeInsets.symmetric(vertical: 16),
    );
  });

  test(
    'uses first and last blocks vertically and least inset horizontally',
    () {
      expect(
        estimate('''
<div style="margin:7px 20px 50px">First</div>
<div style="margin:60px 4px 9px">Last</div>''').insets,
        const EdgeInsets.fromLTRB(4, 7, 4, 9),
      );
    },
  );

  test('local button padding is not a document gutter', () {
    final result = estimate('''
<div>Body text</div>
<a style="display:inline-block;padding:24px">Button</a>
<div>Footer text</div>''');
    expect(result.insets, EdgeInsets.zero);
  });

  test(
    'nested single-column tables include cellpadding and author padding',
    () {
      expect(
        estimate('''
<table width="100%" cellpadding="6"><tr><td width="100">
<table width="100%" cellpadding="0"><tr><td style="padding:4px 8px">
Hello</td></tr></table></td></tr></table>''').insets,
        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      );
    },
  );

  test('CSS cell padding replaces rather than adds legacy cellpadding', () {
    expect(
      estimate('''
<table width="100%" cellpadding="20"><tr><td style="padding:3px">Hello
</td></tr></table>''').insets,
      const EdgeInsets.all(3),
    );
  });

  test(
    'default cell padding and explicit cell spacing match renderer defaults',
    () {
      expect(
        estimate('''
<table width="100%" cellspacing="3"><tr><td>Hello</td></tr></table>''').insets,
        const EdgeInsets.all(5),
      );
    },
  );

  test(
    'media queries and important overrides use the supplied document width',
    () {
      const html = '''
<style>@media(max-width:350px){.body{padding:8px!important}}</style>
<div class="body" style="padding:24px">Hello</div>''';
      expect(estimate(html).insets, const EdgeInsets.all(24));
      expect(estimate(html, width: 328).insets, const EdgeInsets.all(8));
    },
  );

  test(
    'resolves percentages against width and em against inherited font size',
    () {
      expect(
        estimate('''
<body style="padding:5%;font-size:20px"><div style="padding:1em">Hello</div></body>
''', width: 400).insets,
        const EdgeInsets.all(40),
      );
    },
  );

  test('body resets override author stylesheet spacing', () {
    expect(
      estimate('''
<style>body { margin:30px }</style>
<body style="margin:0!important"><div>Hello</div></body>''').insets,
      EdgeInsets.zero,
    );
  });

  test('centered max-width container contributes outer free space', () {
    expect(
      estimate('''
<div style="max-width:200px;padding:10px;box-sizing:border-box">Hello</div>
''').insets,
      const EdgeInsets.fromLTRB(90, 10, 90, 10),
    );
  });

  test('legacy centered table contributes outer free space', () {
    expect(
      estimate('''
<table width="200" align="center" cellpadding="0"><tr><td>Hello</td></tr></table>
''').insets,
      const EdgeInsets.symmetric(horizontal: 80),
    );
  });

  test('percentage and negative margins do not become false known zeroes', () {
    expect(estimate('<div style="margin-left:5%">Hello</div>').left, isNull);
    expect(estimate('<div style="margin-left:-10px">Hello</div>').left, isNull);
    expect(estimate('<div style="width:50%">Hello</div>').right, isNull);
  });

  test(
    'display none is ignored, hidden reserved height is explicitly unknown',
    () {
      expect(
        estimate('''
<div style="display:none;padding:80px">Preheader</div>
<div style="padding:12px">Hello</div>''').insets,
        const EdgeInsets.all(12),
      );
      final hidden = estimate('''
<div style="visibility:hidden">Preheader</div><div>Hello</div>''');
      expect(hidden.top, isNull);
      expect(hidden.bottom, 0);
      expect(hidden.left, 0);
    },
  );

  test('explicit empty spacers contribute vertical distance', () {
    expect(
      estimate('''
<div style="height:10px"></div><div>Hello</div>
<div style="height:6px"></div>''').insets,
      const EdgeInsets.only(top: 10, bottom: 6),
    );
  });

  test(
    'border-box spacer height includes padding, collapsing margins are unknown',
    () {
      expect(
        estimate('''
<div style="height:20px;padding:4px;box-sizing:border-box"></div><div>Hello</div>
''').top,
        20,
      );
      expect(
        estimate('<div style="margin:10px"></div><div>Hello</div>').top,
        isNull,
      );
      expect(estimate('<br><div>Hello</div>').top, isNull);
    },
  );

  test(
    'unknown is distinct from zero for columns, images and fixed overflow',
    () {
      final columns = estimate('''
<table width="100%"><tr><td>A</td><td>B</td></tr></table>''');
      expect(columns.hasContent, isTrue);
      expect(columns.isFullyKnown, isFalse);
      expect(columns.insets, isNull);
      expect(columns.left, isNull);
      expect(estimate('<img src="cid:hero" width="360">').insets, isNull);
      final fixed = estimate('''
<table width="600"><tr><td style="padding:24px">Hello</td></tr></table>''');
      expect(fixed.left, isNull);
      expect(fixed.right, isNull);
      expect(fixed.top, 24);
      expect(fixed.bottom, 24);
    },
  );

  test('constrained height does not invent a bottom inset', () {
    final result = estimate(
      '<div style="height:100px;padding:8px">Hello</div>',
    );
    expect(result.top, 8);
    expect(result.bottom, isNull);
  });

  test('empty document has no content and no reading inset', () {
    final result = estimate('<body style="padding:20px"></body>');
    expect(result.hasContent, isFalse);
    expect(result.insets, EdgeInsets.zero);
  });

  test('invalid widths are rejected and the parsed DOM remains immutable', () {
    final document = HtmlEmailParser().parse(
      '<div style="padding:12px">Hello</div>',
    );
    final before = document.root.outerHtml;
    estimateHtmlDocumentInsets(document, availableWidth: 360);
    expect(document.root.outerHtml, before);
    for (final width in [0.0, -1.0, double.infinity, double.nan]) {
      expect(
        () => estimateHtmlDocumentInsets(document, availableWidth: width),
        throwsArgumentError,
      );
    }
  });

  for (final width in [328.0, 360.0]) {
    testWidgets(
      'estimate agrees with rendered single-column spacing at $width',
      (tester) async {
        const html = '''
<style>@media(max-width:350px){td{padding:8px!important}}</style>
<body style="margin:3px 5px">
<table width="100%" cellpadding="0" cellspacing="0"><tr>
<td style="padding:24px">Hello</td></tr></table></body>''';
        final document = HtmlEmailParser().parse(html);
        final result = estimateHtmlDocumentInsets(
          document,
          availableWidth: width,
          config: const HtmlRenderConfig(baseFontSize: 16),
        );
        const key = ValueKey('document');
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: HtmlEmailView.document(
                  key: key,
                  document: document,
                  config: const HtmlRenderConfig(baseFontSize: 16),
                ),
              ),
            ),
          ),
        );
        final root = tester.getRect(find.byKey(key));
        final text = tester.getRect(find.text('Hello'));
        expect(result.left, closeTo(text.left - root.left, 0.01));
        expect(result.top, closeTo(text.top - root.top, 0.01));
        expect(result.right, closeTo(width - (text.right - root.left), 0.01));
        expect(result.bottom, closeTo(root.bottom - text.bottom, 0.01));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
