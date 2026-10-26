import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'css_length.dart';

/// CSS `display` values relevant to the rendering pipeline.
///
/// The tree builder dispatches on this to decide whether an element flows
/// inline (merged into a [RichText] run) or becomes its own block widget.
enum CssDisplay {
  inline,
  block,
  inlineBlock,
  flex,
  listItem,
  table,
  tableRowGroup,
  tableRow,
  tableCell,
  none,
}

/// CSS `text-transform` values.
enum CssTextTransform { none, uppercase, lowercase, capitalize }

enum CssWhiteSpace { normal, nowrap, pre, preWrap, preLine }

enum CssBoxSizing { contentBox, borderBox }

enum CssBackgroundRepeat { repeat, repeatX, repeatY, noRepeat }

enum CssBorderStyle { none, solid, dashed, dotted, doubleLine }

/// A simplified, side-aware box edge (margin/padding) expressed in CSS lengths
/// so it can be resolved against the current font size and container width.
@immutable
class CssEdges {
  const CssEdges({this.top, this.right, this.bottom, this.left});

  final CssLength? top;
  final CssLength? right;
  final CssLength? bottom;
  final CssLength? left;

  CssEdges merge(CssEdges? other) {
    if (other == null) return this;
    return CssEdges(
      top: other.top ?? top,
      right: other.right ?? right,
      bottom: other.bottom ?? bottom,
      left: other.left ?? left,
    );
  }

  EdgeInsets resolve({
    required double fontSize,
    required double rootFontSize,
    double? percentBase,
  }) {
    double r(CssLength? l) =>
        l?.resolve(
          fontSize: fontSize,
          rootFontSize: rootFontSize,
          percentBase: percentBase,
          fallback: 0,
        ) ??
        0;
    return EdgeInsets.only(
      top: r(top),
      right: r(right),
      bottom: r(bottom),
      left: r(left),
    );
  }

  bool get isEmpty =>
      top == null && right == null && bottom == null && left == null;
}

/// A simplified border model — a single uniform side description per edge is
/// enough for email layout (full per-side styling can be added later).
@immutable
class CssBorderSide {
  const CssBorderSide({
    required this.width,
    required this.color,
    this.style = CssBorderStyle.solid,
    this.hairline = false,
  });
  final double width;
  final Color color;
  final CssBorderStyle style;
  final bool hairline;
}

@immutable
class CssBorders {
  const CssBorders({this.top, this.right, this.bottom, this.left});
  final CssBorderSide? top;
  final CssBorderSide? right;
  final CssBorderSide? bottom;
  final CssBorderSide? left;

  CssBorders merge(CssBorders? other) {
    if (other == null) return this;
    return CssBorders(
      top: other.top ?? top,
      right: other.right ?? right,
      bottom: other.bottom ?? bottom,
      left: other.left ?? left,
    );
  }

  Border? toBorder() {
    if (top == null && right == null && bottom == null && left == null) {
      return null;
    }
    // A zero-width side draws nothing (CSS `border:0` / `border-style:none`).
    // It still exists in the model so it can override a cascaded border, but
    // Flutter renders `BorderSide(width:0)` as a 1px hairline, so map it to
    // none here. A positive-width transparent border is invisible, but still
    // participates in layout as decoration padding.
    BorderSide side(CssBorderSide? s) {
      if (s == null) return BorderSide.none;
      // Flutter's BorderSide only supports solid strokes. Patterned sides are
      // painted by CssBorderDecoration in the rendering layer.
      if (s.style != CssBorderStyle.solid) return BorderSide.none;
      if (s.hairline) return BorderSide(width: 0, color: s.color);
      if (s.width <= 0) return BorderSide.none;
      return BorderSide(width: s.width, color: s.color);
    }

    return Border(
      top: side(top),
      right: side(right),
      bottom: side(bottom),
      left: side(left),
    );
  }
}

