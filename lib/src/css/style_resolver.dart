import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import 'css_color.dart';
import 'css_declaration_mapper.dart';
import 'css_length.dart';
import 'css_parser.dart';
import 'css_stylesheet.dart';
import 'html_style.dart';

/// Runs the CSS cascade for a single element.
///
/// Order (lowest priority first): inherited parent text properties → user-agent
/// defaults for the tag → presentational HTML attributes (`align`, `bgcolor`,
/// `<font>` …) → author stylesheet rules (by specificity) → inline `style=""`.
class StyleResolver {
  StyleResolver({
    required this.stylesheet,
    required this.rootStyle,
    this.availableWidth = double.infinity,
  }) : rootFontSize = rootStyle.resolvedFontSize;

  final CssStylesheet stylesheet;
  final HtmlStyle rootStyle;
  final double rootFontSize;

  /// The width (logical px) the email is being laid out at. Used to evaluate
  /// `@media (max-width/min-width)` queries so responsive emails adapt.
  final double availableWidth;

  /// Author-stylesheet declarations for [element] at the current
  /// [availableWidth] (media queries resolved). Exposed for the auto-link
  /// styling, which treats a detected URL as a synthetic `<a>`.
  CssDecls sheetDeclarationsFor(dom.Element element) => _sheetCache.putIfAbsent(
    element,
    () => stylesheet.isEmpty
        ? CssDecls.empty
        : stylesheet.declarationsFor(element, availableWidth),
  );

  final _sheetCache = <dom.Element, CssDecls>{};
  final _inlineCache = <dom.Element, CssDecls>{};

  /// Per-instance memo of resolved styles. A [StyleResolver] is created fresh
  /// per build at a fixed [availableWidth], so an element always resolves to the
  /// same style given the same [inherited]. The table handler resolves the same
  /// cells repeatedly (column-width detectors re-walk each cell's subtree), so
  /// caching removes a large amount of redundant cascade work. Guarded by
  /// identity of [inherited] so a different inherited context never hits.
  final Map<dom.Element, ({HtmlStyle inherited, HtmlStyle result})> _cache = {};

  /// Computes the full style for [element] given its parent's [inherited]
  /// (inherited-only) style.
  HtmlStyle resolve(dom.Element element, HtmlStyle inherited) {
    final cached = _cache[element];
    if (cached != null && identical(cached.inherited, inherited)) {
      return cached.result;
    }
    final tag = (element.localName ?? '').toLowerCase();
    final parentFontSize = inherited.fontSize ?? rootFontSize;

    final sheet = sheetDeclarationsFor(element);
    final inline = _inlineCache.putIfAbsent(element, () {
      final raw = element.attributes['style'];
      return raw == null
          ? CssDecls.empty
          : CssParser.parseInlineDeclarations(raw);
    });
    final ua = _userAgentStyle(tag, parentFontSize, inherited);
    final parentCellAlignment = _parentCellAlignment(element, tag);
    final presentational = _presentationalStyle(
      element,
      tag,
      parentFontSize,
      useCellAlign:
          !sheet.values.containsKey('text-align') &&
          !inline.values.containsKey('text-align'),
    );

    // The enclosing link's colour (if any) wins over author element rules like
    // `p{color:#666}` — email clients colour the whole link — but still yields
    // to the element's own inline colour. Applied between the author-normal and
    // inline-normal layers.
    final anchor = inherited.anchorColor != null
        ? HtmlStyle(color: inherited.anchorColor)
        : HtmlStyle.empty;

    // Cascade: normal layers in source priority, then `!important` layers on top
    // (author-important then inline-important) so a responsive `!important`
    // override beats an inline desktop value.
    //
    // A parent cell's `align` acts like an inherited text-align — below the
    // element's own UA default — so an element that sets its own alignment
    // (e.g. `<center>`, whose UA is text-align:center) keeps it inside a
    // `<td align="left">` instead of being overridden by the cell.
    final base = inherited
        .merge(parentCellAlignment)
        .merge(ua)
        .merge(presentational)
        .merge(anchor);
    final declarations = <String, String>{};
    void apply(CssDecls source, {required bool important}) {
      for (final entry in source.values.entries) {
        if (source.important.contains(entry.key) != important) continue;
        declarations.remove(entry.key);
        declarations[entry.key] = entry.value;
      }
    }

    apply(sheet, important: false);
    apply(inline, important: false);
    apply(sheet, important: true);
    apply(inline, important: true);
    // Preserve the email-specific enclosing-anchor colour priority.
    if (inherited.anchorColor != null &&
        !inline.values.containsKey('color') &&
        !sheet.important.contains('color')) {
      declarations.remove('color');
    }
    // Compute related values together: line-height and letter-spacing depend
    // on the final font-size even when they originate in different layers.
    final result = base.merge(
      CssDeclarationMapper.map(
        declarations,
        parentFontSize: parentFontSize,
        rootFontSize: rootFontSize,
        elementFontSize: base.resolvedFontSize,
        inheritedFontFamilies: inherited.fontFamilies,
        inheritedColor: inherited.color,
        inheritedFontWeight: inherited.fontWeight,
        elementColor: base.color,
        baseBorders: base.borders,
      ),
    );
    _cache[element] = (inherited: inherited, result: result);
    return result;
  }

