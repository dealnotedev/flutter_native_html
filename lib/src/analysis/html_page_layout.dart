import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../config/html_render_config.dart';
import '../css/css_length.dart';
import '../css/html_style.dart';
import '../css/style_resolver.dart';
import '../parsing/html_email_parser.dart';

/// Whether an email appears to have content formatting but no page layout.
///
/// A conservative heuristic for hosts deciding whether to add their own outer
/// padding. `true` means nonempty content with no detected page-level spacing,
/// decoration, sizing or layout. `false` also includes empty documents and
/// custom handlers, whose layout cannot be inferred. It does not measure gutters
/// or guarantee that adding padding is appropriate for every possible email.
///
/// Uses the renderer's CSS cascade, HTML presentation attributes, `!important`
/// and media queries at [availableWidth]. Layout signals on the root and block
/// containers must cover at least half of the visible content (by non-whitespace
/// text length; non-tracking images count as 64 characters). Nested containers
/// are not double-counted. This keeps a local avatar row, button, signature or
/// footer from defining the whole page.
/// Headings, lists, quotations and semantic data tables are content formatting,
/// not page containers. A table alone is not evidence of a page layout.
///
/// This analyzes the sanitized document without mutation, widget construction
/// or resource loading. Only the renderer's supported CSS is considered. Use
/// [HtmlEmailParser.parse] for bounded parsing; reuse the same [ParsedEmail]
/// for rendering, and recompute when the document, width or config changes.
/// The host owns padding policy; this function does not change rendering.
bool hasNoHtmlPageLayout(
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
  final analyzer = _PageLayoutAnalyzer(
    config,
    StyleResolver(
      stylesheet: document.stylesheet,
      rootStyle: rootStyle,
      availableWidth: availableWidth,
    ),
  );
  final content = analyzer.visit(document.root, rootStyle, isRoot: true);
  return content.weight > 0 &&
      !analyzer.hasCustomContent &&
      content.layoutWeight * 2 < content.weight;
}

class _PageLayoutAnalyzer {
  _PageLayoutAnalyzer(this.config, this.resolver);

  final HtmlRenderConfig config;
  final StyleResolver resolver;
  bool hasCustomContent = false;

  static final _whitespace = RegExp(r'\s+');
  static const _localTags = {
    'a',
    'button',
    'blockquote',
    'pre',
    'code',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'li',
    'dl',
    'dt',
    'dd',
  };

  ({int weight, int layoutWeight}) visit(
    dom.Element element,
    HtmlStyle inherited, {
    bool isRoot = false,
    bool local = false,
  }) {
    final style = resolver.resolve(element, inherited.inheritedOnly());
    if (style.display == CssDisplay.none ||
        style.visibilityHidden == true ||
        style.opacity == 0 ||
        (style.overflowHidden == true && style.maxHeight?.value == 0)) {
      return (weight: 0, layoutWeight: 0);
    }
    if (config.handlers.any((h) => h.tags.contains(element.localName))) {
      hasCustomContent = true;
    }
    final tag = element.localName;
    if (tag == 'img') {
      final width = style.width;
      final height = style.height;
      if (_tiny(width, style) && _tiny(height, style)) {
        return (weight: 0, layoutWeight: 0);
      }
      // Small, explicitly sized inline icons and avatars are not page layout.
      // An unknown or large image might be a banner; be conservative when it
      // forms the main content, without fetching its intrinsic dimensions.
      return (
        weight: 64,
        layoutWeight: _small(width, style) && _small(height, style) ? 0 : 64,
      );
    }

    final dataTable = tag == 'table' && _isDataTable(element);
    final contentOnly = local || _localTags.contains(tag) || dataTable;
    var weight = 0;
    var layoutWeight = 0;
    for (final child in element.nodes) {
      if (child is dom.Text) {
        weight += child.data.replaceAll(_whitespace, '').length;
      } else if (child is dom.Element) {
        final content = visit(child, style, local: contentOnly);
        weight += content.weight;
        layoutWeight += content.layoutWeight;
      }
    }

    final block = switch (style.display) {
      CssDisplay.block ||
      CssDisplay.inlineBlock ||
      CssDisplay.flex ||
      CssDisplay.table ||
      CssDisplay.tableCell => true,
      _ => false,
    };
    if (weight > 0 &&
        !contentOnly &&
        (isRoot || block) &&
        _hasPageStyle(element, style)) {
      layoutWeight = weight;
    }
    return (weight: weight, layoutWeight: layoutWeight);
  }

  bool _hasPageStyle(dom.Element element, HtmlStyle style) {
    final margin = style.margin;
    final padding = style.padding;
    if (_nonzero(margin?.left) ||
        _nonzero(margin?.right) ||
        (element.localName != 'p' &&
            (_nonzero(margin?.top) || _nonzero(margin?.bottom))) ||
        _nonzero(padding?.left) ||
        _nonzero(padding?.right) ||
        _nonzero(padding?.top) ||
        _nonzero(padding?.bottom)) {
      return true;
    }
    // Default paragraph/heading vertical margins are not page design.
    if ((style.backgroundColor?.a ?? 0) > 0 ||
        style.backgroundImage != null ||
        _hasBorder(style.borders) ||
        _sized(style.width) ||
        _sized(style.minWidth) ||
        _sized(style.maxWidth) ||
        _sized(style.height) ||
        _sized(style.minHeight) ||
        _sized(style.maxHeight) ||
        style.float != null ||
        style.display == CssDisplay.flex) {
      return true;
    }
    if (element.localName == 'table') {
      // Presentation tables and nested non-data tables are email scaffolding.
      // Unstyled data tables (even multi-column ones) remain ordinary content.
      return element.attributes['role']?.toLowerCase() == 'presentation' ||
          element.attributes['role']?.toLowerCase() == 'none' ||
          element.querySelector('table') != null ||
          _positiveAttribute(element, 'cellpadding') ||
          _positiveAttribute(element, 'cellspacing') ||
          element.attributes['align']?.toLowerCase() == 'center';
    }
    return false;
  }

  bool _tiny(CssLength? length, HtmlStyle style) {
    final value = _pixels(length, style);
    return value != null && value <= 1;
  }

  bool _small(CssLength? length, HtmlStyle style) {
    final value = _pixels(length, style);
    return value != null && value <= 64;
  }

  double? _pixels(CssLength? length, HtmlStyle style) =>
      length?.unit == CssLengthUnit.percent
      ? null
      : length?.resolve(
          fontSize: style.resolvedFontSize,
          rootFontSize: config.baseFontSize,
        );

  static bool _nonzero(CssLength? length) =>
      length != null && (length.isAuto || length.value != 0);

  static bool _sized(CssLength? length) => length != null && !length.isAuto;

  static bool _hasBorder(CssBorders? borders) => [
    borders?.left,
    borders?.top,
    borders?.right,
    borders?.bottom,
  ].any((border) => border != null && border.width > 0);

  static bool _positiveAttribute(dom.Element element, String name) =>
      (double.tryParse(element.attributes[name] ?? '') ?? 0) > 0;

  static bool _isDataTable(dom.Element element) {
    final role = element.attributes['role']?.toLowerCase();
    if (role == 'presentation' || role == 'none') return false;
    return role == 'table' ||
        role == 'grid' ||
        element.querySelector('th,caption,thead') != null;
  }
}
