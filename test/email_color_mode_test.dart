import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_native_html/src/css/css_parser.dart';
import 'package:flutter_native_html/src/css/email_color_transform.dart';
import 'package:flutter_native_html/src/css/style_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

const _authored = '''
<html><head><meta name="color-scheme" content="light dark"><style>
:root { color-scheme: light dark; --Surface: #ffffff; --ink: #222222; }
body { background: var(--Surface); color: var(--ink); }
.night { display: none; }
@media screen and (prefers-color-scheme: dark) {
  :root { --Surface: #18202a; --ink: #e5edf5; }
  .day { display: none !important; }
  .night { display: block !important; }
  a { color: #92c5ff !important; }
}
</style></head><body>
<p class="day">Day content</p><p class="night">Night content</p>
<p>Message text <a href="https://example.test">Read report</a></p>
</body></html>
''';

Widget _host(
  ParsedEmail document, {
  Brightness brightness = Brightness.light,
  HtmlRenderConfig config = const HtmlRenderConfig(enableTextSelection: false),
  double width = 360,
}) => MaterialApp(
  themeAnimationDuration: Duration.zero,
  theme: ThemeData(brightness: brightness),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: HtmlEmailView.document(document: document, config: config),
      ),
    ),
  ),
);

Color _textColor(WidgetTester tester, String text) {
  Color? found;
  void visit(InlineSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    if (span is TextSpan) {
      if (span.text?.contains(text) ?? false) found = style.color;
      for (final child in span.children ?? <InlineSpan>[]) {
        visit(child, style);
      }
    }
  }

  for (final rt in tester.widgetList<RichText>(
    find.descendant(
      of: find.byType(HtmlEmailView),
      matching: find.byType(RichText),
    ),
  )) {
    visit(rt.text, const TextStyle());
  }
  expect(found, isNotNull, reason: 'Rendered text: $text');
  return found!;
}

Color _canvas(WidgetTester tester) => tester
    .widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(HtmlEmailView),
            matching: find.byType(ColoredBox),
          )
          .first,
    )
    .color;

double _contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