  /// A td/th `align` presentation hint applies to an immediate block child's
  /// text as well (e.g. `<td align=center><h3>...</h3>`). Keep tables out: their
  /// box placement is handled by TableHandler and inheriting this value into a
  /// nested data table would incorrectly center all of its cells.
  HtmlStyle _parentCellAlignment(dom.Element element, String tag) {
    if (tag == 'table') return HtmlStyle.empty;
    final parent = element.parent;
    final parentTag = (parent?.localName ?? '').toLowerCase();
    if (parentTag != 'td' && parentTag != 'th') return HtmlStyle.empty;
    // Author CSS on the cell already participates in normal inheritance.
    // Reapplying its lower-priority HTML hint to the child would override it.
    if (sheetDeclarationsFor(parent!).values.containsKey('text-align') ||
        (_inlineCache[parent] ??
                CssParser.parseInlineDeclarations(
                  parent.attributes['style'] ?? '',
                ))
            .values
            .containsKey('text-align')) {
      return HtmlStyle.empty;
    }
    final align = (parent.attributes['align'] ?? '').toLowerCase();
    final value = switch (align) {
      'left' => TextAlign.left,
      'right' => TextAlign.right,
      'center' => TextAlign.center,
      'middle' => TextAlign.center,
      'justify' => TextAlign.justify,
      _ => null,
    };
    return value == null ? HtmlStyle.empty : HtmlStyle(textAlign: value);
  }

  // --- User-agent default styles ---