/// The fully-typed, resolved style of an element. Built by the
/// `StyleResolver` cascade; consumed by element handlers.
///
/// Every field is nullable so that [merge] implements CSS cascading
/// (a later, more specific source overrides an earlier one only where it
/// actually sets a value) and [inheritedOnly] can drop non-inherited
/// properties when descending into children.
@immutable
class HtmlStyle {
  const HtmlStyle({
    this.resets = const {},
    this.color,
    this.backgroundColor,
    this.backgroundImage,
    this.backgroundPositionX,
    this.backgroundPositionY,
    this.backgroundSize,
    this.backgroundPosition,
    this.backgroundRepeat,
    this.fontSize,
    this.fontWeight,
    this.fontStyle,
    this.fontFamilies,
    this.textDecoration,
    this.textDecorationColor,
    this.lineHeight,
    this.lineHeightPx,
    this.letterSpacing,
    this.textAlign,
    this.legacyTextAlign,
    this.cellTextAlign,
    this.textTransform,
    this.whiteSpace,
    this.visibilityHidden,
    this.pointerEventsNone,
    this.textDirection,
    this.anchorColor,
    this.display,
    this.alignItems,
    this.justifyContent,
    this.margin,
    this.padding,
    this.borders,
    this.borderRadius,
    this.borderRadiusPercent,
    this.borderRadiusGeometry,
    this.width,
    this.minWidth,
    this.maxWidth,
    this.height,
    this.minHeight,
    this.maxHeight,
    this.opacity,
    this.overflowHidden,
    this.textOverflow,
    this.objectFit,
    this.verticalAlign,
    this.listStyleType,
    this.float,
    this.tableLayoutFixed,
    this.boxSizing,
  });

  // --- Inherited (text) properties ---
  /// Explicit CSS resets. Null fields alone mean "not specified" in merge().
  final Set<String> resets;
  final Color? color;
  final double? fontSize; // resolved to logical px during cascade
  final FontWeight? fontWeight;
  final FontStyle? fontStyle;
  final List<String>? fontFamilies;
  final TextDecoration? textDecoration;
  final Color? textDecorationColor;
  final double? lineHeight; // multiplier (CSS unitless / percent line-height)
  final double? lineHeightPx; // absolute line-height in px (inherited as-is)
  final double? letterSpacing;
  final TextAlign? textAlign;

  /// HTML alignment hints inherit through blocks, but reset at a table.
  /// Authored CSS text-align continues to inherit into table cells.
  final bool? legacyTextAlign;
  final CssTextTransform? textTransform;
  final CssWhiteSpace? whiteSpace;
  final bool? visibilityHidden;
  // pointer-events: none. A sender sets this to suppress link auto-detection;
  // we treat it as a signal to expose the bare email/URL as a real link.
  final bool? pointerEventsNone;
  // `direction: rtl|ltr` (inherited). Used to lay out a row of columns
  // right-to-left, the email trick for "image on the right" with image-first
  // source order.
  final TextDirection? textDirection;
  // The enclosing `<a>`'s colour, propagated to descendants so a block inside a
  // link (e.g. a `<p>` with `p{color:#666}`) still shows the link colour, as
  // email clients render it. Overrides author element rules, not inline colour.
  final Color? anchorColor;

  // --- Non-inherited (box) properties ---
  final Color? backgroundColor;
  // A resolved background URL or CSS linear-gradient(...).
  final String? backgroundImage;
  final double? backgroundPositionX;
  final double? backgroundPositionY;
  // background-size keyword: 'cover' | 'contain' | '100%' (scale to box width).
  // Null = draw at the image's natural size (CSS sprite behaviour).
  final String? backgroundSize;
  // background-position as an alignment for a scaled background (e.g. `center
  // top` -> topCenter). Null = centre.
  final Alignment? backgroundPosition;
  final CssBackgroundRepeat? backgroundRepeat;
  // Legacy `align` on td/th. It affects this cell's own content but is kept
  // separate from CSS text-align so it does not leak into nested table cells.
  final TextAlign? cellTextAlign;
  final CssDisplay? display;
  final CrossAxisAlignment? alignItems;
  final MainAxisAlignment? justifyContent;
  final CssEdges? margin;
  final CssEdges? padding;
  final CssBorders? borders;
  final double? borderRadius; // uniform, resolved px
  final double? borderRadiusPercent; // uniform, percent (e.g. 50 -> circle)
  // Per-corner radius (e.g. a card rounded on the top corners only). When set,
  // it takes precedence over [borderRadius] in rendering.
  final BorderRadius? borderRadiusGeometry;
  final CssLength? width;
  final CssLength? minWidth;
  final CssLength? maxWidth;
  final CssLength? height;
  final CssLength? minHeight;
  final CssLength? maxHeight;
  final double? opacity;
  final bool? overflowHidden;
  final String? textOverflow;
  final BoxFit? objectFit;
  final String? verticalAlign;
  final String? listStyleType;
  final String? float; // 'left' | 'right' (non-inherited)
  final bool? tableLayoutFixed; // table-layout: fixed
  final CssBoxSizing? boxSizing;

