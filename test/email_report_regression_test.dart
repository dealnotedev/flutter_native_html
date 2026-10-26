import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_native_html/flutter_native_html.dart';

Widget _host(String html, {double width = 342}) => MaterialApp(
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

Finder _text(String value) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == value,
);

String _button(String label) =>
    '<a href="https://example.invalid" style="display:inline-block">'
    '<table width="auto" cellpadding="0" cellspacing="0"><tr>'
    '<td style="padding:12px 24px;border:1px solid #000;font-size:16px;line-height:1.25;text-align:center">'
    '<a href="https://example.invalid" style="display:inline-block">$label</a>'
    '</td></tr></table></a>';

void main() {
  testWidgets(
    'adjacent linked table buttons wrap their labels within the row',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table width="100%" cellpadding="0" cellspacing="0"><tr>'
          '<td>${_button('Yes')}</td>'
          '<td style="padding-left:8px">${_button('Review invitation')}</td>'
          '</tr></table>',
        ),
      );
      await tester.pumpAndSettle();
      final root = tester.getRect(find.byType(HtmlEmailView));
      final label = tester.getRect(_text('Review invitation'));
      expect(label.right, lessThanOrEqualTo(root.right));
      expect(label.height, greaterThan(25));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a column with only a hidden nested button takes no text width', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="100%" cellpadding="0" cellspacing="0"><tr>'
        '<td width="48" style="padding-right:8px"><div style="width:48px;height:48px"></div></td>'
        '<td style="padding-right:12px"><table width="100%" cellpadding="0" cellspacing="0">'
        '<tr><td>Example Contact</td></tr><tr><td>Short description</td></tr>'
        '</table></td>'
        '<td style="padding-top:8px"><table width="100%" cellpadding="0" cellspacing="0"><tr><td>'
        '<a href="https://example.invalid" style="display:inline-block">'
        '<table width="auto" cellpadding="0" cellspacing="0"><tr>'
        '<td style="display:none;padding:7px 16px;border:1px solid #000">'
        '<a href="https://example.invalid">Hidden action</a>'
        '</td></tr></table></a></td></tr></table></td>'
        '</tr></table>',
      ),
    );
    await tester.pumpAndSettle();
    final name = tester.getRect(_text('Example Contact'));
    expect(name.width, greaterThan(250));
    expect(name.height, lessThan(25));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an empty image source without alt text adds no fallback square',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<p style="margin:0">END-MARKER</p>'
          '<img src="" alt="" style="display:block;width:100%;height:auto">',
        ),
      );
      await tester.pumpAndSettle();
      final root = tester.getRect(find.byType(HtmlEmailView));
      final end = tester.getRect(_text('END-MARKER'));
      expect(root.bottom, closeTo(end.bottom, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an unavailable image retains its explicitly authored height', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host('<img src="" alt="" style="display:block;width:100%;height:40px">'),
    );
    expect(tester.getSize(find.byType(HtmlEmailView)).height, 40);
    expect(tester.takeException(), isNull);
  });
}
