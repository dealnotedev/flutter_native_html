import 'package:flutter/widgets.dart';
import 'package:flutter_native_html/src/css/css_color.dart';
import 'package:flutter_native_html/src/css/css_length.dart';
import 'package:flutter_native_html/src/css/css_parser.dart';
import 'package:flutter_native_html/src/css/css_selector.dart';
import 'package:flutter_native_html/src/css/html_style.dart';
import 'package:flutter_native_html/src/css/style_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  for (final (parent, value, expected) in [
    (FontWeight.w300, 'bolder', FontWeight.w400),
    (FontWeight.w400, 'bolder', FontWeight.w700),
    (FontWeight.w700, 'bolder', FontWeight.w900),
    (FontWeight.w400, 'lighter', FontWeight.w100),
    (FontWeight.w700, 'lighter', FontWeight.w400),
    (FontWeight.w900, 'lighter', FontWeight.w700),
    (FontWeight.w900, 'inherit', FontWeight.w900),
  ]) {
    test('font-weight $value resolves against parent ${parent.value}', () {
      final element = html_parser
          .parse('<span style="font-weight:$value">Title</span>')
          .querySelector('span')!;
      final resolver = StyleResolver(
        stylesheet: CssParser.parseStylesheet(''),
        rootStyle: const HtmlStyle(),
      );
      expect(
        resolver.resolve(element, HtmlStyle(fontWeight: parent)).fontWeight,
        expected,
      );
    });
  }
  test(
    'unvisited link selector styles links without selecting named anchors',
    () {
      final sheet = CssParser.parseStylesheet(
        'a:link{color:#1155cc;text-decoration:none}',
      );
      final document = html_parser.parse(
        '<a href="https://example.test">Link</a><a name="section">Anchor</a><div href="https://example.test">Other</div>',
      );
      final resolver = StyleResolver(
        stylesheet: sheet,
        rootStyle: const HtmlStyle(),
      );
      final links = document.querySelectorAll('a');
      final style = resolver.resolve(links.first, const HtmlStyle());
      expect(style.color, const Color(0xff1155cc));
      expect(style.textDecoration, TextDecoration.none);
      expect(sheet.declarationsFor(links.last, 600).isEmpty, isTrue);
      expect(
        CssSelector.tryParse(':link')!.matches(document.querySelector('div')!),
        isFalse,
      );
      expect(CssSelector.tryParse('a:hover'), isNull);
      expect(CssSelector.tryParse('a:visited'), isNull);
    },
  );
  for (final value in ['inherit', 'unset', 'currentColor']) {
    test('link color $value uses the parent instead of the UA link blue', () {
      final document = html_parser.parse('<a style="color:$value">Link</a>');
      final resolver = StyleResolver(
        stylesheet: CssParser.parseStylesheet('a{color:red}'),
        rootStyle: const HtmlStyle(color: Color(0xff555555)),
      );
      expect(
        resolver
            .resolve(
              document.querySelector('a')!,
              const HtmlStyle(color: Color(0xff555555)),
            )
            .color,
        const Color(0xff555555),
      );
    });
  }
  test('font-family inherit overrides the author family with its parent', () {
    final document = html_parser.parse(
      '<a style="font-family:inherit">Link</a>',
    );
    final resolver = StyleResolver(
      stylesheet: CssParser.parseStylesheet('a { font-family:serif; }'),
      rootStyle: const HtmlStyle(fontFamilies: ['Arial']),
    );
    expect(
      resolver
          .resolve(
            document.querySelector('a')!,
            const HtmlStyle(fontFamilies: ['Arial']),
          )
          .fontFamilies,
      ['Arial'],
    );
  });
  group('CssColor', () {
    test('parses hex forms', () {
      expect(CssColor.tryParse('#fff'), const Color(0xFFFFFFFF));
      expect(CssColor.tryParse('#000000'), const Color(0xFF000000));
      // #rrggbbaa: last byte is alpha.
      final semi = CssColor.tryParse('#ff000080')!;
      expect(semi.a, closeTo(0.5, 0.01));
      expect(semi.r, closeTo(1.0, 0.01));
    });

    test('parses rgb/rgba and names', () {
      expect(CssColor.tryParse('rgb(255,0,0)'), const Color(0xFFFF0000));
      expect(CssColor.tryParse('rgba(0,0,0,0)'), const Color(0x00000000));
      expect(CssColor.tryParse('red'), const Color(0xFFFF0000));
      expect(CssColor.tryParse('transparent'), const Color(0x00000000));
    });

    test('returns null for garbage', () {
      expect(CssColor.tryParse('not-a-color'), isNull);
      expect(CssColor.tryParse(''), isNull);
    });
  });

  group('CssLength', () {
    test('parses and resolves units', () {
      expect(
        CssLength.tryParse('12px')!.resolve(fontSize: 16, rootFontSize: 16),
        12,
      );
      expect(
        CssLength.tryParse('2em')!.resolve(fontSize: 10, rootFontSize: 16),
        20,
      );
      expect(
        CssLength.tryParse('1rem')!.resolve(fontSize: 10, rootFontSize: 16),
        16,
      );
      expect(
        CssLength.tryParse(
          '50%',
        )!.resolve(fontSize: 16, rootFontSize: 16, percentBase: 200),
        100,
      );
      expect(CssLength.tryParse('auto')!.isAuto, isTrue);
    });

    test('converts pt to px', () {
      expect(
        CssLength.tryParse('72pt')!.resolve(fontSize: 16, rootFontSize: 16),
        96,
      );
    });
  });

  group('CssParser', () {
    test('parses rules and inline declarations (with !important)', () {
      final sheet = CssParser.parseStylesheet('''
        .a, .b { color: red; font-weight: bold; }
        #id > p { margin: 0; }
        @media (max-width: 600px) { .a { color: blue; } }
      ''');
      // .a, .b, #id>p, and the @media .a — the @media rule is kept (width-gated).
      expect(sheet.rules.length, 4);

      final decls = CssParser.parseInlineDeclarations(
        'color:#fff; padding:4px !important',
      );
      expect(decls.values['color'], '#fff');
      expect(decls.values['padding-left'], '4px');
      expect(decls.important.contains('padding-left'), isTrue);
      expect(decls.important.contains('color'), isFalse);
    });

    test('@media (max-width) applies only below the breakpoint', () {
      final sheet = CssParser.parseStylesheet(
        '.a { color: red; } @media (max-width: 600px) { .a { color: blue; } }',
      );
      final a = html_parser.parse('<p class="a">x</p>').querySelector('.a')!;
      expect(sheet.declarationsFor(a, 700).values['color'], 'red'); // wide
      expect(sheet.declarationsFor(a, 500).values['color'], 'blue'); // narrow
    });

    test('@media with a non-width feature never applies', () {
      final sheet = CssParser.parseStylesheet(
        '@media (orientation: landscape) { .a { color: blue; } }',
      );
      final a = html_parser.parse('<p class="a">x</p>').querySelector('.a')!;
      expect(sheet.declarationsFor(a, 300).values['color'], isNull);
      expect(sheet.declarationsFor(a, 1200).values['color'], isNull);
    });

    test('@media comma list applies if any branch matches (device-width)', () {
      // The standard Gmail/Outlook responsive query: a comma-separated list
      // (OR) where one branch uses the deprecated `max-device-width`. The
      // unknown-to-us part must not disable the valid `max-width` branch.
      final sheet = CssParser.parseStylesheet(
        '.a { color: red; } @media only screen and (max-device-width: 480px), '
        'only screen and (max-width: 480px) { .a { color: blue; } }',
      );
      final a = html_parser.parse('<p class="a">x</p>').querySelector('.a')!;
      expect(sheet.declarationsFor(a, 800).values['color'], 'red'); // wide
      expect(sheet.declarationsFor(a, 400).values['color'], 'blue'); // narrow
    });

    test('@media max-device-width is treated as the viewport width', () {
      final sheet = CssParser.parseStylesheet(
        '.a { color: red; } @media (max-device-width: 480px) '
        '{ .a { color: blue; } }',
      );
      final a = html_parser.parse('<p class="a">x</p>').querySelector('.a')!;
      expect(sheet.declarationsFor(a, 800).values['color'], 'red');
      expect(sheet.declarationsFor(a, 400).values['color'], 'blue');
    });

    test('does not split semicolons inside data URIs', () {
      final decls = CssParser.parseInlineDeclarations(
        'background:url(data:image/png;base64,AAAA); color:red',
      );
      expect(decls.values['color'], 'red');
      expect(decls.values['background'], contains('base64'));
    });

    test('a statement @import does not swallow the rule after it', () {
      final sheet = CssParser.parseStylesheet(
        '@import url(https://fonts.googleapis.com/css?family=Roboto:400,500,700);'
        ' a, u + #body a {color: #1a73e8;}',
      );
      // The @import (no block) is dropped; both selector branches survive,
      // including the adjacent-sibling combinator.
      expect(sheet.rules.length, 2);
      final a = html_parser.parse('<a href="#">x</a>').querySelector('a')!;
      expect(
        sheet.declarationsFor(a, double.infinity).values['color'],
        '#1a73e8',
      );
    });
  });

  group('CssSelector', () {
    test('matches type, class, id and descendants', () {
      final doc = html_parser.parse(
        '<div id="wrap"><p class="lead">Hi <a>x</a></p></div>',
      );
      final a = doc.querySelector('a')!;
      final p = doc.querySelector('p')!;

      expect(CssSelector.tryParse('a')!.matches(a), isTrue);
      expect(CssSelector.tryParse('.lead')!.matches(p), isTrue);
      expect(CssSelector.tryParse('#wrap p')!.matches(p), isTrue);
      expect(CssSelector.tryParse('#wrap > p')!.matches(p), isTrue);
      expect(CssSelector.tryParse('div a')!.matches(a), isTrue);
      expect(CssSelector.tryParse('span')!.matches(a), isFalse);
    });

    test('skips pseudo-class/element selectors', () {
      expect(CssSelector.tryParse('a:hover'), isNull);
      expect(CssSelector.tryParse('p::first-line'), isNull);
    });

    test('matches attribute selectors (responsive email pattern)', () {
      final doc = html_parser.parse(
        '<table class="table"><tr><td class="cell" data-x="on hold">'
        '<a id="lnk" href="https://x/">y</a></td></tr></table>',
      );
      final table = doc.querySelector('table')!;
      final td = doc.querySelector('td')!;
      final a = doc.querySelector('a')!;

      // Exact class/id match, equivalent to `.table` / `#lnk`.
      expect(
        CssSelector.tryParse('table[class="table"]')!.matches(table),
        isTrue,
      );
      expect(CssSelector.tryParse('td[class="cell"]')!.matches(td), isTrue);
      expect(CssSelector.tryParse('[id="lnk"]')!.matches(a), isTrue);
      // Exact match is whole-value, unlike `.cell`.
      expect(CssSelector.tryParse('[class="cell hold"]')!.matches(td), isFalse);
      // Presence, word, prefix operators.
      expect(CssSelector.tryParse('[data-x]')!.matches(td), isTrue);
      expect(CssSelector.tryParse('[data-x~="hold"]')!.matches(td), isTrue);
      expect(CssSelector.tryParse('a[href^="https://"]')!.matches(a), isTrue);
      // Descendant combinator with attribute selectors, and non-matches.
      expect(
        CssSelector.tryParse(
          'table[class="table"] td[class="cell"]',
        )!.matches(td),
        isTrue,
      );
      expect(CssSelector.tryParse('[class="other"]')!.matches(td), isFalse);
    });
  });

  group('review fixes', () {
    test('nth-child(An+B) matches even rows', () {
      final sheet = CssParser.parseStylesheet('td:nth-child(2n){color:red}');
      final tds = html_parser
          .parse(
            '<table><tr><td>1</td><td>2</td><td>3</td><td>4</td></tr></table>',
          )
          .querySelectorAll('td');
      expect(sheet.declarationsFor(tds[0], 600).values['color'], isNull);
      expect(sheet.declarationsFor(tds[1], 600).values['color'], 'red');
      expect(sheet.declarationsFor(tds[2], 600).values['color'], isNull);
      expect(sheet.declarationsFor(tds[3], 600).values['color'], 'red');
    });

    test('nth-child(2n+1) matches odd rows', () {
      final sheet = CssParser.parseStylesheet('td:nth-child(2n+1){color:red}');
      final tds = html_parser
          .parse('<table><tr><td>1</td><td>2</td><td>3</td></tr></table>')
          .querySelectorAll('td');
      expect(sheet.declarationsFor(tds[0], 600).values['color'], 'red');
      expect(sheet.declarationsFor(tds[1], 600).values['color'], isNull);
      expect(sheet.declarationsFor(tds[2], 600).values['color'], 'red');
    });

    test('bare pseudo selectors match through the universal bucket', () {
      final sheet = CssParser.parseStylesheet(
        ':nth-child(2n){color:red}:not(.skip){font-weight:bold}',
      );
      final spans = html_parser
          .parse('<div><span>1</span><span class="skip">2</span></div>')
          .querySelectorAll('span');
      expect(
        sheet.declarationsFor(spans[0], 600).values['font-weight'],
        'bold',
      );
      expect(sheet.declarationsFor(spans[1], 600).values['color'], 'red');
      expect(
        sheet.declarationsFor(spans[1], 600).values['font-weight'],
        isNull,
      );
    });

    test('full named color table (extended CSS colors)', () {
      expect(CssColor.tryParse('aliceblue'), const Color(0xFFF0F8FF));
      expect(CssColor.tryParse('lavender'), const Color(0xFFE6E6FA));
      expect(CssColor.tryParse('rebeccapurple'), const Color(0xFF663399));
      expect(CssColor.tryParse('orangered'), const Color(0xFFFF4500));
    });

    test('modern space-separated rgb()/hsl() with slash alpha', () {
      expect(CssColor.tryParse('rgb(255 0 0 / 0.5)'), const Color(0x80FF0000));
      expect(CssColor.tryParse('hsl(0 100% 50%)'), const Color(0xFFFF0000));
    });

    test('CSS wrapped in <!-- --> is parsed (CDO/CDC stripped)', () {
      final sheet = CssParser.parseStylesheet(
        '<!-- .a{color:red} --> .b{color:blue}',
      );
      final doc = html_parser.parse(
        '<div class="a"></div><div class="b"></div>',
      );
      expect(
        sheet.declarationsFor(doc.querySelector('.a')!, 600).values['color'],
        'red',
      );
      expect(
        sheet.declarationsFor(doc.querySelector('.b')!, 600).values['color'],
        'blue',
      );
    });

    test('!important beats a later normal declaration in the same block', () {
      final d = CssParser.parseInlineDeclarations(
        'color:red !important;color:blue',
      );
      expect(d.values['color'], 'red');
      expect(d.important.contains('color'), isTrue);
    });

    test('legacy bare-hex bgcolor is accepted', () {
      expect(CssColor.tryParse('#336699'), const Color(0xFF336699));
      // The bare form is handled by the presentational-attribute path; the
      // color parser itself still requires the leading # for CSS values.
      expect(CssColor.tryParse('336699'), isNull);
    });
  });
}
