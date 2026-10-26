import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../../css/css_length.dart';
import '../../css/html_style.dart';
import '../element_handler.dart';
import '../html_build_result.dart';
import '../html_render_context.dart';
import '../layout/percent_boxes.dart';
import 'handler_utils.dart';

/// Renders `<a href>`. Never navigates itself — taps are forwarded to
/// `HtmlRenderConfig.onLinkTap`. Works for both inline links (the common case)
/// and links wrapping block content (e.g. a linked image or button cell).
class AnchorHandler extends HtmlElementHandler {
  const AnchorHandler();

  @override
  Set<String> get tags => const {'a'};

  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    final href = element.attributes['href'];
    final attrs = attributesOf(element);

    // Apply optional link-color override before building children so it
    // cascades into the link's text.
    var childInherited = context.childInherited;
    final linkColor = context.config.linkColor;
    if (linkColor != null) {
      childInherited = childInherited.merge(HtmlStyle(color: linkColor));
    }
    // Propagate the link's colour as `anchorColor` so a block inside the link
    // (e.g. a `<p>` matched by `p{color:#666}`) still renders in the link
    // colour, the way email clients colour an entire link.
    final anchorColor = linkColor ?? context.style.color;
    if (anchorColor != null) {
      childInherited = childInherited.merge(
        HtmlStyle(anchorColor: anchorColor),
      );
    }

    final children = context.builder.buildChildNodes(element, childInherited);

    GestureRecognizer? recognizer;
    final onTap = context.config.onLinkTap;
    if (href != null && onTap != null) {
      recognizer = TapGestureRecognizer()..onTap = () => onTap(href, attrs);
      context.builder.recognizers.add(recognizer);
    }

    final hasBlock = children.any((r) => r is! InlineResult);
    final display = context.style.display;
    final isInlineBlock = display == CssDisplay.inlineBlock;
    final hasInlineBoxStyling = _linkNeedsInlineBox(context.style);
    final plainInlineBlockText =
        isInlineBlock && !hasInlineBoxStyling && _isPlainInlineText(children);
    // A percent width (e.g. width:100%) makes an inline-block button fill its
    // container; otherwise inline-block sizes to its content.
    final fillsWidth = context.style.width?.unit == CssLengthUnit.percent;
    final wrapsFullWidthTable =
        isInlineBlock && _wrapsSingleFullWidthTable(element);

    // Full-width block box: an explicit block, an inline-block CTA that wants
    // 100% width (a button filling a cell), an email-card link that wraps a
    // single full-width table, or inline content that wraps a block (e.g. a
    // linked block image).
    final asBlock =
        display == CssDisplay.block ||
        (isInlineBlock && fillsWidth) ||
        wrapsFullWidthTable ||
        (hasBlock && !isInlineBlock);
    // Content-sized inline box: an inline-block button (padding/bg/radius) that
    // flows in line and is sized to its content — even when its children are
    // block-level (e.g. a `<span style="display:block">` button label).
    final asInlineBox =
        !asBlock &&
        (hasInlineBoxStyling || (isInlineBlock && !plainInlineBlockText));

    if (asBlock) {
      var widget = context.builder.flow(children, context.style);
      widget = context.builder.decorate(widget, context.style);
      if (href != null && onTap != null) {
        widget = _tappable(widget, () => onTap(href, attrs));
      }
      if (isInlineBlock) {
        return [
          InlineResult(
            WidgetSpan(
              alignment: context.style.resolvedFontSize <= 0
                  ? PlaceholderAlignment.bottom
                  : PlaceholderAlignment.aboveBaseline,
              baseline: TextBaseline.alphabetic,
              child: PercentMaxWidthBox(
                widthFactor: 1,
                maxWidth: context.builder.availableWidth,
                child: widget,
              ),
            ),
          ),
        ];
      }
      return [BlockResult(widget)];
    }

