import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../config/html_render_config.dart';
import '../config/html_image_resolver.dart';
import '../css/css_color.dart';
import '../css/css_length.dart';
import '../css/html_style.dart';
import '../css/style_resolver.dart';
import 'css_border_decoration.dart';
import 'element_registry.dart';
import 'html_build_result.dart';
import 'html_render_context.dart';
import 'layout/equal_height_row.dart';
import 'layout/percent_boxes.dart';

/// Walks the sanitized DOM and produces the Flutter widget tree.
///
/// Responsibilities:
/// - recurse the DOM, resolving each element's style via [StyleResolver];
/// - dispatch elements to their [ElementRegistry] handler (or a generic
///   display-based fallback);
/// - "flow" mixed inline/block children into paragraphs + block widgets;
/// - apply each block's box decoration (margin/padding/background/border).
///
/// One builder instance is created per [build]; it owns any gesture
/// recognizers created for links so the widget can dispose them.
class HtmlTreeBuilder {
  HtmlTreeBuilder({
    required this.config,
    required this.buildContext,
    required HtmlStyle rootStyle,
    required StyleResolver resolver,
  }) : _rootStyle = rootStyle, // ignore: prefer_initializing_formals
       _resolver = resolver; // ignore: prefer_initializing_formals

  final HtmlRenderConfig config;
  final BuildContext buildContext;
  final HtmlStyle _rootStyle;
  final StyleResolver _resolver;
  late final HtmlImageResolver imageResolver = config.imageResolver
      .forDocument();
  final _descendantContexts =
      <(dom.Element, HtmlRenderContext), HtmlRenderContext>{};

  /// The logical px width the email is being laid out at (the media-query width).
  /// Used by table layout to clamp cell widths that exceed their container.
  double get availableWidth => _resolver.availableWidth;

  late final ElementRegistry _registry = ElementRegistry(
    custom: config.handlers,
  );

  /// Gesture recognizers created during this build (links). Disposed by the
  /// owning widget.
  final List<GestureRecognizer> recognizers = [];

  /// The widest declared fixed-pixel width resolved after responsive CSS.
  /// This is only a hint: the fit-to-width wrapper combines it with the root
  /// render tree's minimum intrinsic width, which also catches side-by-side
  /// columns and unbreakable content wider than any one declaration.
  double maxDeclaredFixedWidth = 0;

  void noteFixedWidth(double? px) {
    if (px != null && px.isFinite && px > maxDeclaredFixedWidth) {
      maxDeclaredFixedWidth = px;
    }
  }

  /// Builds the full body element into a single block widget.
  Widget buildRoot(dom.Element body) {
    final style = _resolver.resolve(body, _rootStyle.inheritedOnly());
    final ctx = HtmlRenderContext(
      element: body,
      builder: this,
      buildContext: buildContext,
      style: style,
      childInherited: style.inheritedOnly(),
    );
    return buildBlock(body, ctx);
  }

  // --- Recursion ---

  /// Builds all child nodes of [element] into a flat result list. [inherited]
  /// is the inherited-only style children should start from.
  List<HtmlBuildResult> buildChildNodes(
    dom.Element element,
    HtmlStyle inherited,
  ) => buildNodes(element.nodes, inherited);

  /// Builds a run of existing DOM nodes without cloning or reparenting them.
  List<HtmlBuildResult> buildNodes(
    Iterable<dom.Node> nodes,
    HtmlStyle inherited,
  ) {
    final results = <HtmlBuildResult>[];
    double? previousBlockBottom;
    final anonymousCells = <dom.Element>[];
    void flushAnonymousCells() {
      if (anonymousCells.isEmpty) return;
      final parent = anonymousCells.first.parent!;
      results.add(
        BlockResult(
          _buildAnonymousCssTable(
            parent,
            HtmlRenderContext(
              element: parent,
              builder: this,
              buildContext: buildContext,
              style: inherited,
              childInherited: inherited,
            ),
            cellElements: anonymousCells,
            decorateTable: false,
          ),
        ),
      );
      anonymousCells.clear();
      previousBlockBottom = null;
    }

    for (final node in nodes) {
      if (node is dom.Element) {
        var style = _resolver.resolve(node, inherited);
        if (style.display == CssDisplay.none) continue;
        if (style.display == CssDisplay.tableCell) {
          anonymousCells.add(node);
          continue;
        }
        flushAnonymousCells();
        final normalBlock =
            style.display == CssDisplay.block &&
            style.float == null &&
            _registry.handlerFor(node.localName ?? '') == null;
        double edge(CssLength? value) =>
            (value?.resolve(
                      fontSize: style.resolvedFontSize,
                      rootFontSize: config.baseFontSize,
                    ) ??
                    0)
                .clamp(0, double.infinity);
        final emptyBlock =
            normalBlock &&
            !style.preservesWhitespace &&
            !style.preservesNewlines &&
            style.overflowHidden != true &&
            node.nodes.every(
              (child) =>
                  child is dom.Comment ||
                  child is dom.Text &&
                      child.text.replaceAll(_collapsibleWhitespace, '').isEmpty,
            ) &&
            (style.height?.value ?? 0) == 0 &&
            (style.minHeight?.value ?? 0) == 0 &&
            (style.padding?.top?.value ?? 0) == 0 &&
            (style.padding?.bottom?.value ?? 0) == 0 &&
            _borderExtent(style.borders, false) == 0;
        var top = edge(style.margin?.top);
        final bottom = edge(style.margin?.bottom);
        final emptyMargin = top > bottom ? top : bottom;
        if (emptyBlock) {
          top = emptyMargin;
          style = style.merge(
            HtmlStyle(
              margin: CssEdges(
                top: CssLength(top, CssLengthUnit.px),
                bottom: CssLength.zero,
              ),
            ),
          );
        }
        if (normalBlock && previousBlockBottom != null && top > 0) {
          // The previous block already contributes its bottom margin. Only
          // the excess of the next top margin remains after sibling collapse.
          style = style.merge(
            HtmlStyle(
              margin: CssEdges(
                top: CssLength(
                  (top - previousBlockBottom!).clamp(0, double.infinity),
                  CssLengthUnit.px,
                ),
              ),
            ),
          );
        }
        results.addAll(_buildNode(node, inherited, resolvedStyle: style));
        previousBlockBottom = normalBlock
            ? emptyBlock
                  ? (emptyMargin > (previousBlockBottom ?? 0)
                        ? emptyMargin
                        : previousBlockBottom)
                  : bottom
            : null;
      } else {
        if (anonymousCells.isNotEmpty &&
            node is dom.Text &&
            node.text.replaceAll(_collapsibleWhitespace, '').isEmpty) {
          continue;
        }
        flushAnonymousCells();
        results.addAll(_buildNode(node, inherited));
        if (node is dom.Text &&
            (inherited.preservesWhitespace ||
                inherited.preservesNewlines ||
                node.text.replaceAll(_collapsibleWhitespace, '').isNotEmpty)) {
          previousBlockBottom = null;
        }
      }
    }
    flushAnonymousCells();
    return results;
  }

  List<HtmlBuildResult> _buildNode(
    dom.Node node,
    HtmlStyle inherited, {
    HtmlStyle? resolvedStyle,
  }) {
    if (node is dom.Text) {
      final linkify = config.autoLinkify && !_hasAnchorAncestor(node);
      return _buildText(node.text, inherited, node.parent, linkify: linkify);
    }
    if (node is dom.Element) {
      final style = resolvedStyle ?? _resolver.resolve(node, inherited);
      if (style.display == CssDisplay.none) return const [];
      final childInherited = style.inheritedOnly();
      final ctx = HtmlRenderContext(
        element: node,
        builder: this,
        buildContext: buildContext,
        style: style,
        childInherited: childInherited,
      );
      final handler = _registry.handlerFor(node.localName ?? '');
      if (handler != null) return handler.build(node, ctx);
      return _buildGeneric(node, ctx);
    }
    return const [];
  }

