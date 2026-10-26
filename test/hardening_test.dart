import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_native_html/demo/eml_message.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_native_html/src/css/css_parser.dart';
import 'package:flutter_native_html/src/css/css_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

Widget _host(String html, {double width = 320, HtmlRenderConfig? config}) =>
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: HtmlEmailView(
            html: html,
            config: config ?? const HtmlRenderConfig(),
          ),
        ),
      ),
    );

void main() {
  testWidgets('invalid negative dimensions are ignored without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host('<div style="width:-10px;height:-2px"><img width="-4"></div>'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nowrap disables soft wrapping and CSS direction reaches text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="white-space:nowrap;direction:rtl">one two three</div>',
      ),
    );
    final rich = tester.widget<RichText>(find.byType(RichText).first);
    expect(rich.softWrap, isFalse);
    expect(rich.textDirection, TextDirection.rtl);
  });

  testWidgets('visibility hidden preserves geometry', (tester) async {
    await tester.pumpWidget(
      _host(
        '<div style="visibility:hidden;height:40px">hidden</div><p>after</p>',
      ),
    );
    final opacity = find.byType(Opacity);
    expect(opacity, findsOneWidget);
    expect(tester.getSize(opacity).height, closeTo(40, 1));
  });

  testWidgets('box-sizing distinguishes content-box and border-box', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="width:100px;padding:10px;background:#ff0000">a</div>'
        '<div style="width:100px;padding:10px;box-sizing:border-box;background:#00ff00">b</div>',
        width: 300,
      ),
    );
    Finder colored(Color color) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).color == color,
    );
    expect(tester.getSize(colored(const Color(0xFFFF0000))).width, 120);
    expect(tester.getSize(colored(const Color(0xFF00FF00))).width, 100);
  });

  testWidgets('oversized source is rejected before parsing', (tester) async {
    await tester.pumpWidget(
      _host(
        '<p>too long</p>',
        config: const HtmlRenderConfig(maxHtmlCharacters: 4),
      ),
    );
    expect(find.text('Email content is too large to render.'), findsOneWidget);
  });

  testWidgets('DOM node limit rejects pathological nesting', (tester) async {
    await tester.pumpWidget(
      _host(
        '<div><span>a</span><span>b</span></div>',
        config: const HtmlRenderConfig(maxDomNodes: 3),
      ),
    );
    expect(find.text('Email content is too large to render.'), findsOneWidget);
  });

  testWidgets('CSS rule limit rejects pathological stylesheets', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<style>.a{color:red}.b{color:blue}</style><p class="a">x</p>',
        config: const HtmlRenderConfig(maxCssRules: 1),
      ),
    );
    expect(find.text('Email content is too large to render.'), findsOneWidget);
  });

  testWidgets('large accessibility text scale remains layout-safe', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: const SizedBox(
            width: 260,
            child: HtmlEmailView(
              html:
                  '<table width="100%"><tr><td>Large accessible text that wraps safely</td></tr></table>',
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('prepared documents render through the public API', (
    tester,
  ) async {
    final document = HtmlEmailParser().parse('<h2>Prepared once</h2>');
    await tester.pumpWidget(
      MaterialApp(home: HtmlEmailView.document(document: document)),
    );
    expect(find.textContaining('Prepared once'), findsOneWidget);
  });

  test('copyWith can explicitly clear callbacks', () {
    final config = HtmlRenderConfig(onLinkTap: (_, _) {});
    expect(config.copyWith(onLinkTap: null).onLinkTap, isNull);
  });

  test('large data URI and CID images are rejected', () {
    final resolver = DefaultHtmlImageResolver(
      maxInlineImageBytes: 2,
      inlineAttachments: {
        'x': Uint8List.fromList([1, 2, 3]),
      },
    );
    expect(
      resolver.resolve('data:image/png;base64,AAAA', const {}).hasImage,
      isFalse,
    );
    expect(resolver.resolve('cid:x', const {}).hasImage, isFalse);
  });

  test('sanitizer drops non-allowlisted URL schemes', () {
    final parsed = HtmlEmailParser().parse(
      '<a href="file:///secret">x</a><img src="content://private">',
    );
    expect(parsed.root.querySelector('a')!.attributes['href'], isNull);
    expect(parsed.root.querySelector('img')!.attributes['src'], isNull);
  });

  test('selector groups keep commas inside attribute values', () {
    final sheet = CssParser.parseStylesheet(
      '[data-value="a,b"], .fallback { color:red }',
    );
    final element = html_parser
        .parseFragment('<p data-value="a,b"></p>')
        .querySelector('p')!;
    expect(sheet.declarationsFor(element, 300).values['color'], 'red');
  });

  test('@media accepts em breakpoints and rejects speech media', () {
    final sheet = CssParser.parseStylesheet(
      '@media (max-width:30em){.x{color:red}}'
      '@media speech{.x{background:blue}}',
    );
    final element = html_parser
        .parseFragment('<p class="x"></p>')
        .querySelector('p')!;
    final values = sheet.declarationsFor(element, 400).values;
    expect(values['color'], 'red');
    expect(values['background'], isNull);
  });

  test('common structural pseudo classes match safely', () {
    final document = html_parser.parseFragment(
      '<div><p class="a">one</p><p class="skip">two</p><p>three</p></div>',
    );
    final paragraphs = document.querySelectorAll('p');
    expect(
      CssSelector.tryParse('p:first-child')!.matches(paragraphs[0]),
      isTrue,
    );
    expect(
      CssSelector.tryParse('p:last-child')!.matches(paragraphs[2]),
      isTrue,
    );
    expect(
      CssSelector.tryParse('p:nth-child(2)')!.matches(paragraphs[1]),
      isTrue,
    );
    expect(
      CssSelector.tryParse('p:not(.skip)')!.matches(paragraphs[0]),
      isTrue,
    );
    expect(
      CssSelector.tryParse('p:not(.skip)')!.matches(paragraphs[1]),
      isFalse,
    );
    expect(CssSelector.tryParse('p + p')!.matches(paragraphs[1]), isTrue);
    expect(CssSelector.tryParse('.a ~ p')!.matches(paragraphs[2]), isTrue);
  });

  testWidgets('generic rowspan occupies the combined row height', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="240"><tr>'
        '<td rowspan="2" style="background:#ff0000">A<br>A</td>'
        '<td style="height:30px;background:#00ff00">B</td></tr>'
        '<tr><td style="height:40px;background:#0000ff">C</td></tr></table>',
        width: 240,
      ),
    );
    Finder color(Color value) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).color == value,
    );
    final red = tester.getRect(color(const Color(0xFFFF0000)));
    final green = tester.getRect(color(const Color(0xFF00FF00)));
    final blue = tester.getRect(color(const Color(0xFF0000FF)));
    expect(red.height, closeTo(green.height + blue.height, 2));
    expect(green.left, closeTo(blue.left, 1));
    expect(blue.top, closeTo(green.bottom, 1));
    expect(tester.takeException(), isNull);
  });

  test('malformed MIME base64 does not throw and encoded subject decodes', () {
    final raw = Uint8List.fromList(
      'Subject: =?UTF-8?B?0KLQtdGB0YI=?=\r\n'
              'Content-Type: image/png\r\n'
              'Content-ID: <x>\r\n'
              'Content-Transfer-Encoding: base64\r\n\r\n%%%'
          .codeUnits,
    );
    final message = EmlMessage.parse(raw);
    // Preserve multibyte UTF-8 coverage for the encoded-word subject.
    expect(message.subject, '\u0422\u0435\u0441\u0442');
    expect(message.inlineImages['x'], isEmpty);
  });
}