  bool get preservesWhitespace =>
      whiteSpace == CssWhiteSpace.pre || whiteSpace == CssWhiteSpace.preWrap;
  bool get preservesNewlines =>
      preservesWhitespace || whiteSpace == CssWhiteSpace.preLine;
  bool get preventsWrapping =>
      whiteSpace == CssWhiteSpace.nowrap || whiteSpace == CssWhiteSpace.pre;

  TextAlign? get effectiveTextAlign => cellTextAlign ?? textAlign;

  static const HtmlStyle empty = HtmlStyle();

  static final _inheritedStyles = Expando<HtmlStyle>();

  /// Returns a cached copy carrying only inherited CSS properties. Box
  /// properties are dropped so they don't leak down the tree.
  HtmlStyle inheritedOnly() => _inheritedStyles[this] ??= HtmlStyle(
    resets: {
      if (resets.contains('line-height')) 'line-height',
      if (resets.contains('letter-spacing')) 'letter-spacing',
    },
    color: color,
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    fontFamilies: fontFamilies,
    textDecoration: textDecoration,
    textDecorationColor: textDecorationColor,
    lineHeight: lineHeight,
    lineHeightPx: lineHeightPx,
    letterSpacing: letterSpacing,
    textAlign: textAlign,
    legacyTextAlign: legacyTextAlign,
    textTransform: textTransform,
    whiteSpace: whiteSpace,
    visibilityHidden: visibilityHidden,
    pointerEventsNone: pointerEventsNone,
    textDirection: textDirection,
    anchorColor: anchorColor,
    listStyleType: listStyleType,
  );

  /// Cascades [other] over this style: any property [other] sets wins, the rest
  /// fall through to this.
  HtmlStyle merge(HtmlStyle? other) {
    if (other == null) return this;
    final mergedResets = {...resets, ...other.resets};
    void specified(String property, bool present) {
      if (present && !other.resets.contains(property)) {
        mergedResets.remove(property);
      }
    }

    specified('background-image', other.backgroundImage != null);
    specified('float', other.float != null);
    specified(
      'line-height',
      other.lineHeight != null || other.lineHeightPx != null,
    );
    specified('letter-spacing', other.letterSpacing != null);
    return HtmlStyle(
      resets: mergedResets,
      color: other.color ?? color,
      backgroundColor: other.backgroundColor ?? backgroundColor,
      backgroundImage: other.resets.contains('background-image')
          ? null
          : other.backgroundImage ?? backgroundImage,
      backgroundPositionX: other.backgroundPositionX ?? backgroundPositionX,
      backgroundPositionY: other.backgroundPositionY ?? backgroundPositionY,
      backgroundSize: other.backgroundSize ?? backgroundSize,
      backgroundPosition: other.backgroundPosition ?? backgroundPosition,
      backgroundRepeat: other.backgroundRepeat ?? backgroundRepeat,
      fontSize: other.fontSize ?? fontSize,
      fontWeight: other.fontWeight ?? fontWeight,
      fontStyle: other.fontStyle ?? fontStyle,
      fontFamilies: other.fontFamilies ?? fontFamilies,
      textDecoration: other.textDecoration ?? textDecoration,
      textDecorationColor: other.textDecorationColor ?? textDecorationColor,
      lineHeight:
          other.resets.contains('line-height') || other.lineHeightPx != null
          ? null
          : other.lineHeight ?? lineHeight,
      lineHeightPx:
          other.resets.contains('line-height') || other.lineHeight != null
          ? null
          : other.lineHeightPx ?? lineHeightPx,
      letterSpacing: other.resets.contains('letter-spacing')
          ? null
          : other.letterSpacing ?? letterSpacing,
      textAlign: other.textAlign ?? textAlign,
      legacyTextAlign: other.textAlign != null
          ? other.legacyTextAlign ?? false
          : other.legacyTextAlign ?? legacyTextAlign,
      cellTextAlign: other.cellTextAlign ?? cellTextAlign,
      textTransform: other.textTransform ?? textTransform,
      whiteSpace: other.whiteSpace ?? whiteSpace,
      visibilityHidden: other.visibilityHidden ?? visibilityHidden,
      pointerEventsNone: other.pointerEventsNone ?? pointerEventsNone,
      textDirection: other.textDirection ?? textDirection,
      anchorColor: other.anchorColor ?? anchorColor,
      display: other.display ?? display,
      alignItems: other.alignItems ?? alignItems,
      justifyContent: other.justifyContent ?? justifyContent,
      margin: margin?.merge(other.margin) ?? other.margin,
      padding: padding?.merge(other.padding) ?? other.padding,
      borders: borders?.merge(other.borders) ?? other.borders,
      borderRadius: other.borderRadius ?? borderRadius,
      borderRadiusPercent: other.borderRadiusPercent ?? borderRadiusPercent,
      borderRadiusGeometry: other.borderRadiusGeometry ?? borderRadiusGeometry,
      width: other.width ?? width,
      minWidth: other.minWidth ?? minWidth,
      maxWidth: other.maxWidth ?? maxWidth,
      height: other.height ?? height,
      minHeight: other.minHeight ?? minHeight,
      maxHeight: other.maxHeight ?? maxHeight,
      opacity: other.opacity ?? opacity,
      overflowHidden: other.overflowHidden ?? overflowHidden,
      textOverflow: other.textOverflow ?? textOverflow,
      objectFit: other.objectFit ?? objectFit,
      verticalAlign: other.verticalAlign ?? verticalAlign,
      listStyleType: other.listStyleType ?? listStyleType,
      float: other.resets.contains('float') ? null : other.float ?? float,
      tableLayoutFixed: other.tableLayoutFixed ?? tableLayoutFixed,
      boxSizing: other.boxSizing ?? boxSizing,
    );
  }