  List<HtmlBuildResult> _buildText(
    String raw,
    HtmlStyle inherited,
    dom.Element? parent, {
    required bool linkify,
  }) {
    if (raw.isEmpty) return const [];
    final preserve = inherited.preservesWhitespace;
    final preserveNewlines = inherited.preservesNewlines;
    final textStyle = inherited.toTextStyle();
    final transform = inherited.textTransform;
    if (preserve) {
      return _spansFor(
        _transform(raw, transform),
        textStyle,
        linkify,
        inherited,
        parent,
      );
    }
    final collapsed = preserveNewlines
        ? raw
              .replaceAll(RegExp(r'[\t\f\v ]+'), ' ')
              .replaceAll(RegExp(r' *\r?\n *'), '\n')
        : raw.replaceAll(_whitespaceRun, ' ');
    if (collapsed.replaceAll(_collapsibleWhitespace, '').isEmpty) {
      // Only collapsible whitespace: keep a single space the flow step can drop
      // at edges. (A non-breaking space is NOT collapsible — it falls through to
      // a real span below so e.g. a coloured `<div>&nbsp;</div>` spacer keeps
      // its line-box height.)
      return [
        InlineResult(
          TextSpan(text: ' ', style: textStyle),
          isWhitespaceOnly: true,
        ),
      ];
    }
    return _spansFor(
      _transform(collapsed, transform),
      textStyle,
      linkify,
      inherited,
      parent,
    );
  }

  /// Builds spans for a text run, optionally turning bare emails/URLs into
  /// tappable links (Gmail-style auto-linkification).
  List<HtmlBuildResult> _spansFor(
    String text,
    TextStyle style,
    bool linkify,
    HtmlStyle inherited,
    dom.Element? parent,
  ) {
    if (!linkify) {
      return [InlineResult(TextSpan(text: text, style: style))];
    }
    final matches = _linkPattern.allMatches(text).where((m) {
      if (m.group(1) != null) {
        final scheme = Uri.tryParse(m.group(1)!)?.scheme.toLowerCase();
        if (scheme != 'http' && scheme != 'https') return false;
      }
      // Bare-domain matches (group 4) only count with a plausible TLD.
      if (m.group(4) == null) return true;
      return _isKnownDomain(_stripTrailingPunctuation(m.group(0)!));
    }).toList();
    if (matches.isEmpty) {
      return [InlineResult(TextSpan(text: text, style: style))];
    }

    final results = <HtmlBuildResult>[];
    final linkStyle = _autoLinkStyle(style, inherited, parent);
    final onTap = config.onLinkTap;
    var last = 0;
    for (final m in matches) {
      if (m.start > last) {
        results.add(
          InlineResult(
            TextSpan(text: text.substring(last, m.start), style: style),
          ),
        );
      }
      final raw = m.group(0)!;
      final token = _stripTrailingPunctuation(raw);
      final trailing = raw.substring(token.length);

      GestureRecognizer? recognizer;
      if (onTap != null) {
        final url = _toUrl(token);
        recognizer = TapGestureRecognizer()..onTap = () => onTap(url, const {});
        recognizers.add(recognizer);
      }
      results.add(
        InlineResult(
          TextSpan(text: token, style: linkStyle, recognizer: recognizer),
        ),
      );
      if (trailing.isNotEmpty) {
        results.add(InlineResult(TextSpan(text: trailing, style: style)));
      }
      last = m.end;
    }
    if (last < text.length) {
      results.add(
        InlineResult(TextSpan(text: text.substring(last), style: style)),
      );
    }
    return results;
  }

  /// The style an auto-detected email/URL should render with.
  ///
  /// Like a mail client, an auto-link defaults to a Gmail-style blue underline.
  /// The email's own author CSS for `a` overrides that: an `a {color:…}` recolours
  /// it, and a link reset (`text-decoration:none` / `color:inherit`) makes it
  /// blend back into the surrounding text. Two host/sender signals win first: a
  /// configured [HtmlRenderConfig.autoLinkColor], then `pointer-events:none`
  /// (a hide-the-link trick) which we expose as a link.
  TextStyle _autoLinkStyle(
    TextStyle base,
    HtmlStyle inherited,
    dom.Element? parent,
  ) {
    const defaultBlue = Color(0xFF1155CC);

    final cfg = config.autoLinkColor;
    if (cfg != null) {
      return base.copyWith(
        color: cfg,
        decoration: TextDecoration.underline,
        decorationColor: cfg,
      );
    }
    if (inherited.pointerEventsNone ?? false) {
      return base.copyWith(
        color: defaultBlue,
        decoration: TextDecoration.underline,
        decorationColor: defaultBlue,
      );
    }

    final decls = _anchorAuthorDeclarations(parent);
    final colorValue = decls['color'];
    final hasColor = colorValue != null;
    final authorColor =
        (hasColor && colorValue.trim().toLowerCase() != 'inherit')
        ? CssColor.tryParse(colorValue)
        : null;
    final authorDecoration = _authorDecoration(
      decls['text-decoration'] ?? decls['text-decoration-line'],
    );

    // Start from the Gmail default, then let the author's <a> CSS override it.
    Color? color = defaultBlue;
    var decoration = TextDecoration.underline;
    if (authorColor != null) {
      color = authorColor; // a {color:#…}
    } else if (hasColor) {
      color = null; // a {color:inherit} -> blend into the text
    }
    if (authorDecoration != null) {
      decoration = authorDecoration;
      // A reset (text-decoration:none) with no explicit colour also drops the
      // link colour, matching email "reset" stylesheets.
      if (authorDecoration == TextDecoration.none && !hasColor) color = null;
    }

    final resolved = color ?? base.color;
    return base.copyWith(
      color: resolved,
      decoration: decoration,
      decorationColor: resolved,
    );
  }

  /// Author-stylesheet declarations that apply to an `<a>` at [parent]'s
  /// position (UA/inline styling excluded). Resolved via a throwaway `<a>` so
  /// descendant selectors (`#wrap a`, `.body a`) still match the real ancestry.
  Map<String, String> _anchorAuthorDeclarations(dom.Element? parent) {
    final anchor = dom.Element.tag('a');
    if (parent != null) anchor.parentNode = parent;
    return _resolver.sheetDeclarationsFor(anchor).values;
  }

  static TextDecoration? _authorDecoration(String? value) {
    if (value == null) return null;
    final v = value.toLowerCase();
    if (v.contains('underline')) return TextDecoration.underline;
    if (v.contains('line-through')) return TextDecoration.lineThrough;
    if (v.contains('none')) return TextDecoration.none;
    return null; // inherit/overline/etc. — leave the inherited decoration
  }

  static bool _hasAnchorAncestor(dom.Node node) {
    var parent = node.parent;
    while (parent != null) {
      if ((parent.localName ?? '').toLowerCase() == 'a') return true;
      parent = parent.parent;
    }
    return false;
  }

  static String _toUrl(String token) {
    if (token.contains('@') && !token.contains('://')) return 'mailto:$token';
    // `www.` and bare domains (no scheme) get an https scheme.
    if (!token.contains('://')) return 'https://$token';
    return token;
  }

  static String _stripTrailingPunctuation(String token) {
    var end = token.length;
    while (end > 0 && _trailingPunctuation.contains(token[end - 1])) {
      end--;
    }
    return token.substring(0, end);
  }

  static const String _trailingPunctuation = '.,;:!?)]}\'"><';

  // Collapsible whitespace = any whitespace EXCEPT a non-breaking space
  // (U+00A0), which CSS keeps as significant content.
  static final RegExp _whitespaceRun = RegExp(r'[^\S\u00A0]+');
  static final RegExp _collapsibleWhitespace = RegExp(r'[^\S\u00A0]');

  /// Matches a URL with scheme (group 1), a `www.` URL (2), a bare email
  /// address (3), or a bare domain like `novaposhta.ua` (4). Bare-domain
  /// matches are kept only when their TLD looks real (see [_isKnownDomain]).
  static final RegExp _linkPattern = RegExp(
    r'([A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s]+)'
    r'|(www\.[^\s]+)'
    r'|([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})'
    r'|((?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}(?:[\/?#][^\s]*)?)',
    caseSensitive: false,
  );

  /// Whether a bare-domain match (no scheme/`www`/`@`) has a plausible TLD: any
  /// two-letter ccTLD, or a known multi-letter gTLD. Guards against linkifying
  /// ordinary `word.Word` text.
  static bool _isKnownDomain(String token) {
    final host = token.split(RegExp(r'[/?#]')).first;
    final dot = host.lastIndexOf('.');
    if (dot < 0) return false;
    final tld = host.substring(dot + 1).toLowerCase();
    return tld.length == 2 || _knownTlds.contains(tld);
  }