    if (asInlineBox) {
      Widget content;
      final soleWidget = _soleWidget(children);
      final hasFixedWidth =
          context.style.width != null &&
          !context.style.width!.isAuto &&
          context.style.width!.unit != CssLengthUnit.percent;
      if (soleWidget != null) {
        final image =
            element.children.length == 1 &&
                element.children.single.localName == 'img'
            ? element.children.single
            : null;
        final inlineImage =
            image != null &&
            context.builder.contextFor(image, childInherited).style.display !=
                CssDisplay.block;
        // An icon-only button (a single <img> in an inline-block <a>). Lay the
        // image out directly instead of through a text run — a WidgetSpan in a
        // Text.rich inflates the line box (middle alignment + strut), so a
        // square button would render as a tall pill. Centre it only inside a
        // fixed-width box (e.g. a round 38px button); a width-less app-store
        // badge must keep its own size, not fill the line (which would push the
        // sibling badge onto a second row).
        content = inlineImage
            ? context.builder.flow(children, context.style)
            : hasFixedWidth
            ? Align(
                alignment: Alignment.center,
                heightFactor: 1.0,
                child: soleWidget,
              )
            : soleWidget;
      } else if (hasBlock) {
        // A block child (especially an email button table) already has its own
        // shrink/fixed sizing rules. Wrapping it in IntrinsicWidth can trigger
        // a zero-width intrinsic probe in Flutter's Table layout, collapsing
        // the button text into a vertical line on narrow screens.
        content = context.builder.flow(children, context.style);
      } else {
        // A pill button (icon + label). Shrink the run to its content so the
        // icon and label stay on one line instead of wrapping (icon over label)
        // when the cell is narrow.
        content = IntrinsicWidth(
          child: context.builder.flow(children, context.style),
        );
      }
      var box = context.builder.decorate(content, context.style, inline: true);
      if (href != null && onTap != null) {
        box = _tappable(box, () => onTap(href, attrs));
      }
      return [
        InlineResult(
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: box),
        ),
      ];
    }

    // Plain inline link. Drop whitespace-only spans at the link's edges (e.g.
    // the newlines around an `<img>` in the source): a link's decoration would
    // otherwise underline them, drawing stray dashes beside the image.
    final inlines = [
      for (final r in children)
        if (r is InlineResult) r,
    ];
    var start = 0;
    var end = inlines.length;
    while (start < end && inlines[start].isWhitespaceOnly) {
      start++;
    }
    while (end > start && inlines[end - 1].isWhitespaceOnly) {
      end--;
    }
    final linkTap = (href != null && onTap != null)
        ? () => onTap(href, attrs)
        : null;
    final spans = [
      for (final r in inlines.sublist(start, end))
        recognizer == null
            ? r.span
            : _attachRecognizer(r.span, recognizer, linkTap),
    ];
    final linkSpan = TextSpan(children: spans);
    final link = InlineResult(linkSpan);

    // Horizontal margins apply to inline boxes too (e.g. icon links with
    // `margin-right` between them). Emit them as inline spacers.
    final margin = context.style.margin;
    double h(CssLength? l) =>
        l?.resolve(
          fontSize: context.style.resolvedFontSize,
          rootFontSize: context.config.baseFontSize,
          fallback: 0,
        ) ??
        0;
    final ml = h(margin?.left);
    final mr = h(margin?.right);
    if (ml <= 0 && mr <= 0) return [link];
    return [
      if (ml > 0) InlineResult(_spacer(ml)),
      link,
      if (mr > 0) InlineResult(_spacer(mr)),
    ];
  }

  static bool _linkNeedsInlineBox(HtmlStyle style) {
    final width = style.width;
    final height = style.height;
    return (style.padding != null && !style.padding!.isEmpty) ||
        style.borders != null ||
        style.backgroundColor != null ||
        style.backgroundImage != null ||
        (style.borderRadius != null && style.borderRadius! > 0) ||
        style.borderRadiusGeometry != null ||
        (width != null && !width.isAuto) ||
        (height != null && !height.isAuto);
  }

  static bool _isPlainInlineText(List<HtmlBuildResult> children) {
    var hasText = false;
    for (final child in children) {
      if (child is! InlineResult) return false;
      if (_spanHasWidget(child.span)) return false;
      if (!child.isWhitespaceOnly) hasText = true;
    }
    return hasText;
  }

  static bool _spanHasWidget(InlineSpan span) {
    if (span is WidgetSpan) return true;
    if (span is! TextSpan) return false;
    final children = span.children;
    if (children == null) return false;
    return children.any(_spanHasWidget);
  }

  /// Returns the single non-text widget (e.g. an icon image) an inline-block
  /// link wraps, or null if it has text or multiple/block children. Used to
  /// lay an icon button out directly so its line box doesn't inflate.
  static Widget? _soleWidget(List<HtmlBuildResult> children) {
    Widget? widget;
    var count = 0;
    for (final child in children) {
      if (child is! InlineResult) return null;
      if (child.isWhitespaceOnly) continue;
      final span = child.span;
      if (span is! WidgetSpan) return null; // has text
      widget = span.child;
      count++;
    }
    return count == 1 ? widget : null;
  }

  /// Email templates often wrap an entire card in
  /// `<a style="display:inline-block"><table width="100%">...`.
  ///
  /// Treat that shape as a block-level linked card so the table keeps the
  /// available width. Width-less inline-block button links are intentionally
  /// left alone because they should shrink to their label/badge.
  static bool _wrapsSingleFullWidthTable(dom.Element element) {
    final childElement = _singleMeaningfulElement(element);
    if ((childElement?.localName ?? '').toLowerCase() != 'table') {
      return false;
    }

    final table = childElement!;
    final attrWidth = table.attributes['width']?.trim();
    if (attrWidth == '100' || attrWidth == '100%') return true;

    final inlineStyle = table.attributes['style'] ?? '';
    return RegExp(
      r'(^|;)\s*width\s*:\s*100\s*%(\s*;|$)',
      caseSensitive: false,
    ).hasMatch(inlineStyle);
  }

  static dom.Element? _singleMeaningfulElement(dom.Element element) {
    dom.Element? childElement;
    for (final node in element.nodes) {
      if (node is dom.Text && node.text.trim().isEmpty) continue;
      if (node is! dom.Element) return null;
      if (childElement != null) return null;
      childElement = node;
    }
    return childElement;
  }

  /// Wraps a tappable link box so the pointer turns into a hand on hover
  /// (a bare [GestureDetector] doesn't change the cursor; an inline text link
  /// gets the click cursor from its span instead).
  static Widget _tappable(Widget child, VoidCallback onTap) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: Semantics(
      link: true,
      child: GestureDetector(onTap: onTap, child: child),
    ),
  );

  static WidgetSpan _spacer(double width) => WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: SizedBox(width: width),
  );

  /// Attaches [recognizer] to every text-bearing leaf span. A recognizer set on
  /// a parent span with only children is ignored by Flutter's hit-testing, so
  /// it must be applied to the spans that actually carry text. An inline image
  /// (a [WidgetSpan], e.g. a linked social icon) gets a tap+cursor wrapper
  /// instead, since a recognizer can't attach to it.
  InlineSpan _attachRecognizer(
    InlineSpan span,
    GestureRecognizer recognizer,
    VoidCallback? onTap,
  ) {
    if (span is TextSpan) {
      final hasText = span.text != null;
      return TextSpan(
        text: span.text,
        style: span.style,
        recognizer: hasText ? recognizer : span.recognizer,
        // Hand cursor on hover for the tappable text, matching block links.
        mouseCursor: hasText ? SystemMouseCursors.click : span.mouseCursor,
        semanticsLabel: span.semanticsLabel,
        children: span.children
            ?.map((child) => _attachRecognizer(child, recognizer, onTap))
            .toList(),
      );
    }
    if (span is WidgetSpan && onTap != null) {
      return WidgetSpan(
        alignment: span.alignment,
        baseline: span.baseline,
        child: _tappable(span.child, onTap),
      );
    }
    return span;
  }
}
