import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_native_html/src/rendering/css_border_decoration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('twitch visual fixture keeps CTA and emoji cell geometry', (
    tester,
  ) async {
    final html = File(
      'test/fixtures/emails/twitch_visual_regression.html',
    ).readAsStringSync();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 430,
              child: HtmlEmailView(
                html: html,
                config: const HtmlRenderConfig(enableTextSelection: false),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cta = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration as BoxDecoration).color ==
                  const Color(0xFFFA1ED2),
        );
    final ctaRect = tester.getRect(find.byWidget(cta));
    expect(ctaRect.height, greaterThan(40));
    expect(
      ctaRect.height,
      lessThan(60),
      reason: 'empty inline nodes before the CTA must not add a phantom line',
    );

    final emojiCells = tester
        .widgetList<Container>(find.byType(Container))
        .where(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration as BoxDecoration).color ==
                  const Color(0xFF16161D),
        )
        .toList();
    expect(emojiCells, hasLength(2));

    final imageRects = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => tester.getRect(find.byWidget(image)))
        .toList();
    expect(imageRects, hasLength(2));
    for (var i = 0; i < emojiCells.length; i++) {
      final cellRect = tester.getRect(find.byWidget(emojiCells[i]));
      expect(cellRect.size, const Size(118, 118));
      expect(imageRects[i].center.dy, closeTo(cellRect.center.dy, 0.01));
      expect(imageRects[i].center.dx, closeTo(cellRect.center.dx, 0.01));
    }

    final dashedDecorations = tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => container.foregroundDecoration)
        .whereType<CssBorderDecoration>()
        .where(
          (decoration) =>
              decoration.borders.top?.style == CssBorderStyle.dashed,
        )
        .toList();
    expect(dashedDecorations, hasLength(2));
  });
}
