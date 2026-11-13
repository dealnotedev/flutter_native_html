import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../config/html_render_config.dart';
import '../config/html_image_resolver.dart';
import '../css/css_color.dart';
import '../css/css_length.dart';
import '../css/html_style.dart';
import '../css/style_resolver.dart';
import 'css_background.dart';
import 'css_border_decoration.dart';
import 'css_border_radius.dart';
import 'element_registry.dart';
import 'html_build_result.dart';
import 'html_render_context.dart';
import 'layout/equal_height_row.dart';
import 'layout/float_flow.dart';
import 'layout/negative_margin.dart';
import 'layout/paragraph_min_width.dart';
import 'layout/percent_boxes.dart';
import 'text_wrapping.dart';

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
    this.lineHeightQuirk = false,
    bool? allowDataUriImages,
  }) : _rootStyle = rootStyle, // ignore: prefer_initializing_formals
       _allowDataUriImages =
           allowDataUriImages ?? config.sanitizer.allowDataUriImages,
       _resolver = resolver; // ignore: prefer_initializing_formals

  final HtmlRenderConfig config;

  /// See [ParsedEmail.lineHeightQuirk].
  final bool lineHeightQuirk;
  final BuildContext buildContext;
  final HtmlStyle _rootStyle;
  final bool _allowDataUriImages;
  final StyleResolver _resolver;
  late final HtmlImageResolver imageResolver = config.imageResolver
      .forDocument();
  final _descendantContexts =
      <(dom.Element, HtmlRenderContext), HtmlRenderContext>{};
  final _anchorDeclarations = <dom.Element?, Map<String, String>>{};

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
    final parentStyle = _resolver.documentParentStyle(body);
    if (parentStyle.display == CssDisplay.none) return const SizedBox.shrink();
    final style = _resolver.resolve(body, parentStyle.inheritedOnly());
    if (style.display == CssDisplay.none) return const SizedBox.shrink();
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
            (_registry.handlerFor(node.localName ?? '') == null ||
                node.localName == 'ul' ||
                node.localName == 'ol');
        if (normalBlock) style = _collapseChildMargins(node, style);
        double edge(CssLength? value) =>
            (value?.resolve(
                      fontSize: style.resolvedFontSize,
                      rootFontSize: config.baseFontSize,
                    ) ??
                    0)
                .clamp(0, double.infinity);
        final nested = <dom.Element>[];
        final innerMargin = normalBlock
            ? _collapseThroughMargin(node, style, nested)
            : null;
        final emptyBlock = innerMargin != null;
        if (emptyBlock) {
          // The whole empty subtree is one collapsed margin, carried by
          // [node]; the nested blocks lay out with none of their own.
          _collapsedTopMargins.addAll(nested);
          _collapsedBottomMargins.addAll(nested);
        }
        var top = edge(style.margin?.top);
        final bottom = edge(style.margin?.bottom);
        var emptyMargin = top > bottom ? top : bottom;
        if (innerMargin != null && innerMargin > emptyMargin) {
          emptyMargin = innerMargin;
        }
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
    if (preserve) {
      return _spansFor(raw, textStyle, linkify, inherited, parent);
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
    return _spansFor(collapsed, textStyle, linkify, inherited, parent);
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
    final transform = inherited.textTransform;
    final wrapping = inherited.preventsWrapping
        ? null
        : switch (inherited.wordBreak) {
            CssWordBreak.breakAll => TextWrapping.breakAll,
            CssWordBreak.breakWord => TextWrapping.anywhere,
            _ when inherited.overflowWrap == CssOverflowWrap.anywhere =>
              TextWrapping.anywhere,
            _ => null,
          };
    InlineResult run(
      String value,
      TextStyle style, [
      GestureRecognizer? recognizer,
    ]) => InlineResult(
      wrapping == null
          ? TextSpan(text: value, style: style, recognizer: recognizer)
          : WrappingTextSpan(
              wrapping: wrapping,
              text: value,
              style: style,
              recognizer: recognizer,
            ),
    );

    if (!linkify || inherited.visibilityHidden == true) {
      return [run(_transform(text, transform), style)];
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
      return [run(_transform(text, transform), style)];
    }

    final results = <HtmlBuildResult>[];
    final linkStyle = _autoLinkStyle(style, inherited, parent);
    final onTap = config.onLinkTap;
    var last = 0;
    for (final m in matches) {
      if (m.start > last) {
        results.add(
          run(_transform(text.substring(last, m.start), transform), style),
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
      results.add(run(_transform(token, transform), linkStyle, recognizer));
      if (trailing.isNotEmpty) {
        results.add(run(_transform(trailing, transform), style));
      }
      last = m.end;
    }
    if (last < text.length) {
      results.add(run(_transform(text.substring(last), transform), style));
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
    final defaultBlue = _resolver.defaultLinkColorFor(
      parent,
      autoDetected: true,
    );

    final cfg = config.autoLinkColor;
    if (cfg != null) {
      return base.copyWith(
        color: _resolver.readableColor(cfg, parent),
        decoration: TextDecoration.underline,
        decorationColor: _resolver.readableColor(cfg, parent),
      );
    }
    if (inherited.pointerEventsNone ?? false) {
      return base.copyWith(
        color: _resolver.readableColor(defaultBlue, parent),
        decoration: TextDecoration.underline,
        decorationColor: _resolver.readableColor(defaultBlue, parent),
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

    final resolved = color == null
        ? base.color
        : _resolver.readableColor(color, parent);
    return base.copyWith(
      color: resolved,
      decoration: decoration,
      decorationColor: resolved,
    );
  }

  /// Author-stylesheet declarations that apply to an `<a>` at [parent]'s
  /// position (UA/inline styling excluded). Resolved via a throwaway `<a>` so
  /// descendant selectors (`#wrap a`, `.body a`) still match the real ancestry.
  Map<String, String> _anchorAuthorDeclarations(dom.Element? parent) =>
      _anchorDeclarations.putIfAbsent(parent, () {
        final anchor = dom.Element.tag('a');
        if (parent != null) anchor.parentNode = parent;
        return _resolver.resolvedSheetDeclarationsFor(anchor);
      });

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
      case CssDisplay.flex:
        return [BlockResult(_buildFlexRow(element, ctx))];
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
        final span = _inlineFromResults(children, ctx);
        final padding = ctx.style.padding?.resolve(
          fontSize: ctx.style.resolvedFontSize,
          rootFontSize: _rootStyle.resolvedFontSize,
        );
        if (padding == null || (padding.left <= 0 && padding.right <= 0)) {
          return [InlineResult(span)];
        }
        // Plain inline padding does not make its text atomic. Horizontal
        // edges occupy inline space; vertical edges do not enlarge the line.
        return [
          InlineResult(
            TextSpan(
              children: [
                if (padding.left > 0)
                  InlineSpacerSpan(
                    child: SizedBox(width: padding.left, height: 0),
                  ),
                span,
                if (padding.right > 0)
                  InlineSpacerSpan(
                    child: SizedBox(width: padding.right, height: 0),
                  ),
              ],
            ),
          ),
        ];
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
        // A percent-width inline-block is a column (MJML `mj-column-per-N`): the
        // flow step rows a run of them side by side, or stacks them when they
        // don't fit (each 100% on a narrow layout). The effective column width
        // is min(width, max-width) — MJML sets width:100% but caps it with
        // max-width:50% to get a half-width column.
        double? pct;
        final percentWidth =
            w != null && !w.isAuto && w.unit == CssLengthUnit.percent;
        if (percentWidth) pct = w.value;
        if (mw != null && mw.unit == CssLengthUnit.percent) {
          pct = pct == null ? mw.value : (mw.value < pct ? mw.value : pct);
        }
        if (pct != null) {
          // The column row already allots the percentage. Resolving the
          // box's own percentage again inside that share made a desktop MJML
          // `width:33%` column a third of a third.
          final columnStyle = percentWidth
              ? ctx.style.merge(
                  const HtmlStyle(width: CssLength(100, CssLengthUnit.percent)),
                )
              : ctx.style;
          return [
            ColumnResult(decorate(content, columnStyle, inline: true), pct),
          ];
        }
        final box = decorate(content, ctx.style, inline: true);
        return [
          InlineResult(
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: box),
          ),
        ];
      case CssDisplay.block:
        final results = buildChildNodes(element, ctx.childInherited);
        // A bare wrapper around one narrow floated table (Constant Contact's
        // `<div><table align="left">image</table></div>` before the text
        // block) passes the float on, so the next block wraps beside it.
        final clear = _resolver
            .computedDeclarationsFor(element)['clear']
            ?.trim()
            .toLowerCase();
        final clears = clear == 'both' || clear == 'left' || clear == 'right';
        final content = results
            .where((r) => r is! InlineResult || !r.isWhitespaceOnly)
            .toList();
        // A clearing wrapper must stay a block: it starts below the floats
        // before it, so its own float cannot join their row.
        if (!clears &&
            content.length == 1 &&
            content.single is ColumnResult &&
            _isNarrowFloat(content.single as ColumnResult) &&
            _isBareBox(ctx.style)) {
          return content;
        }
        return [
          BlockResult(_blockFromResults(element, ctx, results), clears: clears),
        ];
      case CssDisplay.listItem:
      case CssDisplay.tableRowGroup:
      case CssDisplay.tableRow:
      case CssDisplay.tableCell:
        return [BlockResult(buildBlock(element, ctx))];
      case CssDisplay.table:
        return [BlockResult(_buildAnonymousCssTable(element, ctx))];
    }
  }

  /// Email icon/text flex rows. Auto-width items keep their preferred width
  /// when it fits, but can wrap within the space left by fixed-width icons.
  Widget _buildFlexRow(dom.Element element, HtmlRenderContext ctx) {
    final children = <Widget>[];
    for (final node in element.nodes) {
      if (node is dom.Comment || node is dom.Text && node.text.trim().isEmpty) {
        continue;
      }
      final itemCtx = node is dom.Element
          ? contextFor(node, ctx.childInherited)
          : ctx;
      if (itemCtx.style.display == CssDisplay.none) continue;
      final results = _buildNode(node, ctx.childInherited);
      if (results.isEmpty) continue;
      final item = IntrinsicWidth(child: flow(results, itemCtx.style));
      final width = node is dom.Element ? itemCtx.style.width : null;
      final fixed =
          width != null && !width.isAuto && width.unit != CssLengthUnit.percent;
      children.add(fixed ? item : Flexible(fit: FlexFit.loose, child: item));
    }
    final cross = ctx.style.alignItems ?? CrossAxisAlignment.stretch;
    Widget row = Row(
      mainAxisAlignment: ctx.style.justifyContent ?? MainAxisAlignment.start,
      crossAxisAlignment: cross,
      textBaseline: cross == CrossAxisAlignment.baseline
          ? TextBaseline.alphabetic
          : null,
      textDirection: ctx.style.textDirection,
      children: children,
    );
    if (cross == CrossAxisAlignment.stretch) row = IntrinsicHeight(child: row);
    return decorate(row, ctx.style);
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
    if (cellElements == null) {
      final childDisplays = [
        for (final child in element.children)
          contextFor(child, ctx.childInherited).style.display,
      ].where((display) => display != CssDisplay.none).toList();
      if (!childDisplays.contains(CssDisplay.tableCell)) {
        // CSS wraps the non-cell children of a table box in one anonymous row
        // and cell, so they stack in normal flow — e.g. Campaign Monitor's
        // `<center class="wrapper" style="display:table;width:100%">` around
        // block tables. Only an auto-width table of inline content keeps the
        // shrink-to-fit row below (a centred `display:table` button).
        final width = ctx.style.width;
        final explicitWidth = width != null && !width.isAuto;
        final blockChildren =
            childDisplays.isNotEmpty &&
            childDisplays.every(
              (display) =>
                  display != CssDisplay.inline &&
                  display != CssDisplay.inlineBlock,
            );
        if (explicitWidth || blockChildren) return buildBlock(element, ctx);
      }
    }
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
      final allFixed = cells.every((cell) => cell.fixedPx != null);
      row = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: allMiddle
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        textDirection: ctx.style.textDirection,
        children: [
          for (final cell in cells)
            // An auto-width cell is shrink-to-fit: its max-content width,
            // capped by the line. A bare Row child would get an unbounded
            // width, which a stretched block column inside cannot take.
            if (allFixed || cell.fixedPx != null)
              cell.child
            else
              Flexible(
                fit: FlexFit.loose,
                child: IntrinsicWidth(child: cell.child),
              ),
        ],
      );
      if (allFixed) {
        // Desktop email columns can add up to the container's border-box
        // width, leaving a slightly smaller content box. Match fixed HTML
        // table rows: fit the columns without overflowing the border.
        final rightAligned = mainAxisAlignment == MainAxisAlignment.end
            ? ctx.style.textDirection != TextDirection.rtl
            : ctx.style.textDirection == TextDirection.rtl;
        row = FittedBox(
          fit: BoxFit.scaleDown,
          alignment: mainAxisAlignment == MainAxisAlignment.center
              ? Alignment.topCenter
              : rightAligned
              ? Alignment.topRight
              : Alignment.topLeft,
          child: row,
        );
      }
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

  /// Whether the host provided an override for this element name.
  bool hasCustomElementHandler(String tag) =>
      _registry.customHandlerFor(tag) != null;

  /// Invokes a host override for a child whose layout is owned by its parent.
  List<HtmlBuildResult>? buildCustomElement(
    dom.Element element,
    HtmlRenderContext context,
  ) {
    final handler = _registry.customHandlerFor(element.localName ?? '');
    return handler?.build(element, context);
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
    final background = ctx.style.visibilityHidden == true
        ? null
        : ctx.style.backgroundColor;
    final spanStyle = background == null
        ? null
        : TextStyle(backgroundColor: background);
    if (ctx.style.preservesWhitespace) {
      return _PreservedWhitespaceSpan(children: spans, style: spanStyle);
    }
    return TextSpan(children: spans, style: spanStyle);
  }

  /// Flows an element's children into a block widget and applies its box
  /// decoration.
  /// For a normal-flow block with no line boxes and nothing separating its
  /// top margin from its bottom one, every margin inside collapses through
  /// it into one (CSS 2.1 §8.3.1): `<div><div style="margin:20px 0 30px">
  /// </div><div style="margin:40px 0 50px"></div></div>` is one 50px margin.
  /// Returns the largest margin of its descendants (0 if none) and adds them
  /// to [nested]; null when [node] has content or a separating box.
  double? _collapseThroughMargin(
    dom.Element node,
    HtmlStyle style,
    List<dom.Element> nested,
  ) {
    if (style.preservesWhitespace ||
        style.preservesNewlines ||
        style.overflowHidden == true ||
        (style.height?.value ?? 0) != 0 ||
        (style.minHeight?.value ?? 0) != 0 ||
        (style.padding?.top?.value ?? 0) != 0 ||
        (style.padding?.bottom?.value ?? 0) != 0 ||
        _borderExtent(style.borders, false) != 0) {
      return null;
    }
    var largest = 0.0;
    for (final child in node.nodes) {
      if (child is dom.Comment) continue;
      if (child is dom.Text) {
        if (child.text.replaceAll(_collapsibleWhitespace, '').isEmpty) {
          continue;
        }
        return null;
      }
      if (child is! dom.Element) return null;
      final childStyle = _resolver.resolve(child, style.inheritedOnly());
      if (childStyle.display == CssDisplay.none) continue;
      final childBlock =
          childStyle.display == CssDisplay.block &&
          childStyle.float == null &&
          (_registry.handlerFor(child.localName ?? '') == null ||
              child.localName == 'ul' ||
              child.localName == 'ol');
      if (!childBlock) return null;
      final inner = _collapseThroughMargin(child, childStyle, nested);
      if (inner == null) return null;
      // A margin an ancestor already carries (hoisted, or a whole collapsed
      // subtree) counts as zero here, as in _collapseChildMargins.
      double margin(CssLength? length, Set<dom.Element> taken) =>
          taken.contains(child)
          ? 0
          : (length?.resolve(
                      fontSize: childStyle.resolvedFontSize,
                      rootFontSize: config.baseFontSize,
                    ) ??
                    0)
                .clamp(0.0, double.infinity);
      for (final m in [
        inner,
        margin(childStyle.margin?.top, _collapsedTopMargins),
        margin(childStyle.margin?.bottom, _collapsedBottomMargins),
      ]) {
        if (m > largest) largest = m;
      }
      nested.add(child);
    }
    return largest;
  }

  /// A lone legacy float column (`<table align="left">` around an image) of
  /// known width that leaves most of the line to the content after it.
  bool _isNarrowFloat(ColumnResult column) {
    final width = column.floatWidth;
    return column.float != null &&
        width != null &&
        width > 0 &&
        (!availableWidth.isFinite || width <= availableWidth / 2);
  }

  /// A box that only groups its children: nothing of its own to draw or size.
  static bool _isBareBox(HtmlStyle style) {
    bool zero(CssLength? length) => length == null || length.value == 0;
    final padding = style.padding;
    final borders = style.borders;
    bool noBorder(CssBorderSide? side) =>
        side == null || side.width <= 0 || side.style == CssBorderStyle.none;
    return (padding == null ||
            zero(padding.top) &&
                zero(padding.right) &&
                zero(padding.bottom) &&
                zero(padding.left)) &&
        (borders == null ||
            noBorder(borders.top) &&
                noBorder(borders.right) &&
                noBorder(borders.bottom) &&
                noBorder(borders.left)) &&
        style.backgroundColor == null &&
        style.backgroundImage == null &&
        (style.width == null || style.width!.isAuto) &&
        style.minWidth == null &&
        style.maxWidth == null &&
        (style.margin == null ||
            zero(style.margin!.top) &&
                zero(style.margin!.right) &&
                zero(style.margin!.bottom) &&
                zero(style.margin!.left)) &&
        style.height == null &&
        style.minHeight == null &&
        style.overflowHidden != true &&
        // `opacity` is not inherited: dropping the wrapper would show what
        // it hides (`<div style="opacity:0">` around a float).
        (style.opacity == null || style.opacity! >= 1);
  }

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
  /// A single inline run can use [TextWidthBasis.longestLine] to shrink during
  /// paragraph layout without an additional intrinsic-width parent.
  Widget flow(
    List<HtmlBuildResult> results,
    HtmlStyle containerStyle, {
    TextWidthBasis textWidthBasis = TextWidthBasis.parent,
  }) {
    final children = <Widget>[];
    // While a legacy float is open, the content after it collects here and
    // becomes a FloatFlow beside/below it.
    final floatChildren = <Widget>[];
    var target = children;
    ColumnResult? activeFloat;
    final buffer = <InlineResult>[];
    final floats = <FloatResult>[];
    Widget withFloats(Widget paragraph) {
      if (floats.isEmpty) return paragraph;
      if (floats.length == 1) {
        // One float (`<div style="float:right"><img width=240></div>` before
        // a paragraph): the text goes under it where it cannot fit beside,
        // instead of a word-breaking sliver for its whole length.
        final float = floats.single;
        floats.clear();
        return FloatFlow(
          right: float.side == 'right',
          children: [float.widget, paragraph],
        );
      }
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
        target.add(
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
        final distribution = spans.any(_hasInlineWidgetWithHeight)
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
        final source = TextSpan(children: spans);
        final wrapping = containerStyle.preventsWrapping || config.fitToWidth
            ? null
            : ParagraphWrap(source);
        Widget paragraph = Text.rich(
          wrapping?.text ?? source,
          textWidthBasis: textWidthBasis,
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
          // In (limited-)quirks mode the block's strut only counts on lines
          // with the block's direct text, and such text already carries the
          // same metrics; lines of spans or images take their own height.
          strutStyle: uniformText || lineHeightQuirk
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
        if (wrapping?.hasVisualBreaks == true) {
          paragraph = SoftBreakSelection(child: paragraph);
        }
        final minContentBreaks = wrapping?.minContentBreaks ?? const <int>[];
        if (containerStyle.preventsWrapping || minContentBreaks.isNotEmpty) {
          paragraph = ParagraphMinWidth(
            breaks: minContentBreaks,
            child: paragraph,
          );
        }
        // Preserve the intrinsic width of a nonbreaking-space sizing hack,
        // while respecting its zero CSS line box. No visible glyph is clipped.
        target.add(
          withFloats(
            zeroWhitespaceLine
                ? SizedBox(height: 0, child: paragraph)
                : paragraph,
          ),
        );
      } else if (floats.isNotEmpty) {
        target.add(withFloats(const SizedBox.shrink()));
      }
      buffer.clear();
    }

    // A run of percent-width inline-block columns (MJML `mj-column-per-N`): lay
    // them out side by side in a Row when their widths fit (sum <= ~100%), or
    // stack them when they don't (each is 100% on a narrow layout).
    final columns = <ColumnResult>[];
    // Share of a short column run's free space placed before it.
    double leadingSpace(HtmlStyle style) {
      final rtl = style.textDirection == TextDirection.rtl;
      return switch (style.effectiveTextAlign) {
        TextAlign.center => 0.5,
        TextAlign.right => 1,
        TextAlign.left => 0,
        TextAlign.end => rtl ? 0 : 1,
        _ => rtl ? 1 : 0,
      };
    }

    // One line of columns side by side; each takes its percentage as flex.
    Widget columnRow(List<ColumnResult> line, double total) {
      final hasRightFloat = line.any((c) => c.float == 'right');
      final allFloated = line.every((c) => c.float != null);
      return Row(
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
                for (final c in line.where((c) => c.float != 'right'))
                  Flexible(
                    flex: (c.percent * 100).round().clamp(1, 100000),
                    child: c.widget,
                  ),
                if (total < 100)
                  Spacer(flex: ((100 - total) * 100).round().clamp(1, 100000)),
                for (final c in line.where((c) => c.float == 'right'))
                  Flexible(
                    flex: (c.percent * 100).round().clamp(1, 100000),
                    child: c.widget,
                  ),
              ]
            : [
                // Columns narrower than the line in total keep their
                // percentages; the line's text-align places the rest.
                if (total < 99.5 && leadingSpace(containerStyle) > 0)
                  Spacer(
                    flex: ((100 - total) * 100 * leadingSpace(containerStyle))
                        .round()
                        .clamp(1, 100000),
                  ),
                for (final c in line)
                  Flexible(
                    flex: (c.percent * 100).round().clamp(1, 100000),
                    child: c.widget,
                  ),
                if (total < 99.5 && leadingSpace(containerStyle) < 1)
                  Spacer(
                    flex:
                        ((100 - total) *
                                100 *
                                (1 - leadingSpace(containerStyle)))
                            .round()
                            .clamp(1, 100000),
                  ),
              ],
      );
    }

    void flushColumns() {
      if (columns.isEmpty) return;
      if (columns.length > 1 &&
          columns.first.float != null &&
          columns.every(
            (c) =>
                c.float == columns.first.float &&
                c.floatWidth?.isFinite == true,
          )) {
        // Size floats against the space in this block. Viewport-based flex
        // estimates lose the widths of small tables inside shrink-to-fit cells.
        target.add(
          Wrap(
            textDirection: columns.first.float == 'right'
                ? TextDirection.rtl
                : TextDirection.ltr,
            alignment: containerStyle.effectiveTextAlign == TextAlign.center
                ? WrapAlignment.center
                : WrapAlignment.start,
            children: [
              for (final c in columns)
                SizedBox(width: c.floatWidth, child: c.widget),
            ],
          ),
        );
      } else if (columns.every((c) => c.float == null)) {
        // Inline-block columns wrap like the inline boxes they are: a line
        // takes columns until the next would overflow it (105% tolerates
        // rounded `33.34%` triples), and each keeps its own share. Their
        // boxes fill the slot their line allots, so a lone or wrapped
        // `width:60%` column must still get a row of its own.
        var line = <ColumnResult>[];
        var sum = 0.0;
        void emitLine() {
          if (line.isEmpty) return;
          target.add(
            line.length == 1 && sum >= 99.5
                ? line.single.widget
                : columnRow(line, sum),
          );
          line = [];
          sum = 0;
        }

        for (final c in columns) {
          if (line.isNotEmpty && sum + c.percent > 105) emitLine();
          line.add(c);
          sum += c.percent;
        }
        emitLine();
      } else {
        // Legacy float tables (`align=left/right`): their percentages are
        // estimates, so only a run that fits shares a row.
        final total = columns.fold<double>(0, (s, c) => s + c.percent);
        if (columns.length > 1 && total <= 105) {
          target.add(columnRow(columns, total));
        } else {
          for (final c in columns) {
            target.add(c.widget);
          }
        }
      }
      columns.clear();
    }

    // A lone narrow float column followed by content floats beside it, the
    // way an `align="left"` image table lets the next text wrap around it.
    ColumnResult? loneFloat() =>
        activeFloat == null &&
            columns.length == 1 &&
            _isNarrowFloat(columns.single)
        ? columns.single
        : null;
    void startFloat(ColumnResult float) {
      columns.clear();
      activeFloat = float;
      target = floatChildren;
    }

    void endFloat() {
      final float = activeFloat;
      if (float == null) return;
      final content = [...floatChildren];
      floatChildren.clear();
      activeFloat = null;
      target = children;
      children.add(
        FloatFlow(
          floatWidth: float.floatWidth!,
          right: float.float == 'right',
          children: [float.widget, ...content],
        ),
      );
    }

    for (final result in results) {
      switch (result) {
        case InlineResult():
          // Whitespace between columns (source newlines) must not break the run.
          if (result.isWhitespaceOnly && columns.isNotEmpty && buffer.isEmpty) {
            break;
          }
          final float = loneFloat();
          if (float != null && !result.isWhitespaceOnly) startFloat(float);
          flushColumns();
          buffer.add(result);
        case ColumnResult():
          flushInline();
          endFloat();
          columns.add(result);
        case FloatResult():
          flushColumns();
          floats.add(result);
        case BlockResult(:final widget, :final clears):
          if (clears) {
            flushInline();
            flushColumns();
            endFloat();
            children.add(widget);
            break;
          }
          final float = loneFloat();
          if (float != null &&
              floats.isEmpty &&
              buffer.every((r) => r.isWhitespaceOnly)) {
            buffer.clear();
            startFloat(float);
            target.add(widget);
            break;
          }
          flushInline();
          flushColumns();
          target.add(widget);
      }
    }
    flushInline();
    flushColumns();
    endFloat();

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
  static bool _hasInlineWidgetWithHeight(InlineSpan span) =>
      (span is WidgetSpan && span is! InlineSpacerSpan) ||
      (span is TextSpan &&
          (span.children?.any(_hasInlineWidgetWithHeight) ?? false));

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
  /// not CSS box decoration. Plain fixed padding is represented by inline
  /// spacers so that the text can still wrap between words.
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

    return (hasPadding &&
            (style.preventsWrapping ||
                style.backgroundColor != null ||
                hasPercentEdge(style.padding))) ||
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
      return copyTextSpan(span, text: text, children: children);
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
      return copyTextSpan(span, text: trimmed);
    }
    final children = span.children;
    if (children == null || children.isEmpty) return span;
    final newChildren = List<InlineSpan>.of(children);
    final i = start ? 0 : newChildren.length - 1;
    newChildren[i] = _trimSpanWhitespace(newChildren[i], start: start);
    return copyTextSpan(span, children: newChildren);
  }

  /// Wraps [content] with margin/padding/background/border/width from [style].
  ///
  /// When [inline] is true the result is meant to sit inside a `WidgetSpan`
  /// (inline-block), so the fixed-width Align wrapper — which exists only to
  /// resist the block flow's `stretch` — is skipped.
  Widget decorate(Widget content, HtmlStyle style, {bool inline = false}) {
    final fontSize = style.resolvedFontSize;
    final rootFontSize = _rootStyle.resolvedFontSize;

    // Container accepts only non-negative insets. Apply negative horizontal
    // margins outside it, where they can also affect the available line width.
    final resolvedMargin = style.margin?.resolve(
      fontSize: fontSize,
      rootFontSize: rootFontSize,
    );
    final margin = _clampNonNegative(resolvedMargin);
    final fixedPadding = _clampNonNegative(
      style.padding?.resolve(fontSize: fontSize, rootFontSize: rootFontSize),
    );
    final percentPadding = _percentPadding(style.padding);
    final hidden = style.visibilityHidden == true;
    final border = style.borders?.toBorder();
    final background = hidden ? null : style.backgroundColor;

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
    if (!hidden) {
      content = paintCssBackground(
        content,
        style,
        imageResolver: imageResolver,
        allowDataUriImages: _allowDataUriImages,
        pauseOffscreenAnimations: config.pauseOffscreenImageAnimations,
      );
    }

    final requestedRadius = cssBorderRadius(style);
    final patternedBorder = style.borders == null
        ? null
        : CssBorderDecoration(
            borders: style.borders!,
            borderRadius: requestedRadius,
          );
    final hasPatternedBorder =
        patternedBorder?.hasVisiblePatternedSide ?? false;
    // Dashed/dotted/double sides are painted in the foreground, outside
    // BoxDecoration, so reserve their width like a solid border's.
    double patternedWidth(CssBorderSide? side) =>
        side == null ||
            side.width <= 0 ||
            !side.width.isFinite ||
            side.style == CssBorderStyle.none ||
            side.style == CssBorderStyle.solid
        ? 0
        : side.width;
    final patternedInsets = style.borders == null
        ? EdgeInsets.zero
        : EdgeInsets.only(
            top: patternedWidth(style.borders!.top),
            right: patternedWidth(style.borders!.right),
            bottom: patternedWidth(style.borders!.bottom),
            left: patternedWidth(style.borders!.left),
          );
    if (patternedInsets != EdgeInsets.zero) {
      containerPadding =
          (containerPadding ?? EdgeInsets.zero) + patternedInsets;
    }
    final hasDecoration =
        background != null ||
        border != null ||
        hasPatternedBorder ||
        (requestedRadius != null && style.overflowHidden == true);
    // BoxDecoration only allows borderRadius with a uniform (or absent) border.
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
    final percentWidth =
        !isTableCell && style.width?.unit == CssLengthUnit.percent
        ? style.width!.value / 100.0
        : null;
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
        percentWidth == null &&
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
              border: hidden ? _invisibleBorder(border) : border,
              borderRadius: radius,
            )
          : null,
      foregroundDecoration: hasPatternedBorder && !hidden
          ? patternedBorder
          : null,
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

    if (percentWidth != null && percentWidth >= 0) {
      result = maxWidth == null
          ? FractionallySizedBox(
              widthFactor: percentWidth,
              // HTML cell align positions this box even when its own CSS
              // text-align is left. Ordinary inherited CSS text-align must
              // not move block boxes such as percentage progress fills.
              alignment: inline
                  ? Alignment.topLeft
                  : _blockAlignment(style, useTextAlign: false),
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
      result = Align(
        alignment: _blockAlignment(
          style,
          useTextAlign: percentWidth == null,
          centerByMaxWidth:
              maxWidth != null && width == null && percentWidth == null,
        ),
        heightFactor: 1.0,
        child: result,
      );
    }
    if ((resolvedMargin?.left ?? 0) < 0 || (resolvedMargin?.right ?? 0) < 0) {
      result = NegativeHorizontalMargin(
        left: (resolvedMargin?.left ?? 0).clamp(double.negativeInfinity, 0),
        right: (resolvedMargin?.right ?? 0).clamp(double.negativeInfinity, 0),
        child: result,
      );
    }
    return result;
  }

  static Border? _invisibleBorder(Border? border) {
    if (border == null) return null;
    BorderSide invisible(BorderSide side) =>
        side.copyWith(color: const Color(0x00000000));
    return Border(
      top: invisible(border.top),
      right: invisible(border.right),
      bottom: invisible(border.bottom),
      left: invisible(border.left),
    );
  }

  Alignment _blockAlignment(
    HtmlStyle style, {
    bool useTextAlign = true,
    bool centerByMaxWidth = false,
  }) {
    final leftAuto = style.margin?.left?.isAuto ?? false;
    final rightAuto = style.margin?.right?.isAuto ?? false;
    // Floats and auto margins position the box before HTML alignment hints.
    if (style.float == 'left') return Alignment.topLeft;
    if (style.float == 'right') return Alignment.topRight;
    if (leftAuto && rightAuto) return Alignment.topCenter;
    if (rightAuto) return Alignment.topLeft;
    if (leftAuto) return Alignment.topRight;
    final align = style.blockAlign ?? (useTextAlign ? style.textAlign : null);
    if (align == TextAlign.center) return Alignment.topCenter;
    if (align == TextAlign.right) return Alignment.topRight;
    return centerByMaxWidth ? Alignment.topCenter : Alignment.topLeft;
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

  /// Blocks whose top/bottom margin moved to an ancestor by parent-child
  /// margin collapsing; they lay out with a zero margin on that side.
  final _collapsedTopMargins = <dom.Element>{};
  final _collapsedBottomMargins = <dom.Element>{};

  bool _isNormalFlowBlock(dom.Element element, HtmlStyle style) =>
      style.display == CssDisplay.block &&
      style.float == null &&
      (_registry.handlerFor(element.localName ?? '') == null ||
          element.localName == 'ul' ||
          element.localName == 'ol');

  /// The first (or last) child box of [parent] in normal flow, if it is a
  /// block whose margin may collapse with the parent's. Inline content, a
  /// table or any other box in that position stops the collapse.
  ({dom.Element element, HtmlStyle style})? _edgeFlowBlock(
    dom.Element parent,
    HtmlStyle parentStyle, {
    required bool first,
  }) {
    final nodes = first ? parent.nodes : parent.nodes.reversed;
    final inherited = parentStyle.inheritedOnly();
    for (final node in nodes) {
      if (node is dom.Comment) continue;
      if (node is dom.Text) {
        if (parentStyle.preservesWhitespace ||
            node.text.replaceAll(_collapsibleWhitespace, '').isNotEmpty) {
          return null;
        }
        continue;
      }
      if (node is! dom.Element) return null;
      final style = _resolver.resolve(node, inherited);
      if (style.display == CssDisplay.none) continue;
      return _isNormalFlowBlock(node, style)
          ? (element: node, style: style)
          : null;
    }
    return null;
  }

  /// CSS 2.1 §8.3.1: a block's top margin collapses with its first in-flow
  /// child's when no border or padding separates them (likewise the bottom
  /// margin with the last child for an auto-height block). Email markup nests
  /// paragraphs in divs and cells everywhere; adding the child margins inside
  /// the parent doubled such gaps. The collapsed (largest) margin moves to
  /// [element]; the descendants lay out with zero on that side.
  HtmlStyle _collapseChildMargins(dom.Element element, HtmlStyle style) {
    final zeroTop = _collapsedTopMargins.contains(element);
    final zeroBottom = _collapsedBottomMargins.contains(element);
    double px(CssLength? length, HtmlStyle s) =>
        length?.resolve(
          fontSize: s.resolvedFontSize,
          rootFontSize: config.baseFontSize,
          fallback: 0,
        ) ??
        0;
    double sidePadding(HtmlStyle s, bool top) =>
        px(top ? s.padding?.top : s.padding?.bottom, s);
    double sideBorder(HtmlStyle s, bool top) {
      final side = top ? s.borders?.top : s.borders?.bottom;
      return side == null || !side.width.isFinite || side.width <= 0
          ? 0
          : side.width;
    }

    bool separates(HtmlStyle s, {required bool top}) =>
        s.overflowHidden == true ||
        sidePadding(s, top) != 0 ||
        sideBorder(s, top) != 0 ||
        (!top &&
            ((s.height != null && !s.height!.isAuto) ||
                (s.minHeight?.value ?? 0) > 0));

    double collapse({required bool top}) {
      var margin = (top ? zeroTop : zeroBottom)
          ? 0.0
          : px(top ? style.margin?.top : style.margin?.bottom, style);
      if (margin < 0) return margin;
      var parent = element;
      var parentStyle = style;
      final collapsed = top ? _collapsedTopMargins : _collapsedBottomMargins;
      while (!separates(parentStyle, top: top)) {
        final child = _edgeFlowBlock(parent, parentStyle, first: top);
        if (child == null) break;
        // A margin an outer ancestor already took is zero here; counting it
        // again at every level of a deep div nest stacked it 25 times.
        final childMargin = collapsed.contains(child.element)
            ? 0.0
            : px(
                top ? child.style.margin?.top : child.style.margin?.bottom,
                child.style,
              );
        // Negative margins combine differently; leave them in place.
        if (childMargin < 0) break;
        if (childMargin > margin) margin = childMargin;
        collapsed.add(child.element);
        parent = child.element;
        parentStyle = child.style;
      }
      return margin;
    }

    final top = collapse(top: true);
    final bottom = collapse(top: false);
    final ownTop = px(style.margin?.top, style);
    final ownBottom = px(style.margin?.bottom, style);
    if (top == ownTop && bottom == ownBottom) return style;
    return style.merge(
      HtmlStyle(
        margin: CssEdges(
          top: CssLength(top, CssLengthUnit.px),
          bottom: CssLength(bottom, CssLengthUnit.px),
        ),
      ),
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