  static const Set<String> _knownTlds = {
    'com',
    'org',
    'net',
    'edu',
    'gov',
    'mil',
    'int',
    'info',
    'biz',
    'name',
    'pro',
    'mobi',
    'asia',
    'xyz',
    'top',
    'site',
    'online',
    'store',
    'tech',
    'blog',
    'shop',
    'app',
    'dev',
    'cloud',
    'space',
    'world',
    'agency',
  };

  static String _transform(String text, CssTextTransform? transform) {
    switch (transform) {
      case CssTextTransform.uppercase:
        return text.toUpperCase();
      case CssTextTransform.lowercase:
        return text.toLowerCase();
      case CssTextTransform.capitalize:
        return text.replaceAllMapped(
          RegExp(r'\b\w'),
          (m) => m.group(0)!.toUpperCase(),
        );
      case CssTextTransform.none:
      case null:
        return text;
    }
  }

  /// Generic fallback for tags without a dedicated handler: render as inline or
  /// block according to the computed `display`.
  List<HtmlBuildResult> _buildGeneric(
    dom.Element element,
    HtmlRenderContext ctx,
  ) {
    // Auto floats share the adjacent inline row. Sized columns retain their
    // block alignment; percentage table floats use ColumnResult separately.
    if (ctx.style.float != null) {
      final width = ctx.style.width;
      if (width == null || width.isAuto) {
        return [
          FloatResult(
            decorate(
              flow(buildChildNodes(element, ctx.childInherited), ctx.style),
              ctx.style,
              inline: true,
            ),
            ctx.style.float!,
          ),
        ];
      }
      return [BlockResult(buildBlock(element, ctx))];
    }
    switch (ctx.style.display ?? CssDisplay.inline) {
      case CssDisplay.none:
        return const [];
      case CssDisplay.inline:
        // Keep the first traversal even when this inline wrapper contains a
        // block/column. Rebuilding on fallback doubles work at every level.
        final children = buildChildNodes(element, ctx.childInherited);
        if (children.any((child) => child is! InlineResult)) {
          return [BlockResult(_blockFromResults(element, ctx, children))];
        }
        final needsBox = _inlineNeedsBox(ctx.style);
        if (needsBox || ctx.style.preventsWrapping) {
          if (!children.any(
            (child) => child is InlineResult && _hasInlineContent(child.span),
          )) {
            return const [];
          }
          final content = flow(children, ctx.style);
          // Flutter TextSpan cannot disable wrapping within just one inline
          // run. Keep nowrap text atomic without applying CSS box dimensions
          // (which do not apply to a non-replaced inline span).
          final box = needsBox
              ? decorate(content, ctx.style, inline: true)
              : content;
          return [
            InlineResult(
              WidgetSpan(alignment: PlaceholderAlignment.middle, child: box),
            ),
          ];
        }
        return [InlineResult(_inlineFromResults(children, ctx))];
      case CssDisplay.inlineBlock:
        // Flows inline but keeps its box (width/height/padding/background).
        final results = buildChildNodes(element, ctx.childInherited);
        final w = ctx.style.width;
        final mw = ctx.style.maxWidth;
        final hasBlock = results.any((result) => result is! InlineResult);
        final shrinkBlockChildren =
            hasBlock && (w == null || w.isAuto) && mw == null;
        final content = shrinkBlockChildren
            ? IntrinsicWidth(child: flow(results, ctx.style))
            : flow(results, ctx.style);
        final box = decorate(content, ctx.style, inline: true);
        // A percent-width inline-block is a column (MJML `mj-column-per-N`): the
        // flow step rows a run of them side by side, or stacks them when they
        // don't fit (each 100% on a narrow layout). The effective column width
        // is min(width, max-width) — MJML sets width:100% but caps it with
        // max-width:50% to get a half-width column.
        double? pct;
        if (w != null && !w.isAuto && w.unit == CssLengthUnit.percent) {
          pct = w.value;
        }
        if (mw != null && mw.unit == CssLengthUnit.percent) {
          pct = pct == null ? mw.value : (mw.value < pct ? mw.value : pct);
        }
        if (pct != null) {
          return [ColumnResult(box, pct)];
        }
        return [
          InlineResult(
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: box),
          ),
        ];
      case CssDisplay.block:
      case CssDisplay.listItem:
      case CssDisplay.tableRowGroup:
      case CssDisplay.tableRow:
      case CssDisplay.tableCell:
        return [BlockResult(buildBlock(element, ctx))];
      case CssDisplay.table:
        return [BlockResult(_buildAnonymousCssTable(element, ctx))];
    }
  }

  /// CSS email builders often use `display:table` on a `<div>` with
  /// `display:table-cell` children (or rely on anonymous-cell generation).
  /// Browsers lay those cells in one row and distribute their widths; treating
  /// the container as a normal block would stack them vertically. We mirror the
  /// table column model: a percentage cell flexes by its weight, a fixed cell
  /// takes its px, and an auto cell sizes to content — so e.g. five `width:20%`
  /// social icons spread across a `width:100%` footer instead of clumping left.
  Widget _buildAnonymousCssTable(
    dom.Element element,
    HtmlRenderContext ctx, {
    Iterable<dom.Element>? cellElements,
    bool decorateTable = true,
  }) {
    final rootFontSize = _rootStyle.resolvedFontSize;
    final cells = <({Widget child, double? percent, double? fixedPx})>[];
    var anyFlex = false;
    var allMiddle = true;

    for (final node in cellElements ?? element.nodes) {
      // Whitespace/comments between cells carry no column.
      if (node is! dom.Element) continue;
      final cellCtx = contextFor(node, ctx.childInherited);
      final style = cellCtx.style;
      if (style.display == CssDisplay.none) continue;
      allMiddle = allMiddle && style.verticalAlign == 'middle';
      final handler = _registry.handlerFor(node.localName ?? '');
      final results = handler != null
          ? handler.build(node, cellCtx)
          : _buildGeneric(node, cellCtx);
      if (results.isEmpty) continue;
      final cell = flow(results, style);

      final w = style.width;
      if (w != null &&
          !w.isAuto &&
          w.unit == CssLengthUnit.percent &&
          w.value > 0) {
        anyFlex = true;
        cells.add((child: cell, percent: w.value, fixedPx: null));
      } else if (w != null && !w.isAuto && w.unit != CssLengthUnit.percent) {
        final px = w.resolve(
          fontSize: style.resolvedFontSize,
          rootFontSize: rootFontSize,
        );
        cells.add((
          child: px != null && px > 0 ? SizedBox(width: px, child: cell) : cell,
          percent: null,
          fixedPx: px != null && px > 0 ? px : null,
        ));
      } else {
        cells.add((child: cell, percent: null, fixedPx: null));
      }
    }
    if (cells.isEmpty) return decorate(const SizedBox.shrink(), ctx.style);

    // A flex row fills and distributes; a content-sized row follows the box's
    // own alignment (centre only when it's actually centred — a plain
    // `display:table` left-packs its cells, like CSS).
    final align = (element.attributes['align'] ?? '').toLowerCase();
    final autoCentered =
        align == 'center' ||
        align == 'middle' ||
        ((ctx.style.margin?.left?.isAuto ?? false) &&
            (ctx.style.margin?.right?.isAuto ?? false));
    final textAlign = ctx.style.effectiveTextAlign;
    final MainAxisAlignment mainAxisAlignment;
    if (autoCentered || textAlign == TextAlign.center) {
      mainAxisAlignment = MainAxisAlignment.center;
    } else if (align == 'right' ||
        textAlign == TextAlign.right ||
        textAlign == TextAlign.end) {
      mainAxisAlignment = MainAxisAlignment.end;
    } else {
      mainAxisAlignment = MainAxisAlignment.start;
    }

    Widget row;
    if (anyFlex) {
      row = EqualHeightRow(
        mainAxisAlignment: mainAxisAlignment,
        textDirection: ctx.style.textDirection,
        widthPercents: [for (final cell in cells) cell.percent],
        children: [for (final cell in cells) cell.child],
      );
    } else {
      row = Row(
        mainAxisSize: anyFlex ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: allMiddle
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        textDirection: ctx.style.textDirection,
        children: [for (final cell in cells) cell.child],
      );
    }
    return decorateTable ? decorate(row, ctx.style) : row;
  }

  /// Resolves [element]'s style against [inherited] and returns a fresh render
  /// context for it. Used by container handlers (lists, tables) that need to
  /// build specific descendant elements directly.
  HtmlRenderContext contextFor(dom.Element element, HtmlStyle inherited) {
    final style = _resolver.resolve(element, inherited);
    return HtmlRenderContext(
      element: element,
      builder: this,
      buildContext: buildContext,
      style: style,
      childInherited: style.inheritedOnly(),
    );
  }

  /// Resolves an actual DOM path, retaining styles on intermediate containers
  /// such as tbody. Direct table layout must not skip these ancestors.
  HtmlRenderContext contextForDescendant(
    dom.Element element,
    HtmlRenderContext ancestor,
  ) {
    if (identical(element, ancestor.element)) return ancestor;
    final key = (element, ancestor);
    final cached = _descendantContexts[key];
    if (cached != null) return cached;
    final path = <dom.Element>[];
    var context = ancestor;
    dom.Element? node = element;
    while (node != null && !identical(node, ancestor.element)) {
      final cachedParent = _descendantContexts[(node, ancestor)];
      if (cachedParent != null) {
        context = cachedParent;
        break;
      }
      path.add(node);
      node = node.parent;
    }
    if (node == null) return contextFor(element, ancestor.childInherited);
    for (final child in path.reversed) {
      context = _descendantContexts.putIfAbsent((
        child,
        ancestor,
      ), () => contextFor(child, context.childInherited));
    }
    return context;
  }

  // --- Inline / block assembly (used by handlers) ---

  /// Combines an element's children into a single [InlineSpan]. Returns `null`
  /// if any child is block-level (so the caller renders a block instead).
  InlineSpan? buildInline(dom.Element element, HtmlRenderContext ctx) {
    final children = buildChildNodes(element, ctx.childInherited);
    if (children.any((child) => child is! InlineResult)) return null;
    return _inlineFromResults(children, ctx);
  }

  InlineSpan _inlineFromResults(
    List<HtmlBuildResult> children,
    HtmlRenderContext ctx,
  ) {
    final spans = <InlineSpan>[];
    for (final child in children) {
      switch (child) {
        case InlineResult(:final span):
          spans.add(span);
        case BlockResult():
        case ColumnResult():
        case FloatResult():
          throw StateError('Non-inline content must be assembled by flow()');
      }
    }
    if (ctx.style.preservesWhitespace) {
      return _PreservedWhitespaceSpan(
        children: spans,
        style: ctx.style.backgroundColor != null
            ? TextStyle(backgroundColor: ctx.style.backgroundColor)
            : null,
      );
    }
    return TextSpan(
      children: spans,
      style: ctx.style.backgroundColor != null
          ? TextStyle(backgroundColor: ctx.style.backgroundColor)
          : null,
    );
  }

  /// Flows an element's children into a block widget and applies its box
  /// decoration.
  Widget buildBlock(dom.Element element, HtmlRenderContext ctx) {
    final results = buildChildNodes(element, ctx.childInherited);
    return _blockFromResults(element, ctx, results);
  }

  Widget _blockFromResults(
    dom.Element element,
    HtmlRenderContext ctx,
    List<HtmlBuildResult> results,
  ) {
    final content = flow(results, ctx.style);
    var result = decorate(content, ctx.style);
    final tag = (element.localName ?? '').toLowerCase();
    if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      result = Semantics(header: true, child: result);
    }
    return result;
  }

  /// Lays a result list out vertically: runs of inline spans become rich-text
  /// paragraphs; block results are emitted as siblings.
  Widget flow(List<HtmlBuildResult> results, HtmlStyle containerStyle) {
    final children = <Widget>[];
    final buffer = <InlineResult>[];
    final floats = <FloatResult>[];
    Widget withFloats(Widget paragraph) {
      if (floats.isEmpty) return paragraph;
      final left = floats
          .where((f) => f.side == 'left')
          .map((f) => f.widget)
          .toList();
      final right = floats
          .where((f) => f.side == 'right')
          .map((f) => f.widget)
          .toList()
          .reversed;
      final row = [...left, paragraph, ...right];
      floats.clear();
      return Table(
        textDirection: TextDirection.ltr,
        columnWidths: {
          for (var i = 0; i < row.length; i++)
            i: i == left.length
                ? const FlexColumnWidth(1)
                : const IntrinsicColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [TableRow(children: row)],
      );
    }

    // The block's line-height is the line-box floor (CSS strut): an inline
    // child with a smaller line-height (e.g. a link with `line-height:12px`
    // inside a `line-height:1.6em` paragraph) must not shrink the line.

    // `font-size:0` collapses the line so a box hugs its inline content — the
    // trick for a round icon button (a 12px icon must not sit in a ~20px line
    // from the default 14px font metrics). Setting the rich-text base font to a
    // ~1px line shrinks the empty-line metrics to nothing; an inline placeholder
    // (the icon) still grows the line to its own height. (A literal 0 would make
    // the inline-widget scaler divide by zero and lay out with NaN.)
    final TextStyle baseStyle = containerStyle.resolvedFontSize <= 0
        ? const TextStyle(fontSize: 1, height: 1)
        : containerStyle.toTextStyle();

    final preserveWs = containerStyle.preservesWhitespace;

    void flushInline() {
      // Generic inline elements are represented by nested TextSpans. An empty
      // formatting node such as `<em></em>` therefore still reaches this
      // buffer even though it has no text or replaced content. If it precedes
      // a block, emitting Text.rich for that span creates a phantom line box
      // (notably above email CTA links). Browsers generate no line box for
      // such structurally empty inline runs, so discard them before trimming
      // boundary whitespace. WidgetSpans remain meaningful even when their
      // child has no text (images and sized inline-blocks use them).
      final meaningful = buffer
          .where((result) => _hasInlineContent(result.span))
          .toList();
      final plain = meaningful.map((r) => r.span.toPlainText()).join();
      if (!preserveWs && plain.contains('\n') && plain.trim().isEmpty) {
        // A BR-only block creates one empty CSS line per break. Flutter's
        // empty rich paragraph can combine fallback metrics with the strut,
        // so measure a normal line and reserve its space without extra text.
        final probe = TextPainter(
          text: TextSpan(text: ' ', style: baseStyle),
          textDirection: containerStyle.textDirection ?? TextDirection.ltr,
          strutStyle: _strutFor(containerStyle, TextLeadingDistribution.even),
          textHeightBehavior: const TextHeightBehavior(
            leadingDistribution: TextLeadingDistribution.even,
          ),
        )..layout();
        children.add(
          withFloats(
            SizedBox(height: probe.height * '\n'.allMatches(plain).length),
          ),
        );
        probe.dispose();
        buffer.clear();
        return;
      }
      final trimmed = _trimWhitespace(meaningful);
      if (trimmed.isNotEmpty) {
        final spans = [for (final r in trimmed) r.span];
        // Plain CSS text splits extra line-height evenly. Inline placeholders
        // already contribute ascent/descent from their measured boxes; applying
        // even leading to that paragraph again inflates image and badge rows.
        final distribution = spans.any(_hasInlineWidget)
            ? TextLeadingDistribution.proportional
            : TextLeadingDistribution.even;
        final uniformText = spans.every(
          (span) => _hasUniformTextMetrics(span, baseStyle, baseStyle),
        );
        // Drop collapsible whitespace at the very start/end of the line, the way
        // CSS strips it at a block's edges. Without this a source-indented run
        // like `<td>\n  •</td>` keeps a leading space before the bullet, which
        // in a narrow cell wraps the bullet onto a second line. Skipped under
        // `white-space:pre*`, and a non-breaking space is never stripped.
        if (!preserveWs) {
          _collapseAdjacentSpaces(spans);
          spans[0] = _trimSpanWhitespace(spans.first, start: true);
          spans[spans.length - 1] = _trimSpanWhitespace(
            spans.last,
            start: false,
          );
        }
        final paragraph = Text.rich(
          TextSpan(children: spans),
          textAlign: containerStyle.effectiveTextAlign ?? TextAlign.start,
          textDirection: containerStyle.textDirection,
          softWrap: !containerStyle.preventsWrapping,
          maxLines:
              containerStyle.preventsWrapping &&
                  containerStyle.overflowHidden == true &&
                  containerStyle.textOverflow == 'ellipsis'
              ? 1
              : null,
          overflow:
              containerStyle.preventsWrapping &&
                  containerStyle.overflowHidden == true &&
                  containerStyle.textOverflow == 'ellipsis'
              ? TextOverflow.ellipsis
              : containerStyle.preventsWrapping
              ? TextOverflow.visible
              : null,
          // Uniform text already carries this line-height. A duplicate strut
          // can add a rounded pixel when a fallback emoji supplies metrics.
          // Keep the CSS floor for smaller/different inline runs and widgets.
          strutStyle: uniformText
              ? null
              : _strutFor(containerStyle, distribution),
          textHeightBehavior: TextHeightBehavior(
            leadingDistribution: distribution,
          ),
          style: baseStyle,
        );
        final zeroWhitespaceLine =
            plain.trim().isEmpty &&
            (containerStyle.lineHeightPx == 0 ||
                containerStyle.lineHeight == 0);
        // Preserve the intrinsic width of a nonbreaking-space sizing hack,
        // while respecting its zero CSS line box. No visible glyph is clipped.
        children.add(
          withFloats(
            zeroWhitespaceLine
                ? SizedBox(height: 0, child: paragraph)
                : paragraph,
          ),
        );
      } else if (floats.isNotEmpty) {
        children.add(withFloats(const SizedBox.shrink()));
      }
      buffer.clear();
    }

    // A run of percent-width inline-block columns (MJML `mj-column-per-N`): lay
    // them out side by side in a Row when their widths fit (sum <= ~100%), or
    // stack them when they don't (each is 100% on a narrow layout).
    final columns = <ColumnResult>[];
    void flushColumns() {
      if (columns.isEmpty) return;
      final total = columns.fold<double>(0, (s, c) => s + c.percent);
      if (columns.length > 1 && total <= 105) {
        final hasRightFloat = columns.any((c) => c.float == 'right');
        final allFloated = columns.every((c) => c.float != null);
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            // `direction:rtl` on the container reverses the columns (the email
            // trick for "image on the right" with image-first source order).
            textDirection: containerStyle.textDirection,
            children: hasRightFloat && allFloated
                ? [
                    // CSS floats consume their intrinsic widths from opposite
                    // sides. The flexible remainder belongs between the left
                    // and right groups (e.g. three app badges floated left and
                    // the final badge floated right).
                    for (final c in columns.where((c) => c.float != 'right'))
                      Flexible(
                        flex: (c.percent * 100).round().clamp(1, 100000),
                        child: c.widget,
                      ),
                    if (total < 100)
                      Spacer(
                        flex: ((100 - total) * 100).round().clamp(1, 100000),
                      ),
                    for (final c in columns.where((c) => c.float == 'right'))
                      Flexible(
                        flex: (c.percent * 100).round().clamp(1, 100000),
                        child: c.widget,
                      ),
                  ]
                : [
                    for (final c in columns)
                      Flexible(
                        flex: c.percent.round().clamp(1, 1000),
                        child: c.widget,
                      ),
                  ],
          ),
        );
      } else {
        for (final c in columns) {
          children.add(c.widget);
        }
      }
      columns.clear();
    }

    for (final result in results) {
      switch (result) {
        case InlineResult():
          // Whitespace between columns (source newlines) must not break the run.
          if (result.isWhitespaceOnly && columns.isNotEmpty && buffer.isEmpty) {
            break;
          }
          flushColumns();
          buffer.add(result);
        case ColumnResult():
          flushInline();
          columns.add(result);
        case FloatResult():
          flushColumns();
          floats.add(result);
        case BlockResult(:final widget):
          flushInline();
          flushColumns();
          children.add(widget);
      }
    }
    flushInline();
    flushColumns();

    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// The container's line-height as a [StrutStyle] floor for a [Text.rich], so
  /// an inline child with a smaller line-height can't collapse the line box
  /// (matches CSS: the line box is at least the block's line-height). Returns
  /// null when the block sets no line-height.
  static bool _hasInlineWidget(InlineSpan span) =>
      span is WidgetSpan ||
      (span is TextSpan && (span.children?.any(_hasInlineWidget) ?? false));

  static bool _hasUniformTextMetrics(
    InlineSpan span,
    TextStyle inherited,
    TextStyle base,
  ) {
    if (span is! TextSpan) return false;
    final style = inherited.merge(span.style);
    if (style.fontSize != base.fontSize ||
        style.height != base.height ||
        style.fontFamily != base.fontFamily ||
        (style.fontWeight ?? FontWeight.normal) !=
            (base.fontWeight ?? FontWeight.normal) ||
        (style.fontStyle ?? FontStyle.normal) !=
            (base.fontStyle ?? FontStyle.normal) ||
        style.fontFamilyFallback?.join('\u0000') !=
            base.fontFamilyFallback?.join('\u0000')) {
      return false;
    }
    return span.children?.every(
          (child) => _hasUniformTextMetrics(child, style, base),
        ) ??
        true;
  }

  StrutStyle? _strutFor(HtmlStyle style, TextLeadingDistribution distribution) {
    final fontSize = style.resolvedFontSize;
    if (fontSize <= 0) return null;
    final double? height;
    if (style.lineHeightPx != null) {
      height = style.lineHeightPx! / fontSize;
    } else if (style.lineHeight != null) {
      height = style.lineHeight;
    } else {
      return null;
    }
    final font = style.toTextStyle();
    return StrutStyle(
      fontFamily: font.fontFamily,
      fontFamilyFallback: font.fontFamilyFallback,
      fontWeight: font.fontWeight,
      fontStyle: font.fontStyle,
      fontSize: fontSize,
      height: height,
      leadingDistribution: distribution,
      forceStrutHeight: false, // floor only; taller inline content can exceed
    );
  }

  static List<InlineResult> _trimWhitespace(List<InlineResult> spans) {
    var start = 0;
    var end = spans.length;
    while (start < end && spans[start].isWhitespaceOnly) {
      start++;
    }
    while (end > start && spans[end - 1].isWhitespaceOnly) {
      end--;
    }
    return spans.sublist(start, end);
  }

  /// Whether [span] contributes text or replaced/boxed inline content.
  ///
  /// A nested tree made solely from empty [TextSpan]s is just formatting
  /// structure and must not create a CSS line box. Any [PlaceholderSpan]
  /// represents real inline layout (for example an image or inline-block), and
  /// non-empty text includes significant whitespace such as `&nbsp;`.
  static bool _hasInlineContent(InlineSpan span) {
    if (span is PlaceholderSpan) return true;
    if (span is! TextSpan) return true;
    if (span.text?.isNotEmpty ?? false) return true;
    return span.children?.any(_hasInlineContent) ?? false;
  }

  /// Whether a nominally-inline element needs a real box instead of a
  /// [TextSpan]. TextSpan can carry text styling and a square background, but
  /// not CSS box layout. Email CTAs commonly put the horizontal padding on an
  /// inline `<span>` inside an inline-block link; if we keep that span as text,
  /// the button collapses to the label width.
  bool _inlineNeedsBox(HtmlStyle style) {
    final fontSize = style.resolvedFontSize;
    final rootFontSize = _rootStyle.resolvedFontSize;

    bool hasNonZeroEdges(CssEdges? edges) {
      if (edges == null || edges.isEmpty) return false;
      final resolved = _clampNonNegative(
        edges.resolve(fontSize: fontSize, rootFontSize: rootFontSize),
      );
      return resolved != null &&
          (resolved.left > 0 ||
              resolved.right > 0 ||
              resolved.top > 0 ||
              resolved.bottom > 0);
    }

    bool hasPercentEdge(CssEdges? edges) {
      if (edges == null || edges.isEmpty) return false;
      bool percent(CssLength? length) =>
          length != null &&
          length.unit == CssLengthUnit.percent &&
          length.value > 0;
      return percent(edges.left) ||
          percent(edges.right) ||
          percent(edges.top) ||
          percent(edges.bottom);
    }

    final hasPadding =
        hasNonZeroEdges(style.padding) || hasPercentEdge(style.padding);
    final hasMargin =
        hasNonZeroEdges(style.margin) || hasPercentEdge(style.margin);
    final hasBorder =
        _borderExtent(style.borders, true) > 0 ||
        _borderExtent(style.borders, false) > 0;
    // CSS dimensions do not apply to non-replaced inline elements. In
    // particular, max-width on a price span must not turn it into a clipped
    // inline-block. Explicit inline-blocks take their own sizing path above.
    final hasRadius =
        style.borderRadius != null ||
        style.borderRadiusPercent != null ||
        style.borderRadiusGeometry != null;

    return hasPadding ||
        hasMargin ||
        hasBorder ||
        style.backgroundImage != null ||
        ((style.backgroundColor != null || hasBorder) && hasRadius) ||
        style.opacity != null ||
        style.overflowHidden == true;
  }

  static final RegExp _leadingCollapsible = RegExp(r'^[^\S ]+');
  static final RegExp _trailingCollapsible = RegExp(r'[^\S ]+$');

  /// HTML collapses an ASCII space even when the two source runs are separated
  /// by a style/link boundary. Preserve span metadata and non-breaking spaces.
  static void _collapseAdjacentSpaces(List<InlineSpan> spans) {
    var previousSpace = false;
    var lineStart = false;
    InlineSpan visit(InlineSpan span) {
      if (span is! TextSpan || span is _PreservedWhitespaceSpan) {
        previousSpace = false;
        lineStart = false;
        return span;
      }
      var text = span.text;
      if (text != null && text.isNotEmpty) {
        if ((previousSpace || lineStart) && text.startsWith(' ')) {
          text = text.substring(1);
        }
        if (text.isNotEmpty) {
          previousSpace = text.endsWith(' ');
          lineStart = text.endsWith('\n');
        }
      }
      final children = span.children?.map(visit).toList();
      return TextSpan(
        text: text,
        children: children,
        style: span.style,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        semanticsLabel: span.semanticsLabel,
        spellOut: span.spellOut,
        locale: span.locale,
        onEnter: span.onEnter,
        onExit: span.onExit,
      );
    }

    for (var i = 0; i < spans.length; i++) {
      spans[i] = visit(spans[i]);
    }
  }

  /// Strips collapsible whitespace from the [start] (or end) of [span]'s text,
  /// recursing into the first/last child so a leading space inside a nested run
  /// (e.g. `<b>` at the line start) is trimmed too. A non-breaking space is left
  /// intact. [TextSpan] style/recognizer/cursor are preserved; a [WidgetSpan]
  /// (e.g. an inline image at the edge) is returned unchanged.
  static InlineSpan _trimSpanWhitespace(
    InlineSpan span, {
    required bool start,
  }) {
    if (span is! TextSpan || span is _PreservedWhitespaceSpan) return span;
    final text = span.text;
    // A source newline has already collapsed to a space. This newline is an
    // explicit BR and must create an empty first line when it precedes text.
    if (start && text == '\n') return span;
    if (text != null && text.isNotEmpty) {
      final trimmed = text.replaceFirst(
        start ? _leadingCollapsible : _trailingCollapsible,
        '',
      );
      if (trimmed == text) return span;
      return TextSpan(
        text: trimmed,
        style: span.style,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        semanticsLabel: span.semanticsLabel,
        children: span.children,
      );
    }
    final children = span.children;
    if (children == null || children.isEmpty) return span;
    final newChildren = List<InlineSpan>.of(children);
    final i = start ? 0 : newChildren.length - 1;
    newChildren[i] = _trimSpanWhitespace(newChildren[i], start: start);
    return TextSpan(
      style: span.style,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      semanticsLabel: span.semanticsLabel,
      children: newChildren,
    );
  }

  /// Wraps [content] with margin/padding/background/border/width from [style].
  ///
  /// When [inline] is true the result is meant to sit inside a `WidgetSpan`
  /// (inline-block), so the fixed-width Align wrapper — which exists only to
  /// resist the block flow's `stretch` — is skipped.
  Widget decorate(Widget content, HtmlStyle style, {bool inline = false}) {
    final fontSize = style.resolvedFontSize;
    final rootFontSize = _rootStyle.resolvedFontSize;

    // Flutter's Container forbids negative margin/padding (a common email hack,
    // e.g. `margin-left:-20px` to offset list padding). Clamp to zero rather
    // than crash; the visual difference is minor.
    final margin = _clampNonNegative(
      style.margin?.resolve(fontSize: fontSize, rootFontSize: rootFontSize),
    );
    final fixedPadding = _clampNonNegative(
      style.padding?.resolve(fontSize: fontSize, rootFontSize: rootFontSize),
    );
    final percentPadding = _percentPadding(style.padding);
    final border = style.borders?.toBorder();
    final background = style.backgroundColor;

    // A CSS background-image (e.g. a social-icon sprite or an image bullet) is
    // drawn behind the content, offset by background-position. The background
    // sits at the padding-box edge, so when there's both a background image and
    // padding, pad the CONTENT (inside the background stack) rather than the
    // outer box — otherwise the padding would shift the image too (e.g. a star
    // bullet would slide right onto the text instead of staying at the left).
    var containerPadding = fixedPadding;
    var applyPercentInside = percentPadding != EdgeInsets.zero;
    if (style.backgroundImage != null &&
        (fixedPadding != null || applyPercentInside)) {
      if (applyPercentInside) {
        content = PercentPadding(fractions: percentPadding, child: content);
      }
      if (fixedPadding != null) {
        content = Padding(padding: fixedPadding, child: content);
      }
      containerPadding = null;
      applyPercentInside = false;
    }
    content = _withBackgroundImage(content, style);

    final patternedBorder = style.borders == null
        ? null
        : CssBorderDecoration(
            borders: style.borders!,
            borderRadius:
                style.borderRadiusGeometry ??
                (style.borderRadius != null
                    ? BorderRadius.circular(style.borderRadius!)
                    : null),
          );
    final hasPatternedBorder =
        patternedBorder?.hasVisiblePatternedSide ?? false;
    final hasDecoration =
        background != null || border != null || hasPatternedBorder;
    // BoxDecoration only allows borderRadius with a uniform (or absent) border.
    final requestedRadius =
        style.borderRadiusGeometry ??
        (style.borderRadius != null
            ? BorderRadius.circular(style.borderRadius!)
            : null);
    final clipNonuniformBorder =
        requestedRadius != null && border != null && !border.isUniform;
    final BorderRadius? radius = clipNonuniformBorder ? null : requestedRadius;
    final horizontalBoxExtra = style.boxSizing == CssBoxSizing.borderBox
        ? 0.0
        : (fixedPadding?.horizontal ?? 0) + _borderExtent(style.borders, true);
    final verticalBoxExtra = style.boxSizing == CssBoxSizing.borderBox
        ? 0.0
        : (fixedPadding?.vertical ?? 0) + _borderExtent(style.borders, false);
    // A table cell's `width` is a column hint the table distributes, not a
    // self-applied box width (real `<td>` cells are sized by the column too).
    // So a `display:table-cell` div must not size itself — its anonymous-table
    // parent ([_buildAnonymousCssTable]) reads the width and lays the columns.
    final isTableCell = style.display == CssDisplay.tableCell;
    final declaredWidth = isTableCell
        ? null
        : _resolveAbsoluteLength(style.width, fontSize, rootFontSize);
    final width = declaredWidth == null
        ? null
        : declaredWidth + horizontalBoxExtra;
    noteFixedWidth(width);
    final declaredMaxWidth = _resolveAbsoluteLength(
      style.maxWidth,
      fontSize,
      rootFontSize,
    );
    final maxWidth = declaredMaxWidth == null
        ? null
        : declaredMaxWidth + horizontalBoxExtra;
    final declaredMinWidth = _resolveAbsoluteLength(
      style.minWidth,
      fontSize,
      rootFontSize,
    );
    final minWidth = declaredMinWidth == null
        ? null
        : declaredMinWidth + horizontalBoxExtra;
    final declaredHeight = _resolveAbsoluteLength(
      style.height,
      fontSize,
      rootFontSize,
    );
    final height = declaredHeight == null
        ? null
        : declaredHeight + verticalBoxExtra;
    // min/max-height are content-box measurements like width/height: under the
    // default content-box, the padding/border add on top (so `min-height:40px;
    // padding:12px 0` reserves ≥64px), matching the width path above.
    final minHeightRaw = _resolveAbsoluteLength(
      style.minHeight,
      fontSize,
      rootFontSize,
    );
    final minHeight = minHeightRaw == null
        ? null
        : minHeightRaw + verticalBoxExtra;
    final maxHeightRaw = _resolveAbsoluteLength(
      style.maxHeight,
      fontSize,
      rootFontSize,
    );
    final maxHeight = maxHeightRaw == null
        ? null
        : maxHeightRaw + verticalBoxExtra;

    if (margin == null &&
        fixedPadding == null &&
        !applyPercentInside &&
        !hasDecoration &&
        width == null &&
        minWidth == null &&
        maxWidth == null &&
        height == null &&
        minHeight == null &&
        maxHeight == null &&
        style.opacity == null &&
        style.overflowHidden != true &&
        style.visibilityHidden != true) {
      return content;
    }

    Widget result = Container(
      margin: clipNonuniformBorder ? null : margin,
      padding: containerPadding,
      width: width,
      height: height,
      decoration: hasDecoration
          ? BoxDecoration(
              color: background,
              border: border,
              borderRadius: radius,
            )
          : null,
      foregroundDecoration: hasPatternedBorder ? patternedBorder : null,
      clipBehavior: radius != null && hasDecoration
          ? Clip.antiAlias
          : Clip.none,
      child: applyPercentInside
          ? PercentPadding(fractions: percentPadding, child: content)
          : content,
    );
    if (clipNonuniformBorder) {
      result = ClipRRect(borderRadius: requestedRadius, child: result);
      if (margin != null) result = Padding(padding: margin, child: result);
    }

    final percentWidth =
        !isTableCell && style.width?.unit == CssLengthUnit.percent
        ? style.width!.value / 100.0
        : null;
    if (percentWidth != null && percentWidth >= 0) {
      result = maxWidth == null
          ? FractionallySizedBox(
              widthFactor: percentWidth,
              alignment: Alignment.topLeft,
              child: result,
            )
          : PercentMaxWidthBox(
              widthFactor: percentWidth,
              maxWidth: maxWidth + (margin?.horizontal ?? 0),
              child: result,
            );
    }

    if (maxWidth != null && percentWidth == null) {
      // A block with only `max-width` fills its container up to that width (CSS
      // block-level sizing) rather than shrinking to its content — e.g. a
      // `<div style="max-width:600px">&nbsp;</div>` spacer bar must span the
      // column, not collapse to the nbsp's width. An explicit `width` already
      // sizes the box; an inline-block sizes to content.
      if (inline && width == null) {
        result = ShrinkableMaxWidthBox(
          maxWidth: maxWidth + (margin?.horizontal ?? 0),
          child: result,
        );
      } else {
        final fill = width == null && !inline;
        result = ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth + (margin?.horizontal ?? 0),
          ),
          child: fill
              ? SizedBox(width: double.infinity, child: result)
              : result,
        );
      }
    }

    if (minWidth != null || minHeight != null || maxHeight != null) {
      result = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minWidth ?? 0,
          minHeight: minHeight ?? 0,
          maxHeight: maxHeight == null
              ? double.infinity
              : maxHeight < (minHeight ?? 0)
              ? (minHeight ?? 0)
              : maxHeight,
        ),
        child: result,
      );
    }

    if (style.overflowHidden == true) {
      result = ClipRect(child: result);
    }
    final opacity = style.opacity;
    if (opacity != null && opacity < 1) {
      result = Opacity(opacity: opacity, child: result);
    }

    // A block with a constrained width must not be stretched to full width by
    // the parent flow's `CrossAxisAlignment.stretch`. Wrap it so it keeps its
    // width, centered for `margin:0 auto` / `text-align:center` / `max-width`
    // (the common centered-container idiom), otherwise left-aligned.
    if ((width != null || maxWidth != null) && !inline) {
      final m = style.margin;
      final leftAuto = m?.left?.isAuto ?? false;
      final rightAuto = m?.right?.isAuto ?? false;
      // Auto margins position the box per CSS: both auto -> centre, one auto ->
      // pushed to the opposite side (`margin:0 auto 0 0` = right-auto -> left).
      // `float` pins it to its side. A bare `max-width` block with no auto
      // margins or alignment centres (the common centered-container idiom).
      final centerByMaxWidth =
          maxWidth != null && width == null && percentWidth == null;
      final Alignment alignment;
      if (style.float == 'left') {
        alignment = Alignment.topLeft;
      } else if (style.float == 'right') {
        alignment = Alignment.topRight;
      } else if (leftAuto && rightAuto) {
        alignment = Alignment.topCenter;
      } else if (rightAuto) {
        alignment = Alignment.topLeft;
      } else if (leftAuto) {
        alignment = Alignment.topRight;
      } else if (style.textAlign == TextAlign.center) {
        alignment = Alignment.topCenter;
      } else if (style.textAlign == TextAlign.right) {
        alignment = Alignment.topRight;
      } else if (centerByMaxWidth) {
        alignment = Alignment.topCenter;
      } else {
        alignment = Alignment.topLeft;
      }
      result = Align(alignment: alignment, heightFactor: 1.0, child: result);
    }
    if (style.visibilityHidden ?? false) {
      result = IgnorePointer(
        child: ExcludeSemantics(child: Opacity(opacity: 0, child: result)),
      );
    }
    return result;
  }

  /// Draws a CSS `background-image` behind [content], offset by
  /// `background-position` and clipped to the box (CSS sprites). Honors the
  /// image policy, so a remote sprite is shown only when remote images are
  /// allowed; otherwise the content renders without it.
  Widget _withBackgroundImage(Widget content, HtmlStyle style) {
    final url = style.backgroundImage;
    if (url == null || url.isEmpty) return content;
    if (url.trimLeft().toLowerCase().startsWith('linear-gradient(')) {
      final gradient = _linearGradient(url);
      if (gradient == null) return content;
      Widget result = DecoratedBox(
        decoration: BoxDecoration(gradient: gradient),
        child: content,
      );
      final radius =
          style.borderRadiusGeometry ??
          (style.borderRadius != null
              ? BorderRadius.circular(style.borderRadius!)
              : null);
      if (radius != null) {
        result = ClipRRect(borderRadius: radius, child: result);
      }
      return result;
    }
    if (url.trimLeft().toLowerCase().startsWith('data:') &&
        !config.sanitizer.allowDataUriImages) {
      return content;
    }
    final resolution = imageResolver.resolve(url, const {});
    if (!resolution.hasImage) return content;

    // Clip the background (and its overflow) to the box, rounding the corners
    // when the box has a border-radius — e.g. a hero banner with rounded edges.
    final radius =
        style.borderRadiusGeometry ??
        (style.borderRadius != null && style.borderRadius! > 0
            ? BorderRadius.circular(style.borderRadius!)
            : null);
    Widget clip(Widget child) => radius != null
        ? ClipRRect(borderRadius: radius, child: child)
        : ClipRect(child: child);

    // A scaled background (background-size: cover/contain/100%) fills the box —
    // e.g. a full-bleed hero banner behind centred content.
    final size = style.backgroundSize;
    final spriteWidth = (size != null && size.endsWith('px'))
        ? double.tryParse(size.substring(0, size.length - 2))
        : null;
    final repeat = _imageRepeat(style.backgroundRepeat);
    if (repeat != ImageRepeat.noRepeat && size == null) {
      return clip(
        _TiledBackground(
          image: resolution.provider!,
          repeat: repeat,
          alignment: style.backgroundPosition ?? Alignment.topLeft,
          child: content,
        ),
      );
    }
    if (size != null && spriteWidth == null) {
      final fit = switch (size) {
        'cover' => BoxFit.cover,
        'contain' => BoxFit.contain,
        _ => BoxFit.fitWidth, // '100%': scale to the box width
      };
      return clip(
        Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: Image(
                image: resolution.provider!,
                fit: fit,
                alignment: style.backgroundPosition ?? Alignment.center,
              ),
            ),
            content,
          ],
        ),
      );
    }

    // Otherwise a CSS sprite drawn at its position — natural size, or a fixed
    // width from `background-size:Npx` (an image bullet/icon).
    final x = style.backgroundPositionX ?? 0;
    final y = style.backgroundPositionY ?? 0;
    return clip(
      Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: x,
            top: y,
            child: Image(image: resolution.provider!, width: spriteWidth),
          ),
          content,
        ],
      ),
    );
  }

  static LinearGradient? _linearGradient(String value) {
    final match = RegExp(
      r'^linear-gradient\((.*)\)$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(value.trim());
    if (match == null) return null;
    final parts = <String>[];
    var depth = 0, start = 0;
    final body = match.group(1)!;
    for (var i = 0; i < body.length; i++) {
      if (body[i] == '(') depth++;
      if (body[i] == ')') depth--;
      if (body[i] == ',' && depth == 0) {
        parts.add(body.substring(start, i).trim());
        start = i + 1;
      }
    }
    parts.add(body.substring(start).trim());
    var begin = Alignment.topCenter, end = Alignment.bottomCenter;
    if (parts.first.toLowerCase().startsWith('to ')) {
      final direction = parts.removeAt(0).toLowerCase();
      final ends = switch (direction) {
        'to bottom' => (Alignment.topCenter, Alignment.bottomCenter),
        'to top' => (Alignment.bottomCenter, Alignment.topCenter),
        'to right' => (Alignment.centerLeft, Alignment.centerRight),
        'to left' => (Alignment.centerRight, Alignment.centerLeft),
        'to bottom right' ||
        'to right bottom' => (Alignment.topLeft, Alignment.bottomRight),
        'to bottom left' ||
        'to left bottom' => (Alignment.topRight, Alignment.bottomLeft),
        'to top right' ||
        'to right top' => (Alignment.bottomLeft, Alignment.topRight),
        'to top left' ||
        'to left top' => (Alignment.bottomRight, Alignment.topLeft),
        _ => null,
      };
      if (ends == null) return null;
      begin = ends.$1;
      end = ends.$2;
    }
    final colors = parts.map(CssColor.tryParse).toList();
    if (colors.length < 2 || colors.any((color) => color == null)) return null;
    return LinearGradient(begin: begin, end: end, colors: colors.cast<Color>());
  }

  static ImageRepeat _imageRepeat(CssBackgroundRepeat? repeat) {
    return switch (repeat) {
      // CSS defaults `background-repeat` to `repeat`. Paint tiling in a custom
      // paint-only layer so it never participates in layout.
      CssBackgroundRepeat.repeat || null => ImageRepeat.repeat,
      CssBackgroundRepeat.repeatX => ImageRepeat.repeatX,
      CssBackgroundRepeat.repeatY => ImageRepeat.repeatY,
      CssBackgroundRepeat.noRepeat => ImageRepeat.noRepeat,
    };
  }

  static EdgeInsets? _clampNonNegative(EdgeInsets? insets) {
    if (insets == null || insets.isNonNegative) return insets;
    return EdgeInsets.only(
      left: insets.left < 0 ? 0 : insets.left,
      top: insets.top < 0 ? 0 : insets.top,
      right: insets.right < 0 ? 0 : insets.right,
      bottom: insets.bottom < 0 ? 0 : insets.bottom,
    );
  }

  static double _borderExtent(CssBorders? borders, bool horizontal) {
    if (borders == null) return 0;
    double width(CssBorderSide? side) =>
        side == null || !side.width.isFinite || side.width <= 0
        ? 0
        : side.width;
    return horizontal
        ? width(borders.left) + width(borders.right)
        : width(borders.top) + width(borders.bottom);
  }

  /// Resolves a length to logical px, ignoring `auto`/`%` (which need a base
  /// the block layout doesn't have here).
  double? _resolveAbsoluteLength(
    CssLength? length,
    double fontSize,
    double rootFontSize,
  ) {
    if (length == null ||
        length.isAuto ||
        length.unit == CssLengthUnit.percent) {
      return null;
    }
    return length.resolve(fontSize: fontSize, rootFontSize: rootFontSize);
  }

  static EdgeInsets _percentPadding(CssEdges? edges) {
    double f(CssLength? v) => v?.unit == CssLengthUnit.percent
        ? (v!.value / 100).clamp(0.0, double.infinity)
        : 0;
    return EdgeInsets.fromLTRB(
      f(edges?.left),
      f(edges?.top),
      f(edges?.right),
      f(edges?.bottom),
    );
  }
}

