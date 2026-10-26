import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class PercentHeightBox extends SingleChildRenderObjectWidget {
  const PercentHeightBox({
    super.key,
    required this.percent,
    required super.child,
  });

  final double percent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPercentHeightBox(percent);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPercentHeightBox).percent = percent;
  }
}

class _RenderPercentHeightBox extends RenderProxyBox {
  _RenderPercentHeightBox(double percent) : _percent = percent;

  double _percent;

  set percent(double value) {
    if (_percent == value) return;
    _percent = value;
    markNeedsLayout();
  }

  BoxConstraints _childConstraints(BoxConstraints constraints) {
    if (!constraints.hasBoundedHeight) return constraints;
    final height = constraints.constrainHeight(
      constraints.maxHeight * _percent.clamp(0.0, 1.0),
    );
    return constraints.copyWith(minHeight: height, maxHeight: height);
  }

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

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final childSize = child.getDryLayout(_childConstraints(constraints));
    return constraints.constrain(childSize);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}

class PercentSpacerColumn extends MultiChildRenderObjectWidget {
  const PercentSpacerColumn({
    super.key,
    required this.spacers,
    required super.children,
  });

  final List<bool> spacers;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPercentSpacerColumn(spacers);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPercentSpacerColumn).spacers = spacers;
  }
}

class _PercentSpacerColumnParentData
    extends ContainerBoxParentData<RenderBox> {}

class _RenderPercentSpacerColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PercentSpacerColumnParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _PercentSpacerColumnParentData
        > {
  _RenderPercentSpacerColumn(List<bool> spacers) : _spacers = spacers;

  List<bool> _spacers;

  set spacers(List<bool> value) {
    if (_spacers == value) return;
    _spacers = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PercentSpacerColumnParentData) {
      child.parentData = _PercentSpacerColumnParentData();
    }
  }

  bool _isSpacer(int index) => index < _spacers.length && _spacers[index];

  @override
  double computeMinIntrinsicWidth(double height) =>
      _intrinsicWidth((child) => child.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _intrinsicWidth((child) => child.getMaxIntrinsicWidth(height));

  double _intrinsicWidth(double Function(RenderBox child) getter) {
    var width = 0.0;
    var index = 0;
    var child = firstChild;
    while (child != null) {
      if (!_isSpacer(index)) {
        final childWidth = getter(child);
        if (childWidth > width) width = childWidth;
      }
      final data = child.parentData! as _PercentSpacerColumnParentData;
      child = data.nextSibling;
      index++;
    }
    return width;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight((child) => child.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight((child) => child.getMaxIntrinsicHeight(width));

  double _intrinsicHeight(double Function(RenderBox child) getter) {
    var height = 0.0;
    var index = 0;
    var child = firstChild;
    while (child != null) {
      if (!_isSpacer(index)) height += getter(child);
      final data = child.parentData! as _PercentSpacerColumnParentData;
      child = data.nextSibling;
      index++;
    }
    return height;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childConstraints = BoxConstraints(
      minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
      maxWidth: constraints.maxWidth,
    );
    var width = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
    var height = 0.0;
    var spacerCount = 0;
    var index = 0;
    var child = firstChild;
    while (child != null) {
      if (_isSpacer(index)) {
        spacerCount++;
      } else {
        final childSize = child.getDryLayout(childConstraints);
        height += childSize.height;
        if (!constraints.hasBoundedWidth && childSize.width > width) {
          width = childSize.width;
        }
      }
      final data = child.parentData! as _PercentSpacerColumnParentData;
      child = data.nextSibling;
      index++;
    }
    if (constraints.hasBoundedHeight && spacerCount > 0) {
      height = constraints.maxHeight;
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  void performLayout() {
    var width = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
    var nonSpacerHeight = 0.0;
    var spacerCount = 0;
    var index = 0;
    var child = firstChild;
    final looseChildConstraints = BoxConstraints(
      minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
      maxWidth: constraints.maxWidth,
    );

    while (child != null) {
      final data = child.parentData! as _PercentSpacerColumnParentData;
      if (_isSpacer(index)) {
        spacerCount++;
      } else {
        child.layout(looseChildConstraints, parentUsesSize: true);
        nonSpacerHeight += child.size.height;
        if (!constraints.hasBoundedWidth && child.size.width > width) {
          width = child.size.width;
        }
      }
      child = data.nextSibling;
      index++;
    }

    final remaining = constraints.hasBoundedHeight
        ? (constraints.maxHeight - nonSpacerHeight).clamp(0.0, double.infinity)
        : 0.0;
    final spacerHeight = spacerCount == 0 ? 0.0 : remaining / spacerCount;
    final laidOutWidth = constraints.constrainWidth(width);

    var y = 0.0;
    index = 0;
    child = firstChild;
    while (child != null) {
      final data = child.parentData! as _PercentSpacerColumnParentData;
      if (_isSpacer(index)) {
        child.layout(
          BoxConstraints.tightFor(width: laidOutWidth, height: spacerHeight),
          parentUsesSize: true,
        );
      } else if (child.size.width != laidOutWidth) {
        child.layout(
          BoxConstraints(
            minWidth: laidOutWidth,
            maxWidth: laidOutWidth,
            minHeight: 0,
            maxHeight: double.infinity,
          ),
          parentUsesSize: true,
        );
      }
      data.offset = Offset(0, y);
      y += child.size.height;
      child = data.nextSibling;
      index++;
    }

    final height = constraints.hasBoundedHeight ? constraints.maxHeight : y;
    size = constraints.constrain(Size(laidOutWidth, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
