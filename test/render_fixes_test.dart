import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_native_html/src/rendering/css_border_decoration.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(String html, {double? width, HtmlRenderConfig? config}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: HtmlEmailView(
                html: html,
                config: config ?? const HtmlRenderConfig(),
              ),
            ),
          ),
        ),
      ),
    );

TextSpan? _spanWithText(WidgetTester tester, String text) {
  TextSpan? found;
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    rt.text.visitChildren((span) {
      if (span is TextSpan && (span.text ?? '').contains(text)) found = span;
      return true;
    });
  }
  return found;
}

RichText? _richContaining(WidgetTester tester, String text) {
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    if (rt.text.toPlainText().contains(text)) return rt;
  }
  return null;
}

Border _decoratedBorder(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(find.byType(DecoratedBox))
    .map((box) => box.decoration)
    .whereType<BoxDecoration>()
    .map((decoration) => decoration.border)
    .whereType<Border>()
    .firstWhere(
      (border) =>
          border.top != BorderSide.none ||
          border.right != BorderSide.none ||
          border.bottom != BorderSide.none ||
          border.left != BorderSide.none,
    );

bool _isTiledBackground(Widget widget) =>
    widget.runtimeType.toString().contains('_TiledBackground');

void main() {
  testWidgets('empty inline elements do not add a line before a block CTA', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="400" cellspacing="0" cellpadding="0" '
        'style="border-collapse:collapse"><tbody><tr>'
        '<td style="padding:0;background:#fa1ed2">'
        '<em></em><span></span>'
        '<a style="display:block;font-size:18px;line-height:28px;'
        'padding:8px 16px;border:1px solid #fa1ed2;'
        'background:#fa1ed2">Watch now</a>'
        '</td></tr></tbody></table>',
        width: 400,
      ),
    );

    // The CTA is exactly its 28px line box + 16px vertical padding + 2px
    // border. Empty formatting nodes before it must not create another line.
    expect(
      tester.getSize(find.byType(HtmlEmailView)).height,
      closeTo(46, 0.01),
    );
    expect(_richContaining(tester, 'Watch now'), isNotNull);
  });

  testWidgets('meaningful empty-looking inline content is preserved', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XwL7WQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div><span></span>&nbsp;<br><img src="$png" width="1" height="1"></div>',
      ),
    );

    final rich = tester.widgetList<RichText>(find.byType(RichText)).toList();
    expect(rich.any((r) => r.text.toPlainText().contains('\u00a0\n')), isTrue);
    expect(
      rich.any((r) {
        var hasWidget = false;
        r.text.visitChildren((span) {
          if (span is WidgetSpan) hasWidget = true;
          return true;
        });
        return hasWidget;
      }),
      isTrue,
    );
  });

  testWidgets('fixed-height table cell centers its content vertically', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XwL7WQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table cellspacing="0" cellpadding="0"><tbody><tr>'
        '<td style="padding:0;width:118px;height:118px;background:#16161d;'
        'border-radius:16px;border:1px dashed #facdcd">'
        '<div style="max-width:56px;margin:0 auto">'
        '<img src="$png" width="56" height="56" '
        'style="display:block;margin:0 auto"></div>'
        '</td></tr></tbody></table>',
        width: 200,
      ),
    );

    final cellBox = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFF16161D),
        );
    final cellRect = tester.getRect(find.byWidget(cellBox));
    final imageRect = tester.getRect(find.byType(Image));
    expect(imageRect.center.dy, closeTo(cellRect.center.dy, 0.01));
  });

  testWidgets('fixed-height table cell still honors valign top', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table cellspacing="0" cellpadding="0"><tbody><tr>'
        '<td valign="top" style="padding:0;width:118px;height:118px">'
        '<div style="display:block;width:20px;height:20px;background:#f00"></div>'
        '</td></tr></tbody></table>',
      ),
    );

    final cellRect = tester.getRect(find.byType(TableCell));
    final marker = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFFFF0000),
        );
    expect(
      tester.getRect(find.byWidget(marker)).top,
      closeTo(cellRect.top, 0.01),
    );
  });

  testWidgets('dashed cell border uses patterned border decoration', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table cellspacing="0" cellpadding="0"><tbody><tr>'
        '<td style="width:118px;height:118px;border-radius:16px;'
        'border:1px dashed #facdcd">x</td>'
        '</tr></tbody></table>',
      ),
    );

    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere((c) => c.foregroundDecoration is CssBorderDecoration);
    final decoration = box.foregroundDecoration! as CssBorderDecoration;
    expect(decoration.borders.top!.style, CssBorderStyle.dashed);
  });

  testWidgets('empty block honors CSS height (logo divider)', (tester) async {
    await tester.pumpWidget(
      _host(
        '<span style="display:block;height:40px;background:#cccccc"></span>',
      ),
    );
    final size = tester.getSize(find.byType(HtmlEmailView));
    expect(size.height, 40);
  });

  testWidgets('cell inherits text-align:center from an ancestor (CSS)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="text-align:center">'
        '<table><tbody><tr><td>cell text</td></tr></tbody></table>'
        '</div>',
      ),
    );
    final rich = _richContaining(tester, 'cell text');
    expect(rich, isNotNull);
    expect(rich!.textAlign, TextAlign.center);
  });

  testWidgets('table text-align overrides the default th centering', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="text-align:left;width:300px"><thead><tr>'
        '<th style="width:24px;padding:16px 0 16px 16px">Status</th>'
        '<th style="width:100%;padding:16px">Job</th>'
        '<th style="white-space:nowrap;padding:16px 16px 16px 0">Annotations</th>'
        '</tr></thead><tbody><tr>'
        '<td style="padding:16px 0 16px 16px">x</td>'
        '<td style="width:100%;padding:16px">CI / verify</td>'
        '<td style="white-space:nowrap;padding:16px 16px 16px 0">2</td>'
        '</tr></tbody></table>',
        width: 400,
      ),
    );

    expect(_richContaining(tester, 'Status')!.textAlign, TextAlign.left);
    expect(_richContaining(tester, 'Job')!.textAlign, TextAlign.left);
    expect(_richContaining(tester, 'Annotations')!.textAlign, TextAlign.left);
    expect(
      tester.getTopLeft(find.textContaining('Job')).dx,
      closeTo(tester.getTopLeft(find.textContaining('CI / verify')).dx, 1),
    );
  });

  testWidgets('full-width block text does not widen fixed email tables', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:650px;border-collapse:collapse"><tr>'
        '<td style="padding:0 16px">'
        '<span style="display:block;width:100%;font-size:24px;line-height:28px">'
        'Dear customer, thank you for placing your order!'
        '</span>'
        '</td></tr></table>',
        width: 700,
      ),
    );

    final view = tester.getRect(find.byType(HtmlEmailView));
    final headline = tester.getRect(find.textContaining('thank you'));
    expect(headline.left, greaterThanOrEqualTo(view.left));
    expect(headline.right, lessThanOrEqualTo(view.right));
  });

  testWidgets('flex table columns use remaining width beside fixed siblings', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XwL7WQAAAABJRU5ErkJggg==';

    await tester.pumpWidget(
      _host(
        '<table style="width:650px;border-collapse:collapse"><tr>'
        '<td style="padding:0 16px">'
        '<table style="width:100%;border-collapse:collapse"><tr>'
        '<th style="width:160px;padding:0;vertical-align:top">'
        '<img src="$png" width="160" height="190" style="display:block;width:auto;max-width:160px">'
        '</th>'
        '<th style="padding:0 0 0 16px;vertical-align:top">'
        '<table style="width:100%;border-collapse:collapse"><tr><td>'
        '<span style="display:block;width:100%">'
        'Automatic coffee machine with a milk frother and slim housing'
        '</span>'
        '</td></tr><tr><td>'
        '<span style="display:block;width:100%">Price: UAH 15,999</span>'
        '</td></tr></table>'
        '</th>'
        '<th style="width:130px;padding:0 0 0 16px;vertical-align:top">'
        '<span style="display:inline-block;font-size:24px">15 999 ₴</span>'
        '</th>'
        '</tr></table>'
        '</td></tr></table>',
        width: 700,
      ),
    );

    final view = tester.getRect(find.byType(HtmlEmailView));
    final title = tester.getRect(
      find.textContaining('Automatic coffee machine'),
    );
    final total = tester.getRect(find.textContaining('15 999 ₴'));
    expect(title.right, lessThanOrEqualTo(total.left));
    expect(total.right, lessThanOrEqualTo(view.right));
  });

  testWidgets('th remains centered by default', (tester) async {
    await tester.pumpWidget(
      _host('<table><thead><tr><th>Header</th></tr></thead></table>'),
    );

    expect(_richContaining(tester, 'Header')!.textAlign, TextAlign.center);
  });

  testWidgets('a cell with its own align=center still centers', (tester) async {
    await tester.pumpWidget(
      _host(
        '<table><tbody><tr><td align="center">mid</td></tr></tbody></table>',
      ),
    );
    final rich = _richContaining(tester, 'mid');
    expect(rich!.textAlign, TextAlign.center);
  });

  testWidgets('CSS text-align overrides a cell align attribute', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table><tr><td align="center" style="text-align:left">left</td></tr></table>',
      ),
    );
    expect(_richContaining(tester, 'left')!.textAlign, TextAlign.left);
  });

  testWidgets('table align="center" positions the table, not the cell text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host('<table align="center"><tbody><tr><td>x</td></tr></tbody></table>'),
    );
    final rich = _richContaining(tester, 'x');
    // The table is centered as a box, but the cell text is not forced center.
    expect(rich!.textAlign, isNot(TextAlign.center));
  });

  testWidgets('receipt cell keeps padding and nested labels left aligned', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="400"><tr><td align="center" style="padding:25px 15%">'
        '<table width="100%" style="text-align:left"><tr>'
        '<td>Merchant</td><td style="text-align:right">Xsolla</td>'
        '</tr></table></td></tr></table>',
        width: 800,
      ),
    );
    expect(_richContaining(tester, 'Merchant')!.textAlign, TextAlign.left);
    expect(_richContaining(tester, 'Xsolla')!.textAlign, TextAlign.right);
    final table = tester.widget<Table>(find.byType(Table).first);
    final text = _richContaining(tester, 'Merchant')!;
    expect(
      tester.getTopLeft(find.byWidget(text)).dx -
          tester.getTopLeft(find.byWidget(table)).dx,
      closeTo(60, 3),
    );
  });

  testWidgets('fixed-width padded bullet cell does not overlap text (colspan '
      'fallback)', (tester) async {
    // A `width:10px` bullet cell with `padding-left:24px`, in a table made
    // irregular by a trailing `colspan` row (so it takes the Row fallback). The
    // bullet's border box must include its padding, or the dot overflows onto
    // the text. Assert the bullet ends before the text begins.
    await tester.pumpWidget(
      _host(
        '<table cellpadding="0"><tbody>'
        '<tr><td style="width:10px;padding:0 10px 0 24px;font-size:18px">&#8226;</td>'
        '<td style="padding:0 24px 0 0">Lorem ipsum dolor sit amet here</td></tr>'
        '<tr><td style="padding:0 10px 0 24px;font-size:18px">&#8226;</td>'
        '<td style="padding:0 24px 0 0">Second item without repeated width</td></tr>'
        '<tr><td colspan="2" style="height:20px"></td></tr>'
        '</tbody></table>',
        width: 600,
      ),
    );
    final bullet = _richContaining(tester, '•')!;
    final text = _richContaining(tester, 'Lorem')!;
    final bulletRight = tester.getBottomRight(find.byWidget(bullet)).dx;
    final textLeft = tester.getTopLeft(find.byWidget(text)).dx;
    expect(textLeft, greaterThanOrEqualTo(bulletRight));
    final secondBullet = _richContaining(tester, '•')!;
    final secondText = _richContaining(tester, 'Second item')!;
    expect(
      tester.getTopLeft(find.byWidget(secondText)).dx -
          tester.getBottomRight(find.byWidget(secondBullet)).dx,
      lessThan(40),
    );
  });

  testWidgets('leading whitespace at a block edge is trimmed', (tester) async {
    // Source indentation before a marker (`<td>\n    •</td>`) collapses to a
    // leading space; CSS strips whitespace at a block's edge. Without trimming,
    // that space + the bullet wrap onto a second line in a narrow cell, dropping
    // the dot a line below its text. The cell's text must start at the bullet.
    await tester.pumpWidget(
      _host(
        '<table cellpadding="0"><tbody>'
        '<tr><td style="width:10px;padding-left:24px;font-size:18px">\n'
        '          &#8226;</td><td>item</td></tr>'
        '<tr><td colspan="2"></td></tr>'
        '</tbody></table>',
        width: 400,
      ),
    );
    expect(_richContaining(tester, '•')!.text.toPlainText(), '•');
  });

  testWidgets('a non-breaking space at a block edge is preserved', (
    tester,
  ) async {
    // Only collapsible whitespace is stripped at the edge — `&nbsp;` stays.
    await tester.pumpWidget(_host('<p>&nbsp;keep</p>'));
    expect(_richContaining(tester, 'keep')!.text.toPlainText(), ' keep');
  });

  testWidgets('row background is applied to the TableRow', (tester) async {
    await tester.pumpWidget(
      _host(
        '<table><tbody>'
        '<tr style="background:#eeeeee"><td>h</td></tr>'
        '</tbody></table>',
      ),
    );
    final table = tester.widget<Table>(find.byType(Table));
    final decoration = table.children.first.decoration as BoxDecoration?;
    expect(decoration?.color, const Color(0xFFEEEEEE));
  });

  testWidgets('narrow width= cell is not clamped (no char-wrap squish)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table><tbody><tr>'
        '<td>Date</td><td>Description</td>'
        '<td width="20" align="right">Amount Paid</td>'
        '</tr></tbody></table>',
      ),
    );
    // The amount column should grow to fit "Amount Paid" on one line, so its
    // rendered RichText is far wider than the 20px hint.
    final rich = _richContaining(tester, 'Amount Paid');
    expect(rich, isNotNull);
    expect(tester.getSize(find.byWidget(rich!)).width, greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a non-breaking-space block keeps its line-box height', (
    tester,
  ) async {
    // `<div>&nbsp;</div>` is a visible spacer bar (the nbsp is significant, not
    // collapsible whitespace) — it must not collapse to zero height. (Binance
    // footer gray divider.)
    await tester.pumpWidget(
      _host('<div style="background-color:#efefef">&nbsp;</div>', width: 400),
    );
    final box = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          ((w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).color ==
                      const Color(0xFFEFEFEF)) ||
              w.color == const Color(0xFFEFEFEF)),
    );
    expect(box, findsWidgets);
    expect(tester.getSize(box.first).height, greaterThan(8));
  });

  testWidgets('max-width block fills its container, not shrinks to content', (
    tester,
  ) async {
    // A `max-width` block (no explicit width) fills up to that width like any
    // block, rather than collapsing to its content — Binance's white spacer
    // bar (`<div style="max-width:600px">&nbsp;</div>`).
    await tester.pumpWidget(
      _host(
        '<div style="background-color:#abcdef;max-width:600px;margin:0 auto">'
        '&nbsp;</div>',
        width: 1000,
      ),
    );
    final box = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFFABCDEF),
    );
    expect(box, findsWidgets);
    expect(tester.getSize(box.first).width, closeTo(600, 1));
  });

  testWidgets('percent-width inline-block columns lay out side by side', (
    tester,
  ) async {
    // MJML `mj-column-per-50` pattern: width:100% capped by max-width:50% —
    // the effective 50% columns sit side by side, not stacked.
    await tester.pumpWidget(
      _host(
        '<div>'
        '<div style="display:inline-block;width:100%;max-width:50%">L col</div>'
        '<div style="display:inline-block;width:100%;max-width:50%">R col</div>'
        '</div>',
        width: 600,
      ),
    );
    final l = find.byWidget(_richContaining(tester, 'L col')!);
    final r = find.byWidget(_richContaining(tester, 'R col')!);
    expect(tester.getTopLeft(l).dy, closeTo(tester.getTopLeft(r).dy, 2));
    expect(tester.getTopLeft(r).dx, greaterThan(tester.getTopLeft(l).dx));
  });

  testWidgets('direction:rtl reverses the column order', (tester) async {
    // With direction:rtl, the first column in source goes on the right (the
    // email trick for an image-first source rendering image-on-right).
    await tester.pumpWidget(
      _host(
        '<div style="direction:rtl">'
        '<div style="display:inline-block;width:50%;direction:ltr">first</div>'
        '<div style="display:inline-block;width:50%;direction:ltr">second</div>'
        '</div>',
        width: 600,
      ),
    );
    final f = find.byWidget(_richContaining(tester, 'first')!);
    final s = find.byWidget(_richContaining(tester, 'second')!);
    expect(tester.getTopLeft(f).dy, closeTo(tester.getTopLeft(s).dy, 2));
    expect(tester.getTopLeft(f).dx, greaterThan(tester.getTopLeft(s).dx));
  });

  testWidgets('full-width inline-block columns stack (do not row)', (
    tester,
  ) async {
    // Two width:100% columns (mobile layout) must stack, not squeeze into a row.
    await tester.pumpWidget(
      _host(
        '<div>'
        '<div style="display:inline-block;width:100%">top</div>'
        '<div style="display:inline-block;width:100%">bottom</div>'
        '</div>',
        width: 600,
      ),
    );
    final t = find.byWidget(_richContaining(tester, 'top')!);
    final b = find.byWidget(_richContaining(tester, 'bottom')!);
    expect(tester.getTopLeft(b).dy, greaterThan(tester.getTopLeft(t).dy + 5));
  });

  testWidgets('inline-table elements flow horizontally, not stacked', (
    tester,
  ) async {
    // `display:inline-table` (e.g. a row of social-icon tables) must lay out
    // side by side, not as block tables stacked vertically.
    await tester.pumpWidget(
      _host(
        '<div>'
        '<table style="display:inline-table"><tbody><tr><td>A</td></tr></tbody></table>'
        '<table style="display:inline-table"><tbody><tr><td>B</td></tr></tbody></table>'
        '</div>',
        width: 400,
      ),
    );
    final a = find.byWidget(_richContaining(tester, 'A')!);
    final b = find.byWidget(_richContaining(tester, 'B')!);
    expect(tester.getTopLeft(a).dy, closeTo(tester.getTopLeft(b).dy, 2));
    expect(tester.getTopLeft(b).dx, greaterThan(tester.getTopLeft(a).dx));
  });

  testWidgets('display:table div lays block icon children in one row', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<div style="display:table;width:100%">'
        '<div style="text-align:center"><img width="44" src="$png"></div>'
        '<div style="width:15px"></div>'
        '<div style="text-align:left"><img width="44" src="$png"></div>'
        '<div style="width:15px"></div>'
        '<div style="text-align:left"><img width="44" src="$png"></div>'
        '</div>',
        width: 400,
      ),
    );
    final images = find.byType(Image);
    expect(images, findsNWidgets(3));
    final imageWidgets = images.evaluate().map((e) => find.byWidget(e.widget));
    final rects = imageWidgets.map(tester.getRect).toList();
    expect(rects[1].top, closeTo(rects[0].top, 1));
    expect(rects[2].top, closeTo(rects[0].top, 1));
    expect(rects[1].left, greaterThan(rects[0].right));
    expect(rects[2].left, greaterThan(rects[1].right));
  });

  testWidgets('display:table row follows the box alignment, not always center', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    String html(String style) =>
        '<div style="display:table;width:100%;$style">'
        '<div style="width:40px"><img width="40" src="$png"></div>'
        '<div style="width:40px"><img width="40" src="$png"></div>'
        '</div>';

    // Default: cells left-pack (CSS behaviour), so the first icon sits at the
    // box's left edge.
    await tester.pumpWidget(_host(html(''), width: 400));
    final defaultLeft = tester.getRect(find.byType(Image).first).left;

    // text-align:center clusters them in the middle, pushing the first icon in.
    await tester.pumpWidget(_host(html('text-align:center'), width: 400));
    final centeredLeft = tester.getRect(find.byType(Image).first).left;

    expect(centeredLeft, greaterThan(defaultLeft + 50));
  });

  testWidgets('display:table distributes percent-width cells across the width', (
    tester,
  ) async {
    // The Lovable social-icon footer: a `display:table;width:100%` box whose
    // `display:table-cell;width:20%` cells must spread evenly across the full
    // width (each cell flexes to its percentage) rather than packing to content
    // at the left. Here two 50% cells, each holding a left-aligned icon, put the
    // second icon at the box's midpoint — not snug against the first.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<div style="display:table;width:100%">'
        '<div style="display:table-cell;width:50%;text-align:left">'
        '<img width="40" src="$png"></div>'
        '<div style="display:table-cell;width:50%;text-align:left">'
        '<img width="40" src="$png"></div>'
        '</div>',
        width: 400,
      ),
    );
    final rects = find
        .byType(Image)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .toList();
    expect(rects, hasLength(2));
    // Cell 0 expanded to ~50% (≈200px), so the second icon starts near the
    // midpoint — far past where content-packing (~40px) would leave it.
    expect(rects[1].left - rects[0].left, greaterThan(150));
  });

  testWidgets('display:table over-specified columns scale to fit', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="display:table;width:100%">'
        '<div style="display:table-cell;width:20%;height:12px;background:#111111">&nbsp;</div>'
        '<div style="display:table-cell;width:15px;height:12px;background:#222222">&nbsp;</div>'
        '<div style="display:table-cell;width:20%;height:12px;background:#333333">&nbsp;</div>'
        '<div style="display:table-cell;width:15px;height:12px;background:#444444">&nbsp;</div>'
        '<div style="display:table-cell;width:20%;height:12px;background:#555555">&nbsp;</div>'
        '<div style="display:table-cell;width:15px;height:12px;background:#666666">&nbsp;</div>'
        '<div style="display:table-cell;width:20%;height:12px;background:#777777">&nbsp;</div>'
        '<div style="display:table-cell;width:15px;height:12px;background:#888888">&nbsp;</div>'
        '<div style="display:table-cell;width:20%;height:12px;background:#999999">&nbsp;</div>'
        '</div>',
        width: 300,
      ),
    );

    Finder box(Color color) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == color,
    );

    final colors = [
      const Color(0xFF111111),
      const Color(0xFF222222),
      const Color(0xFF333333),
      const Color(0xFF444444),
      const Color(0xFF555555),
      const Color(0xFF666666),
      const Color(0xFF777777),
      const Color(0xFF888888),
      const Color(0xFF999999),
    ];
    final rects = [for (final color in colors) tester.getRect(box(color))];
    final view = tester.getRect(find.byType(HtmlEmailView));
    final totalWidth = rects.fold<double>(0, (sum, rect) => sum + rect.width);

    expect(rects.last.right, lessThanOrEqualTo(view.right + 0.01));
    expect(totalWidth, lessThanOrEqualTo(view.width + 0.01));
  });

  testWidgets('display:table exact-fit percent cells keep their widths', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="display:table;width:100%">'
        '<div style="display:table-cell;width:50%;height:12px;background:#123456">&nbsp;</div>'
        '<div style="display:table-cell;width:50%;height:12px;background:#abcdef">&nbsp;</div>'
        '</div>',
        width: 400,
      ),
    );

    Finder box(Color color) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == color,
    );

    expect(tester.getSize(box(const Color(0xFF123456))).width, closeTo(200, 1));
    expect(tester.getSize(box(const Color(0xFFABCDEF))).width, closeTo(200, 1));
  });

  testWidgets('display:table scaled columns still share equal height', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="display:table;width:100%">'
        '<div style="display:table-cell;width:80%;height:48px;background:#334455">&nbsp;</div>'
        '<div style="display:table-cell;width:80%;height:12px;background:#556677">&nbsp;</div>'
        '</div>',
        width: 240,
      ),
    );

    Finder box(Color color) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == color,
    );

    final tall = tester.getRect(box(const Color(0xFF334455)));
    final short = tester.getRect(box(const Color(0xFF556677)));
    expect(tall.height, closeTo(short.height, 0.01));
    expect(tall.height, greaterThan(40));
  });

  testWidgets('stylesheet table width bounds inline-block percent tables', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<style>'
        '.email-body_inner{width:570px;margin:0 auto}'
        '.card{padding:6px 8px;text-align:center;border:1px solid #dedfe2}'
        '</style>'
        '<table width="100%" cellpadding="0" cellspacing="0"><tr>'
        '<td align="center">'
        '<table class="email-body_inner" width="1000" cellpadding="0" cellspacing="0">'
        '<tr><td>'
        '<main style="display:inline-block;max-width:800px;background:#eeeeee">'
        '<div style="display:inline-block;width:100%;max-width:100%">'
        '<table align="left" width="33.3%" cellpadding="10" cellspacing="5" '
        'style="height:120px"><tr><td class="card" style="background:#111111">'
        '<a>0</a><p style="margin:0">New Events</p>'
        '</td></tr></table>'
        '<table align="left" width="33.3%" cellpadding="10" cellspacing="5" '
        'style="height:120px"><tr><td class="card" style="background:#222222">'
        '<a>0</a><p style="margin:0">Volume Anomalies</p>'
        '</td></tr></table>'
        '<table align="right" width="33.3%" cellpadding="10" cellspacing="5" '
        'style="height:120px"><tr><td class="card" style="background:#333333">'
        '<a>19</a><p style="margin:0">Events with Property Issues</p>'
        '</td></tr></table>'
        '</div>'
        '</main>'
        '</td></tr></table>'
        '</td></tr></table>',
        width: 1000,
      ),
    );

    Finder box(Color color) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == color,
    );

    final mainRect = tester.getRect(box(const Color(0xFFEEEEEE)));
    final cardRects = [
      tester.getRect(box(const Color(0xFF111111))),
      tester.getRect(box(const Color(0xFF222222))),
      tester.getRect(box(const Color(0xFF333333))),
    ];

    expect(mainRect.width, lessThanOrEqualTo(570.01));
    expect(cardRects[0].top, closeTo(cardRects[1].top, 0.01));
    expect(cardRects[1].top, closeTo(cardRects[2].top, 0.01));
    expect(cardRects.last.right, lessThanOrEqualTo(mainRect.right + 0.01));
  });

  testWidgets('fixed-width table grows to fit content (not clamped)', (
    tester,
  ) async {
    // A table/cell `width` is a minimum: content (here wide text in a 20px
    // cell) grows the table instead of being squeezed — Binance social icons.
    await tester.pumpWidget(
      _host(
        '<table style="width:20px"><tbody><tr>'
        '<td style="width:20px">WIDETEXT</td></tr></tbody></table>',
        width: 400,
      ),
    );
    expect(tester.getSize(find.byType(Table)).width, greaterThan(40));
  });

  testWidgets('fixed-width table keeps its width and is not stretched', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:600px;margin:0 auto;background:#cccccc">'
        '<tbody><tr><td>x</td></tr></tbody></table>',
        width: 1000,
      ),
    );
    // The table must stay 600px wide instead of filling the 1000px host.
    expect(tester.getSize(find.byType(Table)).width, 600);
  });

  testWidgets('text-decoration:none removes the link underline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<a href="https://x.test" style="text-decoration:none">Contacts</a>',
      ),
    );
    TextSpan? found;
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      rt.text.visitChildren((span) {
        if (span is TextSpan && (span.text ?? '').contains('Contacts')) {
          found = span;
        }
        return true;
      });
    }
    expect(found, isNotNull);
    expect(found!.style?.decoration, TextDecoration.none);
  });

  testWidgets('block link inside <a> shows a click cursor on hover', (
    tester,
  ) async {
    final config = HtmlRenderConfig(onLinkTap: (url, _) {});
    await tester.pumpWidget(
      _host(
        '<a href="https://x.test"><p>News and Updates</p></a>',
        config: config,
      ),
    );
    final region = tester
        .widgetList<MouseRegion>(find.byType(MouseRegion))
        .where((m) => m.cursor == SystemMouseCursors.click);
    expect(
      region,
      isNotEmpty,
      reason: 'a block link needs a hand cursor like inline links',
    );
  });

  testWidgets('inline small line-height does not collapse the block line box', (
    tester,
  ) async {
    // A link with `line-height:12px` inside a `line-height:1.6em` paragraph
    // must keep the block's line-height as the floor (CSS strut), so the
    // spacing above/below stays — Apple's "View ..." link rows.
    await tester.pumpWidget(
      _host(
        '<p style="font-size:17px;line-height:1.6em;margin:0">'
        '<a href="https://x.test" style="line-height:12px">View App Store Connect</a>'
        '</p>',
        width: 400,
        config: HtmlRenderConfig(onLinkTap: (url, _) {}),
      ),
    );
    final rt = _richContaining(tester, 'View App Store Connect')!;
    // ~1.6 * 17 = 27px, not the link's 12px.
    expect(tester.getSize(find.byWidget(rt)).height, greaterThan(24));
  });

  testWidgets('an image-only link is tappable (click cursor)', (tester) async {
    // `<a href><img></a>` (a social icon) must be tappable — the recognizer
    // can't attach to an image span, so it gets a tap+cursor wrapper.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<a href="https://x.test"><img src="$png" width="12" height="12" alt="ic"></a>',
        width: 400,
        config: HtmlRenderConfig(onLinkTap: (url, _) {}),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final img = find.byWidgetPredicate((w) => w is Image && w.width == 12);
    final el = tester.element(img);
    var clickable = false;
    el.visitAncestorElements((a) {
      if (a.widget is MouseRegion &&
          (a.widget as MouseRegion).cursor == SystemMouseCursors.click) {
        clickable = true;
      }
      return !clickable;
    });
    expect(clickable, isTrue);
  });

  testWidgets('font-size:0 collapses line metrics so an icon button is round', (
    tester,
  ) async {
    // A round icon button (social-icon footer): the cell sets `font-size:0` so
    // the line box hugs the icon instead of sitting in a ~20px default-font
    // line, which would make the padded box a tall pill. We render the rich text
    // with a 0 base font so the empty-line metrics collapse; the icon (a
    // WidgetSpan) still defines the line's height. Assert that mechanism — the
    // icon-bearing rich text uses a 0 base font.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAwAAAAMCAYAAABWdVznAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAsSURBVChTlcixDQAgAASh339pHYDEiwUN23Y+EYUoRCEKUYhCFKIQhSjE0wXvUY9xLTP9qwAAAABJRU5ErkJggg==';
    final html =
        '<table style="background:#bdc1c6;border-radius:50px;width:12px"><tbody>'
        '<tr><td style="padding:8px;font-size:0;width:12px">'
        '<img src="$png" width="12" height="12" alt=""></td></tr></tbody></table>';
    await tester.runAsync(() async {
      await tester.pumpWidget(_host(html, width: 400));
      // Let the MemoryImage decode so the icon's WidgetSpan gets its 12px size.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();

    // Mechanism: the icon-bearing rich text (a WidgetSpan, no text runs) carries
    // a ~1px base font, collapsing the empty-line metrics.
    final iconRich = tester.widgetList<RichText>(find.byType(RichText)).where((
      rt,
    ) {
      var hasWidget = false;
      rt.text.visitChildren((s) {
        if (s is WidgetSpan) hasWidget = true;
        return true;
      });
      return hasWidget;
    });
    expect(iconRich, isNotEmpty);
    expect(iconRich.first.text.style?.fontSize, 1);

    // Result: the padded box hugs the 12px icon (~12 + 8*2 = 28 square — a
    // circle), instead of a taller pill from a default ~20px line.
    final box = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFFBDC1C6),
    );
    final s = tester.getSize(box.first);
    expect(s.height, closeTo(28, 2));
    expect(s.height, closeTo(s.width, 1));
  });

  testWidgets('inline-block icon-only <a> button is square (round)', (
    tester,
  ) async {
    // A Substack like/comment/share button: a single icon image in an
    // inline-block <a> with width:38px, vertical padding and border-radius:9999.
    // A block image has no inline baseline gap, keeping the padded box square.
    // An inline image legitimately includes the text descent below its bottom.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<a style="display:inline-block;border:1px solid rgb(0,0,0,.1);'
        'border-radius:9999px;padding:9px 0;width:38px;box-sizing:border-box;'
        'font-size:12px;line-height:1"><img style="display:block" width="18" height="18" src="$png"></a>',
        width: 600,
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).border != null,
        );
    final s = tester.getSize(find.byWidget(box));
    expect(s.width, 38);
    expect(
      s.height,
      closeTo(s.width, 1),
    ); // square -> the radius makes a circle
  });

  testWidgets('inline span padding contributes to inline-block button width', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<a style="display:inline-block;background:#735aff;border-radius:8px;'
        'color:#fff;text-decoration:none;font-size:15px;font-weight:bold">'
        '<span style="padding:0 24px;line-height:44px">Review Document</span>'
        '</a>',
        width: 400,
      ),
    );

    final label = _richContaining(tester, 'Review Document')!;
    final button = tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => find.byWidget(container))
        .firstWhere((finder) {
          final widget = tester.widget<Container>(finder);
          return widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  const Color(0xff735aff);
        });

    final paragraph = tester.renderObject<RenderParagraph>(
      find.byWidget(label),
    );
    final start = paragraph.text.toPlainText().indexOf('Review Document');
    final ink = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 15),
    );
    expect(ink, hasLength(1));
    expect(
      tester.getSize(button).width - ink.single.toRect().width,
      greaterThan(44),
    );
    expect(tester.getSize(button).height, closeTo(44, 1));
  });

  testWidgets('a fixed-width content table keeps its width on a wide screen', (
    tester,
  ) async {
    // A classic 775px email panel full of text must stay 775 (centered) on a
    // wide window — not balloon to the unwrapped text width / fill the viewport.
    // (The fixed-width column grows only to min-content, not max-content.)
    await tester.pumpWidget(
      _host(
        '<table width="775"><tbody><tr>'
        '<td style="width:775px;background:#212429">'
        '<p style="color:#fff">Mini Motorways is a strategy simulation game '
        'about designing the road map for a growing city. Build a traffic '
        'network, one road at a time, to create a bustling metropolis.</p>'
        '</td></tr></tbody></table>',
        width: 1200,
      ),
    );
    await tester.pump();
    final panel = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFF212429),
    );
    expect(tester.getSize(panel.first).width, closeTo(775, 1));
  });

  testWidgets(
    'an image wider than its container shrinks to fit (max-width:100%)',
    (tester) async {
      // The near-universal email `img { max-width: 100% }`: a 600px image in a
      // 300px container scales down to 300, keeping its aspect ratio (height
      // 100 -> 50), instead of overflowing.
      const png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      await tester.pumpWidget(
        _host(
          '<table width="100%" cellpadding="0"><tbody><tr><td>'
          '<img src="$png" width="600" height="100" alt="">'
          '</td></tr></tbody></table>',
          width: 300,
        ),
      );
      await tester.pump();
      final img = find.byType(Image);
      final s = tester.getSize(img.first);
      expect(s.width, closeTo(300, 1));
      expect(s.height, closeTo(50, 1)); // aspect ratio preserved
    },
  );

  testWidgets('explicit image width:100% grows past its width attribute', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div style="max-width:200px;margin:0 auto">'
        '<img src="$png" alt="profile" width="112" height="112" '
        'style="display:block;width:100%;height:auto">'
        '</div>',
        width: 300,
      ),
    );
    await tester.pump();
    final image = tester
        .widgetList<Image>(find.byType(Image))
        .singleWhere((widget) => widget.semanticLabel == 'profile');
    expect(tester.getSize(find.byWidget(image)), const Size(200, 200));
  });

  testWidgets(
    'full-width profile table gives its image column the capped width',
    (tester) async {
      const png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      await tester.pumpWidget(
        _host(
          '<table width="100%" style="max-width:200px;margin:0 auto;'
          'background-color:#FA1ED2;border-radius:200px"><tbody><tr>'
          '<td style="padding:4px"><div style="max-width:200px;margin:0 auto">'
          '<img src="$png" alt="profile" width="112" height="112" '
          'style="display:block;width:100%;height:auto;margin:0 auto;'
          'border-radius:200px">'
          '</div></td></tr></tbody></table>',
          width: 450,
        ),
      );
      await tester.pump();

      final image = tester
          .widgetList<Image>(find.byType(Image))
          .singleWhere((widget) => widget.semanticLabel == 'profile');
      expect(tester.getSize(find.byWidget(image)), const Size(192, 192));
      final background = tester
          .widgetList<Container>(find.byType(Container))
          .singleWhere(
            (container) =>
                container.decoration is BoxDecoration &&
                (container.decoration as BoxDecoration).color ==
                    const Color(0xFFFA1ED2),
          );
      expect(tester.getSize(find.byWidget(background)), const Size(200, 200));
    },
  );

  testWidgets('a button cell is tappable across its padding, not just the icon', (
    tester,
  ) async {
    // A social-icon/button cell: the link only wraps a small icon, but the user
    // aims at the whole padded box (the gray circle). Tapping the padding ring —
    // outside the icon — must still navigate.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAwAAAAMCAYAAABWdVznAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAsSURBVChTlcixDQAgAASh339pHYDEiwUN23Y+EYUoRCEKUYhCFKIQhSjE0wXvUY9xLTP9qwAAAABJRU5ErkJggg==';
    String? tapped;
    await tester.pumpWidget(
      _host(
        '<table style="background:#bdc1c6;border-radius:50px;width:12px"><tbody>'
        '<tr><td style="padding:8px;font-size:0;width:12px">'
        '<a href="https://x.test/social"><img src="$png" width="12" height="12" '
        'alt=""></a></td></tr></tbody></table>',
        width: 400,
        config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final box = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFFBDC1C6),
    );
    final rect = tester.getRect(box.first);
    // 3px in from the top edge — inside the gray ring, outside the centred icon.
    await tester.tapAt(Offset(rect.center.dx, rect.top + 3));
    await tester.pump();
    expect(tapped, 'https://x.test/social');
  });

  testWidgets('inline text link carries a click cursor', (tester) async {
    final config = HtmlRenderConfig(onLinkTap: (url, _) {});
    await tester.pumpWidget(
      _host(
        '<p><a href="https://x.test">View your account</a></p>',
        config: config,
      ),
    );
    final span = _spanWithText(tester, 'View your account')!;
    expect(span.mouseCursor, SystemMouseCursors.click);
  });

  testWidgets('link colour wins over p{color} for a block inside the link', (
    tester,
  ) async {
    // A `<p>` inside an `<a>` shows the link colour, not the generic
    // `p{color:#666}` rule (Apple's "News and Updates" icon links).
    await tester.pumpWidget(
      _host(
        '<html><head><style>p{color:#666666}</style></head><body>'
        '<a href="https://x.test" style="color:#0088cc">'
        '<p>News and Updates</p></a></body></html>',
      ),
    );
    final span = _spanWithText(tester, 'News and Updates')!;
    expect(span.style?.color, const Color(0xFF0088CC));
  });

  testWidgets('a descendant inline colour still beats the link colour', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<a href="https://x.test" style="color:#0088cc">'
        '<span style="color:#ff0000">Red</span></a>',
      ),
    );
    final span = _spanWithText(tester, 'Red')!;
    expect(span.style?.color, const Color(0xFFFF0000));
  });

  testWidgets('text-transform:uppercase uppercases inherited text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="text-transform:uppercase"><a href="x">Contacts</a></div>',
      ),
    );
    final rich = _richContaining(tester, 'CONTACTS');
    expect(rich, isNotNull);
    expect(_richContaining(tester, 'Contacts'), isNull);
  });

  testWidgets('bare email with no link CSS is a blue underlined link', (
    tester,
  ) async {
    String? tapped;
    await tester.pumpWidget(
      _host(
        '<span style="color:#888888">DEMO.READER@EXAMPLE.COM</span>',
        config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
      ),
    );
    final span = _spanWithText(tester, 'DEMO.READER@EXAMPLE.COM');
    expect(span, isNotNull);
    // No author <a> CSS -> Gmail default: blue + underlined, tappable.
    expect(span!.style?.color, const Color(0xFF1155CC));
    expect(span.style?.decoration, TextDecoration.underline);
    expect(span.recognizer, isNotNull);
    (span.recognizer as dynamic).onTap();
    expect(tapped, 'mailto:DEMO.READER@EXAMPLE.COM');
  });

  testWidgets('bare domain (example.com) is auto-linked', (tester) async {
    String? tapped;
    await tester.pumpWidget(
      _host(
        '<span>Read more at example.com. Please wait</span>',
        config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
      ),
    );
    final span = _spanWithText(tester, 'example.com');
    expect(span, isNotNull);
    expect(span!.style?.color, const Color(0xFF1155CC));
    expect(span.style?.decoration, TextDecoration.underline);
    expect(span.recognizer, isNotNull);
    (span.recognizer as dynamic).onTap();
    expect(tapped, 'https://example.com');
  });

  testWidgets('autoLinkColor opts into Gmail-style colored, underlined links', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<span style="color:#888888">DEMO.READER@EXAMPLE.COM</span>',
        config: const HtmlRenderConfig(autoLinkColor: Color(0xFF1155CC)),
      ),
    );
    final span = _spanWithText(tester, 'DEMO.READER@EXAMPLE.COM');
    expect(span!.style?.color, const Color(0xFF1155CC));
    expect(span.style?.decoration, TextDecoration.underline);
  });

  testWidgets('pointer-events:none exposes a suppressed email as a real link', (
    tester,
  ) async {
    String? tapped;
    await tester.pumpWidget(
      _host(
        '<span style="pointer-events:none;text-decoration:none;color:#888888">'
        'DEMO.READER@EXAMPLE.COM</span>',
        config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
      ),
    );
    final span = _spanWithText(tester, 'DEMO.READER@EXAMPLE.COM');
    expect(span, isNotNull);
    // The sender tried to hide the link; we override to the Gmail link look.
    expect(span!.style?.color, const Color(0xFF1155CC));
    expect(span.style?.decoration, TextDecoration.underline);
    expect(span.recognizer, isNotNull);
    (span.recognizer as dynamic).onTap();
    expect(tapped, 'mailto:DEMO.READER@EXAMPLE.COM');
  });

  testWidgets(
    'author a{color} colors an auto-linked email like the email does',
    (tester) async {
      String? tapped;
      await tester.pumpWidget(
        _host(
          '<html><head><style>a {color: #1a73e8;}</style></head><body>'
          '<p style="color:#424242">inviter@example.com invited you</p>'
          '</body></html>',
          config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
        ),
      );
      final span = _spanWithText(tester, 'inviter@example.com');
      expect(span, isNotNull);
      expect(span!.style?.color, const Color(0xFF1A73E8));
      expect(span.style?.decoration, TextDecoration.underline);
      expect(span.recognizer, isNotNull);
      (span.recognizer as dynamic).onTap();
      expect(tapped, 'mailto:inviter@example.com');
    },
  );

  testWidgets('author a link-reset keeps an auto-linked email as plain text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<html><head><style>a {color: inherit; text-decoration: none;}</style>'
        '</head><body>'
        '<p style="color:#b0aea5">sent to demo.reader@example.com.</p>'
        '</body></html>',
      ),
    );
    final span = _spanWithText(tester, 'demo.reader@example.com');
    expect(span, isNotNull);
    expect(span!.style?.color, const Color(0xFFB0AEA5));
    expect(span.style?.decoration ?? TextDecoration.none, TextDecoration.none);
  });

  testWidgets('autoLinkify:false leaves bare email as plain text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<span style="color:#888888">a@example.com</span>',
        config: const HtmlRenderConfig(autoLinkify: false),
      ),
    );
    final span = _spanWithText(tester, 'a@example.com');
    expect(span!.recognizer, isNull);
    expect(span.style?.color, const Color(0xFF888888));
  });

  testWidgets('email inside an <a> is not double-linkified', (tester) async {
    String? tapped;
    await tester.pumpWidget(
      _host(
        '<a href="https://x.test">write to a@example.com now</a>',
        config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
      ),
    );
    // The email stays part of the anchor's single run and taps go to the
    // anchor href — not a separate mailto: auto-link.
    final span = _spanWithText(tester, 'a@example.com');
    expect(span!.recognizer, isNotNull);
    (span.recognizer as dynamic).onTap();
    expect(tapped, 'https://x.test');
  });

  testWidgets('cells without valign default to vertical middle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table><tbody><tr>'
        '<td style="padding:20px 0">CONTACTS</td>'
        '<td><div style="width:1px;height:16px;background:#000;display:block"></div></td>'
        '<td style="padding:20px 0">SUPPORT</td>'
        '</tr></tbody></table>',
      ),
    );
    final cells = tester.widgetList<TableCell>(find.byType(TableCell));
    expect(cells, isNotEmpty);
    expect(
      cells.every(
        (c) => c.verticalAlignment == TableCellVerticalAlignment.middle,
      ),
      isTrue,
    );
  });

  testWidgets('negative margin is clamped instead of crashing', (tester) async {
    await tester.pumpWidget(
      _host('<div style="margin-left:-20px;padding:-5px">offset list</div>'),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('offset list'), findsOneWidget);
  });

  testWidgets('img width="N" is used when CSS width is percent', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div style="max-width:75px"><img style="width:100%" width="75" src="$png" alt="logo"></div>',
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 75);
  });

  testWidgets('border-radius is applied to the background box', (tester) async {
    await tester.pumpWidget(
      _host(
        '<div style="background-color:#a0d4b4;border-radius:8px;padding:10px">btn</div>',
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).borderRadius != null,
        );
    expect(
      (box.decoration as BoxDecoration).borderRadius,
      BorderRadius.circular(8),
    );
  });

  testWidgets('table cell preserves background border-radius', (tester) async {
    await tester.pumpWidget(
      _host(
        '<table><tbody><tr>'
        '<td style="background-color:#a0d4b4;border-radius:8px;padding:10px">go</td>'
        '</tr></tbody></table>',
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFFA0D4B4),
        );
    expect(
      (box.decoration as BoxDecoration).borderRadius,
      BorderRadius.circular(8),
    );
  });

  testWidgets('inline-block <a> is a content-sized tappable box', (
    tester,
  ) async {
    String? tapped;
    await tester.pumpWidget(
      _host(
        '<a href="https://x.test" style="display:inline-block;padding:24px 12px;'
        'background-color:#a0d4b4;border-radius:8px">Check activity</a>',
        width: 1000,
        config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFFA0D4B4),
        );
    final size = tester.getSize(find.byWidget(box));
    expect(size.height, greaterThan(40)); // 24+24 padding + text
    expect(size.width, lessThan(300)); // sized to content, not full width
    await tester.tap(find.byWidget(box));
    expect(tapped, 'https://x.test');
  });

  testWidgets('inline-block <a> with width:100% fills width', (tester) async {
    await tester.pumpWidget(
      _host(
        '<a href="x" style="display:inline-block;width:100%;padding:10px;'
        'background-color:#a0d4b4">Full</a>',
        width: 500,
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFFA0D4B4),
        );
    expect(tester.getSize(find.byWidget(box)).width, 500);
  });

  testWidgets('inline-block <a> with a block child stays content-sized', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<a href="x" style="display:inline-block;padding:14px 20px;'
        'background-color:#1a73e8">'
        '<span style="display:block;color:#fff">Accept invite</span></a>',
        width: 800,
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFF1A73E8),
        );
    // Sized to "Accept invite" + padding, not stretched across the 800px line.
    expect(tester.getSize(find.byWidget(box)).width, lessThan(300));
  });

  testWidgets('empty cell honors a row height="24px" spacer', (tester) async {
    await tester.pumpWidget(
      _host(
        '<table cellpadding="0"><tbody>'
        '<tr height="24px"><td style="background:#f8f9fa"></td></tr>'
        '</tbody></table>',
        width: 600,
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFFF8F9FA),
        );
    expect(tester.getSize(find.byWidget(box)).height, greaterThanOrEqualTo(24));
  });

  testWidgets('float:left pins a max-width box to the left, not centered', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="text-align:center">'
        '<div style="float:left;max-width:200px;width:100%;background:#eeeeee">x</div>'
        '</div>',
        width: 600,
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFFEEEEEE),
        );
    // The 600px host is centered in the 800px test view (left edge x=100), so
    // a left-aligned box sits at ~100; a centered one would be far to the right.
    expect(tester.getTopLeft(find.byWidget(box)).dx, lessThan(150));
  });

  testWidgets('inline link margin-right adds a horizontal gap', (tester) async {
    await tester.pumpWidget(
      _host(
        '<a href="a" style="margin-right:12px">one</a><a href="b">two</a>',
        width: 600,
      ),
    );
    final gaps = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((s) => s.width == 12.0);
    expect(gaps.length, greaterThanOrEqualTo(1));
  });

  testWidgets('inline link trims whitespace around an image (no dashes)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<a href="x">\n<img src="https://e/x.png" alt="L">\n</a>',
        width: 400,
      ),
    );
    var underlinedBlanks = 0;
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      rt.text.visitChildren((s) {
        if (s is TextSpan) {
          final t = s.text ?? '';
          if (t.isNotEmpty &&
              t.trim().isEmpty &&
              s.style?.decoration == TextDecoration.underline) {
            underlinedBlanks++;
          }
        }
        return true;
      });
    }
    expect(underlinedBlanks, 0);
  });

  testWidgets('fixed-width column does not collapse the auto column', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:100%"><tbody><tr>'
        '<td style="width:400px">Title</td>'
        '<td>16.06.2026 18:47</td>'
        '</tr></tbody></table>',
        width: 360,
      ),
    );
    final rich = _richContaining(tester, '16.06.2026');
    expect(rich, isNotNull);
    // The date keeps its single-line content width instead of being squeezed
    // to ~1 char (which would wrap it to a tall char-per-line column).
    expect(tester.getSize(find.byWidget(rich!)).height, lessThan(40));
  });

  testWidgets('manual email bullet column keeps its padding before text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:600px;max-width:600px"><tr>'
        '<td style="padding:8px 10px 0 24px;font-size:18px;line-height:28px;'
        'vertical-align:top;width:10px">•</td>'
        '<td style="padding:8px 24px 0 0"><div style="font-size:18px;'
        'line-height:28px">Bullet item text that wraps onto another line</div>'
        '</td></tr></table>',
        width: 360,
      ),
    );
    final bullet = _richContaining(tester, '•')!;
    final text = _richContaining(tester, 'Bullet item text')!;
    final bulletRect = tester.getRect(find.byWidget(bullet));
    final textRect = tester.getRect(find.byWidget(text));
    expect(textRect.left - bulletRect.right, greaterThanOrEqualTo(9));
  });

  testWidgets('cells with display:inline-block;width:100% stack vertically', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:100%"><tbody><tr>'
        '<th style="display:inline-block;width:100%">TITLE</th>'
        '<th style="display:inline-block;width:100%">DATE</th>'
        '</tr></tbody></table>',
        width: 400,
      ),
    );
    final title = _richContaining(tester, 'TITLE')!;
    final date = _richContaining(tester, 'DATE')!;
    final ty = tester.getTopLeft(find.byWidget(title)).dy;
    final dy = tester.getTopLeft(find.byWidget(date)).dy;
    expect(dy, greaterThan(ty), reason: 'second cell stacks below the first');
  });

  testWidgets('fixed inline-block table cells wrap instead of being squeezed', (
    tester,
  ) async {
    String cell(String label) =>
        '<td width="118" style="display:inline-block;width:118px;'
        'padding:0 8px 16px"><div>$label</div></td>';
    await tester.pumpWidget(
      _host(
        '<table width="100%" style="max-width:536px;margin:0 auto;'
        'text-align:center">'
        '<tbody><tr>${cell('One')}${cell('Two')}${cell('Three')}'
        '${cell('Four')}</tr></tbody></table>',
        width: 450,
      ),
    );

    final one = tester.getRect(find.byWidget(_richContaining(tester, 'One')!));
    final two = tester.getRect(find.byWidget(_richContaining(tester, 'Two')!));
    final three = tester.getRect(
      find.byWidget(_richContaining(tester, 'Three')!),
    );
    final four = tester.getRect(
      find.byWidget(_richContaining(tester, 'Four')!),
    );
    expect(two.top, closeTo(one.top, 0.01));
    expect(three.top, closeTo(one.top, 0.01));
    expect(four.top, greaterThan(one.bottom));
    final view = tester.getRect(find.byType(HtmlEmailView));
    expect(four.center.dx, closeTo(view.center.dx, 0.01));
  });

  testWidgets('responsive half-width table cells wrap into a 2x2 grid', (
    tester,
  ) async {
    String cell(String label) =>
        '<td class="half" width="118" style="display:inline-block;'
        'max-width:118px;padding:0 8px 16px"><div>$label</div></td>';
    await tester.pumpWidget(
      _host(
        '<style>@media only screen and (max-width:599px){'
        '.icons{max-width:268px!important}'
        '.half{width:50%!important;max-width:50%!important;'
        'padding-left:0!important;padding-right:0!important;'
        'display:inline-block!important}}</style>'
        '<table class="icons" width="100%" style="max-width:536px;'
        'margin:0 auto"><tbody><tr>${cell('One')}${cell('Two')}'
        '${cell('Three')}${cell('Four')}</tr></tbody></table>',
        width: 500,
      ),
    );

    final one = tester.getRect(find.byWidget(_richContaining(tester, 'One')!));
    final two = tester.getRect(find.byWidget(_richContaining(tester, 'Two')!));
    final three = tester.getRect(
      find.byWidget(_richContaining(tester, 'Three')!),
    );
    final four = tester.getRect(
      find.byWidget(_richContaining(tester, 'Four')!),
    );
    expect(two.top, closeTo(one.top, 0.01));
    expect(three.top, greaterThan(one.bottom));
    expect(four.top, closeTo(three.top, 0.01));
    expect(three.left, closeTo(one.left, 0.01));
    expect(four.left, closeTo(two.left, 0.01));
  });

  testWidgets('responsive image-only half-width cells wrap into a 2x2 grid', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    String cell(String label) =>
        '<td class="half" aria-label="$label" width="118" '
        'style="display:inline-block;width:118px;max-width:118px;'
        'padding:0 8px 16px;vertical-align:top">'
        '<table style="width:100%;background:#16161d;border-radius:16px">'
        '<tbody><tr><td style="padding:20px;text-align:center">'
        '<img width="56" height="56" src="$png"></td></tr></tbody></table>'
        '</td>';

    await tester.pumpWidget(
      _host(
        '<style>@media only screen and (max-width:599px){'
        '.half{width:50%!important;max-width:50%!important;'
        'padding-left:0!important;padding-right:0!important;'
        'display:inline-block!important}}</style>'
        '<table width="100%" style="max-width:536px;margin:0 auto;'
        'text-align:center"><tbody><tr>${cell('One')}${cell('Two')}'
        '${cell('Three')}${cell('Four')}</tr></tbody></table>',
        width: 390,
      ),
    );

    final images = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => find.byWidget(image))
        .toList();
    expect(images, hasLength(4));

    final one = tester.getRect(images[0]);
    final two = tester.getRect(images[1]);
    final three = tester.getRect(images[2]);
    final four = tester.getRect(images[3]);
    expect(two.top, closeTo(one.top, 0.01));
    expect(three.top, greaterThan(one.bottom));
    expect(four.top, closeTo(three.top, 0.01));
    expect(three.left, closeTo(one.left, 0.01));
    expect(four.left, closeTo(two.left, 0.01));
  });

  testWidgets('inline-block cell shrinks to content at the column start', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:100%"><tbody><tr>'
        '<th style="display:inline-block;text-align:center">L</th>'
        '<th>rest of the row content here</th>'
        '</tr></tbody></table>',
        width: 400,
      ),
    );
    final l = _richContaining(tester, 'L')!;
    final rest = _richContaining(tester, 'rest of the row')!;
    // The inline-block cell is content-sized (not a half-width centered column),
    // so "L" sits left of the following cell.
    expect(
      tester.getTopLeft(find.byWidget(l)).dx,
      lessThan(tester.getTopLeft(find.byWidget(rest)).dx),
    );
  });

  testWidgets('table cell with display:none is dropped', (tester) async {
    await tester.pumpWidget(
      _host(
        '<table><tbody><tr>'
        '<th style="display:none">HIDDEN</th>'
        '<th>SHOWN</th>'
        '</tr></tbody></table>',
        width: 600,
      ),
    );
    expect(_richContaining(tester, 'SHOWN'), isNotNull);
    expect(_richContaining(tester, 'HIDDEN'), isNull);
  });

  testWidgets('responsive table renders only the visible desktop/mobile row', (
    tester,
  ) async {
    const html =
        '<style>'
        '@media only screen and (max-width:600px){'
        '.desktop{display:none!important}'
        '.mobile{display:table-row!important}'
        '}'
        '</style>'
        '<table><tbody>'
        '<tr class="desktop"><td>DESKTOP BADGES</td></tr>'
        '<tr class="mobile" style="display:none"><td>MOBILE BADGES</td></tr>'
        '</tbody></table>';

    await tester.pumpWidget(_host(html, width: 800));
    expect(_richContaining(tester, 'DESKTOP BADGES'), isNotNull);
    expect(_richContaining(tester, 'MOBILE BADGES'), isNull);

    await tester.pumpWidget(_host(html, width: 400));
    expect(_richContaining(tester, 'DESKTOP BADGES'), isNull);
    expect(_richContaining(tester, 'MOBILE BADGES'), isNotNull);
  });

  testWidgets('background-image renders a positioned (sprite) image', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<a href="x" style="display:inline-block;width:36px;height:36px;'
        'background:url($png) no-repeat;background-position:0 -112px">&nbsp;</a>',
        width: 400,
      ),
    );
    expect(find.byType(Positioned), findsOneWidget);
    final pos = tester.widget<Positioned>(find.byType(Positioned));
    expect(pos.left, 0); // background-position x
    expect(pos.top, -112); // background-position y (sprite offset)
  });

  testWidgets('fallback table: fixed-width cell of wrapping text does not crash', (
    tester,
  ) async {
    // A px-width cell in the Row-based fallback must be bounded; otherwise the
    // wrapping text inside it gets infinite width and the layout asserts.
    await tester.pumpWidget(
      _host(
        '<table cellspacing="2"><tbody><tr>'
        '<td width="400">This is a long sentence that must wrap inside a fixed '
        'width cell without crashing the layout engine</td>'
        '<td>x</td>'
        '</tr></tbody></table>',
        width: 600,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('all-fixed-width fallback row scales to fit, no overflow', (
    tester,
  ) async {
    // cellspacing forces the Row fallback; fixed cells summing over the
    // (border-shrunk) container must scale down instead of overflowing.
    await tester.pumpWidget(
      _host(
        '<table cellspacing="2" style="border:1px solid #cccccc"><tbody><tr>'
        '<td width="300">a</td><td width="300">b</td>'
        '</tr></tbody></table>',
        width: 600,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline-block table shrinks to content (icons do not spread)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="text-align:center">'
        '<table style="display:inline-block"><tbody><tr>'
        '<td width="48">A</td><td width="48">B</td><td width="48">C</td>'
        '</tr></tbody></table></div>',
        width: 600,
      ),
    );
    // Sized to its ~144px content, not stretched across the 600px line.
    expect(tester.getSize(find.byType(Table)).width, lessThan(200));
  });

  testWidgets('table-layout:fixed fits its container (no content overflow)', (
    tester,
  ) async {
    // Long unbreakable IDs must not push a fixed-layout table past its width:
    // columns split equally and the content wraps inside.
    await tester.pumpWidget(
      _host(
        '<table style="table-layout:fixed;width:100%"><tbody><tr>'
        '<td>imagen-4.0-ultra-generate-001</td>'
        '<td>gemini-3.1-flash-image</td>'
        '</tr></tbody></table>',
        width: 300,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Table)).width, lessThanOrEqualTo(300));
  });

  testWidgets('empty gutter columns collapse so centred content stays centred', (
    tester,
  ) async {
    // A centred content cell flanked by empty gutter cells (no width) must get
    // the full remaining width — the empty gutters collapse instead of each
    // claiming an equal flex share and squeezing the content off-centre.
    await tester.pumpWidget(
      _host(
        '<table style="width:100%"><tbody><tr>'
        '<td style="width:28px">&nbsp;</td>'
        '<td></td>'
        '<td style="text-align:center">Centred</td>'
        '<td></td>'
        '<td style="width:28px">&nbsp;</td>'
        '</tr></tbody></table>',
        width: 600,
      ),
    );
    expect(tester.takeException(), isNull);
    final rt = _richContaining(tester, 'Centred')!;
    final contentCenter =
        tester.getTopLeft(find.byWidget(rt)).dx +
        tester.getSize(find.byWidget(rt)).width / 2;
    final table = find.byType(Table);
    final tableCenter =
        tester.getTopLeft(table).dx + tester.getSize(table).width / 2;
    // The content cell fills the row (gutters collapsed), so its text centres on
    // the table centre rather than sitting in a narrow off-centre box.
    expect(contentCenter, closeTo(tableCenter, 2));
  });

  testWidgets(
    'a cell wider than its table fills the row instead of overflowing',
    (tester) async {
      // A `full-width` fill idiom expressed in px (a cell asking for the whole
      // body width inside a narrower table) must yield to its fixed gutters and
      // fill the remainder, not force the column to its literal width.
      await tester.pumpWidget(
        _host(
          '<table style="width:520px"><tbody><tr>'
          '<td style="width:60px">&nbsp;</td>'
          '<td style="width:600px;text-align:center">Disclaimer</td>'
          '<td style="width:60px">&nbsp;</td>'
          '</tr></tbody></table>',
          width: 700,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(Table)).width,
        lessThanOrEqualTo(520.5),
      );
      // The cell fills the remaining 520-60-60=400 (minus cell padding), instead
      // of forcing its literal 600px and overflowing the 520px table.
      final rt = _richContaining(tester, 'Disclaimer')!;
      expect(tester.getSize(find.byWidget(rt)).width, closeTo(396, 6));
    },
  );

  testWidgets('fallback (ragged) table centres a centred text cell', (
    tester,
  ) async {
    // A colspan makes the table ragged → fallback path. A `text-align:center`
    // cell must still centre its content (the cell box must not shrink it to the
    // left), matching the native path. Mirrors Google One's footer address.
    await tester.pumpWidget(
      _host(
        '<table align=center style="width:400px;text-align:center;margin:0 auto">'
        '<tbody>'
        '<tr><td align=center>Centred line</td></tr>'
        '<tr><td colspan=3 style="font-size:0;line-height:0">&nbsp;</td></tr>'
        '<tr><td align=center>Another centred line</td></tr>'
        '</tbody></table>',
        width: 600,
      ),
    );
    expect(tester.takeException(), isNull);
    final a = _richContaining(tester, 'Centred line')!;
    final b = _richContaining(tester, 'Another centred line')!;
    double cx(RichText rt) =>
        tester.getTopLeft(find.byWidget(rt)).dx +
        tester.getSize(find.byWidget(rt)).width / 2;
    // Both rows share the same 400px table, so they centre on the same axis.
    expect(cx(a), closeTo(cx(b), 1));
  });

  testWidgets('per-side table border draws only the given edges', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:100%;border-top:2px solid #00a046;'
        'border-bottom:1px solid #eaeaea"><tbody><tr><td>x</td></tr></tbody></table>',
        width: 600,
      ),
    );
    final border = _decoratedBorder(tester);
    expect(border.top.color, const Color(0xFF00A046));
    expect(border.top.width, 2);
    expect(border.bottom.color, const Color(0xFFEAEAEA));
    expect(border.left, BorderSide.none);
    expect(border.right, BorderSide.none);
  });

  testWidgets('px line-height is fixed, not scaled by a larger child font', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="line-height:32px"><div style="font-size:24px">Big</div></div>',
      ),
    );
    final span = _spanWithText(tester, 'Big')!;
    // height multiplier resolves against the child's own 24px font: 32/24.
    expect(span.style!.height, closeTo(32 / 24, 0.01));
  });

  testWidgets('heading UA font-size is relative to the parent font-size', (
    tester,
  ) async {
    // An `<h6>` inside a `font-size:24px` block is 0.75x24 = 18px, not
    // 0.75x root — UA heading `em` sizes follow the parent (Binance subject
    // heading wrapped in a 24px div).
    await tester.pumpWidget(
      _host('<div style="font-size:24px"><h6>Margin Call</h6></div>'),
    );
    final span = _spanWithText(tester, 'Margin Call')!;
    expect(span.style!.fontSize, closeTo(18, 0.1));
  });

  testWidgets('em line-height resolves against the element own font-size', (
    tester,
  ) async {
    // An `<h1 style="font-size:40px;line-height:1.1em">` is 44px tall, not
    // 1.1×parent — otherwise wrapped lines overlap (Apple "Welcome" header).
    await tester.pumpWidget(
      _host(
        '<h1 style="font-size:40px;line-height:1.1em">Welcome to the Apple '
        'Developer Program</h1>',
        width: 260,
      ),
    );
    final span = _spanWithText(tester, 'Welcome')!;
    expect(span.style!.fontSize, 40);
    expect(span.style!.height, closeTo(1.1, 0.01)); // 44px / 40px
  });

  testWidgets('widthless align="center" table shrinks and centers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        '<table align="center"><tbody><tr>'
        '<td>A</td><td>email@example.com</td>'
        '</tr></tbody></table>',
        width: 1000,
      ),
    );
    final size = tester.getSize(find.byType(Table));
    expect(size.width, lessThan(900)); // shrunk to content, not full width
    expect(tester.getCenter(find.byType(Table)).dx, closeTo(500, 1));
  });

  testWidgets('inline-block flows inline and does not break the line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div><span>A</span>'
        '<span style="display:inline-block;width:1px;height:13px;background:#000"></span>'
        '<span>B</span></div>',
      ),
    );
    // A, the divider (WidgetSpan U+FFFC) and B stay in one paragraph.
    final oneLine = tester.widgetList<RichText>(find.byType(RichText)).where((
      rt,
    ) {
      final t = rt.text.toPlainText();
      return t.contains('A') && t.contains('B');
    });
    expect(oneLine, isNotEmpty);
  });

  testWidgets('fixed-width block is centered inside align="center"', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        '<table width="100%"><tbody><tr><td align="center">'
        '<table width="200"><tbody><tr><td>x</td></tr></tbody></table>'
        '</td></tr></tbody></table>',
        width: 1000,
      ),
    );
    final inner = tester
        .widgetList<Table>(find.byType(Table))
        .firstWhere((t) => tester.getSize(find.byWidget(t)).width == 200);
    expect(tester.getCenter(find.byWidget(inner)).dx, closeTo(500, 1));
  });

  testWidgets(
    'cell align centers a block heading without leaking into tables',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table width="100%"><tr><td align="center">'
          '<h3>Convenient with us</h3></td></tr></table>',
          width: 600,
        ),
      );
      expect(
        _richContaining(tester, 'Convenient with us')!.textAlign,
        TextAlign.center,
      );
    },
  );

  testWidgets('a <center> keeps centering inside an aligned cell', (
    tester,
  ) async {
    // A parent cell's `align` is inherited-like: an element with its own
    // alignment (here `<center>`, UA text-align:center) must keep it rather
    // than being overridden by the enclosing `<td align="left">`.
    await tester.pumpWidget(
      _host(
        '<table><tr><td align="left">'
        '<center><a href="https://x.test">hi</a></center>'
        '</td></tr></table>',
      ),
    );
    expect(_richContaining(tester, 'hi')!.textAlign, TextAlign.center);
  });

  testWidgets('two floated menu tables form one four-item row', (tester) async {
    await tester.pumpWidget(
      _host(
        '<div><table style="float:left;width:275px"><tr>'
        '<td width="50%">One</td><td width="50%">Two</td></tr></table>'
        '<table style="float:right;width:275px"><tr>'
        '<td width="50%">Three</td><td width="50%">Four</td></tr></table></div>',
        width: 600,
      ),
    );
    final widgets = [
      'One',
      'Two',
      'Three',
      'Four',
    ].map((text) => find.byWidget(_richContaining(tester, text)!)).toList();
    final top = tester.getTopLeft(widgets.first).dy;
    for (final widget in widgets.skip(1)) {
      expect(tester.getTopLeft(widget).dy, closeTo(top, 2));
    }
  });

  testWidgets('unused width separates left and right floated badge groups', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="width:540px">'
        '<table style="float:left"><tr><td style="width:120px">One</td>'
        '<td style="width:20px"></td></tr></table>'
        '<table style="float:left"><tr><td style="width:120px">Two</td>'
        '<td style="width:20px"></td></tr></table>'
        '<table style="float:left"><tr><td style="width:120px">Three</td></tr></table>'
        '<table style="float:right"><tr><td style="width:120px">Four</td></tr></table>'
        '</div>',
        width: 600,
      ),
    );
    final three = find.byWidget(_richContaining(tester, 'Three')!);
    final four = find.byWidget(_richContaining(tester, 'Four')!);
    final tables = find.byType(Table);
    expect(tables, findsNWidgets(4));
    final thirdTable = tables.at(2);
    final fourthTable = tables.at(3);

    expect(tester.getTopLeft(four).dy, closeTo(tester.getTopLeft(three).dy, 2));
    expect(
      tester.getRect(fourthTable).left - tester.getRect(thirdTable).right,
      closeTo(20, 1),
    );
  });

  testWidgets('legacy align left/right auto tables share one header row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="600" cellspacing="0" cellpadding="0"><tr><td>'
        '<table align="left" width="auto" cellspacing="0" cellpadding="0">'
        '<tr><td>Google Cloud</td></tr></table>'
        '<table align="right" width="auto" cellspacing="0" cellpadding="0">'
        '<tr><td><a>MY CONSOLE</a></td></tr></table>'
        '</td></tr></table>',
        width: 600,
      ),
    );

    final logo = find.byWidget(_richContaining(tester, 'Google Cloud')!);
    final console = find.byWidget(_richContaining(tester, 'MY CONSOLE')!);
    final hostRect = tester.getRect(find.byType(HtmlEmailView));

    expect(
      tester.getTopLeft(console).dy,
      closeTo(tester.getTopLeft(logo).dy, 2),
    );
    expect(tester.getRect(logo).left, closeTo(hostRect.left, 2));
    expect(tester.getRect(console).right, closeTo(hostRect.right, 2));
  });

  testWidgets('responsive inline-block social table stays centered', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<style>@media only screen and (max-width:600px){'
        '.social,.social td{display:inline-block!important}'
        'table.social{width:auto!important}'
        '}</style>'
        '<table style="width:600px"><tr><td style="padding:0 30px">'
        '<table style="width:100%"><tr><td align="left" style="width:540px">'
        '<table style="width:100%"><tr><td align="center">'
        '<table class="social"><tr>'
        '<td style="padding-right:10px"><img width="48" src="$png"></td>'
        '<td style="padding-right:10px"><img width="48" src="$png"></td>'
        '<td style="padding-right:10px"><img width="48" src="$png"></td>'
        '<td><img width="48" src="$png"></td>'
        '</tr></table>'
        '</td></tr></table>'
        '</td></tr></table>'
        '</td></tr></table>',
        width: 400,
      ),
    );
    final images = find.byType(Image);
    expect(images, findsNWidgets(4));
    final first = tester.getRect(images.first);
    final last = tester.getRect(images.last);
    final groupCenter = (first.left + last.right) / 2;
    final viewCenter = tester.getRect(find.byType(HtmlEmailView)).center.dx;

    for (var i = 1; i < 4; i++) {
      expect(tester.getRect(images.at(i)).top, closeTo(first.top, 2.1));
    }
    expect(groupCenter, closeTo(viewCenter, 2));
  });

  testWidgets('responsive menu image cells stay in horizontal rows', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<style>@media only screen and (max-width:666px){'
        'table.body .container{width:100%!important}'
        '.large-offset-1{padding-left:0!important;padding-right:0!important}'
        'th.small-12{display:inline-block!important;width:100%!important}'
        'table.menu{width:100%!important}'
        'table.menu td,table.menu th{display:inline-block!important;'
        'width:auto!important;text-align:center}'
        '}</style>'
        '<table class="body"><tr><td>'
        '<table class="container" width="650"><tr><td style="padding:16px">'
        '<table class="row" style="width:100%"><tr>'
        '<th class="small-12 columns pad-bt large-offset-1" '
        'style="width:212px;padding-right:216px">'
        '<table class="menu" style="width:100%;text-align:center"><tr>'
        '<th title="App Store" style="padding:0;padding-right:8px">'
        '<img alt="App Store" width="102" height="32" src="$png" '
        'style="display:block;margin:0 auto;max-width:102px"></th>'
        '<th title="Google Play" style="padding:0">'
        '<img alt="Google Play" width="102" height="32" src="$png" '
        'style="display:block;margin:0 auto;max-width:102px"></th>'
        '</tr></table>'
        '</th>'
        '<th class="small-12 columns large-offset-1" style="width:184px">'
        '<table class="menu" style="width:100%;text-align:center"><tr>'
        '<th title="Facebook" style="width:24px;vertical-align:middle;padding-left:0">'
        '<img width="24" height="24" src="$png" '
        'style="display:block;margin:0 auto;max-width:24px"></th>'
        '<th title="Twitter" style="width:24px;vertical-align:middle;padding-left:8px">'
        '<img width="24" height="24" src="$png" '
        'style="display:block;margin:0 auto;max-width:24px"></th>'
        '<th title="YouTube" style="width:24px;vertical-align:middle;padding-left:8px">'
        '<img width="24" height="24" src="$png" '
        'style="display:block;margin:0 auto;max-width:24px"></th>'
        '<th title="Instagram" style="width:24px;vertical-align:middle;padding-left:8px">'
        '<img width="24" height="24" src="$png" '
        'style="display:block;margin:0 auto;max-width:24px"></th>'
        '<th title="Viber" style="width:24px;vertical-align:middle;padding-left:8px">'
        '<img width="24" height="24" src="$png" '
        'style="display:block;margin:0 auto;max-width:24px"></th>'
        '<th title="Telegram" style="width:24px;vertical-align:middle;padding-left:8px">'
        '<img width="24" height="24" src="$png" '
        'style="display:block;margin:0 auto;max-width:24px"></th>'
        '</tr></table>'
        '</th>'
        '</tr></table>'
        '</td></tr></table>'
        '</td></tr></table>',
        width: 390,
      ),
    );

    final images = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => find.byWidget(image))
        .toList();
    expect(images, hasLength(8));

    final app = [tester.getRect(images[0]), tester.getRect(images[1])];
    expect(app[1].top, closeTo(app[0].top, 0.01));
    expect(app[1].left, greaterThan(app[0].right));

    final social = [for (final image in images.skip(2)) tester.getRect(image)];
    for (final rect in social.skip(1)) {
      expect(rect.top, closeTo(social.first.top, 0.01));
    }
    final socialCenter = (social.first.left + social.last.right) / 2;
    final viewCenter = tester.getRect(find.byType(HtmlEmailView)).center.dx;
    expect(socialCenter, closeTo(viewCenter, 2));
  });

  testWidgets('floated list social icons stay in one row', (tester) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    String item(String title) =>
        '<li style="float:left;width:48px;padding-left:0;margin-left:0">'
        '<a title="$title" style="display:inline-block;width:32px">'
        '<img width="32" height="32" src="$png"></a></li>';

    await tester.pumpWidget(
      _host(
        '<div style="background:#06160e;padding:48px 40px">'
        '<ul style="list-style-type:none;overflow:hidden;padding:0;margin:0">'
        '${item('facebook')}'
        '${item('x')}'
        '${item('tiktok')}'
        '${item('instagram')}'
        '${item('linkedin')}'
        '</ul>'
        '</div>',
        width: 390,
      ),
    );

    final images = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => find.byWidget(image))
        .toList();
    expect(images, hasLength(5));

    final rects = images.map(tester.getRect).toList();
    for (final rect in rects.skip(1)) {
      expect(rect.top, closeTo(rects.first.top, 0.01));
    }
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThan(rects[i - 1].right));
    }
  });

  testWidgets('widthless inline-block wrapper keeps block underline to text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="background:#06160e;padding:40px">'
        '<div style="display:inline-block;color:rgba(92,255,164,.96)">'
        '<a style="text-decoration:none;color:rgba(92,255,164,.96)">'
        'Why this email?</a>'
        '<div style="height:1px;background-color:rgba(18,255,140,.24)"></div>'
        '</div>'
        '</div>',
        width: 390,
      ),
    );

    final link = find.byWidget(_richContaining(tester, 'Why this email?')!);
    final line = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == const Color(0x3d12ff8c),
    );

    final linkRect = tester.getRect(link);
    final lineRect = tester.getRect(line.first);
    final viewRect = tester.getRect(find.byType(HtmlEmailView));

    expect(lineRect.width, closeTo(linkRect.width, 2));
    expect(lineRect.width, lessThan(viewRect.width - 80));
  });

  testWidgets('responsive mixed help row keeps image cell top aligned', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<style>@media only screen and (max-width:666px){'
        'th.small-12{display:inline-block!important;width:100%!important}'
        '}</style>'
        '<table style="width:100%"><tr><td style="padding:16px;'
        'background:rgba(242,201,76,0.2)">'
        '<table style="width:100%"><tr>'
        '<th class="small-12 columns" style="width:40px;vertical-align:middle">'
        '<img width="40" height="40" src="$png" '
        'style="display:block;margin:0 auto;max-width:40px"></th>'
        '<th style="vertical-align:middle;padding-left:16px;text-align:left">'
        '<span style="display:block;font-size:14px;line-height:20px;'
        'font-weight:700;padding-bottom:8px">Have any more questions?</span>'
        '<span style="display:block;font-size:14px;line-height:20px">'
        'Visit our <a>Help Center</a></span>'
        '</th>'
        '</tr></table>'
        '</td></tr></table>',
        width: 390,
      ),
    );

    final imageTop = tester.getRect(find.byType(Image).first).top;
    final titleTop = tester
        .getRect(find.byWidget(_richContaining(tester, 'Have any')!))
        .top;
    expect(imageTop, closeTo(titleTop, 2));
  });

  testWidgets('percent table inside auto inline-block cell shrinks to content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table><tr>'
        '<td style="display:inline-block;width:32px;height:32px;background:#999">A</td>'
        '<td style="display:inline-block;width:32px;height:32px;background:#999">B</td>'
        '<td style="display:inline-block;padding-left:8px">'
        '<table width="100%"><tr>'
        '<td style="width:32px;height:32px;border:1px solid #424242;text-align:center">+1</td>'
        '</tr></table>'
        '</td>'
        '</tr></table>',
        width: 400,
      ),
    );

    final plus = find.byWidget(_richContaining(tester, '+1')!);
    final plusRect = tester.getRect(plus);
    final innerTables = tester
        .widgetList<Table>(find.byType(Table))
        .map((table) => find.byWidget(table))
        .where((table) {
          final size = tester.getSize(table);
          return size.height >= 30 && size.height <= 40;
        })
        .toList();

    expect(plusRect.width, lessThan(80));
    expect(
      innerTables.map(tester.getSize).any((size) => size.width > 100),
      isFalse,
      reason: 'the +1 inner table must not stretch across the whole row',
    );
  });

  testWidgets('inline-block link with full-width table keeps the table width', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<a style="display:inline-block;text-decoration:none">'
        '<table width="100%" style="background:#fff"><tr>'
        '<td style="width:50%;padding:24px"><h2>Widget copy</h2></td>'
        '<td style="width:50%;text-align:right"><div style="width:260px;height:160px;background:#ddd"></div></td>'
        '</tr></table>'
        '</a>',
        width: 512,
      ),
    );

    final widestTable = tester
        .widgetList<Table>(find.byType(Table))
        .map((table) => tester.getSize(find.byWidget(table)).width)
        .fold<double>(0, (max, width) => width > max ? width : max);
    expect(widestTable, greaterThan(450));
  });

  testWidgets('fixed-width linked table button stays visible on narrow screens', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="100%"><tr><td style="text-align:center">'
        '<table width="100%"><tr><td align="middle">'
        '<a style="display:inline-block;vertical-align:top;text-decoration:none">'
        '<table width="auto" style="border-collapse:separate"><tr>'
        '<td width="390" style="width:390px;border-radius:24px;'
        'padding:12px 24px;text-align:center;font-size:16px;font-weight:600;'
        'background-color:#0a66c2;color:#ffffff;border:1px solid #0a66c2;'
        'line-height:1.25">'
        '<a style="display:inline-block;text-decoration:none">'
        '<span style="color:#ffffff">View this post</span>'
        '</a>'
        '</td></tr></table>'
        '</a>'
        '</td></tr></table>'
        '</td></tr></table>',
        width: 320,
      ),
    );

    final label = _richContaining(tester, 'View this post');
    expect(label, isNotNull);
    expect(tester.getSize(find.byWidget(label!)).height, lessThan(80));

    final buttonBox = find
        .byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              ((widget.decoration as BoxDecoration).color ==
                  const Color(0xff0a66c2)),
        )
        .first;
    final rect = tester.getRect(buttonBox);
    expect(rect.width, greaterThan(250));
    expect(rect.height, lessThan(80));
  });

  testWidgets(
    'widthless table button inside centered cell shrinks to content',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table width="100%"><tr><td align="center">'
          '<table style="border-collapse:separate;line-height:100%">'
          '<tr><td bgcolor="#EA71DF" style="background:#EA71DF">'
          '<a style="display:inline-block;background:#EA71DF;'
          'font-size:14px;font-weight:700;padding:18px 30px;'
          'color:#fff;text-decoration:none">ORDER WITH DISCOUNT</a>'
          '</td></tr></table>'
          '</td></tr></table>',
          width: 600,
        ),
      );

      final pinkBoxes = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                ((box.decoration as BoxDecoration).color ==
                    const Color(0xffea71df)),
          )
          .map((box) => find.byWidget(box))
          .toList();
      final widestPink = pinkBoxes
          .map((box) => tester.getSize(box).width)
          .fold<double>(0, (max, width) => width > max ? width : max);

      expect(widestPink, lessThan(340));
      expect(widestPink, greaterThan(180));
    },
  );

  testWidgets('widthless cell-styled link button table shrinks to content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="600" cellspacing="0" cellpadding="0"><tr><td>'
        '<table width="100%" cellspacing="0" cellpadding="0"><tr><td>'
        '<table cellspacing="0" cellpadding="0" role="presentation">'
        '<tr><th bgcolor="#0078D4" style="background:#0078D4;'
        'border:1px solid #0078D4;border-radius:2px;'
        'padding:8px 20px;min-width:100px;font-size:18px;'
        'line-height:24px;font-weight:600">'
        '<a href="https://x.test" style="text-decoration:none;color:#fff">'
        '<strong style="color:#fff">Submit your interest</strong>'
        '</a></th></tr></table>'
        '</td></tr></table>'
        '</td></tr></table>',
        width: 600,
      ),
    );

    final blueBoxes = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where(
          (box) =>
              box.decoration is BoxDecoration &&
              ((box.decoration as BoxDecoration).color ==
                  const Color(0xff0078d4)),
        )
        .map((box) => find.byWidget(box))
        .toList();
    final widestBlue = blueBoxes
        .map((box) => tester.getSize(box).width)
        .fold<double>(0, (max, width) => width > max ? width : max);

    // Flutter widget tests use the Ahem font, so this is wider than the real
    // Segoe UI button. The regression is the 600px full-width stretch.
    expect(widestBlue, lessThan(500));
    expect(widestBlue, greaterThan(180));
  });

  testWidgets('bold font-family names preserve explicit CSS text weight', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<span style="font-family:&quot;Arial Black&quot;,&quot;Arial Bold&quot;,'
        'Gadget,sans-serif;font-size:16px;font-weight:400">\$350.00</span>',
      ),
    );

    final price = _spanWithText(tester, r'$350.00')!;
    expect(price.style?.fontWeight, FontWeight.normal);
  });

  testWidgets('product card spacer rows align CTA buttons at the bottom', (
    tester,
  ) async {
    String card(String title, String price) =>
        '<div style="display:table-cell;vertical-align:top;width:33.333333%">'
        '<table height="100%" width="100%" style="height:100%;table-layout:fixed">'
        '<tbody><tr><td style="padding:10px;vertical-align:top">'
        '<table width="100%" style="height:100%;table-layout:fixed"><tbody>'
        '<tr><td style="height:120px;background:#eee">image</td></tr>'
        '<tr><td align="center"><table align="center"><tr>'
        '<td style="font-size:16px;line-height:1.3;text-align:center">$title</td>'
        '</tr></table></td></tr>'
        '<tr><td align="center"><table align="center"><tr>'
        '<td style="font-family:&quot;Arial Black&quot;,&quot;Arial Bold&quot;,'
        'Gadget,sans-serif;font-size:16px;font-weight:400">$price</td>'
        '</tr></table></td></tr>'
        '<tr><td style="height:100%"></td></tr>'
        '<tr><td align="center" style="padding-top:9px">'
        '<table style="border-collapse:separate;line-height:100%"><tr>'
        '<td bgcolor="#6490F4" style="background:#6490F4">'
        '<a style="display:inline-block;background:#6490F4;'
        'padding:15px 20px;color:#fff;text-decoration:none">SHOP NOW</a>'
        '</td></tr></table>'
        '</td></tr></tbody></table>'
        '</td></tr></tbody></table>'
        '</div>';

    await tester.pumpWidget(
      _host(
        '<div style="display:table;width:100%;height:100%">'
        '${card('Burgundy with butterflies 16 quinceanera champagne glasses', r'$350.00')}'
        '${card('Green quinceanera brindis package', r'$140.00')}'
        '${card('Gold quinceanera cake knife and server', r'$39.00')}'
        '</div>',
        width: 600,
      ),
    );

    final buttons = tester
        .widgetList<RichText>(find.byType(RichText))
        .where((rt) => rt.text.toPlainText().contains('SHOP NOW'))
        .map((rt) => find.byWidget(rt))
        .toList();

    expect(buttons, hasLength(3));
    final tops = buttons.map((button) => tester.getTopLeft(button).dy).toList();
    expect(tops[1], closeTo(tops[0], 2));
    expect(tops[2], closeTo(tops[0], 2));
  });

  testWidgets(
    'percent-height product wrapper is safe during intrinsic sizing',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table style="width:100%"><tr>'
          '<td style="width:100%;padding:0">'
          '<table style="width:100%;height:100%"><tr><td style="padding:0">'
          '<table style="width:100%;height:100%"><tbody>'
          '<tr><td>Title</td></tr>'
          '<tr><td style="height:100%"></td></tr>'
          '<tr><td><a>SHOP NOW</a></td></tr>'
          '</tbody></table>'
          '</td></tr></table>'
          '</td></tr></table>',
          width: 600,
        ),
      );

      expect(_richContaining(tester, 'SHOP NOW'), isNotNull);
    },
  );

  testWidgets('responsive full-width float tables stack into a 2x2 grid', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        '<style>@media only screen and (max-width:600px){'
        '.es-left,.es-right{width:100% !important}}</style>'
        '<div><table class="es-left" style="float:left;width:275px"><tr>'
        '<td width="50%">One</td><td width="50%">Two</td></tr></table>'
        '<table class="es-right" style="float:right;width:275px"><tr>'
        '<td width="50%">Three</td><td width="50%">Four</td></tr></table></div>',
        width: 400,
      ),
    );
    final one = find.byWidget(_richContaining(tester, 'One')!);
    final two = find.byWidget(_richContaining(tester, 'Two')!);
    final three = find.byWidget(_richContaining(tester, 'Three')!);
    final four = find.byWidget(_richContaining(tester, 'Four')!);
    expect(tester.getTopLeft(two).dy, closeTo(tester.getTopLeft(one).dy, 2));
    expect(tester.getTopLeft(four).dy, closeTo(tester.getTopLeft(three).dy, 2));
    expect(
      tester.getTopLeft(three).dy,
      greaterThan(tester.getBottomLeft(one).dy),
    );
  });

  testWidgets('unequal floated tables preserve their ratio without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="600"><tr><td><div>'
        '<table style="float:left"><tr><td width="390">Wide</td></tr></table>'
        '<table style="float:right"><tr><td width="190">Narrow</td></tr></table>'
        '</div></td></tr></table>',
        width: 600,
      ),
    );
    final wide = find.byWidget(_richContaining(tester, 'Wide')!);
    final narrow = find.byWidget(_richContaining(tester, 'Narrow')!);
    expect(
      tester.getTopLeft(narrow).dy,
      closeTo(tester.getTopLeft(wide).dy, 2),
    );
    final host = find.byType(HtmlEmailView);
    expect(
      tester.getRect(narrow).right,
      lessThanOrEqualTo(tester.getRect(host).right + 1),
    );
  });

  testWidgets('percentage-width block paints only its declared fraction', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="width:200px;background:#fadecd">'
        '<div style="width:59%;height:6px;background:#e77427"></div></div>',
        width: 400,
      ),
    );
    final fill = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFFE77427),
    );
    expect(tester.getSize(fill).width, closeTo(118, 1));
  });

  testWidgets('percentage-width table paints only its declared fraction', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="50%" align="center" style="background:#9146ff;'
        'border-radius:50px"><tbody><tr><td style="padding:14px">CTA</td>'
        '</tr></tbody></table>',
        width: 400,
      ),
    );
    final button = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == const Color(0xFF9146FF),
    );
    final rect = tester.getRect(button.first);
    final view = tester.getRect(find.byType(HtmlEmailView));
    expect(rect.width, closeTo(200, 0.01));
    expect(rect.center.dx, closeTo(view.center.dx, 0.01));
  });

  testWidgets('percentage-width progress fill ignores inherited text-align', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="100%" style="text-align:center"><tr><td>'
        '<table width="100%" style="background:#e3e3e3;height:8px">'
        '<tr><td style="padding:0">'
        '<table width="92.639%" style="height:8px"><tr>'
        '<td style="background:#b3261e;height:8px;font-size:1px">&nbsp;</td>'
        '</tr></table>'
        '</td></tr></table>'
        '</td></tr></table>',
        width: 464,
      ),
    );

    final grey = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == const Color(0xFFE3E3E3),
    );
    final red = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == const Color(0xFFB3261E),
    );
    final greyRect = tester.getRect(grey.first);
    final redRect = tester.getRect(red.first);
    expect(redRect.left, closeTo(greyRect.left, 0.01));
    expect(redRect.width, closeTo(greyRect.width * 0.92639, 1));
  });

  testWidgets('image-only table column stays intrinsic beside text', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table width="100%"><tr><td><img width="20" src="$png"></td>'
        '<td>Suggestion text</td></tr></table>',
        width: 500,
      ),
    );
    final image = find.byType(Image).first;
    final text = find.byWidget(_richContaining(tester, 'Suggestion text')!);
    expect(
      tester.getTopLeft(text).dx - tester.getRect(image).right,
      lessThan(12),
    );
  });

  testWidgets('responsive full-width image cell stays intrinsic beside text', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<style>@media (max-width:666px){th.small-12{'
        'display:inline-block!important;width:100%!important}}</style>'
        '<table style="width:100%"><tr>'
        '<th class="small-12" style="width:40px">'
        '<img width="40" src="$png"></th>'
        '<th style="padding-left:16px;text-align:left">Question text</th>'
        '</tr></table>',
        width: 320,
      ),
    );
    final widths = tester.widget<Table>(find.byType(Table)).columnWidths!;
    expect(widths[0], isA<IntrinsicColumnWidth>());
    expect(widths[1].toString(), contains('FlexColumnWidth'));
  });

  testWidgets('three legacy aligned percent tables share one row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div><table width="33.3%" align="left"><tr><td>Card A</td></tr></table>'
        '<table width="33.3%" align="left"><tr><td>Card B</td></tr></table>'
        '<table width="33.3%" align="right"><tr><td>Card C</td></tr></table></div>',
        width: 600,
      ),
    );
    final cards = [
      'Card A',
      'Card B',
      'Card C',
    ].map((s) => find.byWidget(_richContaining(tester, s)!)).toList();
    final y = tester.getTopLeft(cards.first).dy;
    for (final card in cards.skip(1)) {
      expect(tester.getTopLeft(card).dy, closeTo(y, 2));
    }
  });

  testWidgets('CSS table border has no internal cell divider', (tester) async {
    await tester.pumpWidget(
      _host(
        '<table style="border:1px;border-style:solid;border-color:#b1d3ff">'
        '<tr><td>Copy</td><td>Button</td></tr></table>',
      ),
    );
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.border, isNull);
    final outerBorders = tester
        .widgetList<DecoratedBox>(
          find.ancestor(
            of: find.byType(Table),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.border)
        .whereType<Border>()
        .where((border) => border.top.color == const Color(0xFFB1D3FF))
        .toList();
    expect(outerBorders, hasLength(1));
    expect(outerBorders.single.top.width, 0);
    expect(outerBorders.single.top, isNot(BorderSide.none));
  });

  testWidgets('transparent table border reserves layout spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="width:200px;height:40px;background:#cccccc"></div>'
        '<table style="width:200px;border:20px solid transparent">'
        '<tr><td><div style="width:40px;height:10px;background:#ff0000"></div></td></tr></table>',
        width: 300,
      ),
    );

    final hero = find
        .byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  const Color(0xffcccccc),
        )
        .first;
    final content = find
        .byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  const Color(0xffff0000),
        )
        .first;

    expect(
      tester.getRect(content).top - tester.getRect(hero).bottom,
      allOf(greaterThanOrEqualTo(20), lessThan(25)),
    );
  });

  testWidgets('border shorthand without a style does not draw a border', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="border:medium;color:#000;table-layout:fixed;width:100%">'
        '<tr><td><a style="color:#fff;text-decoration:underline">COLORS</a></td>'
        '<td><a style="color:#fff;text-decoration:underline">PRODUCTS</a></td>'
        '<td><a style="color:#fff;text-decoration:underline">REVIEWS</a></td>'
        '</tr></table>',
        width: 600,
      ),
    );

    final visibleBorders = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.border)
        .whereType<Border>()
        .where(
          (border) =>
              border.top != BorderSide.none ||
              border.right != BorderSide.none ||
              border.bottom != BorderSide.none ||
              border.left != BorderSide.none,
        )
        .toList();
    expect(visibleBorders, isEmpty);

    final linkSpan = _spanWithText(tester, 'COLORS')!;
    expect(linkSpan.style?.color, const Color(0xffffffff));
    expect(linkSpan.style?.decoration, TextDecoration.underline);
    expect(linkSpan.style?.decorationColor, const Color(0xffffffff));
  });

  testWidgets('inline-block CTA column leaves the copy column its width', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:100%;padding:8px;border:1px solid #b1d3ff">'
        '<tr><td><p>Get this report for all projects that matter to you</p></td>'
        '<td style="text-align:right"><a style="display:inline-block">'
        'Subscribe To More Projects</a></td></tr></table>',
        width: 850,
      ),
    );
    final copy = find.byWidget(
      _richContaining(
        tester,
        'Get this report for all projects that matter to you',
      )!,
    );
    final tableRect = tester.getRect(find.byType(Table));
    expect(tester.getRect(copy).right, greaterThan(tableRect.center.dx + 50));
  });

  testWidgets('inline icon inside a normal link does not create a CTA column', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:100%"><tr><td>Top Suggestions</td>'
        '<td style="text-align:right"><a><span>View All Suggestions</span>'
        '<img width="20"></a></td></tr></table>',
        width: 600,
      ),
    );
    final widths = tester.widget<Table>(find.byType(Table)).columnWidths!;
    expect(widths[0].toString(), contains('FlexColumnWidth(1.0)'));
    expect(widths[1].toString(), contains('FlexColumnWidth(1.0)'));
  });

  testWidgets('@media (max-width) is ignored above the breakpoint', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<html><head><style>'
        '@media (max-width:480px){ .shell { width:100% !important; } }'
        '</style></head><body>'
        '<table class="shell" width="600"><tbody><tr><td>x</td></tr></tbody></table>'
        '</body></html>',
        width: 800,
      ),
    );
    // Rendered wide (>480px): the mobile rule does not apply; table stays 600.
    expect(tester.getSize(find.byType(Table)).width, 600);
  });

  testWidgets('@media (max-width) !important applies below the breakpoint', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<html><head><style>'
        '@media (max-width:480px){ .shell { width:100% !important; } }'
        '</style></head><body>'
        '<table class="shell" width="600"><tbody><tr><td>x</td></tr></tbody></table>'
        '</body></html>',
        width: 400,
      ),
    );
    // Rendered narrow (<=480px): width:100%!important beats the width="600"
    // attribute, so the table fills the available 400px instead of overflowing.
    expect(tester.getSize(find.byType(Table)).width, 400);
  });

  testWidgets('dir="rtl" reverses table column order', (tester) async {
    await tester.pumpWidget(
      _host(
        '<table dir="rtl" style="direction:rtl" width="400"><tbody><tr>'
        '<td style="direction:ltr">FIRST</td>'
        '<td style="direction:ltr">SECOND</td>'
        '</tr></tbody></table>',
        width: 1000,
      ),
    );
    final first = _richContaining(tester, 'FIRST')!;
    final second = _richContaining(tester, 'SECOND')!;
    // In RTL the first DOM cell renders on the right.
    expect(
      tester.getCenter(find.byWidget(first)).dx,
      greaterThan(tester.getCenter(find.byWidget(second)).dx),
    );
  });

  testWidgets('cellspacing table fills cell backgrounds to full row height', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table cellspacing="3"><tbody><tr>'
        '<td bgcolor="#ff0000" valign="top">A</td>'
        '<td bgcolor="#00ff00" valign="top">B<br>C<br>D</td>'
        '</tr></tbody></table>',
        width: 600,
      ),
    );
    Container boxOf(Color c) => tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (w) =>
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == c,
        );
    final short = tester.getSize(find.byWidget(boxOf(const Color(0xFFFF0000))));
    final tall = tester.getSize(find.byWidget(boxOf(const Color(0xFF00FF00))));
    // The single-line red cell's background fills the same height as the
    // 3-line green cell (the row height), not just its own text height.
    expect(short.height, tall.height);
    expect(short.height, greaterThan(40));
  });

  testWidgets('column width is shared across rows that omit it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table cellspacing="3" width="600"><tbody>'
        '<tr><td width="150" bgcolor="#eeeeee">L1</td><td bgcolor="#eeeeee">V1</td></tr>'
        '<tr><td bgcolor="#eeeeee">Label two</td><td bgcolor="#eeeeee">V2</td></tr>'
        '</tbody></table>',
        width: 600,
      ),
    );
    // Row 2's first cell omits width but inherits the 150px column, so the
    // value cells start at the same x in both rows.
    final v1 = _richContaining(tester, 'V1')!;
    final v2 = _richContaining(tester, 'V2')!;
    expect(
      tester.getTopLeft(find.byWidget(v1)).dx,
      closeTo(tester.getTopLeft(find.byWidget(v2)).dx, 0.5),
    );
  });

  testWidgets('max-width limits a block width', (tester) async {
    await tester.pumpWidget(
      _host(
        '<div style="max-width:300px">A fairly long line of text that would '
        'otherwise stretch far wider than three hundred logical pixels</div>',
        width: 1000,
      ),
    );
    final rich = _richContaining(tester, 'fairly long')!;
    expect(tester.getSize(find.byWidget(rich)).width, lessThanOrEqualTo(301));
  });

  testWidgets('border longhands (style/width/color) draw a border', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="border-style:solid;border-width:thin;border-color:#dadce0;'
        'border-radius:8px;padding:10px">boxed</div>',
      ),
    );
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).border != null,
        );
    final deco = box.decoration as BoxDecoration;
    expect(deco.border!.top.color, const Color(0xFFDADCE0));
    expect(deco.borderRadius, BorderRadius.circular(8));
  });

  testWidgets('@media border-style:none overrides an inline border', (
    tester,
  ) async {
    // A responsive rule that hides a decorative frame must actually remove the
    // inline `border:` shorthand, not be ignored (Twitch hero avatar frame).
    await tester.pumpWidget(
      _host(
        '<html><head><style>'
        '@media screen and (min-width:50px){'
        '.frame{border-style:none !important;border-width:0 !important;'
        'border-color:transparent !important}}'
        '</style></head><body>'
        '<div class="frame" style="border:6px solid #FF73E5;padding:4px">x</div>'
        '</body></html>',
        width: 400,
      ),
    );
    const pink = Color(0xFFFF73E5);
    for (final c in tester.widgetList<Container>(find.byType(Container))) {
      final deco = c.decoration;
      if (deco is BoxDecoration && deco.border is Border) {
        final b = deco.border as Border;
        for (final s in [b.top, b.right, b.bottom, b.left]) {
          expect(
            s.color == pink && s.width > 0,
            isFalse,
            reason: 'pink frame border should be removed by @media',
          );
        }
      }
    }
  });

  testWidgets('table background-image with background-size:100% scales to fit', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table style="background-image:url($png);background-size:100%;width:200px">'
        '<tbody><tr><td>hi</td></tr></tbody></table>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final scaled = tester
        .widgetList<Image>(find.byType(Image))
        .any((i) => i.fit == BoxFit.fitWidth);
    expect(
      scaled,
      isTrue,
      reason: 'a full-width background image scales to the box width',
    );
  });

  testWidgets('table cell renders its CSS background-image', (tester) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table><tbody><tr><td style="background-image:url($png);'
        'background-size:cover;width:200px;height:100px">cell</td>'
        '</tr></tbody></table>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final background = tester
        .widgetList<Image>(find.byType(Image))
        .where((image) => image.fit == BoxFit.cover);
    expect(background, isNotEmpty);
  });

  testWidgets('spanning table cell keeps its CSS background-image', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table><tbody><tr><td>a</td><td>b</td></tr><tr>'
        '<td colspan="2" style="background-image:url($png);'
        'background-size:cover;height:100px">wide</td>'
        '</tr></tbody></table>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final background = tester
        .widgetList<Image>(find.byType(Image))
        .where((image) => image.fit == BoxFit.cover);
    expect(background, isNotEmpty);
  });

  testWidgets('background repeat-y paints sliced email card middles', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div style="width:200px">'
        '<div style="background:url($png) no-repeat;width:100%;height:20px"></div>'
        '<div style="background:url($png) repeat-y;width:100%;height:120px">'
        'middle</div>'
        '<div style="background-image:url($png);background-repeat:repeat-y;'
        'width:100%;height:80px">longhand</div>'
        '</div>',
        width: 400,
      ),
    );
    await tester.pump();

    final repeated = tester
        .widgetList(find.byWidgetPredicate(_isTiledBackground))
        .toList();

    expect(repeated, hasLength(2));
  });

  testWidgets('background repeat paints through layout-neutral tiled layer', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div style="background-image:url($png);'
        'width:200px;height:80px">default</div>'
        '<div style="background-image:url($png);background-repeat:repeat;'
        'width:200px;height:80px">explicit</div>',
        width: 400,
      ),
    );
    await tester.pump();

    final tiled = tester
        .widgetList(find.byWidgetPredicate(_isTiledBackground))
        .toList();

    expect(tiled, hasLength(2));
  });

  testWidgets('tiled background freezes animated image streams', (
    tester,
  ) async {
    final provider = _ManualImageProvider();
    await tester.pumpWidget(
      _host(
        '<div style="background-image:url(manual:animated);'
        'background-repeat:repeat;width:200px;height:80px">tile</div>',
        width: 400,
        config: HtmlRenderConfig(
          imageResolver: _SingleImageResolver('manual:animated', provider),
        ),
      ),
    );

    final listenerCountBeforeFirstFrame = provider.completer.listenerCount;
    expect(listenerCountBeforeFirstFrame, greaterThan(0));

    final frame = await tester.runAsync(
      () => createTestImage(width: 1, height: 1),
    );
    expect(frame, isNotNull);
    provider.completer.emit(frame!);
    await tester.pump();

    expect(provider.completer.removeCount, greaterThan(0));
    expect(
      provider.completer.listenerCount,
      lessThan(listenerCountBeforeFirstFrame),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'percent-width avatar applies max-width after resolving its containing block',
    (tester) async {
      // Twitch-style hero: the profile is 37% of the 600px cell, capped at
      // 230px. The percentage must use the cell (222px), not the max-width
      // itself (37% of 230px = 85.1px).
      const png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      await tester.pumpWidget(
        _host(
          '<table width="100%" cellspacing="0" cellpadding="0" '
          'style="background-image:url($png);background-size:100%">'
          '<tbody><tr><td style="padding:3% 0 10%;text-align:center">'
          '<div style="margin:0 auto;width:37%;max-width:230px">'
          '<img src="$png" alt="streamer" width="230" height="230" '
          'style="width:100%;max-width:230px;height:auto;display:block">'
          '</div></td></tr></tbody></table>',
          width: 600,
        ),
      );
      await tester.pump();

      final avatar = tester
          .widgetList<Image>(find.byType(Image))
          .singleWhere((image) => image.semanticLabel == 'streamer');
      final size = tester.getSize(find.byWidget(avatar));
      expect(size.width, closeTo(222, 0.01));
      expect(size.height, closeTo(222, 0.01));
      final avatarRect = tester.getRect(find.byWidget(avatar));
      final viewRect = tester.getRect(find.byType(HtmlEmailView));
      expect(avatarRect.center.dx, closeTo(viewRect.center.dx, 0.01));
      // 3% top + 10% bottom padding resolve against the 600px cell width.
      // Keeping the avatar at its proper size also restores the hero backdrop's
      // intended 300px box instead of collapsing it to about 163px.
      expect(viewRect.height, greaterThan(290));
    },
  );

  testWidgets('image-list li renders its background-image bullet (sized)', (
    tester,
  ) async {
    // An "image list" uses a `background-image` (sized with `background-size`)
    // as the bullet — the star in the FAST FIVE section.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<ul style="list-style-type:none">'
        '<li style="background-image:url($png);background-size:16px;'
        'background-position:left 6px;padding-left:35px;list-style-type:none">'
        'Android CLI reaches 1.0.</li></ul>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final sized = tester
        .widgetList<Image>(find.byType(Image))
        .any((i) => i.width == 16);
    expect(sized, isTrue, reason: 'the 16px star bullet should render');
  });

  testWidgets('margin:0 auto 0 0 left-aligns a max-width block', (
    tester,
  ) async {
    // `margin-right:auto` (with margin-left:0) pushes the box left, not centre
    // — a left-aligned icon (`max-width:25px;margin:0 auto 0 0`).
    await tester.pumpWidget(
      _host(
        '<div style="text-align:center">'
        '<div style="max-width:50px;margin:0 auto 0 0;background-color:#abcdef">x</div>'
        '</div>',
        width: 600,
      ),
    );
    final box = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFFABCDEF),
    );
    final hostLeft = tester.getTopLeft(find.byType(HtmlEmailView)).dx;
    // The box hugs the left edge, not centred.
    expect(tester.getTopLeft(box).dx, closeTo(hostLeft, 2));
  });

  testWidgets('background-image stays at the edge while padding offsets text', (
    tester,
  ) async {
    // A `padding-left` must offset the content but NOT the background image
    // (the star bullet stays at the left edge, not pushed onto the text).
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div style="background-image:url($png);background-size:16px;'
        'background-position:left;padding-left:35px">Title text</div>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final img = find.byWidgetPredicate((w) => w is Image && w.width == 16);
    final text = find.byWidget(_richContaining(tester, 'Title text')!);
    // Star at the left edge, text padded ~35px to its right (no overlap).
    expect(
      tester.getTopLeft(img).dx + 16,
      lessThanOrEqualTo(tester.getTopLeft(text).dx + 1),
    );
  });

  testWidgets('width:100% inline-block table is full-width (divider rule)', (
    tester,
  ) async {
    // A `display:inline-block; width:100%` table is a full-width divider, not a
    // content-sized inline element — its border-top must span the width.
    await tester.pumpWidget(
      _host(
        '<table width="100%" style="border-top:solid 2px #202124;'
        'display:inline-block"><tbody><tr><td></td></tr></tbody></table>',
        width: 500,
      ),
    );
    expect(_decoratedBorder(tester).top.width, 2);
    expect(tester.getSize(find.byType(Table)).width, greaterThan(400));
  });

  testWidgets('scaled background honors background-position (center top)', (
    tester,
  ) async {
    // A header backdrop with `background-position:center top` must sit at the
    // top (behind a logo), not be vertically centred — Google Developer
    // newsletter header.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table style="background-image:url($png);background-size:cover;'
        'background-position:center top;width:200px"><tbody><tr><td>hi</td>'
        '</tr></tbody></table>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final img = tester
        .widgetList<Image>(find.byType(Image))
        .firstWhere((i) => i.fit == BoxFit.cover);
    expect(img.alignment, Alignment.topCenter);
  });

  testWidgets('background-image with border-radius rounds its corners', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table style="background-image:url($png);background-size:cover;'
        'border-radius:16px;width:200px"><tbody><tr><td>hi</td></tr></tbody></table>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ClipRRect), findsWidgets);
  });

  testWidgets('blocked-image placeholder in a tiny slot does not overflow', (
    tester,
  ) async {
    // A Row-based blocked placeholder dropped into a 12px inline icon slot must
    // not throw a RenderFlex overflow (it scales down to fit).
    final config = HtmlRenderConfig(
      imageResolver: const DefaultHtmlImageResolver(allowRemoteImages: false),
      blockedImageBuilder: (context, src, attrs) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(attrs['alt'] ?? '', overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(
      _host(
        'before <img src="http://example.com/arrow.png" width="12" alt="x"> after',
        width: 200,
        config: config,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('display:block image centers via margin:0 auto', (tester) async {
    // A block image with `margin:0 auto` inside a left-aligned container must
    // centre (it's block-level), not flow inline and sit at the left — Apple's
    // App Store Connect / Xcode / Account icons.
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div style="text-align:left">'
        '<img src="$png" width="64" height="64" '
        'style="display:block;margin:0 auto" alt="icon"></div>',
        width: 400,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final img = tester.widgetList<Image>(find.byType(Image)).first;
    final f = find.byWidget(img);
    final imgCenter = tester.getTopLeft(f).dx + tester.getSize(f).width / 2;
    // Centre of the 400px host (minus the centering of the SizedBox in _host).
    final host = find.byType(HtmlEmailView);
    final hostCenter =
        tester.getTopLeft(host).dx + tester.getSize(host).width / 2;
    expect(imgCenter, closeTo(hostCenter, 1));
  });

  testWidgets('img border-radius:50% clips to an oval', (tester) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<img src="$png" width="20" height="20" style="border-radius:50%" alt="a">',
      ),
    );
    expect(find.byType(ClipOval), findsOneWidget);
  });

  testWidgets('cell width wider than container is clamped (wide-image)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1820, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAABytg0kAAAAEklEQVR42mNk+M9Qz0BkYBxVSFQFAJ3rA/2gC1ABAAAAAElFTkSuQmCC';
    // Substack wide-image: an empty spacer cell + a content cell with a huge
    // width="1456" inside a 600px content column. The cell must clamp to the
    // column (not overflow off to the right).
    await tester.pumpWidget(
      _host(
        '<div style="max-width:600px;margin:0 auto">'
        '<table width="100%"><tbody><tr>'
        '<td></td>'
        '<td width="1456" align="left">'
        '<img width="550" height="100" '
        'style="display:block;width:auto;max-width:100%;margin:0 auto" src="$png">'
        '</td></tr></tbody></table></div>',
        width: 1820,
      ),
    );
    final imgRect = tester.getRect(find.byType(Image).first);
    // Centered within the 600px column (x 610..1210), not pushed right.
    expect(imgRect.left, greaterThan(590));
    expect(imgRect.right, lessThan(1230));
  });

  testWidgets('width-less inline-block image buttons sit side by side', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<div>'
        '<a style="display:inline-block;margin:0 4px"><img width="131" height="40" src="$png"></a>'
        '<a style="display:inline-block;margin:0 4px"><img width="135" height="40" src="$png"></a>'
        '</div>',
        width: 600,
      ),
    );
    final imgs = tester.widgetList<Image>(find.byType(Image)).toList();
    final a = tester.getRect(find.byWidget(imgs[0]));
    final b = tester.getRect(find.byWidget(imgs[1]));
    expect(a.top, closeTo(b.top, 2)); // same row
    expect(b.left, greaterThan(a.right)); // side by side, not stacked
  });

  testWidgets('icon+label pill button stays on one line (no icon-over-text)', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table width="100%"><tbody><tr>'
        '<td><a style="display:inline-block;padding:9px 14px;border-radius:9999px">'
        '<img width="18" height="18" style="margin-right:8px" src="$png"><span>Comment</span></a></td>'
        '<td width="8"></td>'
        '<td><a style="display:inline-block;padding:9px 14px;border-radius:9999px">'
        '<img width="18" height="18" style="margin-right:8px" src="$png"><span>Restack</span></a></td>'
        '</tr></tbody></table>',
        width: 600,
      ),
    );
    final rich = _richContaining(tester, 'Comment')!;
    // One line: icon (18) + label fit on a single ~18px-tall run, not stacked.
    expect(tester.getSize(find.byWidget(rich)).height, lessThan(28));
  });

  testWidgets('empty nested table does not steal width from centered buttons', (
    tester,
  ) async {
    // Substack footer shape: [ <table margin:0 auto> group ] [ empty table ].
    // The structural empty table must collapse so the first cell receives the
    // full row width and can centre its group against the whole email.
    await tester.pumpWidget(
      _host(
        '<table width="100%"><tbody><tr>'
        '<td><table width="auto" style="margin:0 auto"><tbody><tr>'
        '<td><a style="display:inline-block;padding:9px 14px">Like</a></td>'
        '</tr></tbody></table></td>'
        '<td align="right"><table width="auto"><tbody><tr></tr></tbody></table></td>'
        '</tr></tbody></table>',
        width: 600,
      ),
    );
    expect(tester.takeException(), isNull);
    final like = _richContaining(tester, 'Like')!;
    final r = tester.getRect(find.byWidget(like));
    final view = tester.getRect(find.byType(HtmlEmailView));
    final center = (r.left + r.right) / 2;
    final viewCenter = (view.left + view.right) / 2;
    // Centre of the "Like" group sits near the email's midpoint, not pinned to
    // the left edge.
    expect(
      (center - viewCenter).abs(),
      lessThan(40),
      reason: 'group center=$center should be ~$viewCenter',
    );
    expect(
      r.left,
      greaterThan(view.left + 60),
      reason: 'group should not hug the left edge',
    );
  });

  testWidgets(
    'real sibling beside centered sub-table remains in the same row',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table width="100%"><tbody><tr>'
          '<td><table width="auto" style="margin:0 auto"><tbody><tr>'
          '<td>Like</td></tr></tbody></table></td>'
          '<td align="right">Read</td>'
          '</tr></tbody></table>',
          width: 600,
        ),
      );
      expect(tester.takeException(), isNull);
      final like = tester.getRect(
        find.byWidget(_richContaining(tester, 'Like')!),
      );
      final read = tester.getRect(
        find.byWidget(_richContaining(tester, 'Read')!),
      );
      expect(
        (like.center.dy - read.center.dy).abs(),
        lessThan(3),
        reason: 'a non-empty sibling must not be moved to a stacked row',
      );
    },
  );

  testWidgets('border:0 draws no border (not a 1px hairline)', (tester) async {
    // `border: 0` parses to a zero-width side; Flutter renders BorderSide(width:0)
    // as a 1px hairline, so it must map to BorderSide.none instead of a black line.
    await tester.pumpWidget(
      _host(
        '<table style="border:0"><tbody><tr>'
        '<td style="border:0">a</td><td style="border:0">b</td>'
        '</tr></tbody></table>',
      ),
    );
    expect(tester.takeException(), isNull);
    for (final t in tester.widgetList<Table>(find.byType(Table))) {
      final b = t.border;
      if (b == null) continue;
      for (final s in [
        b.top,
        b.bottom,
        b.left,
        b.right,
        b.horizontalInside,
        b.verticalInside,
      ]) {
        expect(s, BorderSide.none, reason: 'border:0 must not draw a hairline');
      }
    }
    // A non-table box with border:0 likewise draws nothing.
    await tester.pumpWidget(_host('<div style="border:0">x</div>'));
    for (final d in tester.widgetList<DecoratedBox>(
      find.byType(DecoratedBox),
    )) {
      final dec = d.decoration;
      if (dec is BoxDecoration && dec.border != null) {
        expect(dec.border!.top, BorderSide.none);
      }
    }
  });

  testWidgets('colspan table falls back without using Table widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table><tbody>'
        '<tr><td colspan="2">wide header</td></tr>'
        '<tr><td>a</td><td>b</td></tr>'
        '</tbody></table>',
      ),
    );
    expect(find.byType(Table), findsNothing);
    expect(find.textContaining('wide header'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('spacer cell height is honored in a colspan/fallback table', (
    tester,
  ) async {
    // Email vertical rhythm uses 1px-line spacer cells sized only by height=N.
    // A colspan row forces the fallback path, which must still apply the height.
    await tester.pumpWidget(
      _host(
        '<table width="600"><tbody>'
        '<tr><td colspan="2" height="48" style="font-size:1px;line-height:1px">'
        '<div>&nbsp;</div></td></tr>'
        '<tr><td>left</td><td>right</td></tr>'
        '</tbody></table>',
        width: 600,
      ),
    );
    expect(tester.takeException(), isNull);
    final left = _richContaining(tester, 'left')!;
    // The 48px spacer pushes the content row down by ~48px.
    expect(tester.getRect(find.byWidget(left)).top, greaterThan(40));
  });

  testWidgets('per-corner border-radius rounds only the named corners', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="200" bgcolor="#ffffff" '
        'style="border-top-left-radius:16px;border-top-right-radius:16px">'
        '<tbody><tr><td>card</td></tr></tbody></table>',
        width: 300,
      ),
    );
    expect(tester.takeException(), isNull);
    BorderRadius? found;
    for (final c in tester.widgetList<Container>(find.byType(Container))) {
      final d = c.decoration;
      if (d is BoxDecoration && d.borderRadius is BorderRadius) {
        found = d.borderRadius as BorderRadius;
      }
    }
    expect(found, isNotNull);
    expect(found!.topLeft, const Radius.circular(16));
    expect(found.topRight, const Radius.circular(16));
    expect(found.bottomLeft, Radius.zero);
    expect(found.bottomRight, Radius.zero);
  });

  testWidgets('border-spacing pads a single-cell box (no cell padding)', (
    tester,
  ) async {
    // A metric tile whose only inset comes from `border-spacing` on the table.
    await tester.pumpWidget(
      _host(
        '<div style="background-color:#18181B">'
        '<table style="border-spacing:30px 10px"><tbody><tr>'
        '<td style="padding:0">Subs</td>'
        '</tr></tbody></table></div>',
        width: 400,
      ),
    );
    expect(tester.takeException(), isNull);
    final text = _richContaining(tester, 'Subs')!;
    final t = tester.getRect(find.byWidget(text));
    // Find the dark box and confirm the text is inset by border-spacing.
    for (final c in tester.widgetList<Container>(find.byType(Container))) {
      final d = c.decoration;
      final col = d is BoxDecoration ? d.color : c.color;
      if (col == const Color(0xFF18181B)) {
        final box = tester.getRect(find.byWidget(c));
        expect(t.left - box.left, greaterThan(20)); // ~30px horizontal
        expect(t.top - box.top, greaterThan(6)); // ~10px vertical
        return;
      }
    }
    fail('dark box not found');
  });

  testWidgets('colgroup widths apply in border-spacing fallback tables', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="width:600px;border-collapse:separate;border-spacing:5px">'
        '<colgroup><col style="width:130px"></colgroup><tbody>'
        '<tr><th style="padding:2px 0;text-align:left">Project</th>'
        '<td style="padding:5px 10px;background:#f4f5f6">friday</td></tr>'
        '<tr><th style="padding:2px 0;text-align:left">Level</th>'
        '<td style="padding:5px 10px;background:#f4f5f6">error</td></tr>'
        '</tbody></table>',
        width: 700,
      ),
    );

    final labelLeft = tester.getTopLeft(find.text('Project')).dx;
    final valueLeft = tester.getTopLeft(find.text('friday')).dx;

    expect(valueLeft - labelLeft, closeTo(145, 10));
  });

  testWidgets('boxed links keep their border and shrink to content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="width:600px">'
        '<a style="display:flex;float:right;border:1px solid #c1b8ca;'
        'border-radius:4px;padding:8px 15px">Set up in Slack</a>'
        '</div>',
        width: 600,
      ),
    );

    final border = _decoratedBorder(tester);
    expect(border.top.color, const Color(0xFFC1B8CA));
    expect(border.top.width, 1);

    final button = tester.getRect(find.text('Set up in Slack'));
    expect(button.width, lessThan(300));
  });

  testWidgets('list-style none inline-block list items wrap as tag chips', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<ul style="list-style:none;margin:0;padding:0">'
        '<li style="display:inline-block;margin-right:5px;margin-bottom:10px;'
        'border-radius:3px;background-color:#f4f5f6;padding:5px 10px 6px">'
        'browser = Chrome</li>'
        '<li style="display:inline-block;margin-right:5px;margin-bottom:10px;'
        'border-radius:3px;background-color:#f4f5f6;padding:5px 10px 6px">'
        'browser.name = Chrome</li>'
        '<li style="display:inline-block;margin-right:5px;margin-bottom:10px;'
        'border-radius:3px;background-color:#f4f5f6;padding:5px 10px 6px">'
        'environment = production</li>'
        '</ul>',
        width: 600,
      ),
    );

    final first = tester.getRect(find.text('browser = Chrome'));
    final second = tester.getRect(find.text('browser.name = Chrome'));

    expect((first.top - second.top).abs(), lessThan(2));
    expect(second.left, greaterThan(first.right));
    expect(find.text('\u2022'), findsNothing);
  });

  testWidgets('inline-block linked auto button table stays inside card column', (
    tester,
  ) async {
    String card(String name) =>
        '<table width="100%" style="border:1px solid #e6e6e6;'
        'border-radius:8px"><tbody><tr><td style="padding:8px">'
        '<table width="100%"><tbody>'
        '<tr><td align="center" style="height:120px">$name</td></tr>'
        '<tr><td style="height:70px">'
        '<table width="100%"><tbody><tr><td align="middle">'
        '<a style="display:inline-block;text-decoration:none">'
        '<table width="auto" style="border-collapse:separate"><tbody><tr>'
        '<td style="border:1px solid #0a66c2;border-radius:24px;'
        'padding:12px 24px;font-size:16px;font-weight:600;line-height:1.25;'
        'color:#0a66c2;text-align:center">'
        '<a href="https://example.test" '
        'style="display:inline-block;text-decoration:none;color:#0a66c2">'
        '<span>Establish contact</span></a>'
        '</td></tr></tbody></table>'
        '</a>'
        '</td></tr></tbody></table>'
        '</td></tr></tbody></table>'
        '</td></tr></tbody></table>';

    await tester.pumpWidget(
      _host(
        '<table width="512" style="border-collapse:collapse"><tbody><tr>'
        '<td width="50%" style="width:50%;padding-right:8px">${card('A')}</td>'
        '<td width="50%" style="width:50%;padding-left:8px">${card('B')}</td>'
        '</tr></tbody></table>',
        width: 512,
      ),
    );

    Rect renderRect(Element element) {
      final box = element.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }

    final blueButtons = find
        .byWidgetPredicate((widget) {
          if (widget is! DecoratedBox) return false;
          final decoration = widget.decoration;
          if (decoration is! BoxDecoration) return false;
          final border = decoration.border;
          return border is Border &&
              border.top.color == const Color(0xFF0A66C2) &&
              border.top.width == 1;
        })
        .evaluate()
        .map(renderRect)
        .toList();
    expect(blueButtons, hasLength(2));

    final leftButton = blueButtons.reduce((a, b) => a.left < b.left ? a : b);
    final rightButton = blueButtons.reduce((a, b) => a.left > b.left ? a : b);

    expect(leftButton.width, greaterThan(200));
    expect(rightButton.width, greaterThan(200));
    expect(leftButton.right, lessThan(rightButton.left));
  });

  testWidgets(
    'inline-block linked auto button table keeps content width when it fits',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table width="512"><tbody><tr><td align="center">'
          '<a style="display:inline-block;text-decoration:none">'
          '<table width="auto" style="border-collapse:separate"><tbody><tr>'
          '<td bgcolor="#0a66c2" style="background:#0a66c2;'
          'border-radius:24px;padding:12px 24px;font-size:16px;'
          'font-weight:600;line-height:1.25;color:#ffffff;text-align:center">'
          '<a href="https://example.test" '
          'style="display:inline-block;text-decoration:none;color:#ffffff">'
          '<span>Establish contact</span></a>'
          '</td></tr></tbody></table>'
          '</a>'
          '</td></tr></tbody></table>',
          width: 512,
        ),
      );

      final blueButton = find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.color == const Color(0xFF0A66C2);
      }).first;
      final rect = tester.getRect(blueButton);

      expect(rect.width, greaterThan(300));
      expect(rect.height, lessThan(60));
    },
  );

  testWidgets('td align=middle centers linked auto button tables', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table width="512"><tbody><tr><td align="middle">'
        '<a style="display:inline-block;text-decoration:none">'
        '<table width="auto" style="border-collapse:separate"><tbody><tr>'
        '<td bgcolor="#0a66c2" style="background:#0a66c2;'
        'border-radius:24px;padding:12px 24px;font-size:16px;'
        'font-weight:600;line-height:1.25;color:#ffffff;text-align:center">'
        '<a href="https://example.test" '
        'style="display:inline-block;text-decoration:none;color:#ffffff">'
        '<span>See more</span></a>'
        '</td></tr></tbody></table>'
        '</a>'
        '</td></tr></tbody></table>',
        width: 512,
      ),
    );

    final blueButton = find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      return decoration is BoxDecoration &&
          decoration.color == const Color(0xFF0A66C2);
    }).first;
    final rect = tester.getRect(blueButton);
    final host = tester.getRect(find.byType(HtmlEmailView));

    expect(rect.center.dx, closeTo(host.center.dx, 2));
  });

  testWidgets('rowspan media + colspan overlay icon renders as a Stack', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    // Twitch "Top Clip" shape: thumbnail spans both rows; the play icon row
    // (colspan) must overlay it, not drop below.
    await tester.pumpWidget(
      _host(
        '<table><tbody>'
        '<tr><td></td>'
        '<td rowspan="2"><img src="$png" width="200" height="120"></td></tr>'
        '<tr><td colspan="2"><img src="$png" width="40" height="40"></td></tr>'
        '</tbody></table>',
        width: 400,
      ),
    );
    expect(tester.takeException(), isNull);
    final imgs = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(imgs.length, 2);
    final a = tester.getRect(find.byWidget(imgs[0]));
    final b = tester.getRect(find.byWidget(imgs[1]));
    // The two images share a center (overlay), rather than stacking vertically.
    expect((a.center.dx - b.center.dx).abs(), lessThan(2));
    expect((a.center.dy - b.center.dy).abs(), lessThan(2));
  });

  testWidgets('empty decorated table resolves percent height from ancestor', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="height:200px">'
        '<table style="height:25%;width:100%"><tbody><tr>'
        '<td style="padding:0;background:#bf94ff"></td>'
        '</tr></tbody></table></div>',
        width: 300,
      ),
    );
    expect(tester.takeException(), isNull);
    Rect? decorated;
    for (final c in tester.widgetList<Container>(find.byType(Container))) {
      final d = c.decoration;
      if (d is BoxDecoration && d.color == const Color(0xFFBF94FF)) {
        decorated = tester.getRect(find.byWidget(c));
      }
    }
    expect(decorated, isNotNull);
    expect(decorated!.height, closeTo(50, 1));
  });

  testWidgets('bottom-aligned percentage chart bars meet the x-axis', (
    tester,
  ) async {
    const purple = Color(0xFFBF94FF);
    const axisColor = Color(0xFFADADB8);
    await tester.pumpWidget(
      _host(
        '<div style="height:322px;padding:20px 30px">'
        '<table style="width:100%;height:100%"><tbody>'
        '<tr style="height:0%"><td><table style="width:100%;margin-bottom:30px">'
        '<tr><td>Average Viewers</td></tr></table></td></tr>'
        '<tr><td><table style="width:100%;height:100%"><tbody><tr>'
        '<td style="width:6%"><table style="height:100%"><tr><td>11</td></tr>'
        '<tr><td>6</td></tr><tr><td>0</td></tr></table></td>'
        '<td><table style="width:100%;height:90%"><tbody><tr><td style="padding:0;height:100%;'
        'border-left:2px solid #ADADB8;border-bottom:2px solid #ADADB8">'
        '<table style="width:100%;height:235px;border-spacing:1px 0"><tr>'
        '<td style="vertical-align:bottom;padding:0"><table style="width:100%;'
        'height:100%"><tr><td style="vertical-align:bottom;padding:0">'
        '<table style="width:100%;height:50%"><tr><td style="background-color:'
        '#BF94FF;padding:0"></td></tr></table></td></tr></table></td>'
        '<td style="vertical-align:bottom;padding:0"><table style="width:100%;'
        'height:100%"><tr><td style="vertical-align:bottom;padding:0">'
        '<table style="width:100%;height:90%"><tr><td style="background-color:'
        '#BF94FF;padding:0"></td></tr></table></td></tr></table></td>'
        '</tr></table></td></tr><tr></tr></tbody></table>'
        '<table style="width:100%"><tr><td>00:00:00</td><td>04:23:00</td>'
        '</tr></table></td></tr></tbody></table></td></tr></tbody></table></div>',
        width: 600,
      ),
    );

    Rect? axis;
    final bars = <Rect>[];
    for (final container in tester.widgetList<Container>(
      find.byType(Container),
    )) {
      final decoration = container.decoration;
      if (decoration is! BoxDecoration) continue;
      if (decoration.color == purple) {
        bars.add(tester.getRect(find.byWidget(container)));
      }
      final border = decoration.border;
      if (border is Border && border.bottom.color == axisColor) {
        axis = tester.getRect(find.byWidget(container));
      }
    }
    expect(axis, isNotNull);
    expect(bars, isNotEmpty);
    for (final bar in bars) {
      expect(bar.bottom, closeTo(axis!.bottom - 2, 0.01));
    }
  });

  testWidgets(
    'single-column percent table distributes definite sibling height',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table style="width:100%"><tbody><tr>'
          '<td style="width:6%;padding:0">'
          '<table style="height:100%"><tbody>'
          '<tr><td>A</td></tr><tr><td>B</td></tr><tr><td>C</td></tr>'
          '</tbody></table></td>'
          '<td style="padding:0"><table style="height:240px;width:100%">'
          '<tbody><tr><td></td></tr></tbody></table></td>'
          '</tr></tbody></table>',
          width: 500,
        ),
      );
      expect(tester.takeException(), isNull);
      final a = tester.getRect(find.byWidget(_richContaining(tester, 'A')!));
      final b = tester.getRect(find.byWidget(_richContaining(tester, 'B')!));
      final c = tester.getRect(find.byWidget(_richContaining(tester, 'C')!));
      expect(b.top - a.top, greaterThan(60));
      expect(c.top - b.top, greaterThan(60));
    },
  );

  testWidgets(
    'percent column reserves its share and auto column gets remainder',
    (tester) async {
      await tester.pumpWidget(
        _host(
          '<table style="width:100%"><tbody><tr>'
          '<td style="width:6%">axis</td>'
          '<td style="background:#123456">content</td>'
          '</tr></tbody></table>',
          width: 500,
        ),
      );
      expect(tester.takeException(), isNull);
      Rect? content;
      for (final c in tester.widgetList<Container>(find.byType(Container))) {
        final d = c.decoration;
        if (d is BoxDecoration && d.color == const Color(0xFF123456)) {
          content = tester.getRect(find.byWidget(c));
        }
      }
      expect(content, isNotNull);
      expect(content!.width, greaterThan(430));
    },
  );

  testWidgets('media overlay fallback preserves tables with other content', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<table><tbody>'
        '<tr><td>caption</td><td rowspan="2"><img src="$png"></td></tr>'
        '<tr><td colspan="2"><img src="$png"></td></tr>'
        '</tbody></table>',
      ),
    );
    expect(tester.takeException(), isNull);
    expect(_richContaining(tester, 'caption'), isNotNull);
  });

  testWidgets('percent-width image fills its container width', (tester) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    // `width:100%` with no pixel width must fill the container, not sit at the
    // 1px natural bitmap width. A known height keeps the test deterministic.
    await tester.pumpWidget(
      _host('<img src="$png" style="width:100%" height="40">', width: 300),
    );
    final size = tester.getSize(find.byType(Image));
    expect(size.width, closeTo(300, 1));
    expect(size.height, closeTo(40, 1));
  });

  testWidgets('percent-width image without height does not collapse', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host('<img src="$png" style="width:100%">', width: 240),
    );
    await tester.pumpAndSettle();

    final imageSize = tester.getSize(find.byType(Image));
    expect(imageSize.width, closeTo(240, 1));
    // The wrapper, rather than the undecoded RenderImage, owns the provisional
    // height. Keeping the child loose is what lets a later decoded aspect ratio
    // replace the square fallback instead of being permanently cropped to it.
    expect(
      tester.getSize(find.byType(HtmlEmailView)).height,
      greaterThanOrEqualTo(240),
    );
  });

  testWidgets('async percent-width image adopts its decoded aspect ratio', (
    tester,
  ) async {
    const src = 'https://example.test/wide.png';
    final provider = _ManualImageProvider();
    await tester.pumpWidget(
      _host(
        '<table width="600"><tr><td style="padding:0 15px">'
        '<img src="$src" width="570" style="width:100%;max-width:100%;'
        'object-fit:cover;display:block">'
        '</td></tr></table>',
        width: 600,
        config: HtmlRenderConfig(
          imageResolver: _SingleImageResolver(src, provider),
        ),
      ),
    );
    await tester.pump();

    // Keep the row non-zero before decoding, then replace that provisional
    // square with the bitmap's real 400:153 aspect ratio.
    expect(tester.getSize(find.byType(Image)), const Size(570, 0));
    expect(
      tester.getSize(find.byType(HtmlEmailView)).height,
      greaterThanOrEqualTo(570),
    );
    final frame = await tester.runAsync(
      () => createTestImage(width: 400, height: 153),
    );
    provider.completer.emit(frame!);
    await tester.pump();

    final decoded = tester.getSize(find.byType(Image));
    expect(decoded.width, closeTo(570, 0.01));
    expect(decoded.height, closeTo(570 * 153 / 400, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('linked image tap follows the anchor, not image tap', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    String? linkTap;
    String? imageTap;
    await tester.pumpWidget(
      _host(
        '<a href="https://example.test"><img src="$png" width="24" height="24"></a>',
        width: 120,
        config: HtmlRenderConfig(
          onLinkTap: (url, _) => linkTap = url,
          onImageTap: (src, _) => imageTap = src,
        ),
      ),
    );

    await tester.tap(find.byType(Image));

    expect(linkTap, 'https://example.test');
    expect(imageTap, isNull);
  });

  testWidgets('list keeps non-<li> children (nested list, stray block)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<ul><li>one</li><div>stray</div><ul><li>nested</li></ul></ul>',
        width: 400,
      ),
    );
    expect(_richContaining(tester, 'one'), isNotNull);
    expect(_richContaining(tester, 'stray'), isNotNull);
    expect(_richContaining(tester, 'nested'), isNotNull);
  });

  testWidgets('ol with list-style:none renders no numbers', (tester) async {
    await tester.pumpWidget(
      _host(
        '<ol style="list-style:none"><li>alpha</li><li>beta</li></ol>',
        width: 400,
      ),
    );
    expect(_richContaining(tester, 'alpha'), isNotNull);
    expect(_richContaining(tester, '1.'), isNull);
    expect(_richContaining(tester, '2.'), isNull);
  });

  testWidgets('hr honors CSS height and background color', (tester) async {
    await tester.pumpWidget(
      _host(
        '<hr style="border:none;height:4px;background:#ff0000">',
        width: 400,
      ),
    );
    // The rule's box is 4px tall and painted red.
    final box = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (c) => c.color == const Color(0xFFFF0000),
          orElse: () => Container(),
        );
    expect(box.color, const Color(0xFFFF0000));
    expect(tester.getSize(find.byWidget(box)).height, closeTo(4, 0.5));
  });

  testWidgets('negative cellpadding/cellspacing do not crash', (tester) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNk+M/wHwAF/gL+XQwAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      _host(
        '<table cellpadding="-5" cellspacing="-3"><tbody>'
        '<tr><td><img src="$png" width="10" height="10"></td></tr></tbody></table>',
        width: 300,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Image)).height, closeTo(10, 0.5));
  });

  testWidgets('em letter-spacing resolves against the element font-size', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<p style="font-size:40px;letter-spacing:0.1em">AB</p>',
        width: 400,
      ),
    );
    final span = _spanWithText(tester, 'AB');
    // 0.1em of 40px = 4px, not 0.1 x a smaller inherited size.
    expect(span?.style?.letterSpacing, closeTo(4.0, 0.2));
  });

  testWidgets('min-height reserves space including content-box padding', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<div style="min-height:40px;padding:12px 0;background:#abcdef">x</div>',
        width: 300,
      ),
    );
    // content-box: 40 + 12 + 12 = 64.
    final box = tester.widgetList<Container>(find.byType(Container)).where((c) {
      final d = c.decoration;
      return d is BoxDecoration && d.color == const Color(0xFFABCDEF);
    }).toList();
    expect(box, isNotEmpty);
    expect(
      tester.getSize(find.byWidget(box.first)).height,
      greaterThanOrEqualTo(63.5),
    );
  });

  testWidgets('gradient background keeps its first color as a fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        '<table style="background:#3a9bed;'
        'background:linear-gradient(to right,#3a9bed 0%,#235ecf 100%)">'
        '<tr><td>View your Wishlist</td></tr></table>',
        width: 400,
      ),
    );

    expect(
      tester.widgetList<Container>(find.byType(Container)).any((container) {
        final decoration = container.decoration;
        return decoration is BoxDecoration &&
            decoration.color == const Color(0xFF3A9BED);
      }),
      isTrue,
    );
  });

  testWidgets('image-only table keeps a percent-width email hero visible', (
    tester,
  ) async {
    const png =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+K'
        'AAAAFElEQVR42mNk+M/wn4GBgYGJAQoAHgQCAf2h6QAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      _host(
        '<table style="width:650px"><tbody><tr><td>'
        '<table style="width:100%"><tbody><tr><td>'
        '<div style="max-width:606px"><a href="https://example.test">'
        '<img src="$png" width="606" '
        'style="display:block;height:auto;width:100%">'
        '</a></div></td></tr></tbody></table>'
        '</td></tr></tbody></table>',
        width: 700,
      ),
    );
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(Image));
    expect(size.width, greaterThan(500));
    // The wrapper reserves the percent-width image's layout height even before
    // the provider reports a decoded aspect ratio.
    expect(tester.getSize(find.byType(HtmlEmailView)).height, greaterThan(500));
  });

  testWidgets('single-cell wrapper grows to its nested email table footer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1607, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rows = List.generate(
      30,
      (index) =>
          '<tr><td style="padding:12px;width:580px">Row $index: '
          'long wrapping text long wrapping text long wrapping text</td></tr>',
    ).join();
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: SizedBox(
            width: 1607,
            child: HtmlEmailView(
              html:
                  '<table width="100%">'
                  '<tr><td style="display:none">preview</td></tr>'
                  '<tr><td><table width="640" align="center">$rows'
                  '<tr><td>FOOTER-MARKER</td></tr>'
                  '</table></td></tr></table>',
              config: const HtmlRenderConfig(fitToWidth: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final view = tester.getRect(find.byType(HtmlEmailView));
    final footer = tester.getRect(find.text('FOOTER-MARKER'));
    expect(view.bottom, greaterThanOrEqualTo(footer.bottom));
    expect(tester.takeException(), isNull);
  });
}

class _SingleImageResolver extends HtmlImageResolver {
  const _SingleImageResolver(this.src, this.provider);

  final String src;
  final ImageProvider provider;

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) {
    return src == this.src
        ? HtmlImageResolution.image(provider)
        : const HtmlImageResolution.unavailable();
  }
}

class _ManualImageProvider extends ImageProvider<_ManualImageProvider> {
  _ManualImageProvider();

  final _ManualImageStreamCompleter completer = _ManualImageStreamCompleter();

  @override
  Future<_ManualImageProvider> obtainKey(ImageConfiguration configuration) {
    return Future<_ManualImageProvider>.value(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _ManualImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return completer;
  }
}

class _ManualImageStreamCompleter extends ImageStreamCompleter {
  var listenerCount = 0;
  var removeCount = 0;

  @override
  void addListener(ImageStreamListener listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listenerCount--;
    removeCount++;
    super.removeListener(listener);
  }

  void emit(ui.Image image) {
    setImage(ImageInfo(image: image));
  }
}
