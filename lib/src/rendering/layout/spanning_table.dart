import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

typedef SpanningCellPosition = ({int row, int column, int rows, int columns});

/// Places cells in logical columns before any cell widgets are built.
/// Returns null for grids that exceed the layout budget.
({int columns, List<SpanningCellPosition> cells})? placeSpanningCells(
  List<({int groupEnd, List<({int rows, int columns})> cells})> rows,
) {
  const maxColumns = 1024;
  const maxSlots = 1000000;
  final occupiedUntil = <int>[];
  final cells = <SpanningCellPosition>[];
  var slots = 0;
  for (var row = 0; row < rows.length; row++) {
    var column = 0;
    final current = rows[row];
    for (final span in current.cells) {
      final remaining = current.groupEnd - row;
      final height = span.rows == 0 ? remaining : span.rows.clamp(1, remaining);
      final width = span.columns;
      // A new cell must fit between all active spans across its whole width.
      for (
        var c = column;
        c < occupiedUntil.length && c < column + width;
        c++
      ) {
        if (occupiedUntil[c] > row) column = c + 1;
      }
      slots += height * width;
      if (column + width > maxColumns || slots > maxSlots) return null;
      while (occupiedUntil.length < column + width) {
        occupiedUntil.add(0);
      }
      for (var c = column; c < column + width; c++) {
        occupiedUntil[c] = row + height;
      }
      cells.add((row: row, column: column, rows: height, columns: width));
      column += width;
    }
  }
  return (columns: occupiedUntil.length, cells: cells);
}

class SpanningTableCell extends ParentDataWidget<_SpanningTableParentData> {
  const SpanningTableCell({
    super.key,
    required this.row,
    required this.column,
    required this.rowSpan,
    required this.columnSpan,
    required super.child,
  });

  final int row;
  final int column;
  final int rowSpan;
  final int columnSpan;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _SpanningTableParentData;
    if (data.row == row &&
        data.column == column &&
        data.rowSpan == rowSpan &&
        data.columnSpan == columnSpan) {
      return;
    }
    data
      ..row = row
      ..column = column
      ..rowSpan = rowSpan
      ..columnSpan = columnSpan;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => SpanningTable;
}

class SpanningTable extends MultiChildRenderObjectWidget {
  const SpanningTable({
    super.key,
    required this.textDirection,
    required this.rows,
    required this.columns,
    required this.columnWidths,
    required this.horizontalSpacing,
    required this.verticalSpacing,
    required super.children,
  });

  final int rows;
  final TextDirection textDirection;
  final int columns;
  final List<({double px, double percent})> columnWidths;
  final double horizontalSpacing;
  final double verticalSpacing;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSpanningTable(
    rows,
    columns,
    columnWidths,
    horizontalSpacing,
    verticalSpacing,
    textDirection,
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderSpanningTable)
      ..rows = rows
      ..columns = columns
      ..columnWidths = columnWidths
      ..horizontalSpacing = horizontalSpacing
      ..verticalSpacing = verticalSpacing
      ..textDirection = textDirection;
  }
}

class _SpanningTableParentData extends ContainerBoxParentData<RenderBox> {
  int row = 0;
  int column = 0;
  int rowSpan = 1;
  int columnSpan = 1;
}

class _RenderSpanningTable extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SpanningTableParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SpanningTableParentData> {
  _RenderSpanningTable(
    this._rows,
    this._columns,
    this._columnWidths,
    this._horizontalSpacing,
    this._verticalSpacing,
    this._textDirection,
  );

  int _rows;
  int _columns;
  List<({double px, double percent})> _columnWidths;
  double _horizontalSpacing;
  double _verticalSpacing;
  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  set rows(int value) {
    if (_rows == value) return;
    _rows = value;
    markNeedsLayout();
  }

  set columns(int value) {
    if (_columns == value) return;
    _columns = value;
    markNeedsLayout();
  }

  set columnWidths(List<({double px, double percent})> value) {
    if (identical(_columnWidths, value)) return;
    _columnWidths = value;
    markNeedsLayout();
  }

  set horizontalSpacing(double value) {
    if (_horizontalSpacing == value) return;
    _horizontalSpacing = value;
    markNeedsLayout();
  }