class _PreservedWhitespaceSpan extends TextSpan {
  const _PreservedWhitespaceSpan({super.children, super.style});
}

class _TiledBackground extends StatefulWidget {
  const _TiledBackground({
    required this.image,
    required this.repeat,
    required this.alignment,
    required this.child,
  });

  final ImageProvider image;
  final ImageRepeat repeat;
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  State<_TiledBackground> createState() => _TiledBackgroundState();
}

class _TiledBackgroundState extends State<_TiledBackground> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _imageInfo;
  bool _acceptedFrameForStream = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(_TiledBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolveImage();
  }

  @override
  void dispose() {
    _removeStreamListener();
    _imageInfo?.dispose();
    super.dispose();
  }

  void _resolveImage() {
    final listener = _listener ??= ImageStreamListener(_handleImage);
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _stream?.removeListener(listener);
    _acceptedFrameForStream = false;
    _stream = stream..addListener(listener);
  }

  void _handleImage(ImageInfo imageInfo, bool synchronousCall) {
    if (_acceptedFrameForStream) {
      imageInfo.dispose();
      return;
    }
    _acceptedFrameForStream = true;
    final oldInfo = _imageInfo;
    if (oldInfo?.image == imageInfo.image &&
        oldInfo?.scale == imageInfo.scale) {
      imageInfo.dispose();
      return;
    }
    _imageInfo = imageInfo;
    oldInfo?.dispose();
    // Repeated backgrounds are decorative tiles. Freezing them at the first
    // decoded frame prevents animated GIF backgrounds from invalidating and
    // repainting the whole tiled layer on every frame.
    _removeStreamListener();
    if (mounted) setState(() {});
  }

  void _removeStreamListener() {
    final listener = _listener;
    final stream = _stream;
    if (listener != null && stream != null) {
      stream.removeListener(listener);
    }
    _stream = null;
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _imageInfo == null
          ? null
          : _TiledBackgroundPainter(
              imageInfo: _imageInfo!,
              repeat: widget.repeat,
              alignment: widget.alignment.resolve(
                Directionality.maybeOf(context),
              ),
            ),
      child: widget.child,
    );
  }
}

