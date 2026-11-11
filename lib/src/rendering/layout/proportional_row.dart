import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A table row of px-wide cells, laid out like a browser's auto table on a
/// narrow screen: each cell keeps its width while the row fits, and the
/// [shrinkable] cells narrow toward their min-content widths when it does not
/// (fixed gutters/spacing keep theirs). Every cell then stretches to the
/// tallest cell's height, measured by a real layout rather than intrinsics.
class ProportionalRow extends MultiChildRenderObjectWidget {
  const ProportionalRow({
    super.key,
    required this.widths,
    required this.shrinkable,
    required super.children,
  });

  final List<double> widths;
  final List<bool> shrinkable;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderProportionalRow(widths: widths, shrinkable: shrinkable);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as RenderProportionalRow)
      ..widths = widths
      ..shrinkable = shrinkable;
  }
}

class _RowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderProportionalRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _RowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _RowParentData> {
  RenderProportionalRow({
    required List<double> widths,
    required List<bool> shrinkable,
  }) : _widths = widths, // ignore: prefer_initializing_formals
       _shrinkable = shrinkable; // ignore: prefer_initializing_formals

  List<double> _widths;
  set widths(List<double> value) {
    _widths = value;
    markNeedsLayout();
  }

  List<bool> _shrinkable;
  set shrinkable(List<bool> value) {
    _shrinkable = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _RowParentData) {
      child.parentData = _RowParentData();
    }
  }

  static double _sum(List<double> widths) =>
      widths.fold(0.0, (sum, width) => sum + width);

  List<double> _minimumWidths() {
    final widths = <double>[];
    var child = firstChild;
    while (child != null) {
      final i = widths.length;
      var minimum = _widths[i];
      if (_shrinkable[i]) {
        try {
          minimum = child.getMinIntrinsicWidth(double.infinity);
        } on FlutterError {
          // Custom widgets can require real layout to determine their size.
          minimum = _widths[i];
        }
        if (!minimum.isFinite || minimum < 0) minimum = _widths[i];
      }
      widths.add(minimum);
      child = childAfter(child);
    }
    return widths;
  }

  List<double> _preferredWidths(List<double> minimums) => [
    for (var i = 0; i < _widths.length; i++) math.max(_widths[i], minimums[i]),
  ];

  /// Each child's width for a row at most [maxWidth] wide.
  List<double> _resolve(double maxWidth) {
    final minimums = _minimumWidths();
    final preferred = _preferredWidths(minimums);
    final total = _sum(preferred);
    if (total <= maxWidth) return preferred;
    final minimumTotal = _sum(minimums);
    if (minimumTotal >= maxWidth) return minimums;
    final fraction = (maxWidth - minimumTotal) / (total - minimumTotal);
    return [
      for (var i = 0; i < _widths.length; i++)
        minimums[i] + (preferred[i] - minimums[i]) * fraction,
    ];
  }

  @override
  void performLayout() {
    final widths = _resolve(constraints.maxWidth);
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      child.layout(
        BoxConstraints.tightFor(width: widths[i]),
        parentUsesSize: true,
      );
      height = math.max(height, child.size.height);
      child = childAfter(child);
      i++;
    }
    height = constraints.constrainHeight(height);
    var x = 0.0;
    child = firstChild;
    i = 0;
    while (child != null) {
      // Stretch: backgrounds and borders fill the row, as table cells do.
      if (child.size.height != height) {
        child.layout(
          BoxConstraints.tightFor(width: widths[i], height: height),
          parentUsesSize: true,
        );
      }
      (child.parentData! as _RowParentData).offset = Offset(x, 0);
      x += widths[i];
      child = childAfter(child);
      i++;
    }
    size = constraints.constrain(Size(x, height));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final widths = _resolve(constraints.maxWidth);
    return constraints.constrain(Size(_sum(widths), _intrinsicHeight(widths)));
  }

  @override
  double computeMinIntrinsicWidth(double height) => _sum(_minimumWidths());

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _sum(_preferredWidths(_minimumWidths()));

  double _intrinsicHeight(List<double> widths) {
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      height = math.max(height, child.getMaxIntrinsicHeight(widths[i]));
      child = childAfter(child);
      i++;
    }
    return height;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(_resolve(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(_resolve(width));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
