import 'package:flutter/widgets.dart';

import 'css_color.dart';
import 'css_declaration_expander.dart';
import 'css_length.dart';
import 'html_style.dart';

/// Translates a parsed CSS declaration map (`property -> value`) into a typed
/// [HtmlStyle]. Only properties relevant to the email subset are mapped;
/// unknown properties are ignored.
///
/// Font size and other `em`-relative lengths that affect inheritance are
/// resolved against [parentFontSize] here; box lengths (margin/padding/size)
/// are kept as [CssLength] in the style and resolved later by handlers against
/// the element's own font size and the container width.
class CssDeclarationMapper {
  const CssDeclarationMapper._();

  static HtmlStyle map(
    Map<String, String> decls, {
    required double parentFontSize,
    required double rootFontSize,
    double? elementFontSize,
    List<String>? inheritedFontFamilies,
    Color? inheritedColor,
    FontWeight? inheritedFontWeight,
    Color? elementColor,
    CssBorders? baseBorders,
  }) {
    if (decls.isEmpty) return HtmlStyle.empty;

    Color? color;
    Color? backgroundColor;
    String? backgroundImage;
    double? backgroundPositionX;
    double? backgroundPositionY;
    String? backgroundSize;
    Alignment? backgroundPosition;
    CssBackgroundRepeat? backgroundRepeat;
    double? fontSize;
    FontWeight? fontWeight;
    FontStyle? fontStyle;
    List<String>? fontFamilies;
    TextDecoration? textDecoration;
    Color? textDecorationColor;
    double? lineHeight;
    double? lineHeightPx;
    String? lineHeightLengthRaw;
    double? letterSpacing;
    String? letterSpacingRaw;
    TextAlign? textAlign;
    CssTextTransform? textTransform;
    CssDisplay? display;
    CssEdges? margin;
    CssEdges? padding;
    CssBorders? borders;
    double? borderRadius;
    double? borderRadiusPercent;
    // Per-corner radii (px), e.g. a card rounded only on the top corners.
    double? brTopLeft, brTopRight, brBottomRight, brBottomLeft;
    CssLength? width;
    CssLength? minWidth;
    CssLength? maxWidth;
    CssLength? height;
    CssLength? minHeight;
    CssLength? maxHeight;
    double? opacity;
    bool? overflowHidden;
    String? textOverflow;
    BoxFit? objectFit;
    String? verticalAlign;
    TextDirection? textDirection;
    CssWhiteSpace? whiteSpace;
    bool? visibilityHidden;
    bool? pointerEventsNone;
    String? listStyleType;
    String? float;
    bool? tableLayoutFixed;
    CssBoxSizing? boxSizing;
    final resets = <String>{};

    final borderParts = <String, Map<String, String>>{};

    double? len(String v, {double? percentBase}) =>
        CssLength.tryParse(v)?.resolve(
          fontSize: parentFontSize,
          rootFontSize: rootFontSize,
          percentBase: percentBase,
        );

    final expanded = <String, String>{};
    for (final entry in decls.entries) {
      for (final longhand in CssDeclarationExpander.expand(
        entry.key,
        entry.value,
      ).entries) {
        expanded.remove(longhand.key);
        expanded[longhand.key] = longhand.value;
      }
    }
    expanded.forEach((prop, value) {
      final border = _borderLonghand.firstMatch(prop);
      if (border != null) {
        (borderParts[border.group(1)!] ??= {})[border.group(2)!] = value;
        return;
      }
      switch (prop) {
        case 'color':
          color = switch (value.trim().toLowerCase()) {
            'inherit' ||
            'unset' ||
            'currentcolor' => inheritedColor ?? const Color(0xff000000),
            'initial' => const Color(0xff000000),
            _ => CssColor.tryParse(value) ?? color,
          };
          break;
        case 'background-color':
          backgroundColor = CssColor.tryParse(value) ?? backgroundColor;
          break;
        case 'background':
          backgroundColor = _colorFromShorthand(value) ?? backgroundColor;
          // A shorthand resets the image even when it supplies only a color.
          backgroundImage = _urlFrom(value) ?? _gradientFrom(value);
          if (backgroundImage == null) {
            resets.add('background-image');
          } else {
            resets.remove('background-image');
          }
          final pos = _bgPositionFrom(value);
          if (pos != null) {
            backgroundPositionX = pos.$1;
            backgroundPositionY = pos.$2;
          }
          backgroundPosition =
              _backgroundAlignment(value.replaceAll(_urlPattern, ' ')) ??
              backgroundPosition;
          backgroundRepeat = _backgroundRepeat(value) ?? backgroundRepeat;
          // `background: ... / contain|cover` carries the size after a slash.
          final slash = value.indexOf('/');
          if (slash >= 0) {
            backgroundSize =
                _backgroundSize(value.substring(slash + 1)) ?? backgroundSize;
          }
          break;
        case 'background-image':
          // Empty is an explicit reset, distinct from an unspecified property
          // when cascading over a legacy HTML background attribute.
          if (value.trim().toLowerCase() == 'none') {
            backgroundImage = null;
            resets.add('background-image');
          } else {
            final url = _urlFrom(value) ?? _gradientFrom(value);
            if (url != null) {
              backgroundImage = url;
              resets.remove('background-image');
            }
          }
          break;
        case 'background-position':
          final p = _parseBgPosition(value);
          if (p != null) {
            backgroundPositionX = p.$1;
            backgroundPositionY = p.$2;
          }
          backgroundPosition =
              _backgroundAlignment(value) ?? backgroundPosition;
          break;
        case 'background-size':
          backgroundSize = _backgroundSize(value);
          break;
        case 'background-repeat':
          backgroundRepeat = _backgroundRepeat(value) ?? backgroundRepeat;
          break;
        case 'font-size':
          fontSize = _fontSize(value, parentFontSize, rootFontSize) ?? fontSize;
          break;
        case 'font-weight':
          fontWeight =
              _fontWeight(
                value,
                parent: inheritedFontWeight ?? FontWeight.normal,
              ) ??
              fontWeight;
          break;
        case 'font-style':
          fontStyle = _fontStyle(value) ?? fontStyle;
          break;
        case 'font-family':
          fontFamilies = switch (value.trim().toLowerCase()) {
            'inherit' || 'unset' => inheritedFontFamilies ?? const [],
            'initial' => const ['serif'],
            _ => _fontFamilies(value) ?? fontFamilies,
          };
          break;
        case 'font':
          final parsed = _fontShorthand(
            value,
            parentFontSize,
            rootFontSize,
            inheritedFontWeight ?? FontWeight.normal,
          );
          fontStyle = parsed.fontStyle ?? fontStyle;
          fontWeight = parsed.fontWeight ?? fontWeight;
          fontSize = parsed.fontSize ?? fontSize;
          fontFamilies = parsed.fontFamilies ?? fontFamilies;
          break;
        case 'text-decoration':
        case 'text-decoration-line':
          textDecoration = _textDecoration(value) ?? textDecoration;
          break;
        case 'text-decoration-color':
          textDecorationColor = CssColor.tryParse(value) ?? textDecorationColor;
          break;
        case 'line-height':
          final lh = value.trim().toLowerCase();
          if (lh == 'normal') {
            resets.add('line-height');
            break;
          }
          final unitless = double.tryParse(lh);
          if (unitless != null && unitless.isFinite && unitless >= 0) {
            lineHeight = unitless; // CSS: multiplier
          } else if (lh.endsWith('%')) {
            final p = double.tryParse(lh.replaceAll('%', ''));
            // A percentage line-height computes to a length on THIS element
            // (percentage × own font-size) and children inherit that px value —
            // unlike a unitless number, which inherits as a ratio. Resolve it as
            // the equivalent em length rather than a multiplier.
            if (p != null && p.isFinite && p >= 0) {
              lineHeightLengthRaw = '${p / 100}em';
            }
          } else {
            // A length (px/em/rem): resolve after the loop, against this
            // element's OWN font-size (an `em` line-height is relative to the
            // element's font-size, not the parent's — e.g. an `<h1>` with
            // `font-size:40px;line-height:1.1em` is 44px, not 1.1×parent).
            lineHeightLengthRaw = lh;
          }
          break;
        case 'letter-spacing':
          // Resolve after the loop against THIS element's own font-size (an `em`
          // letter-spacing is relative to the element's font-size, like
          // line-height — a 32px heading's `0.1em` is 3.2px, not 0.1×parent).
          if (value.trim().toLowerCase() == 'normal') {
            resets.add('letter-spacing');
          } else {
            letterSpacingRaw = value;
          }
          break;
        case 'text-align':
          textAlign = _textAlign(value) ?? textAlign;
          break;
        case 'text-transform':
          textTransform = _textTransform(value) ?? textTransform;
          break;
        case 'display':
          display = _display(value) ?? display;
          break;
        case 'visibility':
          final visibility = value.trim().toLowerCase();
          if (visibility == 'hidden' || visibility == 'collapse') {
            visibilityHidden = true;
          } else if (visibility == 'visible') {
            visibilityHidden = false;
          }
          break;
        case 'white-space':
          whiteSpace = _whiteSpace(value) ?? whiteSpace;
          break;
        case 'pointer-events':
          final v = value.trim().toLowerCase();
          if (v == 'none') {
            pointerEventsNone = true;
          } else if (v == 'auto') {
            pointerEventsNone = false;
          }
          break;
        case 'list-style-type':
          listStyleType = value.trim().toLowerCase();
          break;
        case 'list-style':
          listStyleType = _listStyleType(value) ?? listStyleType;
          break;
        case 'float':
          final f = value.trim().toLowerCase();
          if (f == 'left' || f == 'right') float = f;
          if (f == 'none') resets.add('float');
          break;
        case 'table-layout':
          final tl = value.trim().toLowerCase();
          if (tl == 'fixed') {
            tableLayoutFixed = true;
          } else if (tl == 'auto') {
            tableLayoutFixed = false;
          }
          break;
        case 'vertical-align':
          verticalAlign = value.trim().toLowerCase();
          break;
        case 'text-overflow':
          final overflow = value.trim().toLowerCase();
          if (overflow == 'ellipsis' || overflow == 'clip') {
            textOverflow = overflow;
          }
          break;
        case 'direction':
          final dir = value.trim().toLowerCase();
          if (dir == 'rtl') {
            textDirection = TextDirection.rtl;
          } else if (dir == 'ltr') {
            textDirection = TextDirection.ltr;
          }
          break;
        case 'width':
          width = _nonNegativeLength(value) ?? width;
          break;
        case 'height':
          height = _nonNegativeLength(value) ?? height;
          break;
        case 'min-width':
          minWidth = _nonNegativeLength(value) ?? minWidth;
          break;
        case 'min-height':
          minHeight = _nonNegativeLength(value) ?? minHeight;
          break;
        case 'max-height':
          maxHeight = _nonNegativeLength(value) ?? maxHeight;
          break;
        case 'opacity':
          final parsed = double.tryParse(value.trim());
          if (parsed != null && parsed.isFinite) {
            opacity = parsed.clamp(0.0, 1.0);
          }
          break;
        case 'overflow':
        case 'overflow-x':
        case 'overflow-y':
          final overflow = value.trim().toLowerCase();
          if (overflow == 'hidden' || overflow == 'clip') {
            overflowHidden = true;
          } else if (overflow == 'visible') {
            overflowHidden = false;
          }
          break;
        case 'object-fit':
          objectFit = switch (value.trim().toLowerCase()) {
            'cover' => BoxFit.cover,
            'contain' => BoxFit.contain,
            'fill' => BoxFit.fill,
            'none' => BoxFit.none,
            'scale-down' => BoxFit.scaleDown,
            _ => objectFit,
          };
          break;
        case 'margin':
          margin = (margin ?? const CssEdges()).merge(_edges(value));
          break;
        case 'margin-top':
          margin = (margin ?? const CssEdges()).merge(
            CssEdges(top: CssLength.tryParse(value)),
          );
          break;
        case 'margin-right':
          margin = (margin ?? const CssEdges()).merge(
            CssEdges(right: CssLength.tryParse(value)),
          );
          break;
        case 'margin-bottom':
          margin = (margin ?? const CssEdges()).merge(
            CssEdges(bottom: CssLength.tryParse(value)),
          );
          break;
        case 'margin-left':
          margin = (margin ?? const CssEdges()).merge(
            CssEdges(left: CssLength.tryParse(value)),
          );
          break;
        case 'padding':
          padding = (padding ?? const CssEdges()).merge(_edges(value));
          break;
        case 'padding-top':
          padding = (padding ?? const CssEdges()).merge(
            CssEdges(top: CssLength.tryParse(value)),
          );
          break;
        case 'padding-right':
          padding = (padding ?? const CssEdges()).merge(
            CssEdges(right: CssLength.tryParse(value)),
          );
          break;
        case 'padding-bottom':
          padding = (padding ?? const CssEdges()).merge(
            CssEdges(bottom: CssLength.tryParse(value)),
          );
          break;
        case 'padding-left':
          padding = (padding ?? const CssEdges()).merge(
            CssEdges(left: CssLength.tryParse(value)),
          );
          break;
        case 'border-radius':
          final first = value.trim().split(RegExp(r'\s+')).first;
          if (first.endsWith('%')) {
            final parsed = double.tryParse(first.replaceAll('%', ''));
            if (parsed != null && parsed.isFinite && parsed >= 0) {
              borderRadiusPercent = parsed;
            }
          } else {
            final parsed = len(first);
            if (parsed != null && parsed >= 0) borderRadius = parsed;
          }
          break;
        case 'border-top-left-radius':
          brTopLeft =
              len(value.trim().split(RegExp(r'\s+')).first) ?? brTopLeft;
          break;
        case 'border-top-right-radius':
          brTopRight =
              len(value.trim().split(RegExp(r'\s+')).first) ?? brTopRight;
          break;
        case 'border-bottom-right-radius':
          brBottomRight =
              len(value.trim().split(RegExp(r'\s+')).first) ?? brBottomRight;
          break;
        case 'border-bottom-left-radius':
          brBottomLeft =
              len(value.trim().split(RegExp(r'\s+')).first) ?? brBottomLeft;
          break;
        case 'max-width':
          maxWidth = _nonNegativeLength(value) ?? maxWidth;
          break;
        case 'box-sizing':
          boxSizing = switch (value.trim().toLowerCase()) {
            'border-box' => CssBoxSizing.borderBox,
            'content-box' => CssBoxSizing.contentBox,
            _ => boxSizing,
          };
          break;
      }
    });

    // A length line-height resolves against this element's own font-size (if it
    // set one in this block), falling back to the inherited size otherwise.
    if (lineHeightLengthRaw != null) {
      lineHeightPx =
          CssLength.tryParse(lineHeightLengthRaw)?.resolve(
            fontSize: fontSize ?? elementFontSize ?? parentFontSize,
            rootFontSize: rootFontSize,
          ) ??
          lineHeightPx;
    }

    if (letterSpacingRaw != null) {
      letterSpacing =
          CssLength.tryParse(letterSpacingRaw)?.resolve(
            fontSize: fontSize ?? elementFontSize ?? parentFontSize,
            rootFontSize: rootFontSize,
          ) ??
          letterSpacing;
    }

    // All sources have already cascaded per side and per border property.
    // Resolve widths only after the element's final font-size is known.
    for (final entry in borderParts.entries) {
      final previous = switch (entry.key) {
        'top' => baseBorders?.top,
        'right' => baseBorders?.right,
        'bottom' => baseBorders?.bottom,
        _ => baseBorders?.left,
      };
      final parts = entry.value;
      final borderStyle =
          _borderStyle(parts['style']?.toLowerCase()) ??
          previous?.style ??
          CssBorderStyle.none;
      final width = parts['width'] == null
          ? null
          : _borderWidth(
              parts['width']!,
              fontSize: fontSize ?? elementFontSize ?? parentFontSize,
              rootFontSize: rootFontSize,
            );
      final borderColor = parts['color']?.toLowerCase() == 'currentcolor'
          ? color ?? elementColor
          : CssColor.tryParse(parts['color']);
      final side = CssBorderSide(
        width: borderStyle == CssBorderStyle.none
            ? 0
            : (width ?? previous?.width ?? 3).clamp(0.0, double.infinity),
        color:
            borderColor ??
            previous?.color ??
            color ??
            elementColor ??
            const Color(0xFF000000),
        style: borderStyle,
      );
      borders = (borders ?? const CssBorders()).merge(switch (entry.key) {
        'top' => CssBorders(top: side),
        'right' => CssBorders(right: side),
        'bottom' => CssBorders(bottom: side),
        _ => CssBorders(left: side),
      });
    }

    // Assemble a per-corner radius when any corner was set individually. Unset
    // corners fall back to the uniform `border-radius` (or 0).
    brTopLeft = _nonNegativeFinite(brTopLeft);
    brTopRight = _nonNegativeFinite(brTopRight);
    brBottomRight = _nonNegativeFinite(brBottomRight);
    brBottomLeft = _nonNegativeFinite(brBottomLeft);
    BorderRadius? borderRadiusGeometry;
    if (brTopLeft != null ||
        brTopRight != null ||
        brBottomRight != null ||
        brBottomLeft != null) {
      final base = borderRadius ?? 0;
      borderRadiusGeometry = BorderRadius.only(
        topLeft: Radius.circular(brTopLeft ?? base),
        topRight: Radius.circular(brTopRight ?? base),
        bottomRight: Radius.circular(brBottomRight ?? base),
        bottomLeft: Radius.circular(brBottomLeft ?? base),
      );
    }

    return HtmlStyle(
      resets: resets,
      color: color,
      backgroundColor: backgroundColor,
      backgroundImage: backgroundImage,
      backgroundPositionX: backgroundPositionX,
      backgroundPositionY: backgroundPositionY,
      backgroundSize: backgroundSize,
      backgroundPosition: backgroundPosition,
      backgroundRepeat: backgroundRepeat,
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
      textTransform: textTransform,
      display: display,
      margin: margin,
      padding: padding,
      borders: borders,
      borderRadius: borderRadius,
      borderRadiusPercent: borderRadiusPercent,
      borderRadiusGeometry: borderRadiusGeometry,
      width: width,
      minWidth: minWidth,
      maxWidth: maxWidth,
      height: height,
      minHeight: minHeight,
      maxHeight: maxHeight,
      opacity: opacity,
      overflowHidden: overflowHidden,
      textOverflow: textOverflow,
      objectFit: objectFit,
      verticalAlign: verticalAlign,
      textDirection: textDirection,
      whiteSpace: whiteSpace,
      visibilityHidden: visibilityHidden,
      pointerEventsNone: pointerEventsNone,
      listStyleType: listStyleType,
      float: float,
      tableLayoutFixed: tableLayoutFixed,
      boxSizing: boxSizing,
    );
  }

