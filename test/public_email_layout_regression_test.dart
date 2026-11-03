import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

const _securityText =
    'Your account settings have changed. Please review this security notification and check that the changes were made by you.';

Future<void> _pump(
  WidgetTester tester,
  String html,
  double width,
  bool fit,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HtmlEmailView(
            html: html,
            config: HtmlRenderConfig(
              baseFontSize: 16,
              fitToWidth: fit,
              enableTextSelection: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fixed CSS table cells fit inside their bordered container', (
    tester,
  ) async {
    await _pump(
      tester,
      '''
      <div style="display:table;width:600px;box-sizing:border-box;border:1px solid #333">
        <div style="display:table-cell;width:600px">Fixed column</div>
      </div>
    ''',
      800,
      true,
    );
    final text = tester.getRect(find.text('Fixed column'));
    expect(text.left, greaterThanOrEqualTo(1));
    expect(text.right, lessThanOrEqualTo(599.01));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'auto inline-block icon cells wrap when their row is too narrow',
    (tester) async {
      await _pump(
        tester,
        '''
      <table width="143"><tr>
        <td style="display:inline-block;padding:8px"><img src="https://example.test/a" alt="1" width="32" height="32"></td>
        <td style="display:inline-block;padding:8px"><img src="https://example.test/b" alt="2" width="32" height="32"></td>
        <td style="display:inline-block;padding:8px"><img src="https://example.test/c" alt="3" width="32" height="32"></td>
      </tr></table>
    ''',
        390,
        false,
      );
      expect(
        tester.getRect(find.text('3')).top,
        greaterThan(tester.getRect(find.text('1')).bottom),
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final fit in [false, true]) {
    for (final width in [320.0, 390.0, 600.0, 800.0]) {
      testWidgets(
        'inline-block table cell bounds its nested table ($width, fit=$fit)',
        (tester) async {
          await _pump(
            tester,
            '''
          <style>@media(max-width:639px){td.icon{display:inline-block}}</style>
          <table><tr><td class="icon"><img><table></table></td></tr></table>
        ''',
            width,
            fit,
          );
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'auto table reserves space for content beside percentage gutter ($width, fit=$fit)',
        (tester) async {
          await _pump(
            tester,
            '''
          <table style="max-width:600px"><tr>
            <td>$_securityText</td><td width="6%"></td>
          </tr><tr></tr></table>
        ''',
            width,
            fit,
          );
          final text = tester.getRect(find.text(_securityText));
          final available = width < 600 ? width : 600.0;
          expect(text.width, greaterThan(available * 0.8));
          expect(text.width, lessThanOrEqualTo(available));
          expect(text.height, lessThan(220));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
