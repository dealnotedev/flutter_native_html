import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:html/dom.dart' as dom;

import '../../config/html_image_resolver.dart';
import '../../css/css_length.dart';
import '../../css/html_style.dart';
import '../element_handler.dart';
import '../html_build_result.dart';
import '../html_render_context.dart';
import 'handler_utils.dart';

/// Renders `<img>` as an inline widget.
///
/// Uses the configured [HtmlImageResolver] to obtain (or block) the image:
/// `data:`/`cid:` images show inline; remote images are replaced by a
/// "blocked" placeholder unless the resolver allows them. Sizing honors the
/// element's CSS/attribute width & height, clamped by config limits.
class ImageHandler extends HtmlElementHandler {
  const ImageHandler();

  @override
  Set<String> get tags => const {'img'};

  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    final src = element.attributes['src'] ?? '';
    final alt = element.attributes['alt'];
    final attrs = attributesOf(element);
    final config = context.config;

    // Prefer a fixed CSS width; otherwise fall back to the width/height
    // attribute (emails often set `style="width:100%"` to fill a sized wrapper
    // while the real pixel size lives in the width="N" attribute).
    final declaredWidth =
        _dimension(context, context.style.width) ??
        _attrDimension(element, 'width');
    final declaredHeight =
        _dimension(context, context.style.height) ??
        _attrDimension(element, 'height');
    final padding =
        context.style.padding?.resolve(
          fontSize: context.style.resolvedFontSize,
          rootFontSize: config.baseFontSize,
        ) ??
        EdgeInsets.zero;
    final borderBox = context.style.boxSizing == CssBoxSizing.borderBox;
    final width = declaredWidth == null
        ? null
        : (declaredWidth - (borderBox ? padding.horizontal : 0)).clamp(
            0.0,
            double.infinity,
          );
    final height = declaredHeight == null
        ? null
        : (declaredHeight - (borderBox ? padding.vertical : 0)).clamp(
            0.0,
            double.infinity,
          );
    final widthFactor = context.style.width?.unit == CssLengthUnit.percent
        ? (context.style.width!.value / 100).clamp(0.0, double.infinity)
        : null;

    final resolution = src.isEmpty
        ? const HtmlImageResolution.unavailable()
        : context.imageResolver.resolve(src, attrs);

