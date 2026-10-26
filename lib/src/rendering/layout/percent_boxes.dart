import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class PercentPadding extends SingleChildRenderObjectWidget {
  const PercentPadding({
    super.key,
    required this.fractions,
    required Widget child,
  }) : super(child: child);

  final EdgeInsets fractions;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPercentPadding(fractions);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPercentPadding).fractions = fractions;
  }
}

/// Resolves a percentage width against the containing block before applying a
/// fixed `max-width` cap.
///
/// Nesting Flutter's [FractionallySizedBox] inside a [ConstrainedBox] reverses
/// that CSS order: `width:37%;max-width:230px` becomes 37% of 230px. This
/// render object receives the containing block's loose constraint, computes
/// the percentage from it, and only then clamps the result to [maxWidth]. It
/// also supports intrinsic measurement, which [LayoutBuilder] cannot provide
/// when the box lives inside a Flutter [Table].
class PercentMaxWidthBox extends SingleChildRenderObjectWidget {
  const PercentMaxWidthBox({
    super.key,
    required this.widthFactor,
    required this.maxWidth,
    required Widget child,
  }) : super(child: child);

  final double widthFactor;
  final double maxWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPercentMaxWidthBox(widthFactor, maxWidth);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPercentMaxWidthBox)
      ..widthFactor = widthFactor
      ..maxWidth = maxWidth;
  }
}

class _RenderPercentMaxWidthBox extends RenderProxyBox {
  _RenderPercentMaxWidthBox(this._widthFactor, this._maxWidth);

  double _widthFactor;
  double _maxWidth;

  set widthFactor(double value) {
    if (value == _widthFactor) return;
    _widthFactor = value;
    markNeedsLayout();
  }

  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  double _targetWidth(BoxConstraints constraints) {
    final basis = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : (child?.getMaxIntrinsicWidth(double.infinity) ?? _maxWidth);
    return constraints.constrainWidth(
      (basis * _widthFactor).clamp(0.0, _maxWidth),
    );
  }

  BoxConstraints _childConstraints(BoxConstraints constraints, double width) =>
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        minHeight: 0,
        maxHeight: constraints.maxHeight,
      );

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _widthFactor > 0 ? _maxWidth / _widthFactor.clamp(0.0, 1.0) : 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width.clamp(0.0, _maxWidth)) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width.clamp(0.0, _maxWidth)) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final width = _targetWidth(constraints);
    final childSize = child?.getDryLayout(
      _childConstraints(constraints, width),
    );
    return constraints.constrain(Size(width, childSize?.height ?? 0));
  }

  @override
  void performLayout() {
    final width = _targetWidth(constraints);
    child?.layout(_childConstraints(constraints, width), parentUsesSize: true);
    size = constraints.constrain(Size(width, child?.size.height ?? 0));
  }
}

/// Applies `max-width` to an auto-width inline-block without turning the cap
/// into the element's min-content width.
///
/// Flutter's [ConstrainedBox] reports its max width as intrinsic width. Inside
/// a table column that makes `display:inline-block;max-width:800px` expand a
/// narrower email column to 800px. In CSS, `max-width` is only an upper bound:
/// the containing block still wins.
class ShrinkableMaxWidthBox extends SingleChildRenderObjectWidget {
  const ShrinkableMaxWidthBox({
    super.key,
    required this.maxWidth,
    required Widget child,
  }) : super(child: child);

  final double maxWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderShrinkableMaxWidthBox(maxWidth);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderShrinkableMaxWidthBox).maxWidth = maxWidth;
  }
}

class _RenderShrinkableMaxWidthBox extends RenderProxyBox {
  _RenderShrinkableMaxWidthBox(this._maxWidth);

  double _maxWidth;

  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  double _cap(BoxConstraints constraints) =>
      constraints.maxWidth.isFinite && constraints.maxWidth < _maxWidth
      ? constraints.maxWidth
      : _maxWidth;

  BoxConstraints _childConstraints(BoxConstraints constraints) {
    final cap = _cap(constraints);
    return BoxConstraints(
      minWidth: 0,
      maxWidth: cap,
      minHeight: constraints.minHeight,
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) {
    final childWidth = child?.getMaxIntrinsicWidth(height) ?? 0;
    return childWidth.clamp(0.0, _maxWidth);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width.clamp(0.0, _maxWidth)) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width.clamp(0.0, _maxWidth)) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize = child?.getDryLayout(_childConstraints(constraints));
    return constraints.constrain(
      Size(
        (childSize?.width ?? 0).clamp(0.0, _cap(constraints)),
        childSize?.height ?? 0,
      ),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width.clamp(0.0, _cap(constraints)), child.size.height),
    );
  }
}

class _RenderPercentPadding extends RenderShiftedBox {
  _RenderPercentPadding(this._fractions) : super(null);

  EdgeInsets _fractions;

  set fractions(EdgeInsets value) {
    if (_fractions == value) return;
    _fractions = value;
    markNeedsLayout();
  }

  EdgeInsets _insets(double width) => EdgeInsets.fromLTRB(
    width * _fractions.left,
    width * _fractions.top,
    width * _fractions.right,
    width * _fractions.bottom,
  );

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0;

  double _base(BoxConstraints constraints) => constraints.maxWidth.isFinite
      ? constraints.maxWidth
      : (child?.getMaxIntrinsicWidth(double.infinity) ?? 0);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final insets = _insets(_base(constraints));
    final childSize = child.getDryLayout(constraints.deflate(insets));
    return constraints.constrain(
      Size(
        childSize.width + insets.horizontal,
        childSize.height + insets.vertical,
      ),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final insets = _insets(_base(constraints));
    child.layout(constraints.deflate(insets), parentUsesSize: true);
    (child.parentData as BoxParentData).offset = Offset(
      insets.left,
      insets.top,
    );
    size = constraints.constrain(
      Size(
        child.size.width + insets.horizontal,
        child.size.height + insets.vertical,
      ),
    );
  }
}