  // --- Property value helpers ---

  static double? _fontSize(String value, double parent, double root) {
    final keyword = {
      'xx-small': 9.0,
      'x-small': 10.0,
      'small': 13.0,
      'medium': 16.0,
      'large': 18.0,
      'x-large': 24.0,
      'xx-large': 32.0,
    }[value.trim().toLowerCase()];
    if (keyword != null) return keyword;
    if (value.trim().toLowerCase() == 'smaller') return parent * 0.833;
    if (value.trim().toLowerCase() == 'larger') return parent * 1.2;
    final resolved = CssLength.tryParse(
      value,
    )?.resolve(fontSize: parent, rootFontSize: root, percentBase: parent);
    return resolved != null && resolved.isFinite && resolved >= 0
        ? resolved
        : null;
  }

  static FontWeight? _fontWeight(
    String value, {
    FontWeight parent = FontWeight.normal,
  }) {
    switch (value.trim().toLowerCase()) {
      case 'bold':
        return FontWeight.bold;
      case 'bolder':
        return parent.value <= FontWeight.w300.value
            ? FontWeight.w400
            : parent.value <= FontWeight.w500.value
            ? FontWeight.w700
            : FontWeight.w900;
      case 'lighter':
        return parent.value <= FontWeight.w500.value
            ? FontWeight.w100
            : parent.value <= FontWeight.w700.value
            ? FontWeight.w400
            : FontWeight.w700;
      case 'inherit':
      case 'unset':
        return parent;
      case 'normal':
      case 'initial':
        return FontWeight.normal;
    }
    final numeric = int.tryParse(value.trim());
    if (numeric == null) return null;
    return FontWeight.values[(numeric ~/ 100 - 1).clamp(0, 8)];
  }