    Widget child;
    if (resolution.hasImage) {
      child = Image(
        image: resolution.provider!,
        width: width,
        height: height,
        fit: context.style.objectFit ?? BoxFit.contain,
        semanticLabel: alt?.trim().isNotEmpty == true ? alt!.trim() : null,
        excludeFromSemantics: alt?.trim().isNotEmpty != true,
        errorBuilder: (_, _, _) => _fallback(context, alt),
      );
    } else if (resolution.blockedRemote) {
      final placeholder =
          config.blockedImageBuilder?.call(context.buildContext, src, attrs) ??
          _DefaultBlockedImage(alt: alt, width: width, height: height);
      // The placeholder can land in a slot narrower than its intrinsic size — a
      // tiny inline icon (a 12px arrow) or a squeezed table column. Scale it
      // down to fit (the child lays out unbounded, so its inner Row never
      // overflows) instead of throwing a RenderFlex overflow.
      child = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: placeholder,
      );
    } else {
      child = _fallback(context, alt);
    }

    // Rounded images (e.g. avatars with border-radius:50%).
    child = _clip(child, context.style);
    if (padding != EdgeInsets.zero) {
      child = Padding(padding: padding, child: child);
    }

    // Emulate the near-universal email `img { max-width: 100% }`: an image never
    // overflows its container — it scales down to the available width, keeping
    // its aspect ratio (`height: auto`). A desktop-width logo (e.g. 615px) thus
    // shrinks to fit a narrow column/viewport instead of spilling past it. (A
    // bare browser doesn't constrain images, but every email client does and
    // authors rely on it.) Also applies when only a percent width is given
    // (`width:100%`/`width="100%"` with no pixel size) so the image fills its
    // container instead of sitting at its natural bitmap width.
    final fixedAnchorOverflow =
        width != null &&
        widthFactor == null &&
        context.style.maxWidth == null &&
        _hasSmallerFixedInlineAnchor(element, context, width);
    if (fixedAnchorOverflow) {
      child = OverflowBox(
        alignment: Alignment.topLeft,
        fit: OverflowBoxFit.deferToChild,
        minWidth: width + padding.horizontal,
        maxWidth: width + padding.horizontal,
        child: child,
      );
    } else if (width != null || widthFactor != null) {
      child = _MaxWidthFull(
        naturalWidth: width == null ? null : width + padding.horizontal,
        naturalHeight: height == null ? null : height + padding.vertical,
        widthFactor: widthFactor,
        reservePendingHeight: resolution.hasImage,
        child: child,
      );
    }

    // Clamp to the configured max dimensions so wide images never overflow.
    double? smaller(double? first, double? second) => first == null
        ? second
        : second == null || first < second
        ? first
        : second;
    final maxWidth = smaller(
      config.maxImageWidth,
      _dimension(context, context.style.maxWidth),
    );
    final maxHeight = smaller(
      config.imageMaxHeight,
      _dimension(context, context.style.maxHeight),
    );
    if (maxWidth != null || maxHeight != null) {
      child = ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth ?? double.infinity,
          maxHeight: maxHeight ?? double.infinity,
        ),
        child: child,
      );
    }

    // A linked image (`<a href><img></a>`) must navigate the link, not fire the
    // image callback. Nested tap recognizers resolve to the innermost, so skip
    // the image tap wrapper when an anchor ancestor will handle the tap —
    // otherwise the link is dead (browsers always navigate).
    final onTap = config.onImageTap;
    if (onTap != null && src.isNotEmpty && !_hasLinkAncestor(element)) {
      child = GestureDetector(onTap: () => onTap(src, attrs), child: child);
    }

    if (context.style.visibilityHidden ?? false) {
      child = IgnorePointer(
        child: ExcludeSemantics(child: Opacity(opacity: 0, child: child)),
      );
    }

    // A `display:block` image with `margin:0 auto` is a centered block-level
    // image (the common centered-logo idiom): render it as a centered block
    // instead of flowing inline and following the parent's text-align. Other
    // block images stay inline so they keep their intrinsic width in a tight
    // cell (e.g. a 20px social icon in a padded cell) rather than being
    // squeezed by the centering wrapper.
    final style = context.style;
    final m = style.margin;
    final autoH = (m?.left?.isAuto ?? false) && (m?.right?.isAuto ?? false);
    if (style.display == CssDisplay.block && width != null && autoH) {
      final block = context.builder.decorate(
        Align(alignment: Alignment.topCenter, heightFactor: 1.0, child: child),
        // Keep only the vertical margins (the horizontal ones are `auto`, i.e.
        // the centering we just applied); preserves spacing like `margin:0 auto
        // 10px`.
        HtmlStyle(
          margin: CssEdges(top: m?.top, bottom: m?.bottom),
        ),
      );
      return [BlockResult(block)];
    }

    // Replaced inline elements include all four margins in their line box.
    // A logo's vertical margins must reserve space just like an icon's right
    // margin before a button label.
    double h(CssLength? l) =>
        l?.resolve(
          fontSize: style.resolvedFontSize,
          rootFontSize: context.config.baseFontSize,
          fallback: 0,
        ) ??
        0;
    final ml = h(m?.left).clamp(0.0, double.infinity);
    final mr = h(m?.right).clamp(0.0, double.infinity);
    final mt = h(m?.top).clamp(0.0, double.infinity);
    final mb = h(m?.bottom).clamp(0.0, double.infinity);
    if (ml > 0 || mr > 0 || mt > 0 || mb > 0) {
      child = Padding(
        padding: EdgeInsets.fromLTRB(ml, mt, mr, mb),
        child: child,
      );
    }

    if (style.display == CssDisplay.block || style.float != null) {
      return [
        BlockResult(
          Align(
            alignment: switch (style.float) {
              'right' => Alignment.topRight,
              'left' => Alignment.topLeft,
              _ => switch (style.effectiveTextAlign) {
                TextAlign.center => Alignment.topCenter,
                TextAlign.right || TextAlign.end => Alignment.topRight,
                _ => Alignment.topLeft,
              },
            },
            heightFactor: 1,
            child: child,
          ),
        ),
      ];
    }

    final alignment = switch (style.verticalAlign) {
      'middle' => PlaceholderAlignment.middle,
      'top' || 'text-top' => PlaceholderAlignment.top,
      'bottom' || 'text-bottom' => PlaceholderAlignment.bottom,
      // Replaced elements use their bottom margin edge as the baseline.
      // aboveBaseline expresses that directly and does not ask RenderImage
      // for a text baseline during intrinsic table measurement.
      _ =>
        style.resolvedFontSize <= 0
            ? PlaceholderAlignment.bottom
            : PlaceholderAlignment.aboveBaseline,
    };

    return [
      InlineResult(
        WidgetSpan(
          alignment: alignment,
          baseline: TextBaseline.alphabetic,
          // An image is replaced content. A link's text decoration must not
          // turn into a line across the image's rectangular placeholder.
          style: const TextStyle(decoration: TextDecoration.none),
          child: child,
        ),
      ),
    ];
  }

  bool _hasLinkAncestor(dom.Element element) {
    dom.Element? p = element.parent;
    while (p != null) {
      if ((p.localName ?? '').toLowerCase() == 'a' &&
          p.attributes.containsKey('href')) {
        return true;
      }
      p = p.parent;
    }
    return false;
  }

  bool _hasSmallerFixedInlineAnchor(
    dom.Element element,
    HtmlRenderContext context,
    double imageWidth,
  ) {
    var parent = element.parent;
    while (parent != null) {
      final parentContext = context.builder.contextFor(
        parent,
        context.childInherited,
      );
      final style = parentContext.style;
      if (parent.localName == 'a' && style.display == CssDisplay.inlineBlock) {
        final width = _dimension(parentContext, style.width);
        return width != null && width < imageWidth;
      }
      if (style.display != CssDisplay.inline) return false;
      parent = parent.parent;
    }
    return false;
  }

  Widget _clip(Widget child, HtmlStyle style) {
    // A percent radius >= 50% means a full circle/ellipse; smaller percents and
    // px radii become rounded corners.
    final percent = style.borderRadiusPercent;
    if (percent != null) {
      if (percent >= 50) return ClipOval(child: child);
      return ClipRRect(
        borderRadius: BorderRadius.circular(percent), // best-effort
        child: child,
      );
    }
    final px = style.borderRadius;
    if (px != null && px > 0) {
      return ClipRRect(borderRadius: BorderRadius.circular(px), child: child);
    }
    return child;
  }

  double? _dimension(HtmlRenderContext context, CssLength? length) {
    if (length == null ||
        length.isAuto ||
        length.unit == CssLengthUnit.percent) {
      return null;
    }
    return length.resolve(
      fontSize: context.style.resolvedFontSize,
      rootFontSize: context.config.baseFontSize,
    );
  }

  double? _attrDimension(dom.Element element, String attr) {
    final raw = element.attributes[attr]?.trim();
    if (raw == null || raw.isEmpty || raw.endsWith('%')) return null;
    final value = double.tryParse(
      raw.replaceAll(RegExp(r'px$', caseSensitive: false), ''),
    );
    return value == null || !value.isFinite || value < 0 || value > 1000000
        ? null
        : value;
  }

  Widget _fallback(HtmlRenderContext context, String? alt) {
    if (alt == null || alt.trim().isEmpty) return const SizedBox.shrink();
    return Text(alt, style: context.style.toTextStyle());
  }
}

