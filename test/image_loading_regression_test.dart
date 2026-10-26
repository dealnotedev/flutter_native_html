import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

class _Images extends HtmlImageResolver {
  const _Images(this.provider);
  final ImageProvider provider;

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(provider);
}

void main() {
  late Uint8List png;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    final bitmap = picture.toImageSync(64, 32);
    final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    png = bytes!.buffer.asUint8List();
    bitmap.dispose();
    picture.dispose();
  });

  for (final profile in [
    (
      width: 600.0,
      pendingHeight: 220.0,
      decodedSize: const Size(220, 110),
      totalHeight: 130.0,
    ),
    (
      width: 180.0,
      pendingHeight: 180.0,
      decodedSize: const Size(180, 90),
      totalHeight: 110.0,
    ),
  ]) {
    testWidgets(
      'a pending fixed-width image reserves its nested table height at ${profile.width}px',
      (tester) async {
        // A fresh key keeps the first frame genuinely undecoded, independently of
        // other tests and the global image cache.
        final image = MemoryImage(Uint8List.fromList(png));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: profile.width,
                  child: HtmlEmailView(
                    html:
                        '<table width="100%" cellspacing="0" cellpadding="0"><tr><td></td><td>'
                        '<table width="100%" cellspacing="0" cellpadding="0"><tr><td colspan="2">'
                        '<img src="https://example.invalid/image" width="220" style="display:block">'
                        '</td></tr><tr><td style="font-size:14px;line-height:20px">Footer</td><td></td></tr></table>'
                        '</td><td></td></tr><tr></tr></table>',
                    config: HtmlRenderConfig(
                      imageResolver: _Images(image),
                      enableTextSelection: false,
                      fitToWidth: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(
          tester.takeException(),
          isNull,
          reason: 'The undecoded frame must not overflow',
        );
        expect(
          tester.getTopLeft(find.text('Footer')).dy,
          greaterThanOrEqualTo(profile.pendingHeight),
        );
        expect(
          tester.getSize(find.byType(HtmlEmailView)).height,
          greaterThanOrEqualTo(profile.pendingHeight + 20),
        );

        await tester.runAsync(
          () =>
              precacheImage(image, tester.element(find.byType(HtmlEmailView))),
        );
        await tester.pumpAndSettle();
        final decoded = tester.getRect(find.byType(Image));
        expect(decoded.size, profile.decodedSize);
        expect(
          tester.getTopLeft(find.text('Footer')).dy,
          closeTo(decoded.bottom, 0.1),
        );
        expect(
          tester.getSize(find.byType(HtmlEmailView)).height,
          closeTo(profile.totalHeight, 0.1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
