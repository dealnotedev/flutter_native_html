import 'package:flutter/widgets.dart';
import 'package:flutter_native_html/src/css/css_parser.dart';
import 'package:flutter_native_html/src/css/css_color.dart';
import 'package:flutter_native_html/src/css/html_style.dart';
import 'package:flutter_native_html/src/css/style_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  for (final (value, expected) in <(String, Color?)>[
    ('var(--brand, rgb(97, 31, 105))', const Color(0xff611f69)),
    ('var(--brand, var(--backup, #611f69))', const Color(0xff611f69)),
    ('var(--tint, rgba(97, 31, 105, 0.5))', const Color(0x80611f69)),
    ('var(--brand)', null),
    ('var(--brand,)', null),
    ('var(brand, #611f69)', null),
    ('var(--brand, #611f69) junk)', null),
    ('var(--brand, rgb(97, 31, 105)', null),
    ('${List.filled(40, 'var(--brand,').join()}#611f69${')' * 40}', null),
  ]) {
    test('CSS color token fallback $value', () {
      expect(CssColor.tryParse(value), expected);
    });
  }
  test(
    'undefined CSS color variables use their email design token fallbacks',
    () {
      final document = html_parser.parse(
        '<table><tr><th class="paid">Pro</th></tr><tr><td class="benefit">History</td></tr></table>',
      );
      final resolver = StyleResolver(
        stylesheet: CssParser.parseStylesheet('''
        .paid { background: var(--brand, #611f69); color: white; }
        .benefit { background: var(--tint, #f9edff); }
      '''),
        rootStyle: const HtmlStyle(),
      );
      expect(
        resolver
            .resolve(document.querySelector('.paid')!, const HtmlStyle())
            .backgroundColor,
        const Color(0xff611f69),
      );
      expect(
        resolver
            .resolve(document.querySelector('.benefit')!, const HtmlStyle())
            .backgroundColor,
        const Color(0xfff9edff),
      );
    },
  );
}