/// Caps an image at its container width (`max-width: 100%; height: auto`).
/// It prefers the image's natural width but can shrink all the way down (its
/// min-intrinsic width is 0, so a table column or a narrow line lets it shrink),
/// and its height tracks the width to keep the aspect ratio. Where the container
/// is wide enough (or its width is unbounded, e.g. a bare inline run) the image
/// keeps its natural size. Implemented as a render object — unlike LayoutBuilder
/// it answers intrinsic-dimension queries, so it works inside table cells.
class _MaxWidthFull extends SingleChildRenderObjectWidget {
  const _MaxWidthFull({
    required this.naturalWidth,
    required this.naturalHeight,
    this.widthFactor,
    required this.reservePendingHeight,
    required Widget child,
  }) : super(child: child);

  /// The image's pixel width, or null when only a percent width is known (the
  /// child's own intrinsic width is used as the natural size then).
  final double? naturalWidth;
  final double? naturalHeight;
  final double? widthFactor;

  /// A resolved provider may still decode later. An unavailable image has no
  /// future intrinsic dimensions and must retain the fallback's actual height.
  final bool reservePendingHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMaxWidthFull(
    naturalWidth,
    naturalHeight,
    widthFactor,
    reservePendingHeight,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMaxWidthFull renderObject,
  ) {
    renderObject
      ..naturalWidth = naturalWidth
      ..naturalHeight = naturalHeight
      ..widthFactor = widthFactor
      ..reservePendingHeight = reservePendingHeight;
  }
}

