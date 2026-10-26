import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester,
  String html, {
  required double host,
  required bool fit,
  double minScale = 0.5,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: host,
            child: SingleChildScrollView(
              child: HtmlEmailView(
                html: html,
                config: HtmlRenderConfig(
                  fitToWidth: fit,
                  fitToWidthMinScale: minScale,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

// On-screen (painted) width — composes the fit transform.
double _painted(WidgetTester tester) =>
    tester.getRect(find.byType(Table).first).width;

// Local layout width — the size before the fit transform.
double _local(WidgetTester tester) =>
    tester.renderObject<RenderBox>(find.byType(Table).first).size.width;

String _fixed(int w) =>
    '<table width="$w" cellpadding="0"><tbody><tr><td>content</td></tr></tbody></table>';

void main() {
  testWidgets('fitToWidth shrinks an oversized email to fit the viewport', (
    tester,
  ) async {
    await _pump(tester, _fixed(600), host: 300, fit: true);
    // Laid out at its natural 600, then scaled to paint within the 300 viewport.
    expect(_local(tester), closeTo(600, 2));
    expect(_painted(tester), closeTo(300, 2));
  });

  testWidgets('fitToWidth leaves content that already fits at scale 1', (
    tester,
  ) async {
    await _pump(tester, _fixed(200), host: 300, fit: true);
    expect(_local(tester), closeTo(200, 2));
    expect(_painted(tester), closeTo(200, 2)); // no scaling
  });

  testWidgets('without fitToWidth there is no scaling', (tester) async {
    await _pump(tester, _fixed(600), host: 300, fit: false);
    // No fit transform: the table is not laid out at its natural 600.
    expect(_local(tester), closeTo(300, 2));
    expect(_painted(tester), closeTo(300, 2));
  });

  testWidgets('fitToWidth honors the min-scale floor', (tester) async {
    await _pump(tester, _fixed(1200), host: 300, fit: true, minScale: 0.5);
    // 300/1200 = 0.25 < 0.5: re-layout at 600 then paint at 0.5, so the
    // readable scale floor is honored without inaccessible right overflow.
    expect(_local(tester), closeTo(600, 5));
    expect(_painted(tester), closeTo(300, 5));
  });

  testWidgets('a responsive email is not scaled under fitToWidth', (
    tester,
  ) async {
    // width:100% via @media resolves to a percentage (not a fixed px), so
    // naturalWidth stays within the viewport and the scale is 1.
    await _pump(
      tester,
      '<style>@media (max-width:480px){table[class="m"]{width:100% !important}}'
      '</style>'
      '<table class="m" style="width:600px;max-width:600px" cellpadding="0">'
      '<tbody><tr><td>responsive</td></tr></tbody></table>',
      host: 360,
      fit: true,
    );
    expect(_local(tester), closeTo(360, 2));
    expect(_painted(tester), closeTo(360, 2)); // filled viewport, no shrink
  });

  testWidgets('compound fixed columns are measured as a combined width', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table cellpadding="0"><tbody><tr>'
      '<td width="300">left</td><td width="300">right</td>'
      '</tr></tbody></table>',
      host: 300,
      fit: true,
    );
    // No individual declaration exceeds the viewport, but the minimum table
    // layout is 600px. It must be laid out at 600 and painted at 300.
    expect(_local(tester), closeTo(600, 2));
    expect(_painted(tester), closeTo(300, 2));
  });

  testWidgets('ordinary wrapping text is not globally scaled', (tester) async {
    await _pump(
      tester,
      '<div>This is a long paragraph made from short words that should wrap '
      'normally on a narrow mobile viewport instead of shrinking the entire '
      'email and making the text harder to read.</div>',
      host: 280,
      fit: true,
    );
    final rich = find.byType(RichText).first;
    final local = tester.renderObject<RenderBox>(rich).size;
    final painted = tester.getRect(rich).size;
    expect(painted.width, closeTo(local.width, 0.5));
    expect(painted.height, closeTo(local.height, 0.5));
  });

  testWidgets('invalid fitToWidthMinScale is rejected', (tester) async {
    expect(
      () => HtmlRenderConfig(fitToWidthMinScale: 1.1),
      throwsAssertionError,
    );
    expect(() => HtmlRenderConfig(fitToWidthMinScale: 0), throwsAssertionError);
  });

  testWidgets('unbreakable content participates in fit measurement', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="white-space:nowrap">'
      'THIS_IS_A_SINGLE_UNBREAKABLE_TOKEN_THAT_IS_MUCH_WIDER_THAN_THE_VIEWPORT'
      '</div>',
      host: 180,
      fit: true,
      minScale: 0.1,
    );
    final rich = find.byType(RichText).first;
    final local = tester.renderObject<RenderBox>(rich).size.width;
    final painted = tester.getRect(rich).width;
    expect(local, greaterThan(180));
    expect(painted, lessThanOrEqualTo(180.5));
  });

  testWidgets('links remain hittable after the fit transform', (tester) async {
    String? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: HtmlEmailView(
                html:
                    '<table width="600"><tr><td>'
                    '<a href="https://example.test">Open</a>'
                    '</td></tr></table>',
                config: HtmlRenderConfig(
                  fitToWidth: true,
                  onLinkTap: (url, _) => tapped = url,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Open'));
    expect(tapped, 'https://example.test');
  });

  testWidgets('the same view adapts across desktop-mobile-desktop resize', (
    tester,
  ) async {
    const html =
        '<style>@media (max-width:480px){.shell{width:100%!important}}</style>'
        '<table class="shell" style="width:600px"><tr><td>content</td></tr></table>';

    Future<void> pumpAt(double width) => tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: const HtmlEmailView(
              html: html,
              config: HtmlRenderConfig(fitToWidth: true),
            ),
          ),
        ),
      ),
    );

    await pumpAt(700);
    expect(_local(tester), closeTo(600, 2));
    expect(_painted(tester), closeTo(600, 2));

    await pumpAt(360);
    expect(_local(tester), closeTo(360, 2));
    expect(_painted(tester), closeTo(360, 2));

    await pumpAt(700);
    expect(_local(tester), closeTo(600, 2));
    expect(_painted(tester), closeTo(600, 2));
  });
}