  HtmlStyle _userAgentStyle(
    String tag,
    double parentFontSize,
    HtmlStyle inherited,
  ) {
    CssEdges blockMargin(double em) => CssEdges(
      top: CssLength(em, CssLengthUnit.em),
      bottom: CssLength(em, CssLengthUnit.em),
    );

    switch (tag) {
      case 'h1':
        return _heading(2.0, 0.67, parentFontSize);
      case 'h2':
        return _heading(1.5, 0.75, parentFontSize);
      case 'h3':
        return _heading(1.17, 0.83, parentFontSize);
      case 'h4':
        return _heading(1.0, 1.12, parentFontSize);
      case 'h5':
        return _heading(0.83, 1.5, parentFontSize);
      case 'h6':
        return _heading(0.75, 1.67, parentFontSize);
      case 'p':
        return HtmlStyle(display: CssDisplay.block, margin: blockMargin(1.0));
      case 'div':
      case 'section':
      case 'article':
      case 'header':
      case 'footer':
      case 'main':
      case 'nav':
      case 'aside':
      case 'figure':
      case 'dl':
        return const HtmlStyle(display: CssDisplay.block);
      case 'dt':
        return const HtmlStyle(
          display: CssDisplay.block,
          fontWeight: FontWeight.bold,
        );
      case 'dd':
        return const HtmlStyle(
          display: CssDisplay.block,
          margin: CssEdges(left: CssLength(2.5, CssLengthUnit.em)),
        );
      case 'b':
      case 'strong':
        return const HtmlStyle(fontWeight: FontWeight.bold);
      case 'i':
      case 'em':
      case 'cite':
      case 'var':
      case 'address':
        return const HtmlStyle(fontStyle: FontStyle.italic);
      case 'u':
      case 'ins':
        return const HtmlStyle(textDecoration: TextDecoration.underline);
      case 's':
      case 'strike':
      case 'del':
        return const HtmlStyle(textDecoration: TextDecoration.lineThrough);
      case 'mark':
        return const HtmlStyle(backgroundColor: Color(0xFFFFFF00));
      case 'a':
        return const HtmlStyle(
          color: Color(0xFF1A0DAB),
          textDecoration: TextDecoration.underline,
        );
      case 'code':
      case 'kbd':
      case 'samp':
      case 'tt':
        return const HtmlStyle(fontFamilies: ['monospace']);
      case 'pre':
        return HtmlStyle(
          display: CssDisplay.block,
          fontFamilies: const ['monospace'],
          whiteSpace: CssWhiteSpace.pre,
          margin: blockMargin(1.0),
        );
      case 'blockquote':
        return HtmlStyle(
          display: CssDisplay.block,
          margin: const CssEdges(
            top: CssLength(1, CssLengthUnit.em),
            bottom: CssLength(1, CssLengthUnit.em),
            left: CssLength(2.5, CssLengthUnit.em),
            right: CssLength(2.5, CssLengthUnit.em),
          ),
        );
      case 'ul':
      case 'ol':
        return HtmlStyle(
          display: CssDisplay.block,
          margin: blockMargin(1.0),
          padding: const CssEdges(left: CssLength(40, CssLengthUnit.px)),
        );
      case 'li':
        return const HtmlStyle(display: CssDisplay.listItem);
      case 'table':
        return HtmlStyle(
          display: CssDisplay.table,
          textAlign: inherited.legacyTextAlign == true ? TextAlign.start : null,
        );
      case 'thead':
      case 'tbody':
      case 'tfoot':
        return const HtmlStyle(display: CssDisplay.tableRowGroup);
      case 'tr':
        return const HtmlStyle(display: CssDisplay.tableRow);
      case 'td':
        // No UA text-align: a cell inherits text-align from its ancestors
        // (CSS behaviour), so a `text-align:center` container centers cell
        // content. A cell's own `align`/`text-align` still wins via the cascade.
        return const HtmlStyle(display: CssDisplay.tableCell);
      case 'th':
        return HtmlStyle(
          display: CssDisplay.tableCell,
          fontWeight: FontWeight.bold,
          // Browser UA styles center table headers by default. Email templates,
          // however, often set `text-align` on the table itself (GitHub's
          // `text-left` tables do this) and expect header cells to follow it.
          // Keep the UA default only when no ancestor alignment exists.
          textAlign: inherited.textAlign == null ? TextAlign.center : null,
        );
      case 'center':
        return const HtmlStyle(
          display: CssDisplay.block,
          textAlign: TextAlign.center,
          legacyTextAlign: true,
        );
      case 'small':
        return HtmlStyle(fontSize: parentFontSize * 0.833);
      case 'big':
        return HtmlStyle(fontSize: parentFontSize * 1.2);
      case 'hr':
        return HtmlStyle(display: CssDisplay.block, margin: blockMargin(0.5));
      case 'img':
        return const HtmlStyle(display: CssDisplay.inlineBlock);
      case 'br':
      case 'span':
      case 'label':
        return const HtmlStyle(display: CssDisplay.inline);
      case 'sub':
        return HtmlStyle(
          display: CssDisplay.inline,
          fontSize: parentFontSize * 0.75,
          verticalAlign: 'sub',
        );
      case 'sup':
        return HtmlStyle(
          display: CssDisplay.inline,
          fontSize: parentFontSize * 0.75,
          verticalAlign: 'super',
        );
      case 'head':
      case 'style':
      case 'script':
      case 'title':
      case 'meta':
      case 'link':
        return const HtmlStyle(display: CssDisplay.none);
      default:
        return HtmlStyle.empty;
    }
  }

  // A heading's UA font-size is an `em` multiple of the PARENT font-size (CSS
  // `em` semantics), not the root — so an `<h6>` inside a `font-size:24px`
  // block is 0.75x24, not 0.75x root.
  HtmlStyle _heading(double sizeEm, double marginEm, double parentFontSize) =>
      HtmlStyle(
        display: CssDisplay.block,
        fontWeight: FontWeight.bold,
        fontSize: parentFontSize * sizeEm,
        margin: CssEdges(
          top: CssLength(marginEm, CssLengthUnit.em),
          bottom: CssLength(marginEm, CssLengthUnit.em),
        ),
      );

  // --- Presentational HTML attributes ---