class _RenderMaxWidthFull extends RenderProxyBox {
  _RenderMaxWidthFull(
    this._naturalWidth,
    this._naturalHeight,
    this._widthFactor,
    this._reservePendingHeight,
  );

  double? _naturalWidth;
  double? _naturalHeight;
  double? _widthFactor;
  bool _reservePendingHeight;

  set reservePendingHeight(bool value) {
    if (value == _reservePendingHeight) return;
    _reservePendingHeight = value;
    markNeedsLayout();
  }

  set naturalWidth(double? value) {
    if (value == _naturalWidth) return;
    _naturalWidth = value;
    markNeedsLayout();
  }

  set naturalHeight(double? value) {
    if (value == _naturalHeight) return;
    _naturalHeight = value;
    markNeedsLayout();
  }

  set widthFactor(double? value) {
    if (value == _widthFactor) return;
    _widthFactor = value;
    markNeedsLayout();
  }

  // Aspect ratio (w/h), or 0 when the height is unknown (height stays intrinsic).
  double get _ratio =>
      (_naturalWidth != null && _naturalHeight != null && _naturalHeight! > 0)
      ? _naturalWidth! / _naturalHeight!
      : 0;

  double _resolveWidth(BoxConstraints constraints) {
    // Natural width: the pixel width if known, else the child's own intrinsic
    // (bitmap) width.
    final natural =
        _naturalWidth ?? child?.getMaxIntrinsicWidth(double.infinity) ?? 0;
    var width = _widthFactor != null && constraints.maxWidth.isFinite
        ? constraints.maxWidth * _widthFactor!
        : natural;
    if (constraints.maxWidth.isFinite && width > constraints.maxWidth) {
      width = constraints.maxWidth;
    }
    // A height cap must shrink the width too, preserving the image's aspect.
    if (_ratio > 0 &&
        constraints.maxHeight.isFinite &&
        width / _ratio > constraints.maxHeight) {
      width = constraints.maxHeight * _ratio;
    }
    return width;
  }

  Size _sizeFor(BoxConstraints constraints) {
    final width = _resolveWidth(constraints);
    var height = _ratio > 0
        ? width / _ratio
        : (_naturalHeight ?? child?.getMaxIntrinsicHeight(width) ?? 0);
    if (_reservePendingHeight &&
        _naturalHeight == null &&
        height <= 0 &&
        width > 0) {
      // Before an image provider reports its intrinsic size, RenderImage can
      // answer 0 for intrinsic height. Keep percent/fixed-width images visible
      // instead of collapsing the whole email row to zero.
      height = width;
    }
    return constraints.constrain(Size(width, height));
  }

  // Min-intrinsic width 0: the image may shrink to fit (CSS max-width:100%).
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _naturalWidth ?? child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) {
    final natural = _naturalWidth;
    final w = (natural != null && width > natural) ? natural : width;
    if (_ratio > 0) return w / _ratio;
    return child?.getMinIntrinsicHeight(w) ?? 0;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _sizeFor(constraints);

  @override
  void performLayout() {
    final width = _resolveWidth(constraints);
    if (_ratio > 0 || _naturalHeight != null) {
      // Aspect ratio (or a known height) fixes both dimensions.
      final newSize = _sizeFor(constraints);
      child?.layout(BoxConstraints.tight(newSize), parentUsesSize: true);
      size = newSize;
    } else {
      // Height unknown (percent width, no height/aspect): fix the width and let
      // the image choose its own height so it isn't collapsed to zero.
      child?.layout(
        BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: constraints.maxHeight,
        ),
        parentUsesSize: true,
      );
      var height = child?.size.height ?? 0;
      if (_reservePendingHeight && height <= 0 && width > 0) {
        // Reserve a provisional square while an asynchronous provider has not
        // reported its intrinsic dimensions yet. Do not lay the child out
        // again with tight square constraints: that would make it a relayout
        // boundary, preventing the decoded image's real aspect ratio from
        // propagating back to this render object.
        height = constraints.constrain(Size(width, width)).height;
      }
      size = constraints.constrain(Size(width, height));
    }
  }
}

class _DefaultBlockedImage extends StatelessWidget {
  const _DefaultBlockedImage({this.alt, this.width, this.height});

  final String? alt;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F1F1),
        border: Border.all(color: const Color(0xFFDADADA)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.image_not_supported_outlined,
            size: 16,
            color: Color(0xFF8A8A8A),
          ),
          if (alt != null && alt!.trim().isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                alt!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B6B6B)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