  /// Projects the text-affecting properties into a Flutter [TextStyle].
  TextStyle toTextStyle() {
    final families = _resolvedFontFamilies();
    return TextStyle(
      // CSS inheritance has already been resolved in HtmlStyle. Inheriting a
      // second time from Flutter would reintroduce theme height/letter spacing
      // after CSS explicitly reset them to normal.
      inherit: false,
      color: visibilityHidden == true ? const Color(0x00000000) : color,
      backgroundColor: visibilityHidden == true
          ? const Color(0x00000000)
          : backgroundColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      fontFamily: families?.isNotEmpty == true ? families!.first : null,
      fontFamilyFallback: (families != null && families.length > 1)
          ? families.sublist(1)
          : null,
      decoration: textDecoration,
      decorationColor: visibilityHidden == true
          ? const Color(0x00000000)
          : textDecorationColor ?? (textDecoration == null ? null : color),
      // An absolute px line-height resolves against THIS element's font size
      // (so an inherited fixed line-height isn't scaled by a child's larger
      // font); otherwise use the unitless/percent multiplier.
      height: lineHeightPx != null && resolvedFontSize > 0
          ? lineHeightPx! / resolvedFontSize
          : lineHeight,
      letterSpacing: letterSpacing,
    );
  }

  double get resolvedFontSize => fontSize ?? 14.0;

  List<String>? _resolvedFontFamilies() {
    final families = fontFamilies;
    if (families == null) return null;
    // Family names are opaque: "sans-serif-Bold" is not a generic family,
    // and a fallback containing "Bold" cannot override CSS font-weight.
    // Exhausted CSS family lists fall back to the browser's default serif,
    // rather than the ambient Flutter UI font. Desktop engines need concrete
    // names for CSS generics; Android/iOS already provide generic aliases.
    String generic(String family) => switch ((defaultTargetPlatform, family)) {
      (TargetPlatform.windows, 'serif') => 'Times New Roman',
      (TargetPlatform.windows, 'sans-serif') => 'Arial',
      (TargetPlatform.windows, 'monospace') => 'Courier New',
      (TargetPlatform.linux, 'serif') => 'DejaVu Serif',
      (TargetPlatform.linux, 'sans-serif') => 'DejaVu Sans',
      (TargetPlatform.linux, 'monospace') => 'DejaVu Sans Mono',
      _ => family,
    };
    const generics = {
      'serif',
      'sans-serif',
      'monospace',
      'cursive',
      'fantasy',
      'system-ui',
    };
    return [
      for (final family in families)
        generics.contains(family.toLowerCase())
            ? generic(family.toLowerCase())
            : family,
      if (!families.any((family) => generics.contains(family.toLowerCase())))
        generic('serif'),
      // Keep color glyph fallback available after an explicit CSS family list.
      // Test embedders and desktop font collections need these concrete names.
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Noto Color Emoji',
    ];
  }
}
