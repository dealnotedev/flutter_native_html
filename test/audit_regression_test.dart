import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_native_html/src/css/style_resolver.dart';
import 'package:flutter_native_html/src/css/css_selector.dart';
import 'package:html/dom.dart' as dom;

HtmlStyle styleFor(String html) {
  final doc = HtmlEmailParser().parse(html);
  return StyleResolver(
    stylesheet: doc.stylesheet,
    rootStyle: const HtmlStyle(fontSize: 14),
    availableWidth: 320,
  ).resolve(doc.root.querySelector('#target')!, const HtmlStyle(fontSize: 14));
}

Widget host(
  String html, {
  HtmlRenderConfig config = const HtmlRenderConfig(enableTextSelection: false),
}) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 320,
      child: HtmlEmailView(html: html, config: config),
    ),
  ),
);

class ThemeProbeHandler extends HtmlElementHandler {
  const ThemeProbeHandler();
  @override
  Set<String> get tags => {'theme-probe'};
  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) =>
      [
        BlockResult(
          Text(
            'theme-probe',
            style: TextStyle(
              color: Theme.of(context.buildContext).colorScheme.primary,
            ),
          ),
        ),
      ];
}

class CountingBlockHandler extends HtmlElementHandler {
  const CountingBlockHandler();
  static int calls = 0;
  @override
  Set<String> get tags => {'block-probe'};
  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    calls++;
    return [const BlockResult(SizedBox(width: 1, height: 1))];
  }
}

class CountingImageResolver extends HtmlImageResolver {
  int calls = 0;
  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) {
    calls++;
    return const HtmlImageResolution.unavailable();
  }
}

