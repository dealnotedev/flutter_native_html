import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

const _canvasColor = Color(0xff206040);
const _photoColor = Color(0xffe04020);
const _boundaryKey = Key('email-pixels');
late MemoryImage _photo;

class _Images extends HtmlImageResolver {
  const _Images();

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(_photo);
}

Future<void> _pump(
  WidgetTester tester,
  String html, {
  double width = 120,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: _boundaryKey,
            child: ColoredBox(
              color: _canvasColor,
              child: SizedBox(
                width: width,
                height: 100,
                child: HtmlEmailView(
                  html:
                      '<html style="background:#206040"><body style="margin:0">$html</body></html>',
                  config: const HtmlRenderConfig(
                    enableTextSelection: false,
                    imageResolver: _Images(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => precacheImage(_photo, tester.element(find.byType(HtmlEmailView))),
  );
  await tester.pumpAndSettle();
}

Future<Color> _pixel(WidgetTester tester, Offset global) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  final local = boundary.globalToLocal(global);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (local.dy.floor() * image.width + local.dx.floor()) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}

Rect _box(WidgetTester tester, String text) {
  final containers = find.ancestor(
    of: find.text(text),
    matching: find.byType(Container),
  );
  final decorated = containers.evaluate().firstWhere((e) {
    final widget = e.widget as Container;
    return widget.decoration is BoxDecoration &&
        (widget.decoration! as BoxDecoration).border != null;
  });
  return tester.getRect(find.byWidget(decorated.widget));
}

void main() {
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawPaint(Paint()..color = _photoColor);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(64, 64);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    _photo = MemoryImage(png!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });

  for (final size in [16, 26]) {
    testWidgets('Notion initial avatar stays circular at ${size}px', (
      tester,
    ) async {
      await _pump(
        tester,
        '<div style="box-sizing:content-box;'
        'border:1px solid black;border-radius:100%;width:${size}px;'
        'height:${size}px;line-height:${size}px;overflow:hidden;'
        'text-align:center;font-size:14px;background:white">M</div>',
      );
      final rect = _box(tester, 'M');
      expect(rect.size, Size(size + 2, size + 2));
      expect(await _pixel(tester, rect.topLeft), _canvasColor);
      expect(await _pixel(tester, rect.center), isNot(_canvasColor));
      expect(tester.takeException(), isNull);
    });
  }

  for (final background in ['', 'background:white;']) {
    testWidgets('Notion photo is clipped by its flex wrapper ($background)', (
      tester,
    ) async {
      await _pump(
        tester,
        '<div style="border-radius:100%;overflow:hidden;'
        'width:18px;height:18px;max-width:100%;max-height:100%;$background'
        'display:flex;align-items:center;justify-content:center;flex-shrink:0">'
        '<img src="https://example.invalid/avatar" style="display:block;'
        'width:100%;height:100%;object-fit:cover"></div>',
      );
      final rect = tester.getRect(find.byType(Image));
      expect(rect.size, const Size(18, 18));
      expect(await _pixel(tester, rect.topLeft), _canvasColor);
      expect(await _pixel(tester, rect.center), _photoColor);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'percent radius follows both box dimensions and updates on resize',
    (tester) async {
      const html =
          '<div style="width:100%;height:40px;border-radius:25%;'
          'background:white;overflow:hidden"></div>';
      for (final width in [80.0, 120.0]) {
        await _pump(tester, html, width: width);
        final origin = tester.getTopLeft(find.byKey(_boundaryKey));
        expect(await _pixel(tester, origin), _canvasColor);
        // 25% means x = width / 4 and y = height / 4, rather than 25px.
        expect(
          await _pixel(tester, origin + Offset(width / 4, 1)),
          Colors.white,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('table cells retain percentage radii', (tester) async {
    await _pump(
      tester,
      '<table cellspacing="0" cellpadding="0"><tr>'
      '<td style="width:26px;height:26px;background:white;'
      'border:1px solid black;border-radius:100%;overflow:hidden">M</td>'
      '</tr></table>',
    );
    final rect = _box(tester, 'M');
    expect(await _pixel(tester, rect.topLeft), _canvasColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing a percentage repaints the same box', (tester) async {
    for (final percent in [10, 50]) {
      await _pump(
        tester,
        '<div style="width:40px;height:40px;'
        'border-radius:$percent%;background:white;overflow:hidden"></div>',
      );
      final origin = tester.getTopLeft(find.byKey(_boundaryKey));
      expect(
        await _pixel(tester, origin + const Offset(3, 3)),
        percent == 10 ? Colors.white : _canvasColor,
      );
    }
    expect(tester.takeException(), isNull);
  });
}
