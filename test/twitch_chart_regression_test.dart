import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(String html, double width) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: SizedBox(
        width: width,
        child: HtmlEmailView(
          html: html,
          config: const HtmlRenderConfig(enableTextSelection: false),
        ),
      ),
    ),
  ),
);

void main() {
  for (final width in [342.0, 600.0]) {
    for (final spacing in [0, 1]) {
      testWidgets(
        'Twitch viewer bars stay visible at $width px, gap $spacing',
        (tester) async {
          final html = File('test/fixtures/emails/twitch_viewer_chart.html')
              .readAsStringSync()
              .replaceFirst(
                'border-spacing: 1px 0',
                'border-spacing: ${spacing}px 0',
              );
          await tester.pumpWidget(_host(html, width));

          final bars = <Rect>[];
          for (final box in tester.widgetList<Container>(
            find.byType(Container),
          )) {
            final decoration = box.decoration;
            if (decoration is BoxDecoration &&
                decoration.color == const Color(0xFFBF94FF)) {
              bars.add(tester.getRect(find.byWidget(box)));
            }
          }
          // The real email has 66 samples, with one-pixel gaps (including the
          // outer edges). Each sample must get a share of the available width.
          expect(bars, hasLength(66));
          final expectedWidth = (width - spacing * 67) / 66;
          final chart = tester.getRect(find.byType(HtmlEmailView));
          for (var i = 0; i < bars.length; i++) {
            expect(bars[i].width, closeTo(expectedWidth, 0.01));
            expect(bars[i].height, greaterThan(0));
            expect(bars[i].bottom, closeTo(chart.bottom, 0.01));
            if (i > 0) {
              expect(bars[i].left - bars[i - 1].right, closeTo(spacing, 0.01));
            }
          }
          expect(chart.height, closeTo(235, 0.01));
          expect(bars.first.height, closeTo(235 * 0.1964, 0.01));
          expect(bars.last.height, closeTo(235 * 0.6964, 0.01));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
