import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../text_wrapping.dart';

/// Measures alternate break opportunities for min-content only. Inline boxes
/// keep their own intrinsic widths and the visible paragraph uses the engine's
/// normal fallback breaking for overflow-wrap:anywhere.
class ParagraphMinWidth extends SingleChildRenderObjectWidget {
  const ParagraphMinWidth({super.key, this.breaks = const [], super.child});

  /// An empty list means the paragraph is non-wrapping.
  final List<int> breaks;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderParagraphMinWidth(breaks);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderParagraphMinWidth).breaks = breaks;
  }
}

class _RenderParagraphMinWidth extends RenderProxyBox {
  _RenderParagraphMinWidth(this._breaks);

  List<int> _breaks;
  set breaks(List<int> value) {
    if (identical(_breaks, value)) return;
    _breaks = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    if (_breaks.isEmpty) return super.computeMaxIntrinsicWidth(height);

    // Text.rich adds a mouse region under a SelectionArea.
    RenderBox? paragraph = child;
    while (paragraph is RenderProxyBox) {
      paragraph = paragraph.child;
    }
    if (paragraph is! RenderParagraph || paragraph.text is! TextSpan) {
      return super.computeMinIntrinsicWidth(height);
    }
    final dimensions = <PlaceholderDimensions>[];
    paragraph.visitChildren((child) {
      final box = child as RenderBox;
      final span = (box.parentData! as TextParentData).span!;
      dimensions.add(
        PlaceholderDimensions(
          size: Size(box.getMinIntrinsicWidth(double.infinity), 0),
          alignment: span.alignment,
          baseline: span.baseline,
          baselineOffset: 0,
        ),
      );
    });
    final painter = TextPainter(
      // The engine uses zero-width spaces for line layout but may still
      // include the whole word in minIntrinsicWidth. Measure the opted-in
      // segments as separate lines, with all other break rules intact.
      text: insertSoftBreaks(
        paragraph.text as TextSpan,
        _breaks,
        separator: '\n',
      ),
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      locale: paragraph.locale,
    );
    try {
      painter
        ..setPlaceholderDimensions(dimensions)
        ..layout();
      return painter.minIntrinsicWidth;
    } finally {
      painter.dispose();
    }
  }
}
