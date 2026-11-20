import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

late MemoryImage _image;
late MemoryImage _narrowImage;

class _Images extends HtmlImageResolver {
  const _Images();
  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(src.endsWith('/one') ? _narrowImage : _image);
}

Future<void> _pump(
  WidgetTester tester,
  String html, {
  double width = 600,
  bool fitToWidth = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: HtmlEmailView(
              html: html,
              config: HtmlRenderConfig(
                imageResolver: const _Images(),
                enableTextSelection: false,
                fitToWidth: fitToWidth,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    final context = tester.element(find.byType(HtmlEmailView));
    await precacheImage(_image, context);
    await precacheImage(_narrowImage, context);
  });
  await tester.pumpAndSettle();
}

Rect _ink(WidgetTester tester, String text) {
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final index = paragraph.text.toPlainText().indexOf(text);
    if (index < 0) continue;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: index, extentOffset: index + text.length),
    );
    if (boxes.isNotEmpty) {
      return boxes.first.toRect().shift(paragraph.localToGlobal(Offset.zero));
    }
  }
  throw StateError('Text not rendered: $text');
}

void main() {
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording(),
        bitmap = picture.toImageSync(64, 64);
    final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    _image = MemoryImage(bytes!.buffer.asUint8List());
    final narrow = picture.toImageSync(46, 48);
    final narrowBytes = await narrow.toByteData(format: ui.ImageByteFormat.png);
    _narrowImage = MemoryImage(narrowBytes!.buffer.asUint8List());
    narrow.dispose();
    bitmap.dispose();
    picture.dispose();
  });

  testWidgets('a flex footer keeps its logo beside the descriptive text', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="display:flex;font-size:14px;line-height:20px">'
      '<img src="https://example.invalid/logo" width="36" height="36" style="display:block;margin-bottom:8px">'
      '<div style="padding-left:16px"><div>Brand</div><div>Workspace description</div></div></div>',
    );
    final label = tester.getRect(find.text('Brand'));
    expect(label.left, closeTo(52, 0.1));
    expect(label.top, closeTo(0, 0.1));
    expect(tester.getSize(find.byType(HtmlEmailView)).height, closeTo(44, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested flex avatar and label share a vertical center', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="display:flex;align-items:center;font-size:12px;line-height:20px">'
      '<div style="width:18px;height:18px;display:flex;align-items:center;justify-content:center">'
      '<img src="https://example.invalid/avatar" style="display:block;width:100%;height:100%"></div>'
      '<div style="margin-left:4px;white-space:nowrap">Name</div></div>',
    );
    final image = tester.getRect(find.byType(Image));
    final label = tester.getRect(find.text('Name'));
    expect(image.size, const Size(18, 18));
    expect(label.left, closeTo(22, 0.1));
    expect(label.center.dy, closeTo(image.center.dy, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wrap-enabled flex row keeps review actions readable', (
    tester,
  ) async {
    const html =
        '<div style="display:flex;flex-wrap:wrap;align-items:center">'
        '<div style="width:148px">Approval</div>'
        '<div style="width:190px"><a href="https://example.invalid/review">'
        'Open review</a></div></div>';
    final label = find.text('Approval');
    final link = find.text('Open review');

    await _pump(tester, html, width: 390, fitToWidth: true);
    expect(tester.getRect(link).top, closeTo(tester.getRect(label).top, 0.1));
    expect(tester.getRect(link).left, closeTo(148, 0.1));

    await _pump(tester, html, width: 320, fitToWidth: true);
    expect(tester.getRect(link).top, greaterThan(tester.getRect(label).top));
    expect(tester.getRect(link).left, closeTo(0, 0.1));
    expect(tester.getRect(link).right, lessThanOrEqualTo(320));

    await _pump(
      tester,
      html.replaceFirst('flex-wrap:wrap', 'flex-wrap:wrap;flex-wrap:nowrap'),
      width: 320,
      fitToWidth: true,
    );
    expect(tester.getRect(link).top, closeTo(tester.getRect(label).top, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('newsletter flex columns keep text and actions stacked', (
    tester,
  ) async {
    // Reduced from the stacked paragraphs and action blocks in archived mail.
    const html = '''
<div style="display:flex;flex-direction:column;height:100%;align-items:flex-start">
  <p style="margin:0">Newsletter opening</p>
  <p style="margin:0">Event details</p>
  <div><a href="https://example.invalid/event">See schedule</a></div>
</div>
''';
    for (final width in [360.0, 680.0]) {
      await _pump(tester, html, width: width, fitToWidth: true);
      final opening = tester.getRect(find.text('Newsletter opening'));
      final details = tester.getRect(find.text('Event details'));
      final action = tester.getRect(find.text('See schedule'));
      expect(details.left, closeTo(opening.left, 0.1));
      expect(details.top, greaterThanOrEqualTo(opening.bottom));
      expect(action.left, closeTo(opening.left, 0.1));
      expect(action.top, greaterThanOrEqualTo(details.bottom));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a media query can switch a flex column back to a row', (
    tester,
  ) async {
    const html = '''
<style>
  .cards { display:flex; flex-direction:column }
  @media (min-width:600px) { .cards { flex-direction:row } }
</style>
<div class="cards">
  <div>First card</div><div>Second card</div>
</div>
''';
    await _pump(tester, html, width: 360, fitToWidth: true);
    final first = find.text('First card');
    final second = find.text('Second card');
    expect(tester.getRect(second).top, greaterThan(tester.getRect(first).top));

    await _pump(tester, html, width: 680, fitToWidth: true);
    expect(tester.getRect(second).top, closeTo(tester.getRect(first).top, 0.1));
    expect(
      tester.getRect(second).left,
      greaterThan(tester.getRect(first).left),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an auto table keeps a fixed icon beside its label', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table cellpadding="0" cellspacing="0"><tr>'
      '<td><div style="width:24px;height:24px">X</div></td>'
      '<td style="padding-left:8px">Workspace</td></tr></table>',
    );
    expect(tester.getTopLeft(find.text('Workspace')).dx, closeTo(32, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid valign on a linked image does not displace its baseline', (
    tester,
  ) async {
    await tester.runAsync(() => _narrowImage.evict());
    await _pump(
      tester,
      '<div style="font-size:0"><div style="display:inline-block;width:100%">'
      '<table width="100%" cellpadding="0" cellspacing="0"><tr><td>'
      '<table cellpadding="0" cellspacing="0"><tr><td>'
      '<a href="https://example.invalid/one"> <img src="https://example.invalid/one" width="23" style="padding-right:10px;font-size:13px;line-height:100%"> </a> '
      '<a href="https://example.invalid/two"> <img src="https://example.invalid/two" valign="top" width="24" style="padding-right:10px;font-size:13px;line-height:100%"> </a><br>'
      '</td></tr></table></td></tr></table></div></div>',
    );
    final first = tester.getRect(find.byType(Image).first);
    final second = tester.getRect(find.byType(Image).last);
    expect(second.bottom, closeTo(first.bottom, 0.1));
    expect(second.left, greaterThanOrEqualTo(first.right + 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('padding on inline text does not make the title an atomic box', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="width:300px;font-size:14px;line-height:20px">'
      'Prefix <span style="padding:1px">Title words continue here</span></div>',
    );
    expect(_ink(tester, 'Title').top, closeTo(_ink(tester, 'Prefix').top, 0.1));
    expect(tester.getSize(find.byType(HtmlEmailView)).height, closeTo(40, 0.1));
    expect(tester.takeException(), isNull);
  });
}