  set verticalSpacing(double value) {
    if (_verticalSpacing == value) return;
    _verticalSpacing = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SpanningTableParentData) {
      child.parentData = _SpanningTableParentData();
    }
  }

  double _availableWidth(BoxConstraints constraints) {
    if (constraints.maxWidth.isFinite) return constraints.maxWidth;
    return computeMaxIntrinsicWidth(double.infinity);
  }

  double _intrinsicWidth(bool minimum) {
    final widths = [for (final spec in _columnWidths) spec.px];
    RenderBox? child = firstChild;
    while (child != null) {
      final data = child.parentData! as _SpanningTableParentData;
      final value = minimum
          ? child.getMinIntrinsicWidth(double.infinity)
          : child.getMaxIntrinsicWidth(double.infinity);
      final share =
          (value - _horizontalSpacing * (data.columnSpan - 1)) /
          data.columnSpan;
      for (var c = data.column; c < data.column + data.columnSpan; c++) {
        if (share > widths[c]) widths[c] = share;
      }
      child = data.nextSibling;
    }
    return widths.fold<double>(0, (sum, width) => sum + width) +
        _horizontalSpacing * (_columns - 1);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsicWidth(true);

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsicWidth(false);

  List<double> _resolvedColumnWidths(double width) {
    final available = (width - _horizontalSpacing * (_columns - 1)).clamp(
      0.0,
      double.infinity,
    );
    final widths = [
      for (final spec in _columnWidths)
        spec.px > 0 ? spec.px : available * spec.percent / 100,
    ];
    final total = widths.fold<double>(0, (sum, value) => sum + value);
    final auto = _columnWidths
        .where((spec) => spec.px == 0 && spec.percent == 0)
        .length;
    if (total > available || (auto == 0 && total > 0)) {
      final scale = available / total;
      for (var c = 0; c < _columns; c++) {
        widths[c] *= scale;
      }
    } else if (auto > 0) {
      final share = (available - total) / auto;
      for (var c = 0; c < _columns; c++) {
        if (_columnWidths[c].px == 0 && _columnWidths[c].percent == 0) {
          widths[c] = share;
        }
      }
    }
    return widths;
  }

  double _spanWidth(_SpanningTableParentData data, List<double> widths) {
    var width = _horizontalSpacing * (data.columnSpan - 1);
    for (var c = data.column; c < data.column + data.columnSpan; c++) {
      width += widths[c];
    }
    return width;
  }

  List<double> _rowHeights(
    List<double> widths,
    double Function(RenderBox child, double width) measure,
  ) {
    final heights = List<double>.filled(_rows, 0);
    final spanning = <(_SpanningTableParentData, double)>[];
    for (RenderBox? child = firstChild; child != null;) {
      final data = child.parentData! as _SpanningTableParentData;
      final height = measure(child, _spanWidth(data, widths));
      if (data.rowSpan == 1) {
        heights[data.row] = math.max(heights[data.row], height);
      } else {
        spanning.add((data, height));
      }
      child = data.nextSibling;
    }
    for (final (data, height) in spanning) {
      final missing = height - _spanHeight(data, heights);
      if (missing <= 0) continue;
      final share = missing / data.rowSpan;
      for (var row = data.row; row < data.row + data.rowSpan; row++) {
        heights[row] += share;
      }
    }
    return heights;
  }

  double _spanHeight(_SpanningTableParentData data, List<double> heights) {
    var height = _verticalSpacing * (data.rowSpan - 1);
    for (var row = data.row; row < data.row + data.rowSpan; row++) {
      height += heights[row];
    }
    return height;
  }

  double _gridHeight(List<double> heights) =>
      heights.fold<double>(0, (sum, height) => sum + height) +
      _verticalSpacing * math.max(0, _rows - 1);

  double _intrinsicHeight(double width, {required bool minimum}) {
    if (!width.isFinite) width = computeMaxIntrinsicWidth(double.infinity);
    return _gridHeight(
      _rowHeights(
        _resolvedColumnWidths(width),
        (child, spanWidth) => minimum
            ? child.getMinIntrinsicHeight(spanWidth)
            : child.getMaxIntrinsicHeight(spanWidth),
      ),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, minimum: true);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, minimum: false);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    if (_rows <= 0 || _columns <= 0 || firstChild == null) {
      return constraints.smallest;
    }
    final width = constraints.constrainWidth(_availableWidth(constraints));
    final heights = _rowHeights(
      _resolvedColumnWidths(width),
      (child, spanWidth) =>
          child.getDryLayout(BoxConstraints(maxWidth: spanWidth)).height,
    );
    return constraints.constrain(Size(width, _gridHeight(heights)));
  }

  @override
  void performLayout() {
    if (_rows <= 0 || _columns <= 0 || firstChild == null) {
      size = constraints.smallest;
      return;
    }
    final width = _availableWidth(
      constraints,
    ).clamp(constraints.minWidth, constraints.maxWidth);
    final columnWidths = _resolvedColumnWidths(width);
    final columnOffsets = List<double>.filled(_columns, 0);
    for (var c = 1; c < _columns; c++) {
      columnOffsets[c] =
          columnOffsets[c - 1] + columnWidths[c - 1] + _horizontalSpacing;
    }
    final rowHeights = _rowHeights(columnWidths, (child, spanWidth) {
      child.layout(BoxConstraints(maxWidth: spanWidth), parentUsesSize: true);
      return child.size.height;
    });

    final rowOffsets = List<double>.filled(_rows, 0);
    for (var r = 1; r < _rows; r++) {
      rowOffsets[r] = rowOffsets[r - 1] + rowHeights[r - 1] + _verticalSpacing;
    }

    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _SpanningTableParentData;
      final spanWidth = _spanWidth(data, columnWidths);
      final spanHeight = _spanHeight(data, rowHeights);
      child.layout(
        BoxConstraints.tightFor(width: spanWidth, height: spanHeight),
        parentUsesSize: true,
      );
      final x = columnOffsets[data.column];
      data.offset = Offset(
        _textDirection == TextDirection.rtl ? width - x - spanWidth : x,
        rowOffsets[data.row],
      );
      child = data.nextSibling;
    }

    size = constraints.constrain(Size(width, _gridHeight(rowHeights)));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
