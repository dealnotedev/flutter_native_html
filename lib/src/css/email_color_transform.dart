import 'package:flutter/painting.dart';

import 'html_style.dart';

/// Color-only adaptation, applied after the author cascade. Images and geometry
/// are untouched. Contrast is evaluated against the composited local surface.
class EmailColorTransform {
  const EmailColorTransform();

  Color surface(Color color) {
    if (color.a == 0 || color.computeLuminance() < 0.18) return color;
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness(hsl.saturation < 0.15 ? 0.10 : 0.25).toColor();
  }

  Color foreground(Color color, Color background, [double minimum = 4.5]) {
    if (color.a == 0) return color;
    var hsl = HSLColor.fromColor(color);
    // Preserve primary/muted hierarchy for source grays instead of pushing
    // every dark text color to the same minimum contrast threshold.
    if (minimum >= 4.5 &&
        background.computeLuminance() < 0.18 &&
        hsl.saturation < 0.15 &&
        hsl.lightness < 0.65) {
      hsl = hsl.withLightness((0.92 - hsl.lightness * 0.45).clamp(0.68, 0.92));
      color = hsl.toColor();
    }
    if (_contrast(color, background) >= minimum) return color;
    final target = background.computeLuminance() < 0.18 ? 1.0 : 0.0;
    var low = 0.0, high = 1.0;
    for (var i = 0; i < 16; i++) {
      final mid = (low + high) / 2;
      final candidate = hsl
          .withLightness(hsl.lightness + (target - hsl.lightness) * mid)
          .toColor();
      if (_contrast(candidate, background) < minimum) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return hsl
        .withLightness(hsl.lightness + (target - hsl.lightness) * high)
        .toColor();
  }

  static double _contrast(Color color, Color background) {
    final a = Color.alphaBlend(color, background).computeLuminance();
    final b = background.computeLuminance();
    return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
  }

  HtmlStyle apply(HtmlStyle style, Color background) {
    CssBorderSide? edge(CssBorderSide? side) => side == null
        ? null
        : CssBorderSide(
            width: side.width,
            color: foreground(side.color, background, 1.8),
            style: side.style,
            hairline: side.hairline,
          );
    final borders = style.borders;
    return style.merge(
      HtmlStyle(
        color: style.color == null
            ? null
            : foreground(style.color!, background),
        textDecorationColor: style.textDecorationColor == null
            ? null
            : foreground(style.textDecorationColor!, background),
        borders: borders == null
            ? null
            : CssBorders(
                top: edge(borders.top),
                right: edge(borders.right),
                bottom: edge(borders.bottom),
                left: edge(borders.left),
              ),
      ),
    );
  }
}