void main() {
  test('prepared-document parsing bounds HTML before building a DOM', () {
    expect(
      () => HtmlEmailParser(maxHtmlCharacters: 4).parse('<p>x</p>'),
      throwsA(isA<HtmlContentLimitException>()),
    );
  });
  test('audit: repeated shorthand and longhand keep declaration order', () {
    final style = styleFor(
      '<div id="target" style="margin-left:10px;margin:0;margin-left:20px">x</div>',
    );
    expect(style.margin!.left!.value, 20);
  });

  test('audit: higher-specificity longhand overrides lower shorthand', () {
    final style = styleFor(
      '<style>div{margin-left:10px}.x{margin:0}#target{margin-left:20px}</style><div class="x" id="target">x</div>',
    );
    expect(style.margin!.left!.value, 20);
  });

  test('important padding shorthand and longhands share one cascade', () {
    final style = styleFor(
      '<style>.x{padding:1px 2px !important}#target{padding-left:7px !important}</style>'
      '<div id="target" class="x" style="padding:40px">x</div>',
    );
    expect(style.padding!.top!.value, 1);
    expect(style.padding!.right!.value, 2);
    expect(style.padding!.left!.value, 7);
  });

  test('later border shorthand overrides an earlier border style', () {
    final style = styleFor(
      '<div id="target" style="border-style:none;border:2px solid red">x</div>',
    );
    expect(style.borders!.top!.style, CssBorderStyle.solid);
    expect(style.borders!.top!.width, 2);
  });

  test('important border longhand overrides a lower-priority shorthand', () {
    final style = styleFor(
      '<style>#target{border-left-width:7px!important}</style>'
      '<div id="target" style="border:2px solid red">x</div>',
    );
    expect(style.borders!.left!.width, 7);
    expect(style.borders!.right!.width, 2);
  });

  test('audit: unitless line-height overrides a length', () {
    final doc = HtmlEmailParser().parse(
      '<div id="target" style="line-height:1">x</div>',
    );
    final style =
        StyleResolver(
          stylesheet: doc.stylesheet,
          rootStyle: const HtmlStyle(fontSize: 20),
        ).resolve(
          doc.root.querySelector('#target')!,
          const HtmlStyle(fontSize: 20, lineHeightPx: 40),
        );
    expect(style.toTextStyle().height, 1);
  });

  test('audit: relative line-height uses font-size from all cascade layers', () {
    final style = styleFor(
      '<style>#target{font-size:20px}</style><div id="target" style="line-height:150%">x</div>',
    );
    expect(style.lineHeightPx, 30);
  });

  test('heading and important font sizes determine relative text lengths', () {
    final heading = styleFor(
      '<h1 id="target" style="line-height:150%;letter-spacing:.1em">x</h1>',
    );
    expect(heading.lineHeightPx, 42);
    expect(heading.letterSpacing, closeTo(2.8, .001));
    final important = styleFor(
      '<style>#target{font-size:20px!important}</style>'
      '<div id="target" style="font-size:10px;line-height:150%;letter-spacing:.1em">x</div>',
    );
    expect(important.lineHeightPx, 30);
    expect(important.letterSpacing, 2);
  });

  test('normal line-height and letter-spacing clear inherited lengths', () {
    final doc = HtmlEmailParser().parse(
      '<div id="target" style="line-height:normal;letter-spacing:normal">x</div>',
    );
    final style =
        StyleResolver(
          stylesheet: doc.stylesheet,
          rootStyle: const HtmlStyle(fontSize: 20),
        ).resolve(
          doc.root.querySelector('#target')!,
          const HtmlStyle(fontSize: 20, lineHeightPx: 40, letterSpacing: 5),
        );
    expect(style.toTextStyle().height, isNull);
    expect(style.letterSpacing, isNull);
  });

  test('a later declaration replaces an explicit reset', () {
    final style = styleFor(
      '<div id="target" style="background-image:none;background:url(https://example.test/b.png)">x</div>',
    );
    expect(style.backgroundImage, 'https://example.test/b.png');
    final reset = styleFor('<div id="target" style="float:none">x</div>');
    final floated = reset.merge(const HtmlStyle(float: 'right'));
    expect(HtmlStyle.empty.merge(floated).float, 'right');
  });

  test('audit: background-image none resets an author image', () {
    final style = styleFor(
      '<style>#target{background-image:url(https://example.test/a.png)}</style><div id="target" style="background-image:none">x</div>',
    );
    expect(style.backgroundImage, isNull);
  });

  test('audit: float none resets an author float', () {
    final style = styleFor(
      '<style>#target{float:left}</style><div id="target" style="float:none">x</div>',
    );
    expect(style.float, isNull);
  });

  test('audit: descendant selector backtracks through repeated ancestors', () {
    final doc = HtmlEmailParser().parse(
      '<div class="a"><div class="b"><div class="b"><span id="target">x</span></div></div></div>',
    );
    expect(
      CssSelector.tryParse(
        '.a > .b span',
      )!.matches(doc.root.querySelector('#target')!),
      isTrue,
    );
  });

  test('general-sibling selector considers earlier viable siblings', () {
    final doc = HtmlEmailParser().parse(
      '<i class="a"></i><i class="b"></i><i class="b"></i><span id="target">x</span>',
    );
    expect(
      CssSelector.tryParse(
        '.a + .b ~ span',
      )!.matches(doc.root.querySelector('#target')!),
      isTrue,
    );
  });

  testWidgets('audit: direct list text survives rendering', (tester) async {
    await tester.pumpWidget(host('<ul>Intro<li>Item</li>Outro</ul>'));
    expect(find.textContaining('Intro', findRichText: true), findsOneWidget);
    expect(find.textContaining('Outro', findRichText: true), findsOneWidget);
  });

  testWidgets(
    'audit contract: prepared documents use parser limits instead of view limits',
    (tester) async {
      final doc = HtmlEmailParser().parse('<p>content</p>');
      await tester.pumpWidget(
        MaterialApp(
          home: HtmlEmailView.document(
            document: doc,
            config: const HtmlRenderConfig(maxDomNodes: 1),
          ),
        ),
      );
      expect(
        find.textContaining('content', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets('audit: custom handlers refresh on inherited theme changes', (
    tester,
  ) async {
    const config = HtmlRenderConfig(
      defaultColor: Colors.black,
      enableTextSelection: false,
      handlers: [ThemeProbeHandler()],
    );
    Widget themed(Color color) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: color,
        ).copyWith(primary: color),
      ),
      home: const HtmlEmailView(
        html: '<theme-probe></theme-probe>',
        config: config,
      ),
    );
    await tester.pumpWidget(themed(Colors.red));
    await tester.pumpWidget(themed(Colors.blue));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('theme-probe')).style!.color,
      Colors.blue,
    );
  });

  testWidgets('audit: nested rowspan table supports intrinsic sizing', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        '<table><tr><td><table><tr><td rowspan="2">A</td><td>B</td></tr><tr><td>C</td></tr></table></td></tr></table>',
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('C', findRichText: true), findsOneWidget);
  });

  testWidgets('audit: nested inline wrappers build a block only once', (
    tester,
  ) async {
    const config = HtmlRenderConfig(
      enableTextSelection: false,
      handlers: [CountingBlockHandler()],
    );
    for (final depth in [0, 4, 8, 12]) {
      CountingBlockHandler.calls = 0;
      final html =
          '${'<span>' * depth}<block-probe></block-probe>${'</span>' * depth}';
      await tester.pumpWidget(host(html, config: config));
      expect(CountingBlockHandler.calls, 1, reason: 'depth=$depth');
    }
    expect(CountingBlockHandler.calls, 1);
  });

  testWidgets('audit: inline wrapper preserves percentage inline-block content', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        '<span><div style="display:inline-block;width:100%">Visible content</div></span>',
      ),
    );
    expect(
      find.textContaining('Visible content', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('audit: built-in div and img are not constructed exponentially', (
    tester,
  ) async {
    final images = CountingImageResolver();
    final config = HtmlRenderConfig(
      enableTextSelection: false,
      imageResolver: images,
    );
    const depth = 12;
    await tester.pumpWidget(
      host(
        '${'<span>' * depth}<div><img src="cid:x"></div>${'</span>' * depth}',
        config: config,
      ),
    );
    expect(images.calls, 1);
  });

  testWidgets('audit: hidden tbody does not render its rows', (tester) async {
    await tester.pumpWidget(
      host(
        '<table><tbody style="display:none"><tr><td>Hidden row</td></tr></tbody><tbody><tr><td>Visible row</td></tr></tbody></table>',
      ),
    );
    expect(find.textContaining('Hidden row', findRichText: true), findsNothing);
  });

  testWidgets('hidden groups are excluded before rowspan grid placement', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        '<table><tbody style="display:none"><tr><td>Hidden</td></tr></tbody>'
        '<tbody><tr><td rowspan="2">A</td><td>B</td></tr><tr><td>C</td></tr></tbody></table>',
      ),
    );
    expect(find.textContaining('Hidden', findRichText: true), findsNothing);
    expect(find.text('C', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('row-group text styles reach native, fallback and stacked cells', (
    tester,
  ) async {
    for (final html in [
      '<table><tbody style="font-size:24px"><tr><td>Grouped</td></tr></tbody></table>',
      '<table cellspacing="2"><tbody style="font-size:24px"><tr><td>Grouped</td></tr></tbody></table>',
      '<table><tbody style="font-size:24px"><tr><td style="display:inline-block;width:100%">Grouped</td><td style="display:inline-block;width:100%">Other</td></tr></tbody></table>',
    ]) {
      await tester.pumpWidget(host(html));
      final paragraph = tester
          .widgetList<RichText>(find.byType(RichText))
          .singleWhere((text) => text.text.toPlainText() == 'Grouped');
      final span =
          paragraph.text.getSpanForPosition(const TextPosition(offset: 0))
              as TextSpan;
      expect(span.style!.fontSize, 24);
    }
  });

  testWidgets('linked percentage columns keep content and link taps', (
    tester,
  ) async {
    String? tapped;
    await tester.pumpWidget(
      host(
        '<a href="https://example.test/card"><div style="display:inline-block;width:100%">Card</div></a>',
        config: HtmlRenderConfig(
          enableTextSelection: false,
          onLinkTap: (url, _) => tapped = url,
        ),
      ),
    );
    await tester.tap(find.text('Card', findRichText: true));
    expect(tapped, 'https://example.test/card');
  });

  testWidgets('audit: stylesheet direction rtl reverses table columns', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        '<style>.rtl{direction:rtl}</style><table class="rtl" width="100%"><tr><td>A</td><td>B</td></tr></table>',
      ),
    );
    final a = tester.getRect(find.text('A', findRichText: true));
    final b = tester.getRect(find.text('B', findRichText: true));
    expect(a.center.dx, greaterThan(b.center.dx));
  });

  testWidgets('RTL also places wrapping and spanning cells in source direction', (
    tester,
  ) async {
    for (final html in [
      '<table style="direction:rtl;width:100%"><tr><td style="display:inline-block;width:50%">A</td><td style="display:inline-block;width:50%">B</td></tr></table>',
      '<table style="direction:rtl;width:100%"><tr><td rowspan="2">A</td><td>B</td></tr><tr><td>C</td></tr></table>',
    ]) {
      await tester.pumpWidget(host(html));
      expect(
        tester.getRect(find.text('A', findRichText: true)).center.dx,
        greaterThan(
          tester.getRect(find.text('B', findRichText: true)).center.dx,
        ),
      );
    }
  });
}
