import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Horizontal negative CSS margins expand an auto-width block and shift its
/// content, rather than merely translating paint within the old line width.
class NegativeHorizontalMargin extends SingleChildRenderObjectWidget {
  const NegativeHorizontalMargin({
    super.key,
    required this.left,
    required this.right,
    required super.child,
  });

  final double left;
  final double right;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNegativeHorizontalMargin(left, right);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderNegativeHorizontalMargin)
      ..left = left
      ..right = right;
  }
}

class _RenderNegativeHorizontalMargin extends RenderShiftedBox {
  _RenderNegativeHorizontalMargin(this._left, this._right) : super(null);

  double _left;
  double _right;

  set left(double value) {
    if (_left == value) return;
    _left = value;
    markNeedsLayout();
  }

  set right(double value) {
    if (_right == value) return;
    _right = value;
    markNeedsLayout();
  }

  double get _extent => _left + _right;

  BoxConstraints _inner(BoxConstraints constraints) => constraints.copyWith(
    minWidth: (constraints.minWidth - _extent).clamp(0, double.infinity),
    maxWidth: (constraints.maxWidth - _extent).clamp(0, double.infinity),
  );

  Size _outer(BoxConstraints constraints, Size childSize) =>
      constraints.constrain(
        Size(
          (childSize.width + _extent).clamp(0, double.infinity),
          childSize.height,
        ),
      );

  @override
  void performLayout() {
    final currentChild = child;
    if (currentChild == null) {
      size = constraints.smallest;
      return;
    }
    currentChild.layout(_inner(constraints), parentUsesSize: true);
    size = _outer(constraints, currentChild.size);
    (currentChild.parentData! as BoxParentData).offset = Offset(_left, 0);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => child == null
      ? constraints.smallest
      : _outer(constraints, child!.getDryLayout(_inner(constraints)));

  @override
  double computeMinIntrinsicWidth(double height) =>
      ((child?.getMinIntrinsicWidth(height) ?? 0) + _extent).clamp(
        0,
        double.infinity,
      );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      ((child?.getMaxIntrinsicWidth(height) ?? 0) + _extent).clamp(
        0,
        double.infinity,
      );

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(
        (width - _extent).clamp(0, double.infinity),
      ) ??
      0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(
        (width - _extent).clamp(0, double.infinity),
      ) ??
      0;
}