class _TiledBackgroundPainter extends CustomPainter {
  const _TiledBackgroundPainter({
    required this.imageInfo,
    required this.repeat,
    required this.alignment,
  });

  final ImageInfo imageInfo;
  final ImageRepeat repeat;
  final Alignment alignment;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final image = imageInfo.image;
    final scale = imageInfo.scale;
    if (image.width <= 0 || image.height <= 0 || scale <= 0) return;

    final tileSize = Size(image.width / scale, image.height / scale);
    if (tileSize.isEmpty) return;

    final repeatX =
        repeat == ImageRepeat.repeat || repeat == ImageRepeat.repeatX;
    final repeatY =
        repeat == ImageRepeat.repeat || repeat == ImageRepeat.repeatY;
    final origin = alignment.alongOffset(
      Offset(size.width - tileSize.width, size.height - tileSize.height),
    );
    final logicalRect = Rect.fromLTWH(
      repeatX ? 0 : origin.dx,
      repeatY ? 0 : origin.dy,
      repeatX ? size.width : tileSize.width,
      repeatY ? size.height : tileSize.height,
    ).intersect(Offset.zero & size);
    if (logicalRect.isEmpty) return;

    // `paintImage(repeat: ...)` expands repeats by drawing many image rects.
    // A small footer tile plus an animated GIF elsewhere in the email can then
    // repaint thousands of tiny images per second. Use an ImageShader instead:
    // one draw call fills the repeated area, while non-repeated axes are clipped
    // to the tile's natural extent so they don't stretch.
    final paint = Paint()
      ..isAntiAlias = false
      ..shader = ui.ImageShader(
        image,
        repeatX ? ui.TileMode.repeated : ui.TileMode.clamp,
        repeatY ? ui.TileMode.repeated : ui.TileMode.clamp,
        Matrix4.identity().storage,
      );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(1 / scale, 1 / scale);
    canvas.drawRect(
      Rect.fromLTWH(
        (logicalRect.left - origin.dx) * scale,
        (logicalRect.top - origin.dy) * scale,
        logicalRect.width * scale,
        logicalRect.height * scale,
      ),
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TiledBackgroundPainter oldDelegate) {
    return oldDelegate.imageInfo.image != imageInfo.image ||
        oldDelegate.imageInfo.scale != imageInfo.scale ||
        oldDelegate.repeat != repeat ||
        oldDelegate.alignment != alignment;
  }
}
