import 'package:flutter/widgets.dart';

import '../css/html_style.dart';

BorderRadius? cssBorderRadius(HtmlStyle style) {
  if (style.borderRadiusGeometry case final corners?) return corners;
  if (style.borderRadiusPercent case final percent?) {
    return percent == 0
        ? BorderRadius.zero
        : CssPercentageBorderRadius(percent);
  }
  if (style.borderRadius case final pixels?) {
    return BorderRadius.circular(pixels);
  }
  return null;
}

/// Resolves CSS percentages against the painted border box, independently on
/// each axis. This also works in intrinsically sized table cells: resolving in
/// [toRRect] does not introduce a LayoutBuilder into their measurement path.
class CssPercentageBorderRadius extends BorderRadius {
  const CssPercentageBorderRadius(this.percent)
    : assert(percent >= 0 && percent < double.infinity),
      super.all(Radius.zero);

  final double percent;

  @override
  RRect toRRect(Rect rect) {
    // CSS scales overlapping uniform corners down to half of each dimension.
    final fraction = (percent / 100).clamp(0.0, 0.5);
    return RRect.fromRectAndRadius(
      rect,
      Radius.elliptical(rect.width * fraction, rect.height * fraction),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CssPercentageBorderRadius && other.percent == percent;

  @override
  int get hashCode => Object.hash(CssPercentageBorderRadius, percent);

  @override
  String toString() => 'CssPercentageBorderRadius($percent%)';
}
