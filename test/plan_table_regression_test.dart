import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_native_html/src/css/css_parser.dart';
import 'package:flutter_native_html/src/css/style_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  for (final radius in ['4px', '50%']) {
    test('uniform $radius radius resets earlier shorthand corner values', () {
      final document = html_parser.parse('<div class="card round">Card</div>');
      final resolver = StyleResolver(
        stylesheet: CssParser.parseStylesheet('''
          .card { border-radius:12px 12px 0 0; }
          .round { border-radius:$radius; }
        '''),
        rootStyle: const HtmlStyle(),
      );
      final style = resolver.resolve(
        document.querySelector('div')!,
        const HtmlStyle(),
      );
      expect(style.borderRadiusGeometry, isNull);
      if (radius.endsWith('%')) {
        expect(style.borderRadiusPercent, 50);
      } else {
        expect(style.borderRadius, 4);
      }
    });
  }
  testWidgets('image radii retain uniform and individual corner clipping', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HtmlEmailView(
            html:
                '<img src="" width="40" height="40" style="border-radius:8px">'
                '<img src="" width="40" height="40" style="border-radius:12px 12px 0 0">',
            config: const HtmlRenderConfig(enableTextSelection: false),
          ),
        ),
      ),
    );
    final clips = tester
        .widgetList<ClipRRect>(find.byType(ClipRRect))
        .map((w) => w.borderRadius)
        .toList();
    expect(clips, contains(BorderRadius.circular(8)));
    expect(
      clips,
      contains(const BorderRadius.vertical(top: Radius.circular(12))),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'corner radius longhands keep their specificity against a shorthand',
    () {
      final document = html_parser.parse(
        '<table><tr><th class="heading" id="paid">Plan</th></tr></table>',
      );
      final resolver = StyleResolver(
        stylesheet: CssParser.parseStylesheet('''
      #paid { border-bottom-left-radius: 3px; }
      .heading { border-radius:12px 12px 0 0; }
    '''),
        rootStyle: const HtmlStyle(),
      );
      final style = resolver.resolve(
        document.querySelector('th')!,
        const HtmlStyle(),
      );
      expect(
        style.borderRadiusGeometry,
        const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
          bottomLeft: Radius.circular(3),
        ),
      );
    },
  );
  test('table heading radius rounds only the authored top corners', () {
    final document = html_parser.parse(
      '<table><tr><th style="border-radius:12px 12px 0px 0px">Plan</th></tr></table>',
    );
    final resolver = StyleResolver(
      stylesheet: CssParser.parseStylesheet(''),
      rootStyle: const HtmlStyle(),
    );
    final style = resolver.resolve(
      document.querySelector('th')!,
      const HtmlStyle(),
    );
    expect(
      style.borderRadiusGeometry,
      const BorderRadius.vertical(top: Radius.circular(12)),
    );
  });

  for (final valign in ['top', 'middle', 'bottom']) {
    testWidgets(
      'native table cells fill their row while aligning content $valign',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 500,
                  child: HtmlEmailView(
                    html:
                        '''<table cellspacing="0" cellpadding="0" style="width:100%;font-size:12px;line-height:16px">
          <tr><td style="width:50%;height:100px">A taller feature description</td>
            <td style="vertical-align:$valign;padding:10px;background:#f9edff;border:1px solid #ccc">First benefit</td></tr>
          <tr><td style="height:80px">Another feature</td>
            <td style="vertical-align:$valign;padding:10px;background:#f9edff;border:1px solid #ccc">Second benefit</td></tr>
          </table>''',
                    config: const HtmlRenderConfig(enableTextSelection: false),
                  ),
                ),
              ),
            ),
          ),
        );
        final cells = tester
            .widgetList<Container>(find.byType(Container))
            .where(
              (w) =>
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).color ==
                      const Color(0xfff9edff),
            )
            .toList();
        final first = tester.getRect(find.byWidget(cells[0]));
        final second = tester.getRect(find.byWidget(cells[1]));
        expect(first.height, closeTo(100, 0.01));
        expect(second.top, closeTo(first.bottom, 0.01));
        expect(second.height, closeTo(80, 0.01));
        final label = tester.getRect(find.text('First benefit'));
        switch (valign) {
          case 'top':
            expect(label.top, closeTo(first.top + 11, 0.01));
          case 'bottom':
            expect(label.bottom, closeTo(first.bottom - 11, 0.01));
          default:
            expect(label.center.dy, closeTo(first.center.dy, 0.01));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
