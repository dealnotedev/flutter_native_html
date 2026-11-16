import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final group in ['header', 'footer']) {
    testWidgets('table $group groups stack at the mobile breakpoint', (
      tester,
    ) async {
      final html =
          '''
      <style>
        @media only screen and (max-width: 480px) {
          .card { display: table !important; width: 100% !important; }
          .media { display: table-$group-group !important; width: 100% !important; }
          .copy { padding-left: 20px !important; padding-right: 20px !important; }
        }
      </style>
      <table width="100%" cellpadding="0" cellspacing="0"><tr class="card">
        <td class="media" width="264">
          <div style="width:264px;height:80px;background:#123456"></div>
        </td>
        <td>
          <table cellpadding="0" cellspacing="0"><tr>
            <td class="copy" style="padding:20px 30px 20px 20px">Card title</td>
          </tr></table>
        </td>
      </tr></table>
    ''';
      for (final width in [420.0, 480.0, 481.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: HtmlEmailView(html: html),
                ),
              ),
            ),
          ),
        );
        final title = tester.getRect(find.text('Card title'));
        final media = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color ==
                    const Color(0xFF123456),
          ),
        );
        expect(media.width, closeTo(264, 0.1));
        if (width <= 480) {
          if (group == 'header') {
            expect(title.top, greaterThanOrEqualTo(media.bottom));
          } else {
            expect(media.top, greaterThanOrEqualTo(title.bottom));
          }
          expect(title.left, closeTo(20, 0.1));
          expect(title.width, closeTo(width - 40, 0.1));
        } else {
          expect(title.left, closeTo(media.right + 20, 0.1));
          expect(title.top, lessThan(media.bottom));
        }
        expect(tester.takeException(), isNull);
      }
    });
  }

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
