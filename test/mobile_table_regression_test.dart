import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final fit in [false, true]) {
    testWidgets(
      'pixel column keeps percentage gutters across viewport resize (fit=$fit)',
      (tester) async {
        for (final width in [360.0, 474.0, 800.0, 360.0]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: SizedBox(
                    width: width,
                    child: HtmlEmailView(
                      html: '''
                      <table width="100%" cellpadding="0" cellspacing="0"><tr>
                        <td width="5%"></td>
                        <td width="500" style="font-size:26px;line-height:1.6">Thank you for your order</td>
                        <td width="5%"></td>
                      </tr></table>
                    ''',
                      config: HtmlRenderConfig(
                        fitToWidth: fit,
                        enableTextSelection: false,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final heading = tester.getRect(find.text('Thank you for your order'));
          final expectedWidth = width < 500 ? width * 0.9 : 500.0;
          expect(heading.left, closeTo((width - expectedWidth) / 2, 0.1));
          expect(heading.width, closeTo(expectedWidth, 0.1));
          expect(heading.height, lessThan(130));
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}