  static FontStyle? _fontStyle(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'italic' || v == 'oblique') return FontStyle.italic;
    if (v == 'normal') return FontStyle.normal;
    return null;
  }

  static List<String>? _fontFamilies(String value) {
    final list = value
        .split(',')
        .map((e) => e.trim().replaceAll(RegExp(r'''^["']|["']$'''), ''))
        .where((e) => e.isNotEmpty)
        .toList();
    return list.isEmpty ? null : list;
  }

  static TextDecoration? _textDecoration(String value) {
    final tokens = value.trim().toLowerCase().split(RegExp(r'\s+'));
    final decorations = <TextDecoration>[];
    for (final t in tokens) {
      switch (t) {
        case 'underline':
          decorations.add(TextDecoration.underline);
          break;
        case 'line-through':
          decorations.add(TextDecoration.lineThrough);
          break;
        case 'overline':
          decorations.add(TextDecoration.overline);
          break;
        case 'none':
          return TextDecoration.none;
      }
    }
    return decorations.isEmpty ? null : TextDecoration.combine(decorations);
  }

  static TextAlign? _textAlign(String value) {
    switch (value.trim().toLowerCase()) {
      case 'left':
      case 'start':
        return TextAlign.left;
      case 'right':
      case 'end':
        return TextAlign.right;
      case 'center':
        return TextAlign.center;
      case 'justify':
        return TextAlign.justify;
    }
    return null;
  }

  static CssTextTransform? _textTransform(String value) {
    switch (value.trim().toLowerCase()) {
      case 'none':
        return CssTextTransform.none;
      case 'uppercase':
        return CssTextTransform.uppercase;
      case 'lowercase':
        return CssTextTransform.lowercase;
      case 'capitalize':
        return CssTextTransform.capitalize;
    }
    return null;
  }

  static CssDisplay? _display(String value) {
    switch (value.trim().toLowerCase()) {
      case 'none':
        return CssDisplay.none;
      case 'inline':
        return CssDisplay.inline;
      case 'inline-block':
        return CssDisplay.inlineBlock;
      case 'block':
        return CssDisplay.block;
      case 'list-item':
        return CssDisplay.listItem;
      case 'table':
        return CssDisplay.table;
      case 'inline-table':
        // An inline-level table flows in line with siblings (treated like
        // inline-block: content-sized, horizontal flow).
        return CssDisplay.inlineBlock;
      case 'table-row':
        return CssDisplay.tableRow;
      case 'table-cell':
        return CssDisplay.tableCell;
    }
    return null;
  }

  static CssWhiteSpace? _whiteSpace(String value) {
    switch (value.trim().toLowerCase()) {
      case 'pre':
        return CssWhiteSpace.pre;
      case 'pre-wrap':
        return CssWhiteSpace.preWrap;
      case 'pre-line':
        return CssWhiteSpace.preLine;
      case 'normal':
        return CssWhiteSpace.normal;
      case 'nowrap':
        return CssWhiteSpace.nowrap;
    }
    return null;
  }

  static String? _listStyleType(String value) {
    for (final token in value.trim().toLowerCase().split(RegExp(r'\s+'))) {
      switch (token) {
        case 'none':
        case 'disc':
        case 'circle':
        case 'square':
        case 'decimal':
        case 'decimal-leading-zero':
        case 'lower-alpha':
        case 'upper-alpha':
        case 'lower-roman':
        case 'upper-roman':
          return token;
      }
    }
    return null;
  }

  static CssLength? _nonNegativeLength(String value) {
    final length = CssLength.tryParse(value);
    if (length == null ||
        !length.value.isFinite ||
        length.value < 0 ||
        length.value > 1000000) {
      return null;
    }
    return length;
  }

  static double? _nonNegativeFinite(double? value) =>
      value != null && value.isFinite && value >= 0 ? value : null;

  static CssEdges _edges(String value) {
    final tokens = value.trim().split(RegExp(r'\s+'));
    CssLength? at(int i) =>
        i < tokens.length ? CssLength.tryParse(tokens[i]) : null;
    switch (tokens.length) {
      case 1:
        final all = at(0);
        return CssEdges(top: all, right: all, bottom: all, left: all);
      case 2:
        final v = at(0), h = at(1);
        return CssEdges(top: v, bottom: v, right: h, left: h);
      case 3:
        return CssEdges(top: at(0), right: at(1), left: at(1), bottom: at(2));
      default:
        return CssEdges(top: at(0), right: at(1), bottom: at(2), left: at(3));
    }
  }

  static List<String> _splitCssTokens(String value) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var parenDepth = 0;
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (ch == '(') parenDepth++;
      if (ch == ')' && parenDepth > 0) parenDepth--;
      if (RegExp(r'\s').hasMatch(ch) && parenDepth == 0) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(ch);
      }
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }

  static final _borderLonghand = RegExp(
    r'^border-(top|right|bottom|left)-(width|style|color)$',
  );

  static double? _borderWidth(
    String token, {
    double fontSize = 16,
    double rootFontSize = 16,
  }) {
    switch (token.toLowerCase()) {
      case 'thin':
        return 1.0;
      case 'medium':
        return 3.0;
      case 'thick':
        return 5.0;
    }
    return CssLength.tryParse(
      token,
    )?.resolve(fontSize: fontSize, rootFontSize: rootFontSize);
  }

  static CssBorderStyle? _borderStyle(String? value) => switch (value) {
    'none' || 'hidden' => CssBorderStyle.none,
    'solid' => CssBorderStyle.solid,
    'dashed' => CssBorderStyle.dashed,
    'dotted' => CssBorderStyle.dotted,
    'double' => CssBorderStyle.doubleLine,
    _ => null,
  };

  static Color? _colorFromShorthand(String value) {
    // Don't treat tokens inside url(...) as colors.
    final withoutUrl = value.replaceAll(_urlPattern, ' ').trim();
    for (final token in _splitCssTokens(withoutUrl)) {
      final c = CssColor.tryParse(token);
      if (c != null) return c;
    }
    // Email templates commonly declare a solid `background` followed by a
    // gradient using the same property. The CSS declaration map keeps the
    // latter value, so renderers without gradient painting still need a
    // sensible solid fallback. Use the first explicit gradient stop, which
    // matches the start edge and avoids dropping the background altogether.
    final gradientColor = _firstGradientColor(withoutUrl);
    if (gradientColor != null) return gradientColor;
    return CssColor.tryParse(withoutUrl);
  }

  static Color? _firstGradientColor(String value) {
    final lower = value.toLowerCase();
    if (!lower.contains('gradient(')) return null;

    final colorToken = RegExp(
      r'#[0-9a-f]{3,8}\b|(?:rgb|rgba|hsl|hsla)\([^)]*\)',
      caseSensitive: false,
    ).firstMatch(value)?.group(0);
    return colorToken == null ? null : CssColor.tryParse(colorToken);
  }

  static final RegExp _urlPattern = RegExp(
    r'url\(\s*([^)]+?)\s*\)',
    caseSensitive: false,
  );

  /// Extracts the URL from a `url(...)` token (in `background[-image]`).
  static String? _urlFrom(String value) {
    final m = _urlPattern.firstMatch(value);
    if (m == null) return null;
    var url = m.group(1)!.trim();
    if (url.length >= 2 &&
        ((url.startsWith('"') && url.endsWith('"')) ||
            (url.startsWith("'") && url.endsWith("'")))) {
      url = url.substring(1, url.length - 1);
    }
    return url.isEmpty ? null : url;
  }

  static String? _gradientFrom(String value) {
    final image = value.trim();
    return image.toLowerCase().startsWith('linear-gradient(') &&
            image.endsWith(')')
        ? image
        : null;
  }

  /// Best-effort `background-position` from a `background` shorthand: drops the
  /// `url(...)` part and reads a position pair from the rest.
  static (double, double)? _bgPositionFrom(String shorthand) =>
      _parseBgPosition(shorthand.replaceAll(_urlPattern, ' '));

  /// Parses `background-position` into (x, y) px. Only px/`0` offsets and the
  /// `left`/`top` keywords resolve; `center`/`right`/`bottom`/`%` need box and
  /// image sizes we don't have here and are skipped.
  static (double, double)? _parseBgPosition(String value) {
    final coords = <double>[];
    for (final t in value.trim().split(RegExp(r'\s+'))) {
      if (t.isEmpty) continue;
      final v = _positionToken(t);
      if (v != null) coords.add(v);
      if (coords.length == 2) break;
    }
    if (coords.isEmpty) return null;
    return (coords[0], coords.length > 1 ? coords[1] : 0.0);
  }

  /// Normalises `background-size` to a value we can render: `cover`, `contain`,
  /// `100%` (scale to the box width), or a px width like `16px` (a sized sprite,
  /// e.g. an image bullet). Other values fall back to natural-size (null).
  static String? _backgroundSize(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'cover' || v == 'contain') return v;
    // `100%` or `100% 100%` / `100% auto`: treat as full-width scale.
    if (v.startsWith('100%')) return '100%';
    final first = v.split(RegExp(r'\s+')).first;
    if (first.endsWith('px') &&
        double.tryParse(first.substring(0, first.length - 2)) != null) {
      return first; // e.g. "16px"
    }
    return null;
  }

  static CssBackgroundRepeat? _backgroundRepeat(String value) {
    final tokens = value
        .replaceAll(_urlPattern, ' ')
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty);
    for (final token in tokens) {
      switch (token) {
        case 'repeat':
          return CssBackgroundRepeat.repeat;
        case 'repeat-x':
          return CssBackgroundRepeat.repeatX;
        case 'repeat-y':
          return CssBackgroundRepeat.repeatY;
        case 'no-repeat':
          return CssBackgroundRepeat.noRepeat;
      }
    }
    return null;
  }

  /// Parses `background-position` keywords/percentages into an [Alignment] for
  /// a scaled background (e.g. `center top` -> topCenter, `left bottom`,
  /// `100% 50%`). Returns null when nothing positional is present.
  static Alignment? _backgroundAlignment(String value) {
    final tokens = value
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty);
    double? x, y;
    var sawCenter = false;
    var i = 0;
    for (final t in tokens) {
      switch (t) {
        case 'left':
          x = -1;
        case 'right':
          x = 1;
        case 'top':
          y = -1;
        case 'bottom':
          y = 1;
        case 'center':
          sawCenter = true;
        default:
          if (t.endsWith('%')) {
            final p = double.tryParse(t.replaceAll('%', ''));
            if (p != null) {
              final a = p / 50.0 - 1.0; // 0%->-1, 50%->0, 100%->1
              if (i == 0) {
                x ??= a;
              } else {
                y ??= a;
              }
            }
          }
      }
      i++;
    }
    if (x == null && y == null && !sawCenter) return null;
    return Alignment(x ?? 0, y ?? 0);
  }

  static double? _positionToken(String token) {
    switch (token.toLowerCase()) {
      case 'left':
      case 'top':
        return 0;
      case 'center':
      case 'right':
      case 'bottom':
        return null; // needs sizes; skip
    }
    final len = CssLength.tryParse(token);
    if (len == null) return null;
    if (len.unit == CssLengthUnit.zero) return 0;
    if (len.unit == CssLengthUnit.px) return len.value;
    return null; // %/em offsets unsupported
  }

  static _FontShorthand _fontShorthand(
    String value,
    double parent,
    double root,
    FontWeight inheritedFontWeight,
  ) {
    FontStyle? style;
    FontWeight? weight;
    double? size;
    final tokens = value.trim().split(RegExp(r'\s+'));
    final remainder = <String>[];
    for (final t in tokens) {
      final s = _fontStyle(t);
      if (s != null) {
        style = s;
        continue;
      }
      final w = _fontWeight(t, parent: inheritedFontWeight);
      if (w != null && (t == 'bold' || int.tryParse(t) != null)) {
        weight = w;
        continue;
      }
      final fs = _fontSize(t.split('/').first, parent, root);
      if (fs != null && size == null) {
        size = fs;
        continue;
      }
      remainder.add(t);
    }
    final families = remainder.isEmpty
        ? null
        : _fontFamilies(remainder.join(' '));
    final safeSize = size != null && size.isFinite && size >= 0 ? size : null;
    return _FontShorthand(style, weight, safeSize, families);
  }
}

class _FontShorthand {
  _FontShorthand(
    this.fontStyle,
    this.fontWeight,
    this.fontSize,
    this.fontFamilies,
  );
  final FontStyle? fontStyle;
  final FontWeight? fontWeight;
  final double? fontSize;
  final List<String>? fontFamilies;
}