void main() {
  testWidgets(
    'host dark surface controls canvas and nested adapted backgrounds',
    (tester) async {
      const surface = Color(0xff262629);
      const alternate = Color(0xff303034);
      final document = HtmlEmailParser().parse('''
      <body style="background:white;color:black">
      <div style="background:#f4f4f4"><p>Host-themed message</p></div></body>
    ''');
      final source = document.root.outerHtml;
      for (final mode in [HtmlEmailColorMode.auto, HtmlEmailColorMode.dark]) {
        for (final background in [surface, alternate]) {
          await tester.pumpWidget(
            _host(
              document,
              brightness: Brightness.dark,
              config: HtmlRenderConfig(
                colorMode: mode,
                darkBackgroundColor: background,
              ),
            ),
          );
          expect(_canvas(tester), background);
          final backgrounds = tester
              .widgetList<Container>(
                find.descendant(
                  of: find.byType(HtmlEmailView),
                  matching: find.byType(Container),
                ),
              )
              .map((c) => c.decoration)
              .whereType<BoxDecoration>()
              .map((d) => d.color)
              .whereType<Color>()
              .toList();
          expect(backgrounds, isNotEmpty);
          expect(backgrounds, everyElement(background));
          expect(
            _contrast(_textColor(tester, 'Host-themed message'), background),
            greaterThanOrEqualTo(4.49),
          );
        }
      }
      expect(document.root.outerHtml, source);
    },
  );

  testWidgets('custom dark canvas preserves author themes and original mode', (
    tester,
  ) async {
    const surface = Color(0xff262629);
    const config = HtmlRenderConfig(
      colorMode: HtmlEmailColorMode.dark,
      darkBackgroundColor: surface,
    );
    final document = HtmlEmailParser().parse('''
      <meta name="color-scheme" content="light dark">
      <body style="background:#18202a;color:#e5edf5">Authored message</body>
    ''');
    await tester.pumpWidget(_host(document, config: config));
    expect(_canvas(tester), surface);
    final backgrounds = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(HtmlEmailView),
            matching: find.byType(Container),
          ),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color);
    expect(backgrounds, contains(const Color(0xff18202a)));
    final plain = HtmlEmailParser().parse(
      '<body style="background:white">Original message</body>',
    );
    await tester.pumpWidget(
      _host(
        plain,
        brightness: Brightness.dark,
        config: config.copyWith(colorMode: HtmlEmailColorMode.original),
      ),
    );
    expect(_canvas(tester), Colors.white);
    expect(_textColor(tester, 'Original message'), Colors.black);
  });

  test(
    'host surface adaptation retains alpha and existing colored surfaces',
    () {
      const surface = Color(0xff262629);
      const transform = EmailColorTransform(darkBackgroundColor: surface);
      const translucent = Color(0x80eeeeee);
      expect(
        transform.surface(translucent),
        surface.withValues(alpha: translucent.a),
      );
      expect(transform.surface(Colors.transparent), Colors.transparent);
      const dark = Color(0xff121212);
      expect(transform.surface(dark), dark);
      const brand = Color(0xff00ffff);
      expect(
        transform.surface(brand),
        const EmailColorTransform().surface(brand),
      );
    },
  );

  test('adaptation preserves text hierarchy and invisible colors', () {
    const transform = EmailColorTransform();
    const background = Color(0xff181818);
    final primary = transform.foreground(Colors.black, background);
    final muted = transform.foreground(const Color(0xff777777), background);
    expect(primary.computeLuminance(), greaterThan(muted.computeLuminance()));
    expect(_contrast(muted, background), greaterThanOrEqualTo(4.49));
    expect(
      transform.foreground(Colors.transparent, background),
      Colors.transparent,
    );
  });
  testWidgets(
    'raw HTML honors the metadata hint and explicit brightness override',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const HtmlEmailView(
            html:
                '<meta name="color-scheme" content="light dark"><p>Metadata text</p>',
            config: HtmlRenderConfig(brightness: Brightness.dark),
          ),
        ),
      );
      expect(_canvas(tester), const Color(0xff181818));
      expect(_textColor(tester, 'Metadata text'), const Color(0xffeeeeee));
    },
  );

  testWidgets('native theme default links use their actual local surface', (
    tester,
  ) async {
    final document = HtmlEmailParser().parse('''
      <meta name="color-scheme" content="light dark">
      <p><a href="https://example.test">Dark link</a></p>
      <div style="background:white;color:black">
        <a href="https://example.test">Light link</a><p>support@example.test</p>
      </div>
    ''');
    await tester.pumpWidget(_host(document, brightness: Brightness.dark));
    expect(_textColor(tester, 'Dark link'), const Color(0xff8ab4f8));
    expect(_textColor(tester, 'Light link'), const Color(0xff1a0dab));
    expect(_textColor(tester, 'support@example.test'), const Color(0xff1155cc));
  });

  test(
    'width, scheme, nesting, comma alternatives and important share a cascade',
    () {
      final sheet = CssParser.parseStylesheet('''
      p { color: black; }
      @media (prefers-color-scheme: dark) {
        @media (max-width: 400px) { p { color: white !important; } }
      }
      @media (hover: hover), (prefers-color-scheme: light) { p { color: red; } }
    ''');
      final p = html_parser.parse('<p>x</p>').querySelector('p')!;
      expect(
        sheet
            .declarationsFor(p, 360, brightness: Brightness.dark)
            .values['color'],
        'white',
      );
      expect(
        sheet
            .declarationsFor(p, 500, brightness: Brightness.dark)
            .values['color'],
        'black',
      );
      expect(sheet.declarationsFor(p, 360).values['color'], 'red');
      final unsupported = CssParser.parseStylesheet(
        '@media (prefers-color-scheme: sepia) {p{color:red}}',
      );
      expect(unsupported.declarationsFor(p, 360).isEmpty, isTrue);
    },
  );

  testWidgets(
    'author theme and tokens follow theme changes on the same document',
    (tester) async {
      final document = HtmlEmailParser().parse(_authored);
      final source = document.root.outerHtml;
      await tester.pumpWidget(_host(document));
      expect(_textColor(tester, 'Message text'), const Color(0xff222222));
      expect(find.textContaining('Day content'), findsOneWidget);
      expect(find.textContaining('Night content'), findsNothing);
      await tester.pumpWidget(_host(document, brightness: Brightness.dark));
      expect(_textColor(tester, 'Message text'), const Color(0xffe5edf5));
      expect(_textColor(tester, 'Read report'), const Color(0xff92c5ff));
      expect(find.textContaining('Day content'), findsNothing);
      expect(find.textContaining('Night content'), findsOneWidget);
      await tester.pumpWidget(
        _host(
          document,
          brightness: Brightness.dark,
          config: const HtmlRenderConfig(
            colorMode: HtmlEmailColorMode.original,
          ),
        ),
      );
      expect(_textColor(tester, 'Message text'), const Color(0xff222222));
      expect(find.textContaining('Day content'), findsOneWidget);
      expect(document.root.outerHtml, source);
    },
  );

  testWidgets(
    'original and complex fallback keep dark text on a white canvas',
    (tester) async {
      for (final html in [
        '<p>Plain message</p>',
        '<table><tr><td>Plain message</td></tr></table>',
        '<style>@media(prefers-color-scheme:dark){.unused{color:white}}</style>'
            '<table><tr><td>Plain message</td></tr></table>',
        '<meta name="color-scheme" content="only light"><p>Plain message</p>',
        '<div style="background:#ffcc00"><p>Plain message</p></div>',
        '<p>Plain message</p><img src="https://example.test/logo.png">',
      ]) {
        final document = HtmlEmailParser().parse(html);
        final config = html == '<p>Plain message</p>'
            ? const HtmlRenderConfig(colorMode: HtmlEmailColorMode.original)
            : const HtmlRenderConfig();
        await tester.pumpWidget(
          _host(document, brightness: Brightness.dark, config: config),
        );
        expect(_canvas(tester), Colors.white);
        expect(_textColor(tester, 'Plain message'), Colors.black);
      }
    },
  );

  testWidgets('auto adapts neutral text mail, nested surfaces and bare links', (
    tester,
  ) async {
    final document = HtmlEmailParser().parse('''
      <body style="background:white;color:black">
      <div style="background:#f4f4f4"><p style="color:#333333">Plain message</p>
      <p>support@example.test</p></div></body>
    ''');
    await tester.pumpWidget(_host(document, brightness: Brightness.dark));
    expect(_canvas(tester).computeLuminance(), lessThan(.05));
    final surface = const EmailColorTransform().surface(
      const Color(0xfff4f4f4),
    );
    expect(
      _contrast(_textColor(tester, 'Plain message'), surface),
      greaterThanOrEqualTo(4.49),
    );
    expect(
      _contrast(_textColor(tester, 'support@example.test'), surface),
      greaterThanOrEqualTo(4.49),
    );
    await tester.pumpWidget(_host(document));
    expect(_textColor(tester, 'Plain message'), const Color(0xff333333));
  });

  testWidgets(
    'manual dark mode adapts tables independently of app appearance',
    (tester) async {
      final document = HtmlEmailParser().parse('''
      <table bgcolor="#ffffff"><tr><td style="background:#eeeeee;color:#111111;border:1px solid #cccccc">
      Table message</td></tr></table>
    ''');
      await tester.pumpWidget(
        _host(
          document,
          config: const HtmlRenderConfig(colorMode: HtmlEmailColorMode.dark),
        ),
      );
      expect(_canvas(tester).computeLuminance(), lessThan(.05));
      expect(
        _contrast(_textColor(tester, 'Table message'), const Color(0xff1a1a1a)),
        greaterThanOrEqualTo(4.49),
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'bitmap backdrops preserve source colors and image URLs in manual mode',
    () {
      final document = HtmlEmailParser().parse('''
      <body><div style="background:url(cid:paper)"><p>On paper</p></div></body>
    ''');
      final resolver = StyleResolver(
        stylesheet: document.stylesheet,
        rootStyle: const HtmlStyle(color: Color(0xffeeeeee)),
        brightness: Brightness.dark,
        canvasColor: const Color(0xff181818),
        colorTransform: const EmailColorTransform(),
      );
      final body = resolver.resolve(document.root, const HtmlStyle());
      final div = resolver.resolve(
        document.root.querySelector('div')!,
        body.inheritedOnly(),
      );
      final p = resolver.resolve(
        document.root.querySelector('p')!,
        div.inheritedOnly(),
      );
      expect(div.backgroundImage, 'cid:paper');
      expect(div.backgroundColor, Colors.white);
      expect(p.color, Colors.black);
    },
  );

  group('dark media rules without color-scheme', () {
    // Kit: `@media (prefers-color-scheme: dark) { body { color:#000
    // !important } .light-enabled { display:none } }` and no color-scheme.
    // Chrome keeps the light canvas (CSS Color Adjust), so the black text
    // stays readable; a dark canvas made it invisible.
    const html = '''
      <style>
      .dark-logo { display: none; }
      @media (prefers-color-scheme: dark) {
        body { color: #000000 !important; }
        .light-logo { display: none !important; }
        .dark-logo { display: block !important; }
      }
      </style>
      <body style="color:#06292e"><p class="light-logo">Light logo</p>
      <p class="dark-logo">Dark logo</p><p>Happy Friday, friend.</p></body>
    ''';

    testWidgets('auto keeps the light canvas and applies the dark rules', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(HtmlEmailParser().parse(html), brightness: Brightness.dark),
      );
      expect(find.textContaining('Dark logo'), findsOneWidget);
      expect(find.textContaining('Light logo'), findsNothing);
      final canvas = _canvas(tester);
      expect(canvas.computeLuminance(), greaterThan(0.9));
      expect(
        _contrast(_textColor(tester, 'Happy Friday'), canvas),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('forced dark adapts on top of the dark rules', (tester) async {
      await tester.pumpWidget(
        _host(
          HtmlEmailParser().parse(html),
          brightness: Brightness.dark,
          config: const HtmlRenderConfig(
            enableTextSelection: false,
            colorMode: HtmlEmailColorMode.dark,
          ),
        ),
      );
      expect(find.textContaining('Dark logo'), findsOneWidget);
      final canvas = _canvas(tester);
      expect(canvas.computeLuminance(), lessThan(0.05));
      expect(
        _contrast(_textColor(tester, 'Happy Friday'), canvas),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  test('an opaque panel inside a bitmap backdrop adapts again', () {
    // Constant Contact: the whole layout sits in a patterned
    // `<td background>`; its white content panel covers the pattern, so it
    // must darken like any surface while text on the bitmap keeps its color.
    final document = HtmlEmailParser().parse('''
      <body><div style="background:url(cid:pattern)">
      <p class="on-image" style="color:#333333">On the pattern</p>
      <div style="background-color:#ffffff;color:#000000">
      <p class="on-panel">On the panel</p></div></div></body>
    ''');
    final resolver = StyleResolver(
      stylesheet: document.stylesheet,
      rootStyle: const HtmlStyle(color: Color(0xffeeeeee)),
      brightness: Brightness.dark,
      canvasColor: const Color(0xff181818),
      colorTransform: const EmailColorTransform(),
    );
    final body = resolver.resolve(document.root, const HtmlStyle());
    final backdrop = resolver.resolve(
      document.root.querySelector('div')!,
      body.inheritedOnly(),
    );
    final onImage = resolver.resolve(
      document.root.querySelector('.on-image')!,
      backdrop.inheritedOnly(),
    );
    final panel = resolver.resolve(
      document.root.querySelectorAll('div')[1],
      backdrop.inheritedOnly(),
    );
    final onPanel = resolver.resolve(
      document.root.querySelector('.on-panel')!,
      panel.inheritedOnly(),
    );
    expect(onImage.color, const Color(0xff333333));
    expect(panel.backgroundColor!.computeLuminance(), lessThan(0.05));
    expect(
      _contrast(onPanel.color!, panel.backgroundColor!),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('a translucent group does not hide the bitmap behind its panel', () {
    for (final panel in [
      '<div style="opacity:.55;background:white;color:black">Text</div>',
      '<section style="opacity:.55"><div style="background:white;color:black">'
          'Text</div></section>',
    ]) {
      final document = HtmlEmailParser().parse(
        '<div style="background:url(cid:pattern)">$panel</div>',
      );
      final resolver = StyleResolver(
        stylesheet: document.stylesheet,
        rootStyle: const HtmlStyle(color: Color(0xffeeeeee)),
        brightness: Brightness.dark,
        canvasColor: const Color(0xff181818),
        colorTransform: const EmailColorTransform(),
      );
      final parent = document.root.children.single;
      final bodyStyle = resolver.resolve(document.root, const HtmlStyle());
      final backdrop = resolver.resolve(parent, bodyStyle.inheritedOnly());
      final group = resolver.resolve(
        parent.children.single,
        backdrop.inheritedOnly(),
      );
      final inner = parent.children.single.children;
      final surface = inner.isEmpty
          ? group
          : resolver.resolve(inner.single, group.inheritedOnly());
      expect(surface.backgroundColor, const Color(0xffffffff));
      expect(surface.color, const Color(0xff000000));
    }
  });

  test(
    'theme metadata works without media and CSS can override the head hint',
    () {
      final document = HtmlEmailParser().parse('''
      <meta name="SUPPORTED-COLOR-SCHEMES" content="light dark">
      <style>:root{color-scheme:only light}</style><p>Text</p>
    ''');
      expect(document.colorScheme, 'light dark');
      final resolver = StyleResolver(
        stylesheet: document.stylesheet,
        rootStyle: const HtmlStyle(),
      );
      expect(resolver.colorSchemeFor(document.root), 'only light');
    },
  );

  test(
    'layout analysis uses the same theme and original override as rendering',
    () {
      final document = HtmlEmailParser().parse('''
      <style>body{margin:0;padding:0}
      @media(prefers-color-scheme:dark){body{padding:24px}}</style><p>Text</p>
    ''');
      expect(
        estimateHtmlDocumentInsets(
          document,
          availableWidth: 360,
          brightness: Brightness.dark,
        ).left,
        24,
      );
      expect(
        estimateHtmlDocumentInsets(
          document,
          availableWidth: 360,
          brightness: Brightness.dark,
          config: const HtmlRenderConfig(
            colorMode: HtmlEmailColorMode.original,
          ),
        ).left,
        0,
      );
    },
  );

  test(
    'copyWith can override modes and return brightness to the host theme',
    () {
      const config = HtmlRenderConfig(
        brightness: Brightness.dark,
        darkBackgroundColor: Color(0xff262629),
      );
      expect(config.copyWith().brightness, Brightness.dark);
      expect(config.copyWith().darkBackgroundColor, const Color(0xff262629));
      expect(
        config
            .copyWith(darkBackgroundColor: const Color(0xff303034))
            .darkBackgroundColor,
        const Color(0xff303034),
      );
      final copy = config.copyWith(
        brightness: null,
        colorMode: HtmlEmailColorMode.original,
      );
      expect(copy.brightness, isNull);
      expect(copy.colorMode, HtmlEmailColorMode.original);
    },
  );
}