  HtmlStyle _presentationalStyle(
    dom.Element element,
    String tag,
    double parentFontSize, {
    required bool useCellAlign,
  }) {
    final attrs = element.attributes;
    Color? backgroundColor;
    String? backgroundImage;
    Color? color;
    List<String>? fontFamilies;
    double? fontSize;
    TextAlign? textAlign;
    TextAlign? cellTextAlign;
    String? verticalAlign;
    CssLength? width;
    CssLength? height;
    CssBorders? borders;

    // `align` on most elements maps to text-align; but on <table> it positions
    // the table box itself (handled separately) and must NOT become a text-align
    // that would inherit into and centre the cells' text.
    final align = tag == 'table' ? null : attrs['align'];
    if (align != null) {
      final value = switch (align.toLowerCase()) {
        'left' => TextAlign.left,
        'right' => TextAlign.right,
        'center' => TextAlign.center,
        'middle' => TextAlign.center,
        'justify' => TextAlign.justify,
        _ => null,
      };
      if ((tag == 'td' || tag == 'th') && useCellAlign) {
        cellTextAlign = value;
      } else {
        textAlign = value;
      }
    }

    final valign = attrs['valign'];
    if (valign != null &&
        const {
          'td',
          'th',
          'tr',
          'thead',
          'tbody',
          'tfoot',
          'col',
          'colgroup',
        }.contains(tag)) {
      verticalAlign = valign.toLowerCase();
    }

    final bgcolor = attrs['bgcolor'];
    if (bgcolor != null) backgroundColor = _legacyAttrColor(bgcolor);
    if (tag == 'body' || tag == 'table' || tag == 'td' || tag == 'th') {
      backgroundImage = attrs['background'];
    }

    if (tag == 'font') {
      color = _legacyAttrColor(attrs['color']);
      final face = attrs['face'];
      if (face != null) {
        fontFamilies = face
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      fontSize = _fontTagSize(attrs['size'], parentFontSize);
    }

    final widthAttr = attrs['width'];
    if (widthAttr != null) width = _dimensionAttr(widthAttr);
    final heightAttr = attrs['height'];
    if (heightAttr != null) height = _dimensionAttr(heightAttr);

    final borderAttr = attrs['border'];
    if (borderAttr != null && (tag == 'table' || tag == 'img')) {
      final w = double.tryParse(borderAttr);
      if (w != null && w > 0) {
        final side = CssBorderSide(width: w, color: const Color(0xFF808080));
        borders = CssBorders(top: side, right: side, bottom: side, left: side);
      }
    }

    return HtmlStyle(
      backgroundColor: backgroundColor,
      backgroundImage: backgroundImage,
      color: color,
      fontFamilies: fontFamilies,
      fontSize: fontSize,
      textAlign: textAlign,
      legacyTextAlign: textAlign != null ? true : null,
      cellTextAlign: cellTextAlign,
      verticalAlign: verticalAlign,
      width: width,
      height: height,
      borders: borders,
    );
  }

  /// Colors from presentational attributes (`bgcolor`, `<font color>`) accept
  /// bare hex without the leading `#` per the HTML legacy color algorithm — old
  /// emails still write `bgcolor="336699"` / `bgcolor="EEE"`.
  static Color? _legacyAttrColor(String? raw) {
    if (raw == null) return null;
    final direct = CssColor.tryParse(raw);
    if (direct != null) return direct;
    final trimmed = raw.trim();
    if (RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(trimmed) ||
        RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(trimmed)) {
      return CssColor.tryParse('#$trimmed');
    }
    return null;
  }

  static CssLength? _dimensionAttr(String raw) {
    // HTML width/height attributes are bare pixels (`width="600"`) or percent,
    // but real emails also use `24px`/`auto`. CssLength.tryParse covers all of
    // these (a bare number resolves to px).
    final value = CssLength.tryParse(raw);
    return value == null ||
            !value.value.isFinite ||
            value.value < 0 ||
            value.value > 1000000
        ? null
        : value;
  }

  static double? _fontTagSize(String? raw, double parentFontSize) {
    if (raw == null) return null;
    const sizes = {
      1: 10.0,
      2: 13.0,
      3: 16.0,
      4: 18.0,
      5: 24.0,
      6: 32.0,
      7: 48.0,
    };
    final value = raw.trim();
    if (value.startsWith('+') || value.startsWith('-')) {
      final delta = int.tryParse(value);
      if (delta == null) return null;
      return sizes[(3 + delta).clamp(1, 7)];
    }
    final abs = int.tryParse(value);
    return abs == null ? null : sizes[abs.clamp(1, 7)];
  }
}
