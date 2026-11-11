// Regressions found by the browser-parity corpus harness (tool/email_corpus).
// Each case is a synthetic reduction of a public email that rendered
// differently from Chrome.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

class _Images extends HtmlImageResolver {
  const _Images(this.provider);
  final ImageProvider provider;

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(provider);
}

Future<void> _pump(
  WidgetTester tester,
  String html, {
  double width = 375,
  HtmlRenderConfig config = const HtmlRenderConfig(enableTextSelection: false),
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: HtmlEmailView(html: html, config: config),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late Uint8List png;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    final bitmap = picture.toImageSync(120, 40);
    final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    png = bytes!.buffer.asUint8List();
    bitmap.dispose();
    picture.dispose();
  });

  testWidgets(
    'percentage image-only columns in a spaced table do not crash the row',
    (tester) async {
      // Image-only columns are "intrinsic" but their 50% width makes them
      // flex. With cellspacing the row takes the fallback path, which used to
      // lay out an all-"fixed" row unbounded and throw on the flex children.
      await _pump(
        tester,
        '<table width="100%" cellspacing="4" cellpadding="0"><tr>'
        '<td width="50%" align="right"><a href="https://example.com/a">'
        '<img src="https://example.com/a.png" alt="A"></a></td>'
        '<td width="50%"><a href="https://example.com/b">'
        '<img src="https://example.com/b.png" alt="B"></a></td>'
        '</tr></table>',
        config: HtmlRenderConfig(
          enableTextSelection: false,
          imageResolver: _Images(MemoryImage(png)),
        ),
      );
      expect(tester.takeException(), isNull);
      final images = find.byType(Image);
      expect(images, findsNWidgets(2));
      final left = tester.getRect(images.at(0));
      final right = tester.getRect(images.at(1));
      expect(left.right, lessThanOrEqualTo(375 / 2));
      expect(right.left, greaterThanOrEqualTo(375 / 2));
    },
  );

  testWidgets('block children of a display:table wrapper stack vertically', (
    tester,
  ) async {
    // CSS puts non-cell children of a table box into one anonymous cell.
    // Campaign Monitor wraps every section table in such a <center>; laying
    // each section out as its own column squeezed text to a few px per line.
    await _pump(
      tester,
      '<center style="display:table;width:100%">'
      '<table style="width:300px;margin:0 auto"><tr><td>First section</td></tr></table>'
      '<table style="width:300px;margin:0 auto"><tr><td>Second section</td></tr></table>'
      '<div>Footer text</div>'
      '</center>',
    );
    expect(tester.takeException(), isNull);
    final first = tester.getRect(find.textContaining('First section'));
    final second = tester.getRect(find.textContaining('Second section'));
    final footer = tester.getRect(find.textContaining('Footer text'));
    expect(second.top, greaterThanOrEqualTo(first.bottom));
    expect(footer.top, greaterThanOrEqualTo(second.bottom));
    expect(second.left, closeTo(first.left, 0.5));
    expect(first.left, closeTo((375 - 300) / 2, 4));
  });

  for (final spacing in [0, 4]) {
    testWidgets(
      'a percentage-width logo fills its share of an image-only column '
      '(cellspacing $spacing)',
      (tester) async {
        // EmailOctopus logos: `<img width="107" style="width:17%">` alone in
        // a centred cell. The column used to shrink-wrap the image, whose
        // percentage then resolved against itself (18px), or against zero
        // inside the spaced-row fallback (a NaN transform, nothing painted).
        await _pump(
          tester,
          '<table width="100%" cellspacing="$spacing" cellpadding="0"><tr>'
          '<td align="center"><a href="https://example.com">'
          '<img width="107" style="width:17%;max-width:100%;display:block" '
          'src="https://example.com/logo.png"></a></td></tr></table>',
          width: 680,
          config: HtmlRenderConfig(
            enableTextSelection: false,
            imageResolver: _Images(MemoryImage(png)),
          ),
        );
        expect(tester.takeException(), isNull);
        final logo = tester.getRect(find.byType(Image));
        final cellWidth = 680 - 2 * spacing;
        expect(logo.width, closeTo(cellWidth * 0.17, 1.5));
        expect(logo.center.dx, closeTo(340, 1.5));
      },
    );
  }

  testWidgets('desktop MJML percentage columns take their full share', (
    tester,
  ) async {
    // MJML's min-width:480px rule turns each `width:100%` column into
    // `width:33.33% !important`. The row allots 33.33% and the box used to
    // apply it again, leaving ~66px columns with one syllable per line.
    String column(String text) =>
        '<div class="mj-column-per-33" style="font-size:0px;display:inline-block;'
        'vertical-align:top;width:100%;"><table width="100%" cellpadding="0" '
        'cellspacing="0" role="presentation"><tr><td style="font-size:13px">'
        '$text</td></tr></table></div>';
    await _pump(
      tester,
      '<style>@media only screen and (min-width:480px){'
      '.mj-column-per-33{width:33.333% !important;max-width:33.333%}}</style>'
      '<div style="margin:0 auto;max-width:600px"><table width="100%" '
      'cellpadding="0" cellspacing="0"><tr><td style="font-size:0px">'
      '${column('First product')}${column('Second product')}'
      '${column('Third product')}</td></tr></table></div>',
      width: 680,
    );
    final first = tester.getRect(find.textContaining('First product'));
    final second = tester.getRect(find.textContaining('Second product'));
    final third = tester.getRect(find.textContaining('Third product'));
    expect(second.top, closeTo(first.top, 0.5));
    expect(third.top, closeTo(first.top, 0.5));
    expect(first.left, closeTo(40, 1));
    expect(second.left, closeTo(240, 1));
    expect(third.left, closeTo(440, 1));
  });

  for (final (align, left) in [
    ('left', 0.0),
    ('center', 170.0),
    ('right', 340.0),
  ]) {
    testWidgets('a lone width:50% inline-block keeps half the line ($align)', (
      tester,
    ) async {
      // Chrome: 340px of a 680px line, placed by text-align. The column box
      // fills the share a column row allots, so a lone one took the line.
      await _pump(
        tester,
        '<div style="text-align:$align;font-size:0">'
        '<div style="display:inline-block;width:50%;font-size:14px;'
        'text-align:left;background:#ff0000">Lone</div></div>',
        width: 680,
      );
      final box = tester
          .widgetList<Container>(find.byType(Container))
          .firstWhere(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration as BoxDecoration).color ==
                    const Color(0xffff0000),
          );
      final rect = tester.getRect(find.byWidget(box));
      expect(rect.width, closeTo(340, 1));
      expect(rect.left, closeTo(left, 1));
    });
  }

  testWidgets('percentage inline-blocks that overflow wrap to new lines', (
    tester,
  ) async {
    // Chrome at 400px: 60% + 60% -> one 240px column per line; 3 x 40% ->
    // two columns on the first line, the third alone on the next.
    String col(String text, String width) =>
        '<div style="display:inline-block;width:$width;font-size:14px">'
        '$text</div>';
    await _pump(
      tester,
      '<div style="font-size:0">${col('One', '60%')}${col('Two', '60%')}</div>'
      '<div style="font-size:0">${col('Aaa', '40%')}${col('Bbb', '40%')}'
      '${col('Ccc', '40%')}</div>',
      width: 400,
    );
    Rect at(String text) => tester.getRect(find.textContaining(text));
    // Text width is content-sized; check positions and that nothing is
    // laid out past the column share by measuring the column boxes' slots.
    expect(at('Two').top, greaterThan(at('One').top));
    expect(at('One').left, 0);
    expect(at('Two').left, 0);
    expect(at('Bbb').top, closeTo(at('Aaa').top, 0.5));
    expect(at('Bbb').left, closeTo(160, 1));
    expect(at('Ccc').top, greaterThan(at('Aaa').top));
    expect(at('Ccc').left, 0);
    final rows = tester.widgetList<Row>(find.byType(Row)).toList();
    final flexes = [
      for (final row in rows)
        for (final child in row.children)
          if (child is Flexible && child is! Spacer) child.flex,
    ];
    // Each 60% column sits in a 60/40 row of its own.
    expect(flexes.where((f) => f == 6000), hasLength(2));
  });

  for (final (align, alphaLeft) in [
    ('left', 0.0),
    ('center', 170.0),
    ('right', 340.0),
  ]) {
    testWidgets('a short percentage column run follows text-align:$align', (
      tester,
    ) async {
      // Two 25% columns stay 25% wide; the line's alignment places the
      // remaining half instead of the columns stretching to fill it.
      await _pump(
        tester,
        '<div style="text-align:$align;font-size:0">'
        '<div style="display:inline-block;width:25%;font-size:14px;'
        'text-align:left">Alpha</div>'
        '<div style="display:inline-block;width:25%;font-size:14px;'
        'text-align:left">Beta</div></div>',
        width: 680,
      );
      final alpha = tester.getRect(find.textContaining('Alpha'));
      final beta = tester.getRect(find.textContaining('Beta'));
      expect(alpha.left, closeTo(alphaLeft, 1));
      expect(beta.left, closeTo(alphaLeft + 170, 1));
    });
  }

  group('parent-child margin collapsing', () {
    Future<double> gap(WidgetTester tester, String html) async {
      await _pump(
        tester,
        '<div style="font-family:Arial;font-size:16px;line-height:20px">'
        '$html</div>',
      );
      final alpha = tester.getRect(find.textContaining('Alpha'));
      final bravo = tester.getRect(find.textContaining('Bravo'));
      return bravo.top - alpha.bottom;
    }

    testWidgets('paragraphs in sibling divs share one margin', (tester) async {
      expect(
        await gap(tester, '<div><p>Alpha</p></div><div><p>Bravo</p></div>'),
        closeTo(16, 0.5),
      );
    });

    testWidgets('the largest of nested margins wins', (tester) async {
      expect(
        await gap(
          tester,
          '<div style="margin-bottom:20px"><p style="margin:0 0 30px">Alpha</p>'
          '</div><p style="margin-top:10px">Bravo</p>',
        ),
        closeTo(30, 0.5),
      );
    });

    testWidgets('a deep div nest collapses one margin once', (tester) async {
      final open = '<div>' * 20;
      final close = '</div>' * 20;
      expect(
        await gap(
          tester,
          '<p style="margin:0">Alpha</p>'
          '$open<div style="margin:10px 0">$open<h3 style="margin:0">Bravo'
          '</h3>$close</div>$close',
        ),
        closeTo(10, 0.5),
      );
    });

    testWidgets('a nested empty block is one collapsed margin', (tester) async {
      // Chrome: max(16, 20, 30, 16) = 30, not 20 + 30.
      expect(
        await gap(
          tester,
          '<p style="margin:16px 0">Alpha</p><div><div style="margin:20px 0 '
          '30px"></div></div><p style="margin:16px 0">Bravo</p>',
        ),
        closeTo(30, 0.5),
      );
    });

    testWidgets('several nested empty blocks are one collapsed margin', (
      tester,
    ) async {
      // Chrome: max(16, 20, 30, 40, 50, 16) = 50.
      expect(
        await gap(
          tester,
          '<p style="margin:16px 0">Alpha</p><div>'
          '<div style="margin:20px 0 30px"></div>'
          '<div style="margin:40px 0 50px"></div></div>'
          '<p style="margin:16px 0">Bravo</p>',
        ),
        closeTo(50, 0.5),
      );
    });

    testWidgets('a deep empty nest is counted once', (tester) async {
      expect(
        await gap(
          tester,
          '<p style="margin:0">Alpha</p><div><div><div style="margin:10px 0">'
          '</div><div style="margin:35px 0 5px"></div></div>'
          '<div style="margin:25px 0"></div></div>'
          '<p style="margin:0">Bravo</p>',
        ),
        closeTo(35, 0.5),
      );
    });

    testWidgets('a nested block with padding still separates margins', (
      tester,
    ) async {
      expect(
        await gap(
          tester,
          '<p style="margin:0">Alpha</p><div><div style="margin:20px 0 30px;'
          'padding-top:1px"></div></div><p style="margin:0">Bravo</p>',
        ),
        closeTo(51, 0.5),
      );
    });

    for (final separator in [
      'padding-top:1px',
      'border-top:1px solid',
      'overflow:hidden',
    ]) {
      testWidgets('$separator keeps the child margin inside', (tester) async {
        expect(
          await gap(
            tester,
            '<p style="margin:0">Alpha</p>'
            '<div style="margin-top:10px;$separator"><p style="margin:16px 0">'
            'Bravo</p></div>',
          ),
          greaterThanOrEqualTo(26),
        );
      });
    }
  });

  testWidgets('padded fixed cells narrow to fit their declared table', (
    tester,
  ) async {
    // Two `width="300"` cells with 10px padding ask for 640px inside a
    // `width="600"` table; browsers keep the table at 600.
    await _pump(
      tester,
      '<table width="600" cellpadding="0" cellspacing="0"><tr>'
      '<td width="300" style="padding:10px">Left column text</td>'
      '<td width="300" style="padding:10px">Right column text</td>'
      '</tr></table>',
      width: 680,
    );
    final right = tester.getRect(find.textContaining('Right column'));
    expect(right.left, closeTo(310, 1.5));
    expect(tester.getSize(find.byType(Table)).width, closeTo(600, 0.5));
  });

  testWidgets('a widthless spaced table shrinks to content with its grid', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table border="1" cellspacing="2"><tr><td>cell one</td><td>cell two</td>'
      '</tr></table>',
      width: 680,
    );
    // The 680px line would stretch the second column far right.
    final two = tester.getRect(find.textContaining('cell two'));
    expect(two.right, lessThan(340));
    // The outer border and one per cell.
    final borders = tester.widgetList<Container>(find.byType(Container)).where((
      c,
    ) {
      final decoration = c.decoration;
      return decoration is BoxDecoration && decoration.border != null;
    });
    expect(borders.length, greaterThanOrEqualTo(3));
  });

  testWidgets('cells without cellpadding get the browser 1px padding', (
    tester,
  ) async {
    await _pump(
      tester,
      '<table cellspacing="0"><tr><td>Padded</td></tr></table>',
    );
    expect(
      tester.getRect(find.textContaining('Padded')).topLeft,
      const Offset(1, 1),
    );
  });

  testWidgets('a min-width display:table-cell beside floats does not crash', (
    tester,
  ) async {
    // Constant Contact footer: floated sign-up badges and a
    // `display:table-cell;min-width:150px` text cell share one cell. The
    // anonymous table row handed the cell an unbounded width.
    await _pump(
      tester,
      '<table width="100%" cellpadding="0" cellspacing="0"><tr>'
      '<td style="padding:10px" align="center">'
      '<table width="160" cellspacing="0" cellpadding="0" align="right"><tr>'
      '<td style="padding:8px" width="1%"><div align="center">Sign up</div>'
      '</td></tr></table>'
      '<table width="160" cellspacing="0" cellpadding="0" align="left"><tr>'
      '<td style="padding:8px" width="1%"><div align="center"></div></td>'
      '</tr></table>'
      '<div style="display:table-cell;min-width:150px;text-align:center">'
      '<div style="font-size:1.2em"><br></div>6506 Members 122 Clubs<br>'
      '</div></td></tr></table>',
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('6506 Members'), findsOneWidget);
  });

  testWidgets('fixed image columns shrink to fit a narrow 100% table', (
    tester,
  ) async {
    // Mailchimp product grid: three `width="181"` image cells in a
    // `width="100%"` collapsed table on a 375px screen. Chrome narrows the
    // columns and their `max-width:100%` images (~120px) rather than
    // pushing the row 170px past the screen edge.
    String cell(String name) =>
        '<td width="181"><img src="https://example.com/$name.png" '
        'style="width:180px;height:101px"></td>';
    await _pump(
      tester,
      '<table width="100%" style="border-collapse:collapse"><tr>'
      '${cell('a')}${cell('b')}${cell('c')}</tr></table>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    expect(tester.takeException(), isNull);
    final images = find.byType(Image);
    expect(images, findsNWidgets(3));
    final last = tester.getRect(images.at(2));
    expect(last.right, lessThanOrEqualTo(375.5));
    expect(tester.getRect(images.at(0)).width, closeTo(123, 3));
  });

  testWidgets('text after an align=left image table wraps beside it', (
    tester,
  ) async {
    // Constant Contact image+text block: the image table floats left inside
    // a bare <div>, and the next <div>'s text starts to its right.
    await _pump(
      tester,
      '<table width="100%" cellpadding="0" cellspacing="0"><tr>'
      '<td style="padding:10px 20px">'
      '<div><table align="left" cellpadding="0" cellspacing="0"><tr>'
      '<td><img src="https://example.com/p.png" width="120" height="40"></td>'
      '<td width="15"></td></tr></table></div>'
      '<div><div><b>Ofer Elhanani</b> is the recipient of a fellowship.</div>'
      '</div></td></tr></table>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    expect(tester.takeException(), isNull);
    final image = tester.getRect(find.byType(Image));
    final text = tester.getRect(find.textContaining('Ofer Elhanani'));
    expect(image.left, closeTo(20, 1));
    expect(text.left, greaterThanOrEqualTo(image.right + 10));
    expect(text.top, lessThan(image.bottom));
  });

  testWidgets('blocks wrap beside a float until they pass its bottom', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="font-size:16px;line-height:20px">'
      '<table align="left" cellpadding="0" cellspacing="0"><tr>'
      '<td><img src="https://example.com/p.png" width="120" height="50"></td>'
      '</tr></table>'
      '<p style="margin:0">First beside</p>'
      '<p style="margin:0">Second beside</p>'
      '<p style="margin:0">Third beside</p>'
      '<p style="margin:0">Fourth below</p></div>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    final image = tester.getRect(find.byType(Image));
    // Lines at y 0, 20, 40 start beside the 50px float; 60 is below it.
    for (final text in ['First beside', 'Second beside', 'Third beside']) {
      expect(
        tester.getRect(find.textContaining(text)).left,
        closeTo(image.right, 0.5),
        reason: text,
      );
    }
    expect(tester.getRect(find.textContaining('Fourth below')).left, 0);
  });

  testWidgets('an opacity:0 wrapper keeps hiding its floated table', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="opacity:0"><table align="left" cellpadding="0" '
      'cellspacing="0"><tr><td><img src="https://example.com/p.png" '
      'width="100" height="40"></td></tr></table></div><p>Text after</p>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.byType(Image), matching: find.byType(Opacity)),
    );
    expect(opacity.opacity, 0);
  });

  testWidgets('text that cannot fit beside a wide float goes under it', (
    tester,
  ) async {
    // Mailchimp RSS item: a 240px `float:right` image before the text in a
    // ~340px cell. The whole paragraph used to stay in the ~90px left beside
    // the image, breaking words ("De shna"); browsers put it under the image.
    await _pump(
      tester,
      '<div style="padding:0 18px;font-size:15px;line-height:150%">'
      '<div style="float:right;margin-left:10px"><img '
      'src="https://example.com/p.png" width="240" height="200"></div>'
      '7-year-old Deshna Aditya Nahar has quite the ability: she is small '
      'and flexible enough to rollerskate underneath cars, and set a new '
      'world record for the fastest time to limbo skate under twenty cars.'
      '</div>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    expect(tester.takeException(), isNull);
    final image = tester.getRect(find.byType(Image));
    final text = tester.getRect(find.textContaining('Deshna'));
    expect(image.right, closeTo(375 - 18, 1));
    expect(text.top, greaterThanOrEqualTo(image.bottom - 0.5));
    expect(text.left, closeTo(18, 0.5));
    expect(text.width, greaterThan(300));
  });

  testWidgets('text still wraps beside a narrow float', (tester) async {
    await _pump(
      tester,
      '<div><div style="float:left"><img src="https://example.com/p.png" '
      'width="80" height="60"></div>Short caption beside a small icon.</div>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    final image = tester.getRect(find.byType(Image));
    final text = tester.getRect(find.textContaining('Short caption'));
    expect(text.left, greaterThanOrEqualTo(image.right - 0.5));
    expect(text.top, lessThan(image.bottom));
  });

  group('long words', () {
    const url = 'https://www.extolecommunity.example/unsubscribe/link/token';

    for (final css in ['word-break:break-all', 'word-break:break-word']) {
      testWidgets('$css lets a shrink-to-fit cell break the word', (
        tester,
      ) async {
        // Chrome: these properties drop the word's min-content, so a
        // widthless (shrink-to-fit) table stays inside the screen.
        await _pump(
          tester,
          '<table align="center" cellpadding="0" cellspacing="0"><tr>'
          '<td style="$css;font-size:16px">$url</td></tr></table>',
        );
        expect(tester.takeException(), isNull);
        final text = tester.getRect(find.textContaining('extole'));
        expect(text.right, lessThanOrEqualTo(375.5));
        expect(text.left, greaterThanOrEqualTo(-0.5));
      });
    }

    testWidgets('overflow-wrap:break-word keeps the min-content word', (
      tester,
    ) async {
      // Browsers break it only at layout: a short word still sets the
      // column's minimum, so two such cells keep their words whole.
      await _pump(
        tester,
        '<table cellpadding="0" cellspacing="0"><tr>'
        '<td style="word-wrap:break-word;font-size:16px">Alpha</td>'
        '<td style="font-size:16px">Beta</td></tr></table>',
        width: 680,
      );
      final alpha = tester.getRect(find.textContaining('Alpha'));
      final beta = tester.getRect(find.textContaining('Beta'));
      expect(alpha.height, lessThan(30));
      expect(beta.left, greaterThanOrEqualTo(alpha.right - 0.5));
    });
  });

  testWidgets('a fixed 40|600|40 row narrows on a phone instead of scaling', (
    tester,
  ) async {
    // Kit (hbr.org): a widthless table of fixed cells with a colspan row
    // takes the row fallback. Scaling that 680px row into 375px shrank the
    // text to 55%; Chrome narrows the columns and rewraps at full size.
    await _pump(
      tester,
      '<table cellpadding="0" cellspacing="0" align="center"><tr>'
      '<td width="40"></td><td width="600" style="font-size:16px">'
      'Diversity and Inclusion is an increasingly popular term these past '
      'few years, especially in tech.</td><td width="40"></td></tr>'
      '<tr><td colspan="3" height="20"></td></tr></table>',
    );
    expect(tester.takeException(), isNull);
    final text = find.textContaining('Diversity');
    final painted = tester.getRect(text);
    final laidOut = tester.renderObject<RenderBox>(text).size;
    expect(painted.width, closeTo(laidOut.width, 0.5));
    expect(painted.right, lessThanOrEqualTo(375.5));
    expect(painted.left, greaterThan(10));
  });

  testWidgets('a fixed row that fits keeps its exact widths', (tester) async {
    await _pump(
      tester,
      '<table cellpadding="0" cellspacing="0"><tr>'
      '<td width="40"></td><td width="200">Narrow content</td>'
      '<td width="40"></td></tr><tr><td colspan="3">Footer</td></tr></table>',
    );
    expect(
      tester.getRect(find.textContaining('Narrow content')).left,
      closeTo(40, 0.5),
    );
  });

  testWidgets('a clear:both wrapper puts its float under the previous one', (
    tester,
  ) async {
    String float(String name) =>
        '<table align="left" cellpadding="0" cellspacing="0"><tr><td>'
        '<img src="https://example.com/$name.png" width="100" height="40">'
        '</td></tr></table>';
    await _pump(
      tester,
      '<div>${float('a')}</div><div style="clear:both">${float('b')}</div>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    final images = find.byType(Image);
    final first = tester.getRect(images.at(0));
    final second = tester.getRect(images.at(1));
    expect(second.top, greaterThanOrEqualTo(first.bottom - 0.5));
    expect(second.left, closeTo(first.left, 0.5));
  });

  testWidgets('clear:both keeps a block below an align=left table', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div><table align="left" cellpadding="0" cellspacing="0"><tr>'
      '<td><img src="https://example.com/p.png" width="120" height="40"></td>'
      '</tr></table></div>'
      '<div style="clear:both">Below the float</div>',
      config: HtmlRenderConfig(
        enableTextSelection: false,
        imageResolver: _Images(MemoryImage(png)),
      ),
    );
    final image = tester.getRect(find.byType(Image));
    final text = tester.getRect(find.textContaining('Below the float'));
    expect(text.top, greaterThanOrEqualTo(image.bottom - 0.5));
  });

  group('doctype line-height quirk', () {
    // Chrome (and Apple Mail) honour the author's doctype. XHTML 1.0
    // Transitional puts the page in limited-quirks mode, where a line of
    // `<span>` text no longer gets the block's taller strut (16px block,
    // 11px span, line-height 1.35: 21.6px in standards, 14.85px here).
    const transitional =
        '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" '
        '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">';
    const body =
        '<div style="font-size:16px;line-height:1.35">'
        '<span style="font-size:11px">Quirky</span></div>';

    Future<double> lineHeight(WidgetTester tester, String doctype) async {
      await _pump(tester, '$doctype<html><body>$body</body></html>');
      return tester.getSize(find.byType(RichText).first).height;
    }

    testWidgets('standards mode keeps the block strut', (tester) async {
      expect(await lineHeight(tester, '<!DOCTYPE html>'), closeTo(21.6, 0.6));
    });

    testWidgets('no doctype renders like standards (webmail)', (tester) async {
      expect(await lineHeight(tester, ''), closeTo(21.6, 0.6));
    });

    testWidgets('a Transitional doctype drops the strut', (tester) async {
      expect(await lineHeight(tester, transitional), closeTo(14.85, 0.6));
    });

    testWidgets('direct block text keeps its own height in quirks', (
      tester,
    ) async {
      await _pump(
        tester,
        '$transitional<html><body><div style="font-size:16px;'
        'line-height:1.35">Direct</div></body></html>',
      );
      expect(
        tester.getSize(find.byType(RichText).first).height,
        closeTo(21.6, 0.6),
      );
    });
  });

  group('table spacing from author CSS', () {
    // EmailOctopus and many templates reset spacing in a stylesheet
    // (`table{border-spacing:0;border-collapse:collapse}`) and leave the
    // inner tables without `cellspacing`; each nested table used to keep the
    // 2px UA spacing and squeeze the text.
    Future<double> textLeft(
      WidgetTester tester,
      String css,
      String attrs,
    ) async {
      await _pump(
        tester,
        '<style>$css</style>'
        '<table $attrs cellpadding="0"><tr><td>'
        '<table $attrs cellpadding="0"><tr><td>Nested</td></tr></table>'
        '</td></tr></table>',
        // A browser-like host (the library default is the email reset, 0).
        config: const HtmlRenderConfig(
          enableTextSelection: false,
          defaultTableCellSpacing: 2,
        ),
      );
      return tester.getRect(find.textContaining('Nested')).left;
    }

    testWidgets('no CSS keeps the 2px UA spacing per table', (tester) async {
      expect(await textLeft(tester, '', ''), closeTo(4, 0.5));
    });

    testWidgets('a stylesheet border-spacing:0 removes it', (tester) async {
      expect(
        await textLeft(tester, 'table{border-spacing:0}', ''),
        closeTo(0, 0.5),
      );
    });

    testWidgets('border-collapse:collapse removes it', (tester) async {
      expect(
        await textLeft(tester, 'table{border-collapse:collapse}', ''),
        closeTo(0, 0.5),
      );
    });

    testWidgets('author border-spacing beats the cellspacing hint', (
      tester,
    ) async {
      expect(
        await textLeft(tester, 'table{border-spacing:3px}', 'cellspacing="10"'),
        closeTo(6, 0.5),
      );
    });

    testWidgets('border-collapse ignores cellspacing', (tester) async {
      expect(
        await textLeft(
          tester,
          'table{border-collapse:collapse}',
          'cellspacing="10"',
        ),
        closeTo(0, 0.5),
      );
    });

    testWidgets('cellspacing still applies without author CSS', (tester) async {
      expect(await textLeft(tester, '', 'cellspacing="5"'), closeTo(10, 0.5));
    });
  });

  testWidgets('a centred auto-width display:table button keeps shrinking', (
    tester,
  ) async {
    await _pump(
      tester,
      '<div style="display:table;margin:0 auto">'
      '<a href="https://example.com" style="display:inline-block;padding:8px">Go</a>'
      '</div>',
    );
    final button = tester.getRect(find.textContaining('Go'));
    expect(button.center.dx, closeTo(375 / 2, 2));
  });
}
