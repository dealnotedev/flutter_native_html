import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

late MemoryImage _square;

class _Images extends HtmlImageResolver {
  const _Images();

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(_square);
}

Future<void> _pump(WidgetTester tester, String html) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 600,
            child: HtmlEmailView(
              html: html,
              config: const HtmlRenderConfig(
                imageResolver: _Images(),
                enableTextSelection: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => precacheImage(_square, tester.element(find.byType(HtmlEmailView))),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(64, 64);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    _square = MemoryImage(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });

  testWidgets('an inline-block panel uses a nested table preferred width', (
    tester,
  ) async {
    const label =
        'A descriptive sentence with many short words that should share the available line instead of becoming a narrow vertical column.';
    await _pump(
      tester,
      '<div style="display:inline-block"><table cellpadding="0" cellspacing="0"><tr>'
      '<td valign="top"><img src="https://example.invalid/icon" width="40" height="40"></td>'
      '<td valign="top"><div>$label</div></td>'
      '</tr></table></div>',
    );
    final text = tester.getRect(find.text(label));
    expect(tester.getSize(find.byType(Image)), const Size(40, 40));
    expect(text.width, closeTo(560, 0.1));
    expect(text.height, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short inline-block table stays content sized', (tester) async {
    await _pump(
      tester,
      '<div style="display:inline-block"><table cellpadding="0" cellspacing="0"><tr>'
      '<td><img src="https://example.invalid/icon" width="40" height="40"></td>'
      '<td>Short label</td></tr></table></div>',
    );
    final text = tester.getRect(find.text('Short label'));
    expect(text.left, closeTo(40, 0.1));
    expect(text.width, lessThan(200));
    expect(tester.getSize(find.byType(Image)), const Size(40, 40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full-row spanning cell aligns within the entire table', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table width="100%" cellpadding="0" cellspacing="0">'
      '<tr><td>Item</td><td>Price</td></tr>'
      '<tr><td width="150" colspan="2" style="text-align:right">Total: 123.45</td></tr>'
      '</table>',
    );
    final total = tester.getRect(find.text('Total: 123.45'));
    expect(total.right, closeTo(600, 0.1));
    expect(total.height, lessThan(25));
    expect(tester.takeException(), isNull);
  });

  testWidgets('list margins collapse with adjacent block margins', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="font-size:14px;line-height:20px">'
      '<h4 style="font-size:14px;line-height:20px;margin:20px 0">Heading</h4>'
      '<ul style="margin:14px 0"><li>Entry</li></ul>'
      '<p style="margin:20px 0">After</p></div>',
    );
    final heading = tester.getRect(find.text('Heading'));
    final entry = tester.getRect(find.text('Entry'));
    final after = tester.getRect(find.text('After'));
    expect(entry.top - heading.bottom, closeTo(20, 0.1));
    expect(after.top - entry.bottom, closeTo(20, 0.1));
  });

  testWidgets('a negative horizontal margin offsets list indentation', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="padding:0 24px"><div style="margin-left:-20px">'
      '<ul style="margin:0"><li>Offset list entry</li></ul></div></div>',
    );
    final entry = tester.getRect(find.text('Offset list entry'));
    expect(entry.left, closeTo(44, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('negative margins expand the line width inside a table cell', (
    tester,
  ) async {
    const label = '1234567890123456789012345678901234567';
    await _pump(
      tester,
      '<table width="600" cellpadding="0" cellspacing="0"><tr><td style="padding:0 24px">'
      '<div style="margin-left:-20px;font-size:14px;line-height:20px">'
      '<ul style="margin:0"><li>$label</li></ul></div></td></tr></table>',
    );
    final entry = tester.getRect(find.text(label));
    expect(entry.left, closeTo(44, 0.1));
    expect(entry.width, inInclusiveRange(518, 532));
    expect(entry.height, closeTo(20, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('CSS cell alignment overrides legacy align for block children', (
    tester,
  ) async {
    await _pump(
      tester,
      '<style>.centered {text-align:center!important}</style>'
      '<table width="600" cellpadding="0" cellspacing="0"><tr>'
      '<td align="left" class="centered"><p style="margin:0">Centered label</p></td>'
      '</tr></table>',
    );
    final finder = find.text('Centered label');
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    final ink = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 14),
        )
        .single
        .toRect();
    expect(ink.center.dx + tester.getTopLeft(finder).dx, closeTo(300, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an auto-sized image remains visible in an inline-block table', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="display:inline-block;max-width:600px"><table cellpadding="0" cellspacing="0"><tr>'
      '<td><img src="https://example.invalid/icon" style="max-width:50px"></td>'
      '<td>A long descriptive sentence that must wrap while the adjacent icon remains visible in its own column.</td>'
      '</tr></table></div>',
    );
    expect(tester.getSize(find.byType(Image)), const Size(50, 50));
    expect(tester.takeException(), isNull);
  });
}
