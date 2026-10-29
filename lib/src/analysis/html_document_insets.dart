import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../config/html_render_config.dart';
import '../css/css_length.dart';
import '../css/html_style.dart';
import '../css/style_resolver.dart';
import '../parsing/html_email_parser.dart';

/// Estimated space already provided by a document, in layout logical pixels.
///
/// Each side is independent. `null` means that text/image measurement or a more
/// complex layout is needed; it does NOT mean zero. Values describe the edges
/// of content boxes, not glyph ink, bitmap transparency, or background paint.
/// They exclude host padding, safe areas and the fit-to-width paint transform.
@immutable
class HtmlDocumentInsetsEstimate {
  const HtmlDocumentInsetsEstimate({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.hasContent,
  });

  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
  final bool hasContent;

  /// Whether all four sides can be resolved by this pre-layout model.
  /// This does not turn the estimate into an exact painted measurement.
  bool get isFullyKnown =>
      left != null && top != null && right != null && bottom != null;

  /// An [EdgeInsets] only when every side can be estimated.
  EdgeInsets? get insets =>
      isFullyKnown ? EdgeInsets.fromLTRB(left!, top!, right!, bottom!) : null;
}

/// Estimates existing content insets without building widgets or loading images.
///
/// Reuses the renderer's CSS cascade, including media queries, inherited font
/// sizes, author resets and `!important`. [availableWidth] must be the same width
/// that the HTML renderer receives; changing it may change the estimate. Host
/// spacing outside that width is not included in the returned insets.
///
/// Normal block flow and single-column email tables are supported. Short text
/// uses its available line box, so unused space after its final word is not
/// mistaken for an authored right inset. Nested spacing is accumulated; sibling
/// blocks use the least horizontal inset and the first/last vertical inset.
/// Images, inline boxes, multi-column/spanning tables, floats, constrained
/// heights and custom handlers can leave individual sides unknown. Backgrounds
/// are decoration and are not used to identify content edges.
///
/// This is a pre-layout estimate, not a browser layout measurement or a minimum
/// gutter policy. In particular, [HtmlRenderConfig.fitToWidth] is not simulated:
/// a fixed-width overflow leaves its horizontal sides unknown. The caller owns
/// any fallback for unknown sides and any decision to add margins.
HtmlDocumentInsetsEstimate estimateHtmlDocumentInsets(
  ParsedEmail document, {
  required double availableWidth,
  HtmlRenderConfig config = const HtmlRenderConfig(),
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (!availableWidth.isFinite || availableWidth <= 0) {
    throw ArgumentError.value(
      availableWidth,
      'availableWidth',
      'Must be finite and positive',
    );
  }
  final rootStyle = HtmlStyle(
    fontSize: config.baseFontSize,
    textDirection: textDirection,
    color: config.defaultColor,
  );
  return _Estimator(
    config,
    StyleResolver(
      stylesheet: document.stylesheet,
      rootStyle: rootStyle,
      availableWidth: availableWidth,
    ),
  ).element(document.root, rootStyle, availableWidth).estimate;
}

class _Content {
  const _Content({this.left = 0, this.top = 0, this.right = 0, this.bottom = 0})
    : hasContent = true,
      emptyHeight = null;

  const _Content.empty([this.emptyHeight = 0])
    : left = 0,
      top = 0,
      right = 0,
      bottom = 0,
      hasContent = false;

  const _Content.unknown()
    : left = null,
      top = null,
      right = null,
      bottom = null,
      hasContent = true,
      emptyHeight = null;

  final double? left, top, right, bottom;
  final bool hasContent;
  final double? emptyHeight;

  HtmlDocumentInsetsEstimate get estimate => HtmlDocumentInsetsEstimate(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    hasContent: hasContent,
  );
}

double? _add(double? a, double? b) => a == null || b == null ? null : a + b;
double _positive(double value) => math.max(0, value);
double? _minimum(Iterable<double?> values) {
  final known = values.whereType<double>().toList();
  // Every reported inset is nonnegative, so a known zero determines the minimum
  // even when another sibling requires layout.
  if (known.contains(0)) return 0;
  if (known.length != values.length) return null;
  return known.reduce(math.min);
}

class _Estimator {
  _Estimator(this.config, this.resolver);
  final HtmlRenderConfig config;
  final StyleResolver resolver;

  double? length(CssLength? value, HtmlStyle style, double? width) =>
      value == null
      ? 0
      : value.resolve(
          fontSize: style.resolvedFontSize,
          rootFontSize: config.baseFontSize,
          percentBase: width,
        );

  _Content element(
    dom.Element node,
    HtmlStyle inherited,
    double? width, {
    double? cellPadding,
  }) {
    var style = resolver.resolve(node, inherited.inheritedOnly());
    if (style.display == CssDisplay.none) return const _Content.empty();
    if (config.handlers.any(
      (handler) => handler.tags.contains(node.localName),
    )) {
      return const _Content.unknown();
    }
    if (style.visibilityHidden == true || style.opacity == 0) {
      final height = style.height ?? style.maxHeight;
      // An invisible preheader may still reserve an unknown line height.
      return _Content.empty(
        height?.value == 0 &&
                style.padding == null &&
                style.margin == null &&
                style.borders == null
            ? 0
            : null,
      );
    }
    if (cellPadding != null && style.padding == null) {
      final edge = CssLength(cellPadding, CssLengthUnit.px);
      style = style.merge(
        HtmlStyle(
          padding: CssEdges(left: edge, top: edge, right: edge, bottom: edge),
        ),
      );
    }
    if (style.float != null ||
        style.display == CssDisplay.flex ||
        style.display == CssDisplay.inlineBlock ||
        style.display == CssDisplay.listItem) {
      return const _Content.unknown();
    }
    if (node.localName == 'br') return const _Content.empty(null);
    if (node.localName == 'hr') return const _Content.unknown();

    double? edge(CssLength? value) {
      final resolved = length(value, style, width);
      return resolved == null || resolved < 0 ? null : resolved;
    }

    double? marginEdge(CssLength? value) =>
        value?.unit == CssLengthUnit.percent ? null : edge(value);

    final margin = style.margin;
    final padding = style.padding;
    var ml = margin?.left?.isAuto == true ? 0.0 : marginEdge(margin?.left);
    var mr = margin?.right?.isAuto == true ? 0.0 : marginEdge(margin?.right);
    final mt = marginEdge(margin?.top);
    final mb = marginEdge(margin?.bottom);
    final pl = _add(edge(padding?.left), style.borders?.left?.width ?? 0);
    final pr = _add(edge(padding?.right), style.borders?.right?.width ?? 0);
    final pt = _add(edge(padding?.top), style.borders?.top?.width ?? 0);
    final pb = _add(edge(padding?.bottom), style.borders?.bottom?.width ?? 0);
    final horizontal = _add(pl, pr);
    final available = width == null || ml == null || mr == null
        ? null
        : _positive(width - ml - mr);

    final cell = node.localName == 'td' || node.localName == 'th';
    // The table allocates its single column. A td width is a hint, not a box
    // width applied independently inside that column.
    final declared = cell || style.width == null || style.width!.isAuto
        ? null
        : length(style.width, style, width);
    final maxWidth = cell || style.maxWidth == null || style.maxWidth!.isAuto
        ? null
        : length(style.maxWidth, style, width);
    final minWidth = cell || style.minWidth == null || style.minWidth!.isAuto
        ? null
        : length(style.minWidth, style, width);
    double? outer(double? size) => size == null || horizontal == null
        ? null
        : size + (style.boxSizing == CssBoxSizing.borderBox ? 0 : horizontal);
    var boxWidth = outer(declared) ?? available;
    if (boxWidth != null && outer(maxWidth) != null) {
      boxWidth = math.min(boxWidth, outer(maxWidth)!);
    }
    if (boxWidth != null && outer(minWidth) != null) {
      boxWidth = math.max(boxWidth, outer(minWidth)!);
    }
    var horizontalKnown =
        available != null && boxWidth != null && boxWidth <= available;
    if (horizontalKnown) {
      final free = available - boxWidth;
      final leftAuto = margin?.left?.isAuto == true;
      final rightAuto = margin?.right?.isAuto == true;
      final tableAlign = node.localName == 'table'
          ? node.attributes['align']
          : null;
      final centered =
          leftAuto && rightAuto ||
          !leftAuto && !rightAuto && declared == null && maxWidth != null ||
          !leftAuto &&
              !rightAuto &&
              declared != null &&
              (style.textAlign == TextAlign.center || tableAlign == 'center');
      final rightAligned =
          leftAuto && !rightAuto ||
          !leftAuto &&
              !rightAuto &&
              declared != null &&
              (style.textAlign == TextAlign.right || tableAlign == 'right');
      final before = centered
          ? free / 2
          : rightAligned
          ? free
          : 0.0;
      ml = _add(ml, before);
      mr = _add(mr, free - before);
    }
    if (style.width?.unit == CssLengthUnit.percent &&
            style.width!.value != 100 ||
        style.maxWidth?.unit == CssLengthUnit.percent ||
        style.minWidth?.unit == CssLengthUnit.percent) {
      horizontalKnown = false;
    }
    final contentWidth = boxWidth == null || horizontal == null
        ? null
        : _positive(boxWidth - horizontal);

    _Content content;
    if (node.localName == 'img') {
      // Image/placeholder metrics and the surrounding inline baseline are not
      // known until the configured image resolver and Flutter layout run.
      return const _Content.unknown();
    } else if (node.localName == 'table') {
      content = table(node, style, contentWidth);
      // Widthless centered/inline tables are shrink-to-fit in the renderer.
      if (declared == null &&
          (margin?.left?.isAuto == true ||
              node.attributes['align'] == 'center' ||
              node.attributes['align'] == 'right' ||
              node.parent?.attributes['align'] == 'center' ||
              node.parent?.attributes['align'] == 'right')) {
        horizontalKnown = false;
      }
    } else {
      content = sequence(node.nodes, style, contentWidth);
    }
    final vertical = _add(_add(mt, pt), _add(pb, mb));
    if (!content.hasContent) {
      if (style.minHeight != null ||
          style.maxHeight != null ||
          (mt ?? 0) > 0 ||
          (mb ?? 0) > 0) {
        // Empty-block margin collapsing depends on adjacent siblings. Do not
        // turn a sum of declared margins into a claimed spacer height.
        return const _Content.empty(null);
      }
      final h = style.height == null
          ? content.emptyHeight
          : length(style.height, style, width);
      return _Content.empty(
        _add(
          h,
          style.height != null && style.boxSizing == CssBoxSizing.borderBox
              ? _add(mt, mb)
              : vertical,
        ),
      );
    }
    final constrainedHeight =
        style.height != null ||
        style.minHeight != null ||
        style.maxHeight != null;
    final inlineSpacing =
        style.display == CssDisplay.inline &&
        (margin != null || padding != null || style.borders != null);
    return _Content(
      left: horizontalKnown && !inlineSpacing
          ? _add(_add(ml, pl), content.left)
          : null,
      right: horizontalKnown && !inlineSpacing
          ? _add(_add(mr, pr), content.right)
          : null,
      top:
          inlineSpacing ||
              style.verticalAlign == 'middle' ||
              style.verticalAlign == 'bottom'
          ? null
          : _add(_add(mt, pt), content.top),
      bottom:
          constrainedHeight ||
              inlineSpacing ||
              style.verticalAlign == 'middle' ||
              style.verticalAlign == 'bottom'
          ? null
          : _add(_add(pb, mb), content.bottom),
    );
  }

  _Content sequence(Iterable<dom.Node> nodes, HtmlStyle style, double? width) {
    final items = <_Content>[];
    for (final node in nodes) {
      if (node is dom.Text) {
        if (node.text.trim().isNotEmpty) items.add(const _Content());
      } else if (node is dom.Element) {
        items.add(element(node, style, width));
      }
    }
    return combine(items);
  }

  _Content combine(List<_Content> items) {
    final first = items.indexWhere((item) => item.hasContent);
    if (first < 0) {
      return _Content.empty(
        items.fold<double?>(0, (sum, item) => _add(sum, item.emptyHeight)),
      );
    }
    final last = items.lastIndexWhere((item) => item.hasContent);
    final visible = items.where((item) => item.hasContent);
    var top = items[first].top;
    var bottom = items[last].bottom;
    for (var i = 0; i < first; i++) {
      top = _add(top, items[i].emptyHeight);
    }
    for (var i = last + 1; i < items.length; i++) {
      bottom = _add(bottom, items[i].emptyHeight);
    }
    return _Content(
      left: _minimum(visible.map((item) => item.left)),
      right: _minimum(visible.map((item) => item.right)),
      top: top,
      bottom: bottom,
    );
  }

  _Content table(dom.Element node, HtmlStyle style, double? width) {
    final rows = <_Content>[];
    final rawPadding = double.tryParse(node.attributes['cellpadding'] ?? '');
    final padding = rawPadding == null || !rawPadding.isFinite
        ? 2.0
        : _positive(rawPadding);
    final rawSpacing = double.tryParse(node.attributes['cellspacing'] ?? '');
    final spacing = rawSpacing == null || !rawSpacing.isFinite
        ? config.defaultTableCellSpacing
        : _positive(rawSpacing);
    // Inline border-spacing has its own parsing path in TableHandler. Do not
    // silently substitute the default for a value this estimator does not model.
    if (rawSpacing == null &&
        RegExp(
          r'border-spacing\s*:',
          caseSensitive: false,
        ).hasMatch(node.attributes['style'] ?? '')) {
      return const _Content.unknown();
    }
    final cellWidth = width == null ? null : _positive(width - 2 * spacing);
    void collect(dom.Element parent, HtmlStyle inherited) {
      for (final child in parent.children) {
        final childStyle = resolver.resolve(child, inherited.inheritedOnly());
        if (childStyle.display == CssDisplay.none) continue;
        if (child.localName == 'tr') {
          if (childStyle.height != null ||
              childStyle.minHeight != null ||
              childStyle.padding != null ||
              childStyle.margin != null ||
              childStyle.opacity != null ||
              childStyle.visibilityHidden == true) {
            rows.add(const _Content.unknown());
            continue;
          }
          final cells = child.children
              .where((c) => c.localName == 'td' || c.localName == 'th')
              .where(
                (c) =>
                    resolver.resolve(c, childStyle.inheritedOnly()).display !=
                    CssDisplay.none,
              )
              .toList();
          if (cells.length != 1 ||
              cells.any(
                (c) =>
                    (int.tryParse(c.attributes['colspan'] ?? '1') ?? 1) != 1 ||
                    (int.tryParse(c.attributes['rowspan'] ?? '1') ?? 1) != 1,
              )) {
            rows.add(const _Content.unknown());
          } else {
            rows.add(
              element(
                cells.single,
                childStyle,
                cellWidth,
                cellPadding: padding,
              ),
            );
          }
        } else if (child.localName == 'tbody' ||
            child.localName == 'thead' ||
            child.localName == 'tfoot') {
          if (childStyle.padding != null ||
              childStyle.margin != null ||
              childStyle.opacity != null ||
              childStyle.visibilityHidden == true) {
            rows.add(const _Content.unknown());
          } else {
            collect(child, childStyle);
          }
        } else if (child.localName == 'caption') {
          rows.add(const _Content.unknown());
        }
      }
    }

    collect(node, style);
    final result = combine(rows);
    if (!result.hasContent) return result;
    return _Content(
      left: _add(spacing, result.left),
      top: _add(spacing, result.top),
      right: _add(spacing, result.right),
      bottom: _add(spacing, result.bottom),
    );
  }
}
