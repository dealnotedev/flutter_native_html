import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_native_html/src/css/css_parser.dart';
import 'package:flutter_native_html/src/css/css_selector.dart';
import 'package:flutter_native_html/src/css/css_variables.dart';
import 'package:flutter_native_html/src/css/style_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

Finder rich(String value) => find.text(value, findRichText: true);

Widget host(
  String source, {
  HtmlRenderConfig config = const HtmlRenderConfig(),
  double width = 450,
}) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      child: SingleChildScrollView(
        child: HtmlEmailView(html: source, config: config),
      ),
    ),
  ),
);

void main() {
  test(
    'CSS fallbacks and important shorthand precedence survive the cascade',
    () {
      final parsed = HtmlEmailParser().parse('''
      <style>
        p { color:#123456; color:unsupported(1); background-color:red }
        p { background:green!important }
        p { background-color:blue!important }
        .deferred { --fill:green; background:var(--fill)!important; background-color:blue!important }
      </style>
      <p>First</p><p class="deferred">Second</p>
    ''');
      final resolver = StyleResolver(
        stylesheet: parsed.stylesheet,
        rootStyle: const HtmlStyle(),
      );
      for (final element in parsed.root.querySelectorAll('p')) {
        final result = resolver.resolve(element, const HtmlStyle());
        expect(result.color, const Color(0xff123456));
        expect(result.backgroundColor, const Color(0xff0000ff));
      }
    },
  );

  test('style media and repeated width restrictions are both applied', () {
    final parsed = HtmlEmailParser().parse('''
      <style media="print">p { color:red }</style>
      <style media="screen and (min-width: 300px)">
        @media (max-width:400px) and (max-width:600px) { p { color:blue } }
      </style><p>Content</p>
    ''');
    final element = parsed.root.querySelector('p')!;
    expect(parsed.stylesheet.declarationsFor(element, 450).values, isEmpty);
    expect(parsed.stylesheet.declarationsFor(element, 250).values, isEmpty);
    expect(
      parsed.stylesheet.declarationsFor(element, 350).values['color'],
      'blue',
    );
  });

  test('compound attribute selectors inside :not keep their own scope', () {
    final sheet = CssParser.parseStylesheet('p:not([data-note].x) {color:red}');
    final elements = html
        .parse('<p class="x">First</p><p class="x" data-note>Second</p>')
        .querySelectorAll('p');
    expect(sheet.declarationsFor(elements.first, 450).values['color'], 'red');
    expect(sheet.declarationsFor(elements.last, 450).values, isEmpty);
  });

  test('variable dependency cycles include unused fallbacks', () {
    final tokens = CssVariables({
      '--available': 'red',
      '--primary': 'var(--available, var(--primary))',
    });
    expect(tokens.resolve('var(--primary, blue)')?.trim(), 'blue');
  });

  test('CSS matching has a shared per-render work budget', () {
    final sheet = CssParser.parseStylesheet('p { color:red }');
    final node = html.parse('<p>Text</p>').querySelector('p')!;
    final matches = CssMatchContext(maxVisits: 2);
    expect(
      sheet.declarationsFor(node, 450, matchContext: matches).values['color'],
      'red',
    );
    expect(
      () => sheet.declarationsFor(node, 450, matchContext: matches),
      throwsA(isA<CssMatchLimitException>()),
    );
  });

  testWidgets('prepared documents keep their background image policy', (
    tester,
  ) async {
    final allowed = _BackgroundProvider();
    final resolver = _Backgrounds({'data:image/png;base64,AAAA': allowed});
    const source =
        '<div style="background-image:url(data:image/png;base64,AAAA)">Text</div>';
    final document = HtmlEmailParser(
      sanitizer: const HtmlSanitizer(allowDataUriImages: false),
    ).parse(source);
    await tester.pumpWidget(
      MaterialApp(
        home: HtmlEmailView.document(
          document: document,
          config: HtmlRenderConfig(imageResolver: resolver),
        ),
      ),
    );
    expect(allowed.stream.listening, isFalse);
    await tester.pumpWidget(
      host(source, config: HtmlRenderConfig(imageResolver: resolver)),
    );
    expect(allowed.stream.listening, isTrue);
  });

  testWidgets('HTML dir is inherited and the root can suppress display', (
    tester,
  ) async {
    await tester.pumpWidget(host('<html dir="rtl"><p>Direction</p></html>'));
    expect(
      tester.widget<RichText>(rich('Direction')).textDirection,
      TextDirection.rtl,
    );
    for (final tag in ['html', 'body']) {
      await tester.pumpWidget(
        host('<$tag style="display:none"><p>Hidden</p></$tag>'),
      );
      expect(rich('Hidden'), findsNothing);
    }
  });

  testWidgets('explicitly visible descendants keep their text color', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        '<div style="visibility:hidden"><p>Hidden</p>'
        '<p style="visibility:visible;color:blue">Visible</p></div>',
      ),
    );
    Color? color(String value) {
      final span = tester.widget<RichText>(rich(value)).text;
      return span
          .getSpanForPosition(const TextPosition(offset: 0))
          ?.style
          ?.color;
    }

    expect(color('Hidden'), const Color(0x00000000));
    expect(color('Visible'), const Color(0xff0000ff));
  });

  testWidgets('transformed autolinks preserve the original URL', (
    tester,
  ) async {
    final targets = <String>[];
    await tester.pumpWidget(
      host(
        '<p style="text-transform:uppercase">https://example.test/Case</p>',
        config: HtmlRenderConfig(
          enableTextSelection: false,
          onLinkTap: (url, _) => targets.add(url),
        ),
      ),
    );
    await tester.tapAt(
      tester.getTopLeft(rich('HTTPS://EXAMPLE.TEST/CASE')) + const Offset(8, 8),
    );
    expect(targets, ['https://example.test/Case']);
  });

  testWidgets('spanned and ordinary cells share column coordinates', (
    tester,
  ) async {
    await tester.pumpWidget(
      host('''
      <table width="300" cellspacing="0" cellpadding="0">
        <tr><td width="30">A</td><td width="60">B</td><td width="210">C</td></tr>
        <tr><td colspan="2">AB</td><td>Third</td></tr>
      </table>
    '''),
    );
    expect(
      tester.getTopLeft(rich('Third')).dx,
      closeTo(tester.getTopLeft(rich('C')).dx, 1),
    );
  });

  testWidgets('a nested rowspan grid reserves room in a spaced outer row', (
    tester,
  ) async {
    await tester.pumpWidget(
      host('''
      <table width="350" cellspacing="2" cellpadding="0">
        <tr><td width="200"><table width="160" cellspacing="0" cellpadding="0">
          <tr><td rowspan="2">Span</td><td style="height:60px">Top</td></tr>
          <tr><td style="height:60px;vertical-align:bottom">Bottom</td></tr>
        </table></td><td>Side</td></tr>
        <tr><td>Next row</td><td>Last</td></tr>
      </table>
    '''),
    );
    expect(
      tester.getTopLeft(rich('Next row')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(rich('Bottom')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('table captions and custom cell handlers render', (tester) async {
    await tester.pumpWidget(
      host(
        '<table cellspacing="0"><caption>Caption</caption><tr><td>Original</td></tr></table>',
        config: const HtmlRenderConfig(handlers: [_CellOverride()]),
      ),
    );
    expect(rich('Caption'), findsOneWidget);
    expect(find.text('Custom cell'), findsOneWidget);
    expect(rich('Original'), findsNothing);
  });

  for (final spacing in [0, 2]) {
    testWidgets(
      'cell opacity and table visibility work with spacing $spacing',
      (tester) async {
        final taps = <String>[];
        final config = HtmlRenderConfig(
          enableTextSelection: false,
          onLinkTap: (url, _) => taps.add(url),
        );
        await tester.pumpWidget(
          host('''
        <table cellspacing="$spacing"><tr><td style="opacity:.4">Faded</td></tr></table>
        <table cellspacing="$spacing" style="visibility:hidden"><tr>
          <td><a href="https://example.test">Hidden action</a></td>
        </tr></table>
      ''', config: config),
        );
        expect(
          find.ancestor(
            of: rich('Faded'),
            matching: find.byWidgetPredicate(
              (w) => w is Opacity && w.opacity == .4,
            ),
          ),
          findsOneWidget,
        );
        await tester.tapAt(
          tester.getTopLeft(rich('Hidden action')) + const Offset(8, 8),
        );
        expect(taps, isEmpty);
      },
    );
  }

  testWidgets('a failed replacement clears the previous CSS tile', (
    tester,
  ) async {
    final old = _BackgroundProvider();
    final next = _BackgroundProvider();
    final config = HtmlRenderConfig(
      imageResolver: _Backgrounds({'cid:old': old, 'cid:next': next}),
    );
    Finder paintedTiles() => find.descendant(
      of: find.byType(HtmlEmailView),
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter != null,
      ),
    );
    await tester.pumpWidget(
      host(
        '<div style="background-image:url(cid:old)">Old</div>',
        config: config,
      ),
    );
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    old.stream.emit(ImageInfo(image: picture.toImageSync(4, 4)));
    picture.dispose();
    await tester.pump();
    expect(paintedTiles(), findsOneWidget);
    await tester.pumpWidget(
      host(
        '<div style="background-image:url(cid:next)">New</div>',
        config: config,
      ),
    );
    expect(paintedTiles(), findsNothing);
    next.fail();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(rich('New'), findsOneWidget);
  });

  testWidgets('failure in a non-tiled background leaves the content usable', (
    tester,
  ) async {
    final provider = _BackgroundProvider();
    await tester.pumpWidget(
      host(
        '<div style="background-image:url(cid:failed);background-repeat:no-repeat">Content</div>',
        config: HtmlRenderConfig(
          imageResolver: _Backgrounds({'cid:failed': provider}),
        ),
      ),
    );
    provider.fail();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(rich('Content'), findsOneWidget);
  });
}

class _CellOverride extends HtmlElementHandler {
  const _CellOverride();

  @override
  Set<String> get tags => {'td'};

  @override
  List<HtmlBuildResult> build(element, context) => [
    const BlockResult(Text('Custom cell')),
  ];
}

class _Backgrounds extends HtmlImageResolver {
  const _Backgrounds(this.providers);

  final Map<String, _BackgroundProvider> providers;

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(providers[src]);
}

class _BackgroundProvider extends ImageProvider<_BackgroundProvider> {
  final stream = _BackgroundStream();

  @override
  Future<_BackgroundProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _BackgroundProvider key,
    ImageDecoderCallback decode,
  ) => stream;

  void fail() => stream.fail();
}

class _BackgroundStream extends ImageStreamCompleter {
  bool get listening => hasListeners;

  void emit(ImageInfo image) => setImage(image);

  void fail() => reportError(exception: StateError('Image unavailable'));
}
