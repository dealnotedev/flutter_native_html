import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

late MemoryImage _badge;

class _Images extends HtmlImageResolver {
  const _Images();

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(_badge);
}

void main() {
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 240, 80),
      Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(240, 80);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    _badge = MemoryImage(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });

  for (final width in [342.0, 390.0, 600.0]) {
    testWidgets('Astra footer adapts text and store badges at $width px', (
      tester,
    ) async {
      final html = File(
        'test/fixtures/emails/astra_responsive_footer.html',
      ).readAsStringSync();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: width,
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
        () => precacheImage(_badge, tester.element(find.byType(HtmlEmailView))),
      );
      await tester.pumpAndSettle();

      Rect textRect(String value) {
        final text = tester
            .widgetList<RichText>(find.byType(RichText))
            .singleWhere((widget) => widget.text.toPlainText().contains(value));
        return tester.getRect(find.byWidget(text));
      }

      Rect badgeRect(String label) => tester.getRect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.semanticLabel == label,
        ),
      );

      final copy = textRect('1455 3rd Street');
      final copyright = textRect('OpenAI ©');
      final appStore = badgeRect('Download on the App Store');
      final googlePlay = badgeRect('Get it on Google Play');
      final footer = tester.getRect(find.byType(HtmlEmailView));
      expect(appStore.size, const Size(120, 40));
      expect(googlePlay.size, const Size(120, 40));
      expect(googlePlay.top, closeTo(appStore.top, 0.01));
      expect(googlePlay.left - appStore.right, closeTo(10, 0.01));
      expect(googlePlay.right, lessThanOrEqualTo(footer.right));
      expect(footer.height, lessThan(330));
      if (width < 600) {
        // Only the copy's width:100% wins. The more specific store-cell rule
        // keeps width:250px, while BOTH cells become display:block on mobile.
        expect(copy.width, closeTo(width - 64, 0.01));
        expect(copy.height, closeTo(80, 0.01));
        expect(copyright.height, closeTo(16, 0.01));
        expect(appStore.top - copyright.bottom, closeTo(20, 0.01));
      } else {
        // Desktop table cells must keep the two columns beside each other.
        expect(appStore.left, greaterThanOrEqualTo(copy.right));
        expect(appStore.top, lessThan(copyright.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
