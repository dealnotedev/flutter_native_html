import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class EqualHeightRow extends MultiChildRenderObjectWidget {
  const EqualHeightRow({
    super.key,
    required this.mainAxisAlignment,
    required this.textDirection,
    required this.widthPercents,
    required super.children,
  });

  final MainAxisAlignment mainAxisAlignment;
  final TextDirection? textDirection;
  final List<double?> widthPercents;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEqualHeightRow(
        mainAxisAlignment: mainAxisAlignment,
        textDirection: textDirection ?? Directionality.of(context),
        widthPercents: widthPercents,
      );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderEqualHeightRow)
      ..mainAxisAlignment = mainAxisAlignment
      ..textDirection = textDirection ?? Directionality.of(context)
      ..widthPercents = widthPercents;
  }
}

class _EqualHeightParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderEqualHeightRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EqualHeightParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EqualHeightParentData> {
  _RenderEqualHeightRow({
    required this._mainAxisAlignment,
    required this._textDirection,
    required this._widthPercents,
  });

  MainAxisAlignment _mainAxisAlignment;

  set mainAxisAlignment(MainAxisAlignment value) {
    if (_mainAxisAlignment == value) return;
    _mainAxisAlignment = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  List<double?> _widthPercents;

  set widthPercents(List<double?> value) {
    if (_widthPercents == value) return;
    _widthPercents = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualHeightParentData) {
      child.parentData = _EqualHeightParentData();
    }
  }

  double? _percentWidthFor(int index) {
    if (index >= _widthPercents.length) return null;
    final percent = _widthPercents[index];
    return percent == null || percent <= 0 ? null : percent;
  }

  BoxConstraints _constraintsForChild(
    int index,
    BoxConstraints constraints, {
    double? height,
  }) {
    final percent = constraints.hasBoundedWidth && constraints.maxWidth.isFinite
        ? _percentWidthFor(index)
        : null;
    final width = percent == null ? null : constraints.maxWidth * percent / 100;
    if (width != null || height != null) {
      return BoxConstraints(
        minWidth: width ?? 0,
        maxWidth: width ?? constraints.maxWidth,
        minHeight: height ?? 0,
        maxHeight: height ?? constraints.maxHeight,
      );
    }
    return BoxConstraints(
      minWidth: 0,
      maxWidth: constraints.maxWidth,
      minHeight: 0,
      maxHeight: constraints.maxHeight.isFinite
          ? constraints.maxHeight
          : double.infinity,
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _intrinsicWidth((child) => child.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _intrinsicWidth((child) => child.getMaxIntrinsicWidth(height));

  double _intrinsicWidth(double Function(RenderBox child) getter) {
    var width = 0.0;
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _EqualHeightParentData;
      width += getter(child);
      child = parentData.nextSibling;
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
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _EqualHeightParentData;
      final childHeight = getter(child);
      if (childHeight > height) height = childHeight;
      child = parentData.nextSibling;
    }
    return height;
  }

  @override
  void performLayout() {
    var child = firstChild;
    if (child == null) {
      size = constraints.smallest;
      return;
    }

    final measuredWidths = <double>[];
    var totalWidth = 0.0;
    var maxHeight = 0.0;
    var index = 0;
    while (child != null) {
      final parentData = child.parentData! as _EqualHeightParentData;
      child.layout(
        _constraintsForChild(index, constraints),
        parentUsesSize: true,
      );
      measuredWidths.add(child.size.width);
      totalWidth += child.size.width;
      if (child.size.height > maxHeight) maxHeight = child.size.height;
      child = parentData.nextSibling;
      index++;
    }

    final scale =
        constraints.hasBoundedWidth &&
            constraints.maxWidth.isFinite &&
            totalWidth > constraints.maxWidth &&
            totalWidth > 0
        ? constraints.maxWidth / totalWidth
        : 1.0;

    final targetHeight = constraints.constrainHeight(maxHeight);
    child = firstChild;
    totalWidth = 0;
    index = 0;
    while (child != null) {
      final parentData = child.parentData! as _EqualHeightParentData;
      if (scale < 1) {
        child.layout(
          BoxConstraints.tightFor(
            width: measuredWidths[index] * scale,
            height: targetHeight,
          ),
          parentUsesSize: true,
        );
      } else {
        child.layout(
          _constraintsForChild(index, constraints, height: targetHeight),
          parentUsesSize: true,
        );
      }
      totalWidth += child.size.width;
      child = parentData.nextSibling;
      index++;
    }

    final rowWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : totalWidth;
    size = constraints.constrain(Size(rowWidth, targetHeight));

    final freeSpace = (size.width - totalWidth).clamp(0.0, double.infinity);
    final startOffset = switch (_mainAxisAlignment) {
      MainAxisAlignment.end => freeSpace,
      MainAxisAlignment.center => freeSpace / 2,
      _ => 0.0,
    };

    final rtl = _textDirection == TextDirection.rtl;
    var x = rtl ? size.width - startOffset : startOffset;
    child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _EqualHeightParentData;
      if (rtl) {
        x -= child.size.width;
        parentData.offset = Offset(x, 0);
      } else {
        parentData.offset = Offset(x, 0);
        x += child.size.width;
      }
      child = parentData.nextSibling;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
