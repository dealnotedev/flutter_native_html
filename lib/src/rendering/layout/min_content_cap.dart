import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Caps the min-content (min intrinsic) width a paragraph reports, i.e. the
/// width of its longest unbreakable word. Shrink-to-fit boxes and auto table
/// columns size to that width; capped, a long URL or compound word (or
/// `word-break: break-all` text) cannot push them past [cap], and the text
/// breaks inside the word at layout instead.
class MinContentCap extends SingleChildRenderObjectWidget {
  const MinContentCap({super.key, required this.cap, super.child});

  final double cap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMinContentCap(cap);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMinContentCap).cap = cap;
  }
}

class _RenderMinContentCap extends RenderProxyBox {
  _RenderMinContentCap(this._cap);

  double _cap;
  set cap(double value) {
    if (value == _cap) return;
    _cap = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.min(super.computeMinIntrinsicWidth(height), _cap);
}
