import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = HtmlRenderConfig(
  baseFontSize: 16,
  fitToWidth: true,
  fallbackHorizontalPadding: 16,
);
const _longText =
    'A message with enough ordinary words to wrap across the available width. '
    'The author controls the text and any existing space around this message.';

// Reduced invoice layout: five header columns, a spanning body cell, and footer
// text outside its closing td, which the HTML parser moves ahead of the table.
// The fixture contains no private account details or payment URLs.
const _invoice = '''
<style>body{font-size:12px;font-family:Arial}</style>
<table width="600" cellpadding="0" cellspacing="0" style="margin:0 auto">
<tr><td width="192">Logo</td><td width="102" bgcolor="#8f0076">Account</td>
<td width="102">Pay</td><td width="102">Offers</td><td width="102">Contacts</td></tr>
<tr><td colspan="5" align="justify">Dear subscriber!<br><br>
Your invoice is attached. <a href="https://example.test/pay">Payment link</a>.
<br><br>Thank you for using our services.</td>
Telegram: <a href="https://example.test/contact">Contact support</a></tr>
</table>''';

Future<void> _pump(
  WidgetTester tester,
  String html, {
  double width = 360,
  HtmlRenderConfig config = _config,
  ParsedEmail? document,
  Brightness brightness = Brightness.light,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: document == null
                    ? HtmlEmailView(html: html, config: config)
                    : HtmlEmailView.document(
                        document: document,
                        config: config,
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Rect _text(WidgetTester tester, String text) =>
    tester.getRect(find.text(text, findRichText: true).first);

List<Rect> _textBoxes(WidgetTester tester) => find
    .descendant(of: find.byType(HtmlEmailView), matching: find.byType(RichText))
    .evaluate()
    .where(
      (element) => (element.widget as RichText).text
          .toPlainText(includePlaceholders: false)
          .trim()
          .isNotEmpty,
    )
    .map((element) => tester.getRect(find.byWidget(element.widget)))
    .toList();

void main() {
  test('configuration is opt-in, copyable and finite', () {
    expect(const HtmlRenderConfig().fallbackHorizontalPadding, 0);
    expect(_config.copyWith(baseFontSize: 18).fallbackHorizontalPadding, 16);
    expect(
      _config.copyWith(fallbackHorizontalPadding: 0).fallbackHorizontalPadding,
      0,
    );
    for (final value in [-1.0, double.nan, double.infinity]) {
      expect(
        () => HtmlRenderConfig(fallbackHorizontalPadding: value),
        throwsAssertionError,
      );
    }
  });

  testWidgets('default configuration preserves a flush fixed-width email', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table width="600" cellpadding="0"><tr><td>Fixed email</td></tr></table>',
      config: const HtmlRenderConfig(fitToWidth: true),
    );
    expect(_text(tester, 'Fixed email').left, 0);
    expect(_text(tester, 'Fixed email').right, 360);
  });

  testWidgets('adds fallback around bare HTML without fit-to-width', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div>$_longText</div>',
      config: const HtmlRenderConfig(fallbackHorizontalPadding: 16),
    );
    expect(_text(tester, _longText).left, 16);
    expect(_text(tester, _longText).right, 344);
  });

  testWidgets('fits fixed-width and multi-column text between gutters', (
    tester,
  ) async {
    for (final html in [
      '<table width="600" cellpadding="0"><tr><td>Fixed email</td></tr></table>',
      '<table width="100%" cellpadding="0"><tr><td>A</td><td>B</td></tr></table>',
    ]) {
      await _pump(tester, html);
      final boxes = _textBoxes(tester);
      expect(boxes.map((box) => box.left).reduce((a, b) => a < b ? a : b), 16);
      expect(
        boxes.map((box) => box.right).reduce((a, b) => a > b ? a : b),
        344,
      );
      expect(find.byType(SelectionArea), findsOneWidget);
    }
  });

  testWidgets('preserves padding inside a scaled fixed-width table', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table width="600" cellpadding="0"><tr>'
      '<td style="padding:24px">Fixed email</td></tr></table>',
    );
    final text = _text(tester, 'Fixed email');
    expect(text.left, closeTo(24 * 360 / 600, 0.01));
    expect(text.right, closeTo(360 - 24 * 360 / 600, 0.01));
  });

  testWidgets('positive author spacing is preserved even below the fallback', (
    tester,
  ) async {
    await _pump(tester, '<body style="padding:4px">$_longText</body>');
    expect(_text(tester, _longText).left, 4);
    expect(_text(tester, _longText).right, 356);
  });

  testWidgets('supplies only the missing side in LTR and RTL', (tester) async {
    for (final direction in TextDirection.values) {
      await _pump(
        tester,
        '<body style="padding-left:24px">$_longText</body>',
        direction: direction,
      );
      expect(_text(tester, _longText).left, 24);
      expect(_text(tester, _longText).right, 344);
    }
  });

  testWidgets('vertical author spacing does not suppress side gutters', (
    tester,
  ) async {
    await _pump(tester, '<body style="padding:20px 0">$_longText</body>');
    expect(_text(tester, _longText).left, 16);
    expect(_text(tester, _longText).right, 344);
    expect(_text(tester, _longText).top, 20);
  });

  testWidgets('centered authored space needs no extra padding', (tester) async {
    await _pump(
      tester,
      '<table width="600" cellpadding="0" style="margin:0 auto">'
      '<tr><td>Centered email</td></tr></table>',
      width: 800,
    );
    expect(_text(tester, 'Centered email').left, 100);
    expect(_text(tester, 'Centered email').right, 700);
  });

  testWidgets('does not stack gutters across a responsive breakpoint', (
    tester,
  ) async {
    const html = '''
<style>@media(max-width:350px){.body{padding:24px}}</style>
<div class="body">$_longText</div>''';
    for (final (width, inset) in [
      (420.0, 16.0),
      (360.0, 0.0),
      (340.0, 24.0),
      (420.0, 16.0),
    ]) {
      await _pump(tester, html, width: width);
      expect(_text(tester, _longText).left, inset);
    }
  });

  testWidgets('updates the fallback value, source and enabled state', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div>$_longText</div>',
      config: _config.copyWith(fallbackHorizontalPadding: 12),
    );
    expect(_text(tester, _longText).left, 12);
    await _pump(tester, '<body style="padding:24px">$_longText</body>');
    expect(_text(tester, _longText).left, 24);
    await _pump(
      tester,
      '<div>$_longText</div>',
      config: _config.copyWith(fallbackHorizontalPadding: 0),
    );
    expect(_text(tester, _longText).left, 0);
  });

  for (final brightness in Brightness.values) {
    for (final prepared in [false, true]) {
      testWidgets('invoice gutters ($brightness, prepared=$prepared)', (
        tester,
      ) async {
        final document = prepared ? HtmlEmailParser().parse(_invoice) : null;
        for (final width in [320.0, 390.0, 600.0, 800.0]) {
          await _pump(
            tester,
            _invoice,
            width: width,
            document: document,
            brightness: brightness,
          );
          final boxes = _textBoxes(tester);
          expect(boxes, isNotEmpty);
          for (final box in boxes) {
            expect(
              box.left,
              greaterThanOrEqualTo(15.99),
              reason: 'viewport $width',
            );
            expect(
              box.right,
              lessThanOrEqualTo(width - 15.99),
              reason: 'viewport $width',
            );
          }
          expect(boxes.first.left, 16);
          expect(boxes.first.right, width - 16);
        }
      });
    }
  }

  testWidgets(
    'handles list markers and inline text transforms in wide tables',
    (tester) async {
      for (final content in [
        '<ul><li>First item</li><li>Second item</li></ul>',
        'Water H<sub>2</sub>O and x<sup>2</sup>',
      ]) {
        await _pump(
          tester,
          '<table width="600" cellpadding="0"><tr>'
          '<td colspan="2">$content</td></tr></table>',
        );
        for (final box in _textBoxes(tester)) {
          expect(box.right, lessThanOrEqualTo(360));
        }
      }
    },
  );

  testWidgets('image-only mail keeps its authored full width', (tester) async {
    const key = ValueKey('banner');
    await _pump(
      tester,
      '<img width="600" height="100" src="https://example.test/banner.png">',
      config: _config.copyWith(
        blockedImageBuilder: (_, _, _) =>
            const SizedBox(key: key, width: 600, height: 100),
      ),
    );
    expect(tester.getRect(find.byKey(key)).left, 0);
    expect(tester.getRect(find.byKey(key)).right, 360);
  });

  testWidgets('empty and rejected documents receive no fallback', (
    tester,
  ) async {
    await _pump(tester, '');
    expect(tester.getSize(find.byType(HtmlEmailView)).height, 0);
    await _pump(
      tester,
      'Too long',
      config: _config.copyWith(maxHtmlCharacters: 1),
    );
    expect(_text(tester, 'Email content is too large to render.').left, 0);
  });

  testWidgets('custom handlers retain control of their own layout', (
    tester,
  ) async {
    await _pump(
      tester,
      '<p>Custom content</p>',
      config: _config.copyWith(handlers: [_CustomParagraph()]),
    );
    expect(_text(tester, 'Custom content').left, 0);
  });

  testWidgets('link hit testing includes both the gutter and fit transform', (
    tester,
  ) async {
    final urls = <String>[];
    await _pump(
      tester,
      '<table width="600" cellpadding="0"><tr><td>'
      '<a href="https://example.test/pay">Payment link</a></td></tr></table>',
      config: _config.copyWith(onLinkTap: (url, _) => urls.add(url)),
    );
    await tester.tapAt(
      _text(tester, 'Payment link').topLeft + const Offset(4, 4),
    );
    expect(urls, ['https://example.test/pay']);
  });
}

class _CustomParagraph extends HtmlElementHandler {
  @override
  Set<String> get tags => {'p'};

  @override
  List<HtmlBuildResult> build(element, context) => [
    const BlockResult(Text('Custom content')),
  ];
}
