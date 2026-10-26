import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

late MemoryImage _square;
late MemoryImage _logo;

Future<MemoryImage> _blankImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final provider = MemoryImage(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return provider;
}

class _Images extends HtmlImageResolver {
  const _Images();

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(src.endsWith('/logo') ? _logo : _square);
}

String _nestedImageTable(String image) =>
    '''
  <table width="100%" cellspacing="0" cellpadding="0" align="center" style="max-width:600px;margin:0 auto"><tr><td></td><td style="width:600px">
    <table width="100%" cellspacing="0" cellpadding="0"><tr><td>
      <table width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" valign="top">
        <table width="600" cellspacing="0" cellpadding="0" align="center"><tr><td align="center" valign="top">
          <table width="100%" cellspacing="0" cellpadding="0" align="center"><tr>
            <td height="1" style="height:1px;font-size:0;line-height:0">$image</td>
          </tr></table>
        </td></tr></table>
      </td></tr></table>
    </td></tr><tr><td height="20" colspan="3">&nbsp;</td></tr></table>
    <img src="https://example.invalid/square" height="1">
  </td><td></td></tr></table>
''';

Future<void> _pump(
  WidgetTester tester,
  String html, {
  double tableSpacing = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 600,
            child: HtmlEmailView(
              html: html,
              config: HtmlRenderConfig(
                imageResolver: const _Images(),
                defaultTableCellSpacing: tableSpacing,
                enableTextSelection: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    final context = tester.element(find.byType(HtmlEmailView));
    await precacheImage(_logo, context);
    await precacheImage(_square, context);
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    _logo = await _blankImage(360, 86);
    _square = await _blankImage(64, 64);
  });

  testWidgets('nested table height contains a growing percentage-width image', (
    tester,
  ) async {
    await _pump(
      tester,
      _nestedImageTable(
        '<img src="https://example.invalid/square" width="100%" style="display:block">',
      ),
    );
    final image = tester.getRect(find.byType(Image).first);
    expect(image.height, closeTo(600, 0.1));
    expect(
      tester.getRect(find.byType(HtmlEmailView)).bottom,
      greaterThanOrEqualTo(image.bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested percentage image height preserves a non-square aspect', (
    tester,
  ) async {
    await _pump(
      tester,
      _nestedImageTable(
        '<img src="https://example.invalid/logo" width="50%" style="display:block">',
      ),
    );
    final image = tester.getRect(find.byType(Image).first);
    expect(image.width, closeTo(300, 0.1));
    expect(image.height, closeTo(300 * 86 / 360, 0.1));
    expect(
      tester.getRect(find.byType(HtmlEmailView)).bottom,
      greaterThanOrEqualTo(image.bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested percentage image keeps an explicitly authored height', (
    tester,
  ) async {
    await _pump(
      tester,
      _nestedImageTable(
        '<img src="https://example.invalid/square" width="100%" height="40" style="display:block">',
      ),
    );
    final image = tester.getRect(find.byType(Image).first);
    expect(image.height, 40);
    expect(tester.getSize(find.byType(HtmlEmailView)).height, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested percentage image height includes authored padding', (
    tester,
  ) async {
    await _pump(
      tester,
      _nestedImageTable(
        '<img src="https://example.invalid/square" width="100%" style="display:block;padding:0 50px">',
      ),
    );
    final image = tester.getRect(find.byType(Image).first);
    expect(image.height, closeTo(500, 0.1));
    expect(
      tester.getRect(find.byType(HtmlEmailView)).bottom,
      greaterThanOrEqualTo(image.bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a right-aligned badge stays visible beside a percentage column',
    (tester) async {
      await _pump(tester, '''
      <table width="100%" cellpadding="0" cellspacing="0"><tr align="right">
      <td style="width:100%">Heading</td><td>
      <div style="display:inline-block;border:1px solid #000;margin-left:14px;max-width:200px">
      <table width="100%" height="18" cellpadding="0" cellspacing="0"><tr>
        <td style="border-radius:4px;font-size:0;height:18px;line-height:0;width:18px">
          <img src="https://example.invalid/square" width="auto" height="18"
               style="border-radius:4px;font-size:0;height:18px;line-height:0;width:18px">
        </td>
        <td style="font-size:12px;max-width:160px;overflow:hidden;padding:0 6px;text-overflow:ellipsis;white-space:nowrap">Example application</td>
      </tr></table></div></td></tr></table>
    ''');
      expect(tester.getSize(find.byType(Image)), const Size(18, 18));
      final image = tester.getRect(find.byType(Image));
      final root = tester.getRect(find.byType(HtmlEmailView));
      expect(image.right, lessThanOrEqualTo(root.right));
      for (final clip
          in find
              .ancestor(of: find.byType(Image), matching: find.byType(ClipRect))
              .evaluate()) {
        final visible = tester
            .getRect(find.byElementPredicate((e) => e == clip))
            .intersect(image);
        expect(visible.width, closeTo(image.width, 0.1));
        expect(visible.height, closeTo(image.height, 0.1));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an invalid unitless CSS width keeps the earlier valid width', (
    tester,
  ) async {
    await _pump(
      tester,
      '<span style="display:inline-block;font-size:10px;width:40px;width:240">One</span>'
      '<span style="display:inline-block;font-size:10px">Two</span>',
    );
    final first = tester.getTopLeft(find.text('One'));
    final second = tester.getTopLeft(find.text('Two'));
    expect(second.dx - first.dx, closeTo(40, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('numeric HTML width attributes still specify pixels', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table width="120" cellpadding="0" cellspacing="0"><tr><td>'
      '<img src="https://example.invalid/square" width="100%" style="display:block">'
      '</td></tr></table>',
    );
    expect(tester.getSize(find.byType(Image)), const Size(120, 120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unitless zero remains a valid CSS width', (tester) async {
    await _pump(
      tester,
      '<span style="display:inline-block;font-size:10px;width:40px;width:0">One</span>'
      '<span style="display:inline-block;font-size:10px">Two</span>',
    );
    expect(
      tester.getTopLeft(find.text('Two')).dx,
      closeTo(tester.getTopLeft(find.text('One')).dx, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty gutter in a ragged table takes no flexible width', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table width="100%" cellpadding="0" cellspacing="0">'
      '<tr><td></td><td><img src="https://example.invalid/square" width="100%" style="display:block"></td></tr>'
      '<tr><td></td></tr></table>',
    );
    final image = tester.getRect(find.byType(Image));
    expect(image.width, closeTo(600, 0.1));
    expect(image.left, tester.getRect(find.byType(HtmlEmailView)).left);
    expect(tester.takeException(), isNull);
  });

  for (final gutter in [
    (attributes: 'style="padding:0 10px"', imageWidth: 580.0),
    (attributes: 'width="30"', imageWidth: 570.0),
  ]) {
    testWidgets('an empty ragged-table gutter retains ${gutter.attributes}', (
      tester,
    ) async {
      await _pump(
        tester,
        '<table width="100%" cellpadding="0" cellspacing="0">'
        '<tr><td ${gutter.attributes}></td><td><img src="https://example.invalid/square" width="100%" style="display:block"></td></tr>'
        '<tr><td></td></tr></table>',
      );
      expect(
        tester.getSize(find.byType(Image)).width,
        closeTo(gutter.imageWidth, 0.1),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final spacing in [0, 2]) {
    testWidgets(
      'single-row table height includes cell padding with cellspacing=$spacing',
      (tester) async {
        await _pump(tester, '''
          <table height="120" width="100%" cellpadding="10" cellspacing="$spacing">
            <tr><td valign="middle"><div style="height:20px;line-height:20px">Greeting</div></td></tr>
          </table>
          <div>Following section</div>
        ''');
        expect(
          tester.getTopLeft(find.text('Following section')).dy,
          closeTo(120, 0.1),
        );
        expect(
          tester.getRect(find.text('Greeting')).center.dy,
          closeTo(60, 0.1),
        );
        expect(tester.takeException(), isNull);
      },
    );
    for (final height in ['height="0"', 'style="height:1px"']) {
      testWidgets(
        'table $height with cellspacing=$spacing grows to fit its content',
        (tester) async {
          await _pump(tester, '''
            <table $height width="100%" cellpadding="10" cellspacing="$spacing">
              <tr><td valign="middle"><div style="height:60px">Greeting</div></td></tr>
            </table>
            <div>Following section</div>
          ''');
          expect(
            tester.getTopLeft(find.text('Following section')).dy,
            closeTo(80 + spacing * 2, 0.1),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'one-pixel divider table gives its empty cells a painted height',
    (tester) async {
      await _pump(tester, '''
      <table height="1" width="100%" cellpadding="0" cellspacing="0"><tr>
        <td width="40%" style="background:#eeeeee"></td>
        <td width="20%" style="background:#9147ff"></td>
        <td width="40%" style="background:#eeeeee"></td>
      </tr></table>
    ''');
      expect(find.byType(TableCell), findsNWidgets(3));
      for (final cell in find.byType(TableCell).evaluate()) {
        expect(tester.getSize(find.byWidget(cell.widget)).height, 1);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested zero-height email sections keep their document order', (
    tester,
  ) async {
    await _pump(tester, '''
      <table width="600" cellpadding="20" cellspacing="0"><tr><td>
        <table width="100%" cellpadding="0" cellspacing="0">
          <tr><td><table width="100%" height="90" cellpadding="0" cellspacing="0">
            <tr><td align="center" valign="middle"><img src="https://example.test/logo" width="114" height="38"></td></tr>
          </table></td></tr>
          <tr><td><table width="100%" height="0" cellpadding="40" cellspacing="0">
            <tr><td align="center" valign="middle"><div>New follower</div></td></tr>
          </table></td></tr>
          <tr><td><table width="100%" height="0" cellpadding="0" cellspacing="0">
            <tr><td align="center" valign="middle">
              <img src="https://example.test/avatar" width="96" height="96">
              <div style="font-size:28px;margin:10px 0 30px">Follower name</div>
            </td></tr>
          </table></td></tr>
          <tr><td><table width="100%" height="0" cellpadding="30" cellspacing="0">
            <tr><td align="center" valign="middle"><a href="https://example.test/profile"
              style="display:inline-block;line-height:40px;width:200px">View profile</a></td></tr>
          </table></td></tr>
        </table>
      </td></tr><tr><td><p>Email footer</p></td></tr></table>
    ''');
    final greeting = tester.getRect(find.text('New follower'));
    final avatar = tester.getRect(find.byType(Image).at(1));
    final name = tester.getRect(find.text('Follower name'));
    final button = tester.getRect(find.text('View profile'));
    final footer = tester.getRect(find.text('Email footer'));
    expect(avatar.top, greaterThanOrEqualTo(greeting.bottom + 40));
    expect(name.top, greaterThanOrEqualTo(avatar.bottom + 10));
    expect(button.top, greaterThanOrEqualTo(name.bottom + 60));
    expect(footer.top, greaterThanOrEqualTo(button.bottom + 30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('gradient and rounded nonuniform border keep their paint', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: const ColoredBox(
              color: Colors.white,
              child: SizedBox(
                width: 26,
                child: HtmlEmailView(
                  html:
                      '<div style="width:24px;height:24px;border:1px solid black;border-bottom-color:red;border-radius:6px;background-color:blue;background-image:linear-gradient(to bottom,#00ff00,#0000ff)"></div>',
                  config: HtmlRenderConfig(enableTextSelection: false),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final image =
        (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImageSync();
    final bytes = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int channel(int x, int y, int c) =>
        bytes!.getUint8((y * image.width + x) * 4 + c);
    expect(
      channel(0, 0, 0),
      greaterThan(240),
      reason: 'The rounded corner must show the white backdrop',
    );
    expect(channel(13, 3, 1), greaterThan(channel(13, 22, 1) + 120));
    expect(channel(13, 22, 2), greaterThan(channel(13, 3, 2) + 120));
    image.dispose();
  });
  testWidgets('auto right float shares the preceding inline row', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="width:400px"><div style="display:inline-block;font-size:14px;line-height:20px">Status label</div><span style="float:right;font-size:14px;line-height:20px"><span style="display:inline-block;background:#ccc;padding:2px 10px">Action</span></span><div style="clear:both"></div></div><div>After float</div>',
    );
    final label = tester.getRect(find.text('Status label'));
    final action = tester.getRect(find.text('Action'));
    expect(action.top, lessThan(label.bottom));
    expect(action.right, closeTo(390, 0.1));
    expect(tester.getTopLeft(find.text('After float')).dy, lessThan(32));
  });
  testWidgets('percent width max cap keeps external margins and left placement', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div align="left" style="width:100%;max-width:400px;margin:0 10px"><img src="https://example.test/logo" style="width:100%"></div>',
    );
    expect(tester.getSize(find.byType(Image)).width, closeTo(400, 0.1));
    expect(tester.getTopLeft(find.byType(Image)).dx, closeTo(10, 0.1));
  });
  testWidgets('zero line-height whitespace spacer reserves no block height', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="white-space:nowrap;font:15px monospace;line-height:0">&nbsp; &nbsp; &nbsp;</div><div>After spacer</div>',
    );
    expect(tester.getTopLeft(find.text('After spacer')).dy, 0);
  });
  testWidgets('nested auto tables size a block cell CTA to its unwrapped text', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table cellpadding="0" cellspacing="0" align="center"><tr><td><table cellpadding="0" cellspacing="0" align="center"><tr><td><table width="100%" cellpadding="0" cellspacing="0"><tr><th style="display:block;width:auto;min-width:100px;padding:8px 20px;font-size:14px;line-height:20px"><a href="https://example.test"><strong>Open the release details</strong></a></th></tr></table></td></tr></table></td></tr></table>',
    );
    final label = find.byWidgetPredicate(
      (w) =>
          w is RichText && w.text.toPlainText() == 'Open the release details',
    );
    expect(tester.getSize(label).height, closeTo(20, 0.1));
    expect(tester.getSize(label).width, greaterThan(200));
  });
  testWidgets(
    'collapsible indentation after BR does not indent the next line',
    (tester) async {
      await _pump(
        tester,
        '<p style="margin:0">First<br>   <strong> Next</strong></p>',
      );
      final rich = tester.widget<RichText>(find.byType(RichText).last);
      expect(rich.text.toPlainText(), 'First\nNext');
    },
  );
  for (final (html, height) in [
    ('<br>Text', 48.0),
    ('Text<br><br>', 48.0),
    ('<br>', 24.0),
    ('Text<br>', 24.0),
  ]) {
    testWidgets('explicit breaks retain CSS line boxes: $html', (tester) async {
      await _pump(
        tester,
        '<p style="margin:0;font-size:16px;line-height:24px">$html</p><div>After break</div>',
      );
      expect(
        tester.getTopLeft(find.text('After break')).dy,
        closeTo(height, 0.1),
      );
    });
  }
  testWidgets('middle aligned image does not duplicate inherited line leading', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="font-size:18px;line-height:27px"><img src="https://example.test/icon" width="32" height="32" style="vertical-align:middle"></div><div>After image</div>',
    );
    expect(tester.getTopLeft(find.text('After image')).dy, closeTo(32, 0.1));
  });
  testWidgets('CSS line-height splits extra leading above and below glyphs', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="font-family:Ahem;font-size:36px;line-height:80px">G</div>',
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText).last,
    );
    final natural = TextPainter(
      text: const TextSpan(
        text: 'G',
        style: TextStyle(fontFamily: 'Ahem', fontSize: 36),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final normalBaseline = natural.computeLineMetrics().single.baseline;
    expect(
      paragraph.getDryBaseline(paragraph.constraints, TextBaseline.alphabetic),
      closeTo(normalBaseline + (80 - natural.height) / 2, 0.1),
    );
    expect(paragraph.size.height, 80);
    natural.dispose();
  });
  testWidgets('linked image does not acquire a text underline', (tester) async {
    final font = File(
      '${Platform.environment['WINDIR'] ?? '/nonexistent'}/Fonts/arial.ttf',
    );
    if (font.existsSync()) {
      final loader = FontLoader('UnderlineRegressionFont')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: const ColoredBox(
              color: Colors.white,
              child: SizedBox(
                width: 300,
                child: HtmlEmailView(
                  html:
                      '<div style="text-align:center"><div style="display:inline-block;padding:0 20px;max-width:100%"><a href="https://example.test" style="display:inline-block">\n<img src="https://example.test/icon" style="width:100%;height:auto;min-width:200px;border-radius:50%;object-fit:cover;border:1px solid rgba(0,0,0,0.1)">\n</a></div></div>',
                  config: HtmlRenderConfig(
                    imageResolver: _Images(),
                    defaultFontFamily: 'UnderlineRegressionFont',
                    enableTextSelection: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(_square, boundary.currentContext!),
    );
    await tester.pumpAndSettle();
    final image =
        (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImageSync();
    final pixels = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    var bluePixels = 0;
    for (var i = 0; i < pixels!.lengthInBytes; i += 4) {
      final blue = pixels.getUint8(i + 2);
      if (blue > pixels.getUint8(i) + 60 &&
          blue > pixels.getUint8(i + 1) + 60) {
        bluePixels++;
      }
    }
    image.dispose();
    expect(
      bluePixels,
      0,
      reason: 'Text decoration must not paint underneath a replaced image',
    );
  });
  testWidgets('orphan CSS table cells form one anonymous row', (tester) async {
    await _pump(tester, '''
      <div align="center" style="font-size:18px">
        <div style="display:table-cell;vertical-align:middle"><img
          src="https://example.test/icon" width="32" height="32" style="margin-right:8px;vertical-align:middle"></div>
        <div style="display:table-cell;vertical-align:middle">Distribution</div>
      </div>
    ''');
    final icon = tester.getRect(find.byType(Image));
    final label = tester.getRect(find.text('Distribution'));
    expect(label.left, closeTo(icon.right + 8, 0.1));
    expect(label.center.dy, closeTo(icon.center.dy, 0.5));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'table resets legacy center alignment but inherits CSS alignment',
    (tester) async {
      await _pump(tester, '''
      <div align="center"><div><table width="400" cellpadding="0" cellspacing="0"><tr><td>Legacy</td></tr></table></div></div>
      <div style="text-align:center"><table width="400" cellpadding="0" cellspacing="0"><tr><td>Authored</td></tr></table></div>
    ''');
      expect(
        tester.widget<Text>(find.text('Legacy')).textAlign,
        TextAlign.start,
      );
      expect(
        tester.widget<Text>(find.text('Authored')).textAlign,
        TextAlign.center,
      );
    },
  );
  testWidgets('bare inline table retains default outer cell spacing', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="font-size:0;line-height:0"><table cellpadding="0" style="display:inline-block"><tr><td>
        <img src="https://example.test/icon" width="20" height="20">
      </td></tr></table></div><div>After table</div>
    ''', tableSpacing: 2);
    expect(tester.getTopLeft(find.byType(Image)).dx, closeTo(2, 0.1));
    expect(tester.getTopLeft(find.byType(Image)).dy, closeTo(2, 0.1));
    expect(tester.getTopLeft(find.text('After table')).dy, closeTo(24, 0.1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('inline-block max-width excludes its horizontal margins', (
    tester,
  ) async {
    await _pump(tester, '''
      <div align="center"><div style="display:inline-block;max-width:400px;margin:0 16px">
        <table width="100%" cellpadding="0" cellspacing="0"><tr><td>
          <img src="https://example.test/logo" width="600" height="60" style="width:100%">
        </td></tr></table>
      </div></div>
    ''');
    expect(tester.getSize(find.byType(Image)).width, closeTo(400, 0.1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('block max-width excludes its horizontal margins', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="max-width:400px;margin:0 16px"><img src="https://example.test/logo" width="600" height="60" style="width:100%"></div>
    ''');
    expect(tester.getSize(find.byType(Image)).width, closeTo(400, 0.1));
  });
  testWidgets('spaced table keeps an auto icon column at its intrinsic width', (
    tester,
  ) async {
    await _pump(tester, '''
      <table width="400" cellspacing="2" cellpadding="0"><tr>
        <td><div style="font-size:14px;line-height:20px">A link and its explanation fit beside the compact icon.</div></td>
        <td><img src="https://example.test/icon" width="60" height="60"></td>
      </tr></table>
    ''');
    expect(tester.getRect(find.byType(Image)).right, closeTo(398, 0.1));
    expect(tester.getRect(find.byType(Image)).width, closeTo(60, 0.1));
  });
  testWidgets('fallback cells let nested centered blocks use the whole cell', (
    tester,
  ) async {
    await _pump(tester, '''
      <table width="400" cellpadding="0" cellspacing="0">
        <tr><td>Left</td><td>Right</td></tr>
        <tr><td colspan="2"><div align="center">Centered footer</div></td></tr>
      </table>
    ''');
    final footer = tester.getRect(find.text('Centered footer'));
    expect(footer.width, closeTo(400, 0.1));
    expect(
      tester.widget<Text>(find.text('Centered footer')).textAlign,
      TextAlign.center,
    );
  });
  testWidgets(
    'image padding reserves space with content and border box sizing',
    (tester) async {
      await _pump(tester, '''
      <div style="line-height:0;font-size:0"><img src="https://example.test/icon" width="20" height="20" style="padding-right:8px;vertical-align:bottom"><img src="https://example.test/marker" width="2" height="2"></div>
      <div style="line-height:0;font-size:0"><img src="https://example.test/icon" width="28" height="20" style="box-sizing:border-box;padding-right:8px;vertical-align:bottom"><img src="https://example.test/marker" width="2" height="2"></div>
    ''');
      final images = find.byType(Image);
      for (var i = 0; i < 2; i++) {
        final image = tester.getRect(images.at(i * 2));
        final marker = tester.getRect(images.at(i * 2 + 1));
        expect(image.width, closeTo(20, 0.1));
        expect(marker.left - image.right, closeTo(8, 0.1));
      }
    },
  );
  testWidgets('default inline image bottom sits on the alphabetic baseline', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="font-size:14px;line-height:20px"><img
        src="https://example.test/icon" width="100" height="40"></div>
    ''');
    final imageRect = tester.getRect(find.byType(Image));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains('\uFFFC'),
      ),
    );
    final baseline = paragraph
        .localToGlobal(
          Offset(
            0,
            paragraph.getDryBaseline(
              paragraph.constraints,
              TextBaseline.alphabetic,
            )!,
          ),
        )
        .dy;
    expect(imageRect.bottom, closeTo(baseline, 0.6));
    expect(tester.takeException(), isNull);
  });
  testWidgets('fixed linked image may overflow its smaller inline anchor', (
    tester,
  ) async {
    await _pump(tester, '''
      <a href="https://example.test" style="display:inline-block;width:84px">
        <img src="https://example.test/logo" width="101" height="37">
      </a>
    ''');
    expect(tester.getSize(find.byType(Image)), const Size(101, 37));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'a single inline-block table cell stays content sized with spacing',
    (tester) async {
      await _pump(tester, '''
      <div style="font-size:0;line-height:0"><table style="display:inline-block" cellpadding="0"><tr>
        <td style="display:inline-block;padding:4px;margin-top:4px;background:#eee">
          <table width="100%" cellpadding="0" cellspacing="0"><tr><td width="8" style="padding-right:4px"><img src="https://example.test/icon" width="16" height="16" style="display:block"></td><td><p style="margin:0;font-size:12px;line-height:15px">Short badge</p></td></tr></table>
        </td></tr></table></div><div>After badge</div>
    ''', tableSpacing: 2);
      expect(tester.getTopLeft(find.text('After badge')).dy, closeTo(32, 0.1));
      expect(tester.getRect(find.text('Short badge')).width, lessThan(200));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'full-width inline-block links retain the surrounding baseline gap',
    (tester) async {
      await _pump(tester, '''
      <div style="font-size:14px;line-height:20px"><a style="display:inline-block;width:100%">
        <table width="100%" cellpadding="0" cellspacing="0"><tr><td><div style="height:40px;font-size:0;line-height:0"></div></td></tr></table>
      </a></div><div>After inline link</div>
      <div style="font-size:14px;line-height:20px"><a style="display:block">
        <table width="100%" cellpadding="0" cellspacing="0"><tr><td><div style="height:40px;font-size:0;line-height:0"></div></td></tr></table>
      </a></div><div>After block link</div>
    ''');
      final first = tester.getRect(find.text('After inline link'));
      final second = tester.getRect(find.text('After block link'));
      expect(first.top, greaterThan(42));
      expect(second.top - first.bottom, closeTo(40, 0.1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('a floated image does not reserve an inline baseline gap', (
    tester,
  ) async {
    await _pump(tester, '''
      <table width="600" cellspacing="0" cellpadding="0"><tr><td style="font-size:14px;line-height:20px"><img src="https://example.test/icon" width="40" height="40" style="float:right"></td></tr></table><div>After floated image</div>
    ''');
    expect(tester.getRect(find.byType(Image)).right, closeTo(600, 0.1));
    expect(
      tester.getRect(find.text('After floated image')).top,
      closeTo(40, 0.1),
    );
  });
  testWidgets('an empty paragraph collapses its own vertical margins', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="padding-top:1px;font-size:14px;line-height:20px"><p style="margin:10px 0 20px"></p><div>After empty paragraph</div></div>
    ''');
    expect(
      tester.getTopLeft(find.text('After empty paragraph')).dy,
      closeTo(21, 0.1),
    );
  });
  testWidgets('empty paragraph margins collapse with a following block', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="padding-top:1px;font-size:14px;line-height:20px"><p style="margin:10px 0 20px"></p><p style="margin:30px 0 0">After empty paragraph</p></div>
    ''');
    expect(
      tester.getTopLeft(find.text('After empty paragraph')).dy,
      closeTo(31, 0.1),
    );
  });
  testWidgets(
    'ellipsis cell truncates a nowrap inline price without changing copied text',
    (tester) async {
      const price = 'Price 123456789.00';
      await _pump(tester, '''
      <table width="192" cellpadding="0" cellspacing="0"><tr><td width="56">Sale</td>
        <td style="max-width:128px;overflow:hidden;text-overflow:ellipsis;padding:0"><span style="max-width:128px;white-space:nowrap;font-size:24px;line-height:36px">$price</span></td>
      </tr></table>
    ''');
      final rich = find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == price,
      );
      expect(rich, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(rich);
      expect(
        paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 16, extentOffset: 17),
        ),
        isEmpty,
      );
      expect(tester.widget<RichText>(rich).text.toPlainText(), price);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('CSS normal line-height ignores an unrelated Flutter text height', (
    tester,
  ) async {
    final probe = TextPainter(
      text: const TextSpan(
        text: 'First\nSecond',
        style: TextStyle(fontFamily: 'Ahem', fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final naturalHeight = probe.height;
    probe.dispose();
    await tester.pumpWidget(
      const MaterialApp(
        home: DefaultTextStyle(
          style: TextStyle(fontFamily: 'Ahem', fontSize: 40, height: 3),
          child: SingleChildScrollView(
            child: HtmlEmailView(
              html:
                  '<div style="font-family:Ahem;font-size:14px;line-height:normal">First<br>Second</div>',
              config: HtmlRenderConfig(enableTextSelection: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.text('First\nSecond')).height,
      closeTo(naturalHeight, 0.1),
    );
  });
  for (final containerWidth in [600, 360]) {
    testWidgets(
      'percent min-width overrides a narrow image table in a $containerWidth px container',
      (tester) async {
        await _pump(tester, '''
        <div style="width:${containerWidth}px">
          <table cellpadding="0" cellspacing="0" style="width:100px;min-width:100%;max-width:100%">
            <tr><td><img src="https://example.test/logo" width="100"
              style="width:100%;min-width:100%;max-width:100%;height:auto"></td></tr>
          </table>
        </div>
      ''');
        expect(
          tester.getSize(find.byType(Image)).width,
          closeTo(containerWidth, 0.1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('adjacent paragraph margins collapse through source whitespace', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="font-size:14px;line-height:20px">
        <p style="margin:10px 0 20px">First</p>
        <p style="margin:30px 0 10px">Second</p>
      </div>
    ''');
    final first = tester.getRect(find.text('First'));
    final second = tester.getRect(find.text('Second'));
    expect(second.top - first.bottom, closeTo(30, 0.1));
  });
  testWidgets('authored line-height is independent of the host text theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DefaultTextStyle(
          style: TextStyle(fontSize: 40, height: 3),
          child: SingleChildScrollView(
            child: HtmlEmailView(
              html:
                  '<div style="font-size:14px;line-height:20px">First<br>Second</div>',
              config: HtmlRenderConfig(enableTextSelection: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('First\nSecond')).height, closeTo(40, 0.1));
  });
  testWidgets('outside list markers do not consume the authored text inset', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="font-size:14px;line-height:20px">
        <div>Origin</div>
        <ul style="padding-left:40px;margin:0"><li>First item</li><li>Second item</li></ul>
      </div>
    ''');
    final origin = tester.getRect(find.text('Origin'));
    final first = tester.getRect(find.text('First item'));
    final second = tester.getRect(find.text('Second item'));
    expect(first.left - origin.left, closeTo(40, 0.1));
    expect(second.top - first.top, closeTo(20, 0.1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('default list indentation is 40 pixels at larger font sizes', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="font-size:20px;line-height:24px">
        <div>Origin</div><ul style="margin:0"><li>List item</li></ul>
      </div>
    ''');
    expect(
      tester.getRect(find.text('List item')).left -
          tester.getRect(find.text('Origin')).left,
      closeTo(40, 0.1),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('HTML spaces collapse across styled inline boundaries', (
    tester,
  ) async {
    await _pump(tester, '''
      <p>Read our <a href="https://example.test/help"> Help </a> if needed.</p>
      <p>Keep&nbsp; <strong> both</strong> spaces.</p>
      <pre>Keep   all spaces.</pre>
      <p>Plain <span style="white-space:pre-wrap">  preserved</span> spaces.</p>
    ''');
    expect(find.text('Read our Help if needed.'), findsOneWidget);
    expect(find.text('Keep\u00a0 both spaces.'), findsOneWidget);
    expect(find.text('Keep   all spaces.'), findsOneWidget);
    expect(find.text('Plain   preserved spaces.'), findsOneWidget);
  });
  testWidgets('inline image vertical margins contribute to its line box', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="line-height:0;font-size:0"><img src="https://example.test/logo"
        width="100" height="20" style="margin:20px"></div>
      <div>After image</div>
    ''');
    expect(tester.getTopLeft(find.byType(Image)).dy, closeTo(20, 0.1));
    expect(tester.getTopLeft(find.text('After image')).dy, closeTo(60, 0.1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('inline badge table sizes nested percent cells to max content', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="font-size:0">
        <table cellpadding="0" cellspacing="0" style="display:inline-block"><tr>
          <td style="display:inline-block;padding:4px;background:#eee">
            <table width="100%" cellpadding="0" cellspacing="0"><tr>
              <td width="8" style="padding-right:4px"><img src="https://example.test/icon" width="16" height="16"></td>
              <td><p style="margin:0;font-size:12px;line-height:15px">Recruiting actively right now</p></td>
            </tr></table>
          </td>
        </tr></table>
      </div>
    ''');
    expect(
      tester.getSize(find.text('Recruiting actively right now')).height,
      closeTo(15, 0.1),
    );
    expect(tester.getSize(find.byType(Image)).width, closeTo(16, 0.1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('inline-block table cells retain margins in their inline box', (
    tester,
  ) async {
    await _pump(tester, '''
      <div style="font-size:0;line-height:0">
        <table cellspacing="0" cellpadding="0" style="display:inline-block"><tr>
          <td style="display:inline-block;margin:10px 8px 0 0"><p style="margin:0;font-size:14px;line-height:20px">Badge</p></td>
        </tr></table>
      </div>
    ''');
    expect(tester.getTopLeft(find.text('Badge')).dy, closeTo(10, 0.1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('email logo respects max-height with auto width and height', (
    tester,
  ) async {
    await _pump(
      tester,
      '<img src="https://example.test/logo" style="max-height:40px;width:auto;height:auto">',
    );
    final image = tester.getSize(find.byType(Image));
    expect(image.height, closeTo(40, 0.1));
    expect(image.width, closeTo(360 / 86 * 40, 0.1));
  });

  testWidgets('rowspan product card preserves the declared column widths', (
    tester,
  ) async {
    await _pump(tester, '''
      <table width="568" cellpadding="0" cellspacing="0"><tr>
        <td rowspan="3" width="371" style="width:371px;vertical-align:top">
          <table width="100%" cellpadding="0" cellspacing="0"><tr><td>
            <div style="width:100%;line-height:0"><a style="font-size:0">
              <img src="https://example.test/hero" width="371" height="371">
            </a><div style="font-size:24px;line-height:32px">3544.30</div></div>
          </td></tr></table>
        </td>
        <td width="12" rowspan="3"></td>
        <td width="185" style="width:185px;vertical-align:top">
          <table width="100%" cellpadding="0" cellspacing="0"><tr><td>
            <div style="width:100%;line-height:0"><a style="font-size:0">
              <img src="https://example.test/small1" width="185" height="185">
            </a></div>
          </td></tr></table>
        </td>
      </tr><tr><td height="12"></td></tr><tr><td width="185">
        <img src="https://example.test/small2" width="185" height="185">
      </td></tr></table>
    ''');
    final images = find.byType(Image);
    expect(tester.getSize(images.at(0)).width, closeTo(371, 0.1));
    expect(tester.getSize(images.at(1)).width, closeTo(185, 0.1));
    expect(
      tester.getRect(images.at(1)).left,
      closeTo(tester.getRect(images.at(2)).left, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  test('font family names do not implicitly change font-weight', () {
    const style = HtmlStyle(
      fontFamilies: ['Roboto-Medium', 'SegoeUI-Bold', 'sans-serif-Bold'],
    );
    expect(
      style.toTextStyle().fontWeight ?? FontWeight.normal,
      FontWeight.normal,
    );
    expect(
      style.toTextStyle().fontFamilyFallback,
      contains(anyOf('serif', 'Times New Roman', 'DejaVu Serif')),
    );
    const light = HtmlStyle(
      fontFamilies: ['Missing-Bold'],
      fontWeight: FontWeight.w300,
    );
    expect(light.toTextStyle().fontWeight, FontWeight.w300);
  });

  testWidgets('sized image preserves its aspect ratio under a CSS height cap', (
    tester,
  ) async {
    await _pump(
      tester,
      '<img src="https://example.test/logo" width="360" height="86" style="max-height:40px">',
    );
    expect(tester.getSize(find.byType(Image)).height, closeTo(40, 0.1));
    expect(
      tester.getSize(find.byType(Image)).width,
      closeTo(360 / 86 * 40, 0.1),
    );
  });

  testWidgets('legacy background attribute renders a product photograph', (
    tester,
  ) async {
    await _pump(tester, '''
      <table width="192" cellpadding="0" cellspacing="0"><tr>
        <td colspan="8" width="192" height="192"
            background="https://example.test/product"
            style="background-size:cover;background-repeat:no-repeat;border-radius:12px;background-color:#ccc">
          <div style="width:192px;height:192px;background-color:rgba(0,0,0,0.02)"></div>
        </td></tr></table>
    ''');
    expect(find.byType(Image), findsOneWidget);
    expect(tester.getSize(find.byType(Image)), const Size(192, 192));
  });

  testWidgets('CSS can disable a legacy background attribute', (tester) async {
    await _pump(tester, '''
      <table width="192" cellpadding="0"><tr><td
        background="https://example.test/product"
        style="background-image:none;background-size:cover">
        <div style="height:192px">Product</div>
      </td></tr></table>
    ''');
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('legacy backgrounds still obey the remote image policy', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HtmlEmailView(
          html:
              '<table><tr><td background="https://example.test/product" '
              'style="background-size:cover">Product</td></tr></table>',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline price ignores max-width and keeps all digits visible', (
    tester,
  ) async {
    await _pump(tester, '''
      <table width="192" cellpadding="0" cellspacing="0"><tr>
        <td colspan="2" style="overflow:hidden;max-width:128px">
          <span style="max-width:128px;white-space:nowrap;font-size:12px">UAH 39,348.68</span>
        </td></tr></table>
    ''');
    final price = find.byWidgetPredicate(
      (widget) =>
          widget is RichText &&
          widget.text.toPlainText().contains('UAH 39,348.68'),
    );
    expect(price, findsOneWidget);
    expect(tester.getSize(price).width, greaterThan(128));
    final rich = tester.widget<RichText>(price);
    expect(rich.softWrap, isFalse);
    expect(rich.overflow, TextOverflow.visible);
    expect(
      rich.text.toPlainText().contains('\uFFFC'),
      isFalse,
      reason:
          'a non-replaced inline span must remain text, not a constrained WidgetSpan',
    );
    expect(tester.takeException(), isNull);
  });
}
