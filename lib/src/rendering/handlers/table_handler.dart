import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../../css/css_length.dart';
import '../../css/html_style.dart';
import '../element_handler.dart';
import '../html_build_result.dart';
import '../html_render_context.dart';
import '../layout/percent_height.dart';
import 'handler_utils.dart';

/// Renders tables.
///
/// "Regular" tables (every row has the same number of cells and no
/// `colspan`/`rowspan`) use Flutter's [Table], which gives proper column-width
/// sharing across rows, per-row backgrounds and content-driven sizing. Tables
/// with spans or ragged rows fall back to a [Column] of [Row]s (best-effort).
///
/// Row groups (`thead`/`tbody`/`tfoot`) are traversed transparently.
class TableHandler extends HtmlElementHandler {
  const TableHandler();

  @override
  Set<String> get tags => const {
    'table',
    'thead',
    'tbody',
    'tfoot',
    'tr',
    'td',
    'th',
    'caption',
    'colgroup',
    'col',
  };

  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    switch ((element.localName ?? '').toLowerCase()) {
      case 'table':
        // An inline-level table (`display:inline-table`/`inline-block`) flows
        // in line with its siblings — e.g. a row of social-icon tables that
        // must sit horizontally, not stack. Emit it as an inline span. But a
        // `width:100%` inline-block table is meant to fill its container (e.g. a
        // full-width divider rule), so keep it block-level.
        final w = context.style.width;
        final fillsWidth =
            w != null && w.unit == CssLengthUnit.percent && w.value >= 100;
        final align = (element.attributes['align'] ?? '').toLowerCase();
        final legacyAlignSide = align == 'left' || align == 'right'
            ? align
            : null;
        final legacyPercentColumn =
            w != null &&
            w.unit == CssLengthUnit.percent &&
            w.value > 0 &&
            w.value < 100 &&
            legacyAlignSide != null;
        // Responsive email CSS commonly leaves float:left/right in place but
        // switches `.es-left/.es-right` to width:100%!important. At that point
        // the table is no longer a desktop float column: render it as a block so
        // consecutive two-item tables stack into the intended mobile 2x2 grid.
        final cssFloating = context.style.float != null && !fillsWidth;
        // Legacy email templates often use sibling
        // `<table align="left/right" width="auto">` blocks as floats. Keep
        // treating full-width responsive overrides as normal blocks, but let
        // auto/fixed-width align tables participate in the existing float row
        // flow.
        final legacyAlignFloating = legacyAlignSide != null && !fillsWidth;
        final floatSide = cssFloating
            ? context.style.float
            : legacyAlignFloating
            ? legacyAlignSide
            : null;
        final inline =
            !fillsWidth &&
            (context.style.display == CssDisplay.inlineBlock ||
                context.style.display == CssDisplay.inline);
        final table = _buildTable(
          element,
          context,
          inline: inline || cssFloating,
          percentWidthAllocated: legacyPercentColumn,
          forceShrinkToFit: legacyAlignFloating && (w == null || w.isAuto),
        );
        // Email templates commonly build a four-item desktop menu as two
        // sibling tables floated left/right, each containing two cells. Treat
        // consecutive floated tables as half-width columns so they share one
        // row; responsive CSS can set float:none to stack them on mobile.
        if (floatSide != null) {
          return [
            ColumnResult(
              table,
              legacyPercentColumn
                  ? w.value
                  : _floatColumnPercent(element, context),
              float: floatSide,
            ),
          ];
        }
        return inline
            ? [
                InlineResult(
                  WidgetSpan(
                    alignment: context.style.resolvedFontSize <= 0
                        ? PlaceholderAlignment.bottom
                        : PlaceholderAlignment.middle,
                    child: table,
                  ),
                ),
              ]
            : [BlockResult(table)];
      case 'tr':
        final parent = element.parent;
        return [
          BlockResult(
            _buildRowFallback(
              element,
              context,
              _cellPaddingFor(parent),
              context.style.textDirection == TextDirection.rtl,
              parent == null
                  ? (h: 0.0, v: 0.0)
                  : _cellSpacingFor(parent, context),
              const [],
            ),
          ),
        ];
      case 'td':
      case 'th':
      case 'caption':
        return [
          BlockResult(
            context.builder.decorate(
              _cellContent(element, context),
              context.style,
            ),
          ),
        ];
      default:
        // thead/tbody/tfoot/colgroup: transparent passthrough.
        return context.buildChildren(element);
    }
  }

  Widget _buildTable(
    dom.Element table,
    HtmlRenderContext context, {
    bool inline = false,
    bool percentWidthAllocated = false,
    bool forceShrinkToFit = false,
  }) {
    final allRows = _rowsOf(table, context);
    if (allRows.isEmpty) return const SizedBox.shrink();

    // Resolve every row/cell once.
    final rows = <dom.Element>[];
    final rowData = <_RowData>[];
    // `dir="rtl"`/`direction:rtl` lays columns out right-to-left.
    final rtl = context.style.textDirection == TextDirection.rtl;
    for (final tr in allRows) {
      final rowCtx = context.builder.contextForDescendant(tr, context);
      // Rows are consumed directly by the table renderer rather than through
      // HtmlTreeBuilder._buildNode, so apply display:none here as well.
      // Responsive email templates commonly keep separate desktop/mobile rows
      // and toggle them in @media rules; rendering a hidden row duplicates the
      // whole block.
      if (rowCtx.style.display == CssDisplay.none) continue;
      rows.add(tr);
      final cellEls = _cellsOf(tr, context);
      final cells = [
        for (final cellEl in cellEls)
          _CellData(
            element: cellEl,
            ctx: context.builder.contextForDescendant(cellEl, rowCtx),
          ),
      ];
      rowData.add(_RowData(rowCtx, cells));
    }
    if (rows.isEmpty) return const SizedBox.shrink();

    final columns = rowData.fold<int>(
      0,
      (m, r) => r.cells.length > m ? r.cells.length : m,
    );
    final colSpecs = _colgroupSpecs(table, columns, context);
    final regular =
        columns > 0 &&
        rowData.every((r) => r.cells.length == columns) &&
        rowData.every((r) => r.cells.every((c) => !c.hasSpan));

    // A responsive email stacks columns on mobile by making every cell a
    // full-width block (`th{display:inline-block;width:100%}` under @media).
    // Such rows can't be a grid — render them as a vertical stack (fallback).
    final hasStack = rowData.any(_rowStacks);
    // `display:inline-block` cells leave the table-column grid and wrap like
    // ordinary inline boxes. Email templates use this for responsive card
    // rows (fixed cards become 3+1; width:50% cards become a 2x2 grid).
    final wrapsInlineCells =
        rowData.isNotEmpty && rowData.every(_rowWrapsInlineCells);

    // With cellspacing the cells are separate boxes with gaps between them, and
    // per-cell backgrounds must fill the row height — the Row-based path
    // (IntrinsicHeight + stretch) handles both; the native Table can't.
    final cellSpacing = _cellSpacingFor(table, context);
    // A widthless table is shrink-to-fit (sized to its content, not stretched to
    // fill) when it's centered via align="center"/margin:0 auto, or when it's an
    // inline-level table (`display:inline-block`) — e.g. a centered row of fixed
    // icons that must cluster, not spread across the full width.
    final parentTag = (table.parent?.localName ?? '').toLowerCase();
    final parentCellAlign = parentTag == 'td' || parentTag == 'th'
        ? (table.parent?.attributes['align'] ?? '').toLowerCase()
        : '';
    final tableAlign = (table.attributes['align'] ?? '').toLowerCase();
    final autoCenter =
        _isCenterAlign(tableAlign) ||
        _isCenterAlign(parentCellAlign) ||
        parentCellAlign == 'right' ||
        ((context.style.margin?.left?.isAuto ?? false) &&
            (context.style.margin?.right?.isAuto ?? false));
    final inlineLevel =
        context.style.display == CssDisplay.inlineBlock ||
        context.style.display == CssDisplay.inline;
    // `width="auto"` is shrink-to-fit, same as no width (e.g. a centered
    // `<table width="auto" style="margin:0 auto">` button row).
    final noWidth = context.style.width == null || context.style.width!.isAuto;
    final noMaxWidth =
        context.style.maxWidth == null || context.style.maxWidth!.isAuto;
    final shrinkWrappedButtonTable = _isShrinkWrappedButtonTable(rowData);
    final inlineBlockAnchorParent = _parentIsInlineBlockAnchor(table, context);
    final shrinkToFitButtonTable =
        shrinkWrappedButtonTable && inlineBlockAnchorParent;
    final shrinkToFitMaxWidth = shrinkToFitButtonTable
        ? _shrinkToFitMaxWidthPx(table, context)
        : null;
    final shrink =
        noWidth &&
        noMaxWidth &&
        (autoCenter ||
            inlineLevel ||
            forceShrinkToFit ||
            shrinkWrappedButtonTable);

    final native =
        regular &&
        cellSpacing.h == 0 &&
        cellSpacing.v == 0 &&
        !hasStack &&
        !wrapsInlineCells;
    // Flat auto-width rows (for example an icon followed by a label) keep
    // their natural column widths. Structural wrappers with nested tables
    // still need the containing width to resolve responsive descendants.
    final naturalAutoWidth =
        native &&
        noWidth &&
        noMaxWidth &&
        columns > 1 &&
        rowData.every(
          (row) => row.cells.every(
            (cell) => cell.element.querySelector('table') == null,
          ),
        );
    // For the native path, compute the column layout up front so we know whether
    // any column flexes (fills the table width) — that decides how the table's
    // own width is applied below.
    final parentInlineBlock = _parentIsAutoInlineBlock(table, context);
    final parentShrinkTable = _parentIsShrinkToFitTable(table, context);
    final layout = native
        ? _columnWidths(
            rowData,
            columns,
            context,
            colSpecs,
            shrink ||
                parentInlineBlock ||
                parentShrinkTable ||
                naturalAutoWidth,
            context.style.tableLayoutFixed ?? false,
            shrinkToFitButtonTable,
            shrinkToFitMaxWidth,
          )
        : null;
    final resolvedPercentHeight = native
        ? _resolvedStructuralPercentHeight(table, context, rowData)
        : null;
    final singleCellPercentHeight =
        native &&
        resolvedPercentHeight == null &&
        _hasSingleCellPercentHeightTable(rowData, context);
    final hasPercentSpacerRow =
        native && _hasSingleColumnPercentSpacerRow(rowData);
    final tableWidthAttribute = table.attributes['width']?.trim();
    final fullWidthTable =
        context.style.width?.unit == CssLengthUnit.percent ||
        tableWidthAttribute?.endsWith('%') == true;
    final singleNestedTableWrapper =
        native &&
        !inline &&
        !shrink &&
        fullWidthTable &&
        resolvedPercentHeight == null &&
        !singleCellPercentHeight &&
        !hasPercentSpacerRow &&
        rowData.length == 1 &&
        rowData.single.cells.length == 1 &&
        rowData.single.cells.single.element.querySelector('table') != null;
    var content = hasStack
        ? _buildFallback(table, context, rows, rtl, cellSpacing)
        : wrapsInlineCells
        ? _buildInlineCellWrap(
            table,
            rowData,
            context,
            cellSpacing,
            _cellPaddingFor(table),
          )
        : singleCellPercentHeight
        ? _buildSingleCellPercentHeightTable(
            rowData.single,
            context,
            _cellPaddingFor(table),
          )
        : hasPercentSpacerRow
        ? _buildSingleColumnPercentSpacerTable(
            rowData,
            context,
            _cellPaddingFor(table),
          )
        : singleNestedTableWrapper
        ? _buildSingleNestedTableWrapper(
            rowData.single,
            context,
            _cellPaddingFor(table),
          )
        : native
        ? _buildNativeTable(
            table,
            context,
            rowData,
            columns,
            layout!.widths,
            resolvedPercentHeight,
          )
        : _buildFallback(table, context, rows, rtl, cellSpacing);

    // A percentage-width table sizes its actual grid to the containing block,
    // not just the decoration painted around it. Without this, an image-only
    // single column stays at its intrinsic width (e.g. 112px) inside a 200px
    // `width:100%;max-width:200px` profile background.
    final hasPercentWidth = context.style.width?.unit == CssLengthUnit.percent;
    if (hasPercentWidth && !inline && !shrink && !parentInlineBlock) {
      content = SizedBox(width: double.infinity, child: content);
    }

    // CSS borders belong to the table's outer box, outside its padding. Legacy
    // `border="N"` is different: it also requests the cell grid, so that stays
    // on Flutter's Table widget.
    final legacyGrid =
        (double.tryParse(table.attributes['border'] ?? '') ?? 0) > 0;
    var decorated = context.builder.decorate(
      content,
      _boxOnly(context.style, includeBorders: !legacyGrid),
    );

    // Apply the table's own CSS `width`. A table with a flex column must be
    // pinned to that width (a hard width that the flex fills, not the
    // container). A content-only table (all fixed/intrinsic columns) instead
    // treats the width as a floor and grows past it to fit content + padding —
    // e.g. a `width:20px` icon table whose 20px image + padding need 30px.
    final fixedWidth = _tableFixedWidthPx(context);
    if (fixedWidth != null && !inline) {
      context.builder.noteFixedWidth(fixedWidth);
    }
    if (fixedWidth != null && fixedWidth.isFinite && !inline) {
      final hasFlex = layout?.hasFlex ?? true; // fallback path: treat as fixed
      final minWidth = context.style.minWidth;
      decorated = minWidth?.unit == CssLengthUnit.percent && minWidth!.value > 0
          ? _TablePercentMinWidth(
              preferredWidth: fixedWidth,
              minimumFactor: minWidth.value / 100,
              child: decorated,
            )
          : hasFlex
          ? SizedBox(width: fixedWidth, child: decorated)
          : ConstrainedBox(
              constraints: BoxConstraints(minWidth: fixedWidth),
              child: decorated,
            );
    }

    // Position the table box. A widthless shrink table or a fixed-width table
    // both need an Align so the parent block flow's `stretch` doesn't force the
    // table to full width; the alignment follows align/margin/text-align. An
    // inline-level table is content-sized inside a WidgetSpan and must NOT get a
    // full-width Align (it would grab the whole line).
    // A cell align attribute positions a fixed-width child table but must not
    // become inherited text-align for that table's own cells.
    final centered =
        autoCenter ||
        context.style.textAlign == TextAlign.center ||
        _isCenterAlign(parentCellAlign);
    // Percentage-width tables need the parent's full offered width as their
    // containing block. A nested table often receives loose constraints, so
    // establish that block first, then size the painted table to its authored
    // fraction. Previously every percentage (including mobile CTA width:50%)
    // was treated as 100%.
    final percentWidth = context.style.width?.unit == CssLengthUnit.percent
        ? context.style.width!.value / 100
        : null;
    if (percentWidth != null &&
        !inline &&
        !shrink &&
        !parentInlineBlock &&
        fixedWidth == null) {
      final fraction = percentWidthAllocated
          ? 1.0
          : percentWidth.clamp(0.0, 1.0);
      final autoMargins =
          (context.style.margin?.left?.isAuto ?? false) &&
          (context.style.margin?.right?.isAuto ?? false);
      final alignment =
          _isCenterAlign(tableAlign) ||
              _isCenterAlign(parentCellAlign) ||
              autoMargins
          ? Alignment.topCenter
          : tableAlign == 'right' || parentCellAlign == 'right'
          ? Alignment.topRight
          : Alignment.topLeft;
      decorated = SizedBox(
        width: double.infinity,
        child: fraction >= 1
            ? decorated
            : FractionallySizedBox(
                widthFactor: fraction,
                alignment: alignment,
                child: decorated,
              ),
      );
    }

    final needsAlign =
        !inline && (shrink || fixedWidth != null || naturalAutoWidth);
    if (needsAlign) {
      final alignment =
          tableAlign == 'right' ||
              context.style.textAlign == TextAlign.right ||
              parentCellAlign == 'right'
          ? Alignment.topRight
          : centered
          ? Alignment.topCenter
          : Alignment.topLeft;
      // Fill the available width before aligning. A parent table cell gives
      // LOOSE constraints, where a bare Align shrinks to its child and can't
      // position it — so a `margin:0 auto` button row stays left. SizedBox
      // makes the box take the offered width (clamped where bounded), giving
      // the Align room to centre/right-align the content-sized table.
      decorated = SizedBox(
        width: double.infinity,
        child: Align(alignment: alignment, heightFactor: 1.0, child: decorated),
      );
    }
    return decorated;
  }

  bool _parentIsAutoInlineBlock(dom.Element table, HtmlRenderContext context) {
    final parent = table.parent;
    if (parent == null) return false;
    final parentTag = parent.localName;
    final tableWidth = context.style.width;
    if (parentTag != 'td' &&
        parentTag != 'th' &&
        tableWidth != null &&
        !tableWidth.isAuto) {
      return false;
    }
    final parentCtx = context.builder.contextFor(
      parent,
      context.childInherited,
    );
    final style = parentCtx.style;
    final inlineBlock = style.display == CssDisplay.inlineBlock;
    final width = style.width;
    return inlineBlock && (width == null || width.isAuto);
  }

  bool _parentIsShrinkToFitTable(dom.Element table, HtmlRenderContext context) {
    var parent = table.parent;
    while (parent != null && parent.localName != 'table') {
      parent = parent.parent;
    }
    if (parent == null) return false;
    final style = context.builder
        .contextFor(parent, context.childInherited)
        .style;
    if ((style.width != null && !style.width!.isAuto) ||
        (style.maxWidth != null && !style.maxWidth!.isAuto)) {
      return false;
    }
    final align = (parent.attributes['align'] ?? '').toLowerCase();
    return const {'center', 'left', 'right'}.contains(align) ||
        style.display == CssDisplay.inlineBlock ||
        style.display == CssDisplay.inline ||
        style.float != null ||
        ((style.margin?.left?.isAuto ?? false) &&
            (style.margin?.right?.isAuto ?? false));
  }

  bool _parentIsInlineBlockAnchor(
    dom.Element table,
    HtmlRenderContext context,
  ) {
    final parent = table.parent;
    if (parent == null || (parent.localName ?? '').toLowerCase() != 'a') {
      return false;
    }
    final parentCtx = context.builder.contextFor(
      parent,
      context.childInherited,
    );
    final style = parentCtx.style;
    final width = style.width;
    return style.display == CssDisplay.inlineBlock &&
        (width == null || width.isAuto);
  }

  double? _shrinkToFitMaxWidthPx(dom.Element table, HtmlRenderContext context) {
    final rootWidth = context.builder.availableWidth;
    if (!rootWidth.isFinite || rootWidth <= 0) return null;
    var width = rootWidth;

    final ancestors = <dom.Element>[];
    var ancestor = table.parent;
    while (ancestor != null) {
      ancestors.add(ancestor);
      ancestor = ancestor.parent;
    }

    for (final element in ancestors.reversed) {
      final ctx = context.builder.contextFor(element, context.childInherited);
      final style = ctx.style;
      final declared = _resolveLengthPx(
        style.width,
        style,
        context,
        percentBase: width,
      );
      if (declared != null && declared > 0) {
        width = declared;
      }
      final maxWidth = _resolveLengthPx(
        style.maxWidth,
        style,
        context,
        percentBase: width,
      );
      if (maxWidth != null && maxWidth > 0 && maxWidth < width) {
        width = maxWidth;
      }
      final padding = style.padding;
      if (padding != null) {
        final left = _resolveLengthPx(
          padding.left,
          style,
          context,
          percentBase: width,
        );
        final right = _resolveLengthPx(
          padding.right,
          style,
          context,
          percentBase: width,
        );
        width -= (left ?? 0) + (right ?? 0);
        if (width <= 0) return null;
      }
    }

    return width.isFinite && width > 0 ? width : null;
  }

  double? _resolveLengthPx(
    CssLength? length,
    HtmlStyle style,
    HtmlRenderContext context, {
    double? percentBase,
  }) {
    if (length == null || length.isAuto) return null;
    return length.resolve(
      fontSize: style.resolvedFontSize,
      rootFontSize: context.config.baseFontSize,
      percentBase: percentBase,
    );
  }

  bool _isCenterAlign(String align) => align == 'center' || align == 'middle';

  /// Width share for a floated email-layout table. Templates often pair
  /// unequal columns (e.g. 390px + 190px), so forcing every float to 50% makes
  /// the wider child overflow its half. Resolve the table's own width, or the
  /// first cell's width when the table is widthless, against the nearest
  /// definite ancestor width. Consecutive ColumnResults use these values as
  /// flex weights, preserving the authored ratio.
  double _floatColumnPercent(dom.Element table, HtmlRenderContext context) {
    double? absolute(CssLength? length, HtmlStyle style) {
      if (length == null ||
          length.isAuto ||
          length.unit == CssLengthUnit.percent) {
        return null;
      }
      return length.resolve(
        fontSize: style.resolvedFontSize,
        rootFontSize: context.config.baseFontSize,
      );
    }

    var own = absolute(context.style.width, context.style);
    if (own == null) {
      final rows = _rowsOf(table, context);
      if (rows.isNotEmpty) {
        final cells = _cellsOf(rows.first, context);
        var total = 0.0;
        var foundFixedCell = false;
        for (final cell in cells) {
          final cellCtx = context.builder.contextForDescendant(cell, context);
          final width = absolute(cellCtx.style.width, cellCtx.style);
          if (width != null) {
            total += width;
            foundFixedCell = true;
          }
        }
        if (foundFixedCell) own = total;
      }
    }
    if (own == null || own <= 0) return 50;

    double? basis;
    var innerInset = 0.0;
    var ancestor = table.parent;
    while (ancestor != null && basis == null) {
      final ancestorCtx = context.builder.contextFor(
        ancestor,
        context.childInherited,
      );
      final declared = absolute(ancestorCtx.style.width, ancestorCtx.style);
      if (declared != null) {
        basis = declared - innerInset;
        break;
      }
      final padding = ancestorCtx.style.padding;
      if (padding != null) {
        for (final edge in [padding.left, padding.right]) {
          final px = absolute(edge, ancestorCtx.style);
          if (px != null) innerInset += px;
        }
      }
      ancestor = ancestor.parent;
    }
    basis ??= context.builder.availableWidth.isFinite
        ? context.builder.availableWidth
        : null;
    return basis == null || basis <= 0 ? 50 : own / basis * 100;
  }

  /// The table's own `width` resolved to px when it is a fixed length (not a
  /// percent/auto); null otherwise.
  double? _tableFixedWidthPx(HtmlRenderContext context) {
    final w = context.style.width;
    if (w == null || w.isAuto || w.unit == CssLengthUnit.percent) return null;
    return w.resolve(
      fontSize: context.style.resolvedFontSize,
      rootFontSize: context.config.baseFontSize,
    );
  }

  // --- Native Table path ---

  Widget _buildNativeTable(
    dom.Element table,
    HtmlRenderContext context,
    List<_RowData> rowData,
    int columns,
    Map<int, TableColumnWidth> columnWidths,
    double? resolvedPercentHeight,
  ) {
    final cellPadding = _cellPaddingFor(table);
    final populatedRows = rowData.where((r) => r.cells.isNotEmpty).length;
    // A definite height also expands a single native row, so its backgrounds
    // and valign fill the table (including empty one-pixel divider cells).
    final tableHeight =
        resolvedPercentHeight ??
        (populatedRows == 1
            ? _resolveHeightPx(context.style.height, context)
            : null);
    final forcedRowHeight = tableHeight != null && populatedRows > 0
        ? tableHeight / populatedRows
        : null;

    final tableRows = <TableRow>[];
    for (final row in rowData) {
      final rowHeight = row.ctx.style.height;
      final children = <Widget>[
        for (final cell in row.cells)
          _nativeCell(cell, cellPadding, rowHeight, forcedRowHeight),
      ];
      final bg = row.ctx.style.backgroundColor;
      tableRows.add(
        TableRow(
          decoration: bg != null ? BoxDecoration(color: bg) : null,
          children: children,
        ),
      );
    }

    return Table(
      textDirection: context.style.textDirection,
      columnWidths: columnWidths,
      defaultColumnWidth: const IntrinsicColumnWidth(),
      border: (double.tryParse(table.attributes['border'] ?? '') ?? 0) > 0
          ? _tableBorder(context.style, drawInner: true)
          : null,
      children: tableRows,
    );
  }

  bool _hasSingleCellPercentHeightTable(
    List<_RowData> rowData,
    HtmlRenderContext context,
  ) {
    final height = context.style.height;
    return height != null &&
        height.unit == CssLengthUnit.percent &&
        height.value > 0 &&
        rowData.length == 1 &&
        rowData.single.cells.length == 1 &&
        _containsSingleColumnPercentSpacerTable(
          rowData.single.cells.single.element,
          context,
        );
  }

  bool _containsSingleColumnPercentSpacerTable(
    dom.Element element,
    HtmlRenderContext context,
  ) {
    for (final table in element.querySelectorAll('table')) {
      final tableCtx = context.builder.contextForDescendant(table, context);
      final rows = <_RowData>[];
      for (final tr in _rowsOf(table, tableCtx)) {
        final rowCtx = context.builder.contextForDescendant(tr, tableCtx);
        if (rowCtx.style.display == CssDisplay.none) continue;
        final cells = [
          for (final cellEl in _cellsOf(tr, tableCtx))
            _CellData(
              element: cellEl,
              ctx: context.builder.contextForDescendant(cellEl, rowCtx),
            ),
        ];
        rows.add(_RowData(rowCtx, cells));
      }
      if (_hasSingleColumnPercentSpacerRow(rows)) return true;
    }
    return false;
  }

  Widget _buildSingleCellPercentHeightTable(
    _RowData row,
    HtmlRenderContext context,
    EdgeInsets cellPadding,
  ) {
    final percent = context.style.height!.value / 100;
    final cell = row.cells.single;

    Widget cellWidget() {
      final style = cell.ctx.style;
      Widget content = _cellContent(cell.element, cell.ctx);
      content = _alignVertically(
        content,
        style.verticalAlign,
        style.effectiveTextAlign,
      );
      Widget decorated = context.builder.decorate(
        content,
        HtmlStyle(
          padding: style.padding ?? _toEdges(cellPadding),
          backgroundColor: style.backgroundColor,
          backgroundImage: style.backgroundImage,
          backgroundPositionX: style.backgroundPositionX,
          backgroundPositionY: style.backgroundPositionY,
          backgroundSize: style.backgroundSize,
          backgroundPosition: style.backgroundPosition,
          backgroundRepeat: style.backgroundRepeat,
          borders: style.borders,
          borderRadius: style.borderRadius,
          borderRadiusGeometry: style.borderRadiusGeometry,
          overflowHidden: style.overflowHidden,
        ),
      );
      decorated = _wrapCellLink(decorated, cell.element, cell.ctx);
      final bg = row.ctx.style.backgroundColor;
      return bg == null ? decorated : ColoredBox(color: bg, child: decorated);
    }

    return PercentHeightBox(percent: percent, child: cellWidget());
  }

  Widget _buildSingleNestedTableWrapper(
    _RowData row,
    HtmlRenderContext context,
    EdgeInsets cellPadding,
  ) {
    final cell = row.cells.single;
    final style = cell.ctx.style;
    Widget content = _cellContent(cell.element, cell.ctx);
    final minHeight = _resolveHeightPx(
      style.height ?? row.ctx.style.height,
      cell.ctx,
    );
    if (minHeight != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: _alignVertically(
          content,
          style.verticalAlign,
          style.effectiveTextAlign,
        ),
      );
    }
    Widget decorated = context.builder.decorate(
      content,
      HtmlStyle(
        padding: style.padding ?? _toEdges(cellPadding),
        backgroundColor: style.backgroundColor,
        backgroundImage: style.backgroundImage,
        backgroundPositionX: style.backgroundPositionX,
        backgroundPositionY: style.backgroundPositionY,
        backgroundSize: style.backgroundSize,
        backgroundPosition: style.backgroundPosition,
        backgroundRepeat: style.backgroundRepeat,
        borders: style.borders,
        borderRadius: style.borderRadius,
        borderRadiusGeometry: style.borderRadiusGeometry,
        overflowHidden: style.overflowHidden,
      ),
    );
    decorated = _wrapCellLink(decorated, cell.element, cell.ctx);
    final background = row.ctx.style.backgroundColor;
    if (background != null) {
      decorated = ColoredBox(color: background, child: decorated);
    }
    // Flutter's native Table measures a nested RenderTable through intrinsic
    // height before laying it out at its final width. For a long email body the
    // nested table can then become taller than that estimate and overflow the
    // sole outer row, clipping the footer. A one-cell wrapper has no column
    // geometry to preserve, so normal box layout adopts the actual height.
    return SizedBox(width: double.infinity, child: decorated);
  }

  bool _hasSingleColumnPercentSpacerRow(List<_RowData> rowData) {
    if (rowData.length < 2 || !rowData.every((row) => row.cells.length == 1)) {
      return false;
    }
    return rowData.any((row) {
      final cell = row.cells.single;
      final height = cell.ctx.style.height ?? row.ctx.style.height;
      if (height == null ||
          height.unit != CssLengthUnit.percent ||
          height.value < 100) {
        return false;
      }
      return cell.element.text.trim().isEmpty && cell.element.children.isEmpty;
    });
  }

  Widget _buildSingleColumnPercentSpacerTable(
    List<_RowData> rowData,
    HtmlRenderContext context,
    EdgeInsets cellPadding,
  ) {
    Widget rowWidget(_RowData row) {
      final cell = row.cells.single;
      final style = cell.ctx.style;
      Widget content = _cellContent(cell.element, cell.ctx);
      final minHeight = _resolveHeightPx(
        style.height ?? row.ctx.style.height,
        cell.ctx,
      );
      if (minHeight != null) {
        content = ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: _alignVertically(
            content,
            style.verticalAlign,
            style.effectiveTextAlign,
          ),
        );
      } else {
        content = _alignVertically(
          content,
          style.verticalAlign,
          style.effectiveTextAlign,
        );
      }
      Widget decorated = context.builder.decorate(
        content,
        HtmlStyle(
          padding: style.padding ?? _toEdges(cellPadding),
          backgroundColor: style.backgroundColor,
          backgroundImage: style.backgroundImage,
          backgroundPositionX: style.backgroundPositionX,
          backgroundPositionY: style.backgroundPositionY,
          backgroundSize: style.backgroundSize,
          backgroundPosition: style.backgroundPosition,
          backgroundRepeat: style.backgroundRepeat,
          borders: style.borders,
          borderRadius: style.borderRadius,
          borderRadiusGeometry: style.borderRadiusGeometry,
          overflowHidden: style.overflowHidden,
        ),
      );
      decorated = _wrapCellLink(decorated, cell.element, cell.ctx);
      final bg = row.ctx.style.backgroundColor;
      return bg == null ? decorated : ColoredBox(color: bg, child: decorated);
    }

    bool isSpacer(_RowData row) {
      final cell = row.cells.single;
      final height = cell.ctx.style.height ?? row.ctx.style.height;
      return height != null &&
          height.unit == CssLengthUnit.percent &&
          height.value >= 100 &&
          cell.element.text.trim().isEmpty &&
          cell.element.children.isEmpty;
    }

    return PercentSpacerColumn(
      spacers: [for (final row in rowData) isSpacer(row)],
      children: [for (final row in rowData) rowWidget(row)],
    );
  }

  bool _rowWrapsInlineCells(_RowData row) =>
      row.cells.isNotEmpty &&
      row.cells.every(
        (cell) => cell.ctx.style.display == CssDisplay.inlineBlock,
      );

  /// Renders rows whose cells were changed to inline-blocks by responsive CSS.
  /// Keeping them in Flutter's [Table] would normalize four `width:50%` cells
  /// to four 25% columns instead of wrapping them into two rows.
  Widget _buildInlineCellWrap(
    dom.Element table,
    List<_RowData> rows,
    HtmlRenderContext context,
    ({double h, double v}) spacing,
    EdgeInsets defaultPadding,
  ) {
    final parent = table.parent;
    final parentTag = (parent?.localName ?? '').toLowerCase();
    final parentCellAlign = parentTag == 'td' || parentTag == 'th'
        ? (parent?.attributes['align'] ?? '').toLowerCase()
        : '';
    final rowWidgets = <Widget>[];
    for (final row in rows) {
      // Legacy td/th align is kept as `cellTextAlign` and deliberately not
      // inherited into nested table cells. It still positions the nested
      // table's inline-block row, so use it when the table/row has no explicit
      // CSS text-align of its own.
      final textAlign =
          row.ctx.style.textAlign ??
          context.style.textAlign ??
          switch (parentCellAlign) {
            'center' || 'middle' => TextAlign.center,
            'right' => TextAlign.right,
            'left' => TextAlign.left,
            _ => null,
          };
      final alignment = switch (textAlign) {
        TextAlign.center => WrapAlignment.center,
        TextAlign.right || TextAlign.end => WrapAlignment.end,
        _ => WrapAlignment.start,
      };
      final imageOnlyInlineRow = row.cells.every(
        (cell) => cell.content.onlyImages,
      );
      final imageOnlyShrinkRow =
          imageOnlyInlineRow &&
          row.cells.every((cell) {
            final width = cell.ctx.style.width;
            final maxWidth = cell.ctx.style.maxWidth;
            return (width == null ||
                    width.isAuto ||
                    width.unit != CssLengthUnit.percent) &&
                (maxWidth == null || maxWidth.unit != CssLengthUnit.percent);
          });
      Widget wrapped;
      if (imageOnlyShrinkRow) {
        final rowWidget = Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          textDirection: context.style.textDirection,
          children: [
            for (final cell in row.cells)
              _inlineBlockCell(cell, defaultPadding),
          ],
        );
        final rowAlignment = switch (alignment) {
          WrapAlignment.center => Alignment.topCenter,
          WrapAlignment.end => Alignment.topRight,
          _ => Alignment.topLeft,
        };
        wrapped = Align(alignment: rowAlignment, child: rowWidget);
      } else {
        wrapped = Wrap(
          alignment: alignment,
          spacing: spacing.h,
          runSpacing: spacing.v,
          textDirection: context.style.textDirection,
          children: [
            for (final cell in row.cells)
              _inlineBlockCell(cell, defaultPadding),
          ],
        );
      }
      final background = row.ctx.style.backgroundColor;
      if (background != null) {
        wrapped = ColoredBox(color: background, child: wrapped);
      }
      rowWidgets.add(wrapped);
    }
    final content = rowWidgets.length == 1
        ? rowWidgets.single
        : Column(mainAxisSize: MainAxisSize.min, children: rowWidgets);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: spacing.h, vertical: spacing.v),
      child: content,
    );
  }

  Widget _inlineBlockCell(_CellData cell, EdgeInsets defaultPadding) {
    final style = cell.ctx.style;
    Widget content = _cellContent(cell.element, cell.ctx);
    if (_resolveHeightPx(style.height, cell.ctx) != null) {
      content = _alignVertically(
        content,
        style.verticalAlign,
        style.effectiveTextAlign,
      );
    }
    final boxStyle = style.padding == null
        ? style.merge(HtmlStyle(padding: _toEdges(defaultPadding)))
        : style;
    final decorated = cell.ctx.builder.decorate(
      content,
      boxStyle,
      inline: true,
    );
    return _wrapCellLink(decorated, cell.element, cell.ctx);
  }

  Widget _nativeCell(
    _CellData cell,
    EdgeInsets defaultPadding,
    CssLength? rowHeight,
    double? forcedMinHeight,
  ) {
    final style = cell.ctx.style;
    final effectiveVerticalAlign =
        style.display == CssDisplay.inlineBlock && cell.content.onlyImages
        ? 'top'
        : style.verticalAlign;
    Widget content = _cellContent(cell.element, cell.ctx);
    // A cell's own height, or the row's height, acts as a minimum so an empty
    // spacer cell (e.g. a `<tr height="24px">` divider with a background)
    // still occupies its height.
    final declaredHeight = _resolveHeightPx(
      style.height ?? rowHeight,
      cell.ctx,
    );
    if (declaredHeight != null || forcedMinHeight != null) {
      // TableCell.middle only aligns the cell box within the row. Its content
      // must also be aligned inside the cell's own minimum-height box.
      content = _alignVertically(
        content,
        effectiveVerticalAlign,
        style.effectiveTextAlign,
      );
    }
    if (declaredHeight != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(minHeight: declaredHeight),
        child: content,
      );
    }
    Widget decorated = cell.ctx.builder.decorate(
      content,
      HtmlStyle(
        // A normal table cell ignores margins. display:inline-block changes
        // that box model: its margins affect badge spacing and line wrapping.
        margin: style.display == CssDisplay.inlineBlock ? style.margin : null,
        padding: style.padding ?? _toEdges(defaultPadding),
        backgroundColor: style.backgroundColor,
        backgroundImage: style.backgroundImage,
        backgroundPositionX: style.backgroundPositionX,
        backgroundPositionY: style.backgroundPositionY,
        backgroundSize: style.backgroundSize,
        backgroundPosition: style.backgroundPosition,
        backgroundRepeat: style.backgroundRepeat,
        borders: style.borders,
        borderRadius: style.borderRadius,
        borderRadiusGeometry: style.borderRadiusGeometry,
        overflowHidden: style.overflowHidden,
      ),
    );
    if (forcedMinHeight != null) {
      // The table allocates the whole cell box, including its padding/border;
      // a cell's own declared height above still sizes its content box.
      decorated = ConstrainedBox(
        constraints: BoxConstraints(minHeight: forcedMinHeight),
        child: decorated,
      );
    }
    return TableCell(
      verticalAlignment: _verticalAlignment(effectiveVerticalAlign),
      child: _wrapCellLink(decorated, cell.element, cell.ctx),
    );
  }

  /// Resolves a row/cell height to absolute px, ignoring `auto`/`%`.
  double? _resolveHeightPx(CssLength? height, HtmlRenderContext ctx) {
    if (height == null ||
        height.isAuto ||
        height.unit == CssLengthUnit.percent) {
      return null;
    }
    return height.resolve(
      fontSize: ctx.style.resolvedFontSize,
      rootFontSize: ctx.config.baseFontSize,
    );
  }

  /// Resolves percentage height for structural table patterns whose basis can
  /// be inferred without a full CSS containing-block layout:
  ///
  /// * an empty decorated one-cell table uses the nearest definite ancestor;
  /// * a multi-row, one-column table uses a definite-height sibling in the
  ///   same row and divides that height among its populated rows.
  ///
  /// Other percentage-height tables remain intrinsic. Guessing a distant
  /// height for arbitrary content tables can constrain their Columns and clip
  /// later content.
  double? _resolvedStructuralPercentHeight(
    dom.Element table,
    HtmlRenderContext context,
    List<_RowData> rows,
  ) {
    final height = context.style.height;
    if (height == null || height.unit != CssLengthUnit.percent) return null;

    final cells = [for (final row in rows) ...row.cells];
    final isEmptyDecoratedCell =
        rows.length == 1 &&
        cells.length == 1 &&
        cells.single.ctx.style.backgroundColor != null &&
        cells.single.element.text.trim().isEmpty &&
        cells.single.element.children.isEmpty;

    final isSingleColumnDistribution =
        rows.length >= 2 &&
        rows.every((row) => row.cells.length == 1) &&
        height.value >= 100 &&
        table.text.trim().isNotEmpty;

    if (!isEmptyDecoratedCell && !isSingleColumnDistribution) return null;
    final basis = isSingleColumnDistribution
        ? _definiteSiblingHeight(table, context)
        : _nearestDefiniteAncestorHeight(table, context);
    return basis == null ? null : basis * height.value / 100;
  }

  double? _nearestDefiniteAncestorHeight(
    dom.Element element,
    HtmlRenderContext context,
  ) {
    var ancestor = element.parent;
    while (ancestor != null) {
      final style = context.builder
          .contextFor(ancestor, context.childInherited)
          .style;
      final height = style.height;
      if (height != null &&
          !height.isAuto &&
          height.unit != CssLengthUnit.percent) {
        return height.resolve(
          fontSize: style.resolvedFontSize,
          rootFontSize: context.config.baseFontSize,
        );
      }
      ancestor = ancestor.parent;
    }
    return null;
  }

  double? _definiteSiblingHeight(
    dom.Element element,
    HtmlRenderContext context,
  ) {
    dom.Element? branch = element;
    var ancestor = element.parent;
    while (ancestor != null) {
      if ((ancestor.localName ?? '').toLowerCase() == 'tr') {
        double? result;
        for (final sibling in ancestor.children) {
          if (sibling == branch) continue;
          for (final candidate in <dom.Element>[
            sibling,
            ...sibling.querySelectorAll('*'),
          ]) {
            final style = context.builder
                .contextFor(candidate, context.childInherited)
                .style;
            final height = style.height;
            if (height == null ||
                height.isAuto ||
                height.unit == CssLengthUnit.percent) {
              continue;
            }
            final px = height.resolve(
              fontSize: style.resolvedFontSize,
              rootFontSize: context.config.baseFontSize,
            );
            if (px != null && (result == null || px > result)) result = px;
          }
        }
        if (result != null) return result;
      }
      branch = ancestor;
      ancestor = ancestor.parent;
    }
    return null;
  }

  ({Map<int, TableColumnWidth> widths, bool hasFlex}) _columnWidths(
    List<_RowData> rowData,
    int columns,
    HtmlRenderContext context,
    List<_ColSpec> colSpecs,
    bool intrinsicColumns,
    bool fixedLayout,
    bool shrinkToFitColumns,
    double? shrinkToFitMaxWidth,
  ) {
    final widths = <int, TableColumnWidth>{};
    var percentTotal = 0.0;
    final remainderColumns = <int>[];
    // Whether any column flexes to fill the table width (vs sizing to content).
    // A flex column needs the table pinned to its CSS width; a content-only
    // table grows to fit its content instead.
    var hasFlex = false;
    // The table's own resolved px width caps any single column: a cell asking
    // for more than the whole table is a fill idiom. A cell whose px width
    // exceeds the table's *actual* container (e.g. a `width="1456"` wide-image
    // cell in a ~550px column) is clamped later by _FixedOrMinContentColumnWidth
    // against the real containerWidth.
    final tableWidth = _tableWidthPx(context);
    for (var col = 0; col < columns; col++) {
      if (shrinkToFitColumns) {
        widths[col] = _ShrinkToFitColumnWidth(shrinkToFitMaxWidth);
        continue;
      }
      double? fixedPx;
      // The horizontal padding of the cell that set [fixedPx]. CSS `width` is a
      // content-box size, so the column (border box) is width + padding.
      var fixedPad = 0.0;
      var imageFloor = 0.0;
      double? percent;
      var inlineBlock = false;
      var hasContent = false;
      var imageOnly = true;
      var hasImageOnlyCell = false;
      var hasFillImage = false;
      var shrinkContentOnly = true;
      var hasShrinkContentCell = false;
      var rightAlignedOnly = true;
      if (col < colSpecs.length) {
        final colSpec = colSpecs[col];
        if (colSpec.px > 0) fixedPx = colSpec.px;
        if (colSpec.percent > 0) percent = colSpec.percent;
      }
      for (final row in rowData) {
        final cell = row.cells[col];
        final cellHasContent = cell.content.hasContent;
        if (!hasContent && cellHasContent) {
          hasContent = true;
        }
        if (cellHasContent) {
          final onlyImages = cell.content.onlyImages;
          imageOnly = imageOnly && onlyImages;
          hasImageOnlyCell = hasImageOnlyCell || onlyImages;
          hasFillImage = hasFillImage || cell.content.hasFillImage;
          if (onlyImages && !cell.content.hasFillImage) {
            final minimum = _fixedImageMinimum(cell);
            if (minimum > imageFloor) imageFloor = minimum;
          }
          final shrinkContent = cell.content.onlyInlineBlock;
          shrinkContentOnly = shrinkContentOnly && shrinkContent;
          hasShrinkContentCell = hasShrinkContentCell || shrinkContent;
          rightAlignedOnly =
              rightAlignedOnly &&
              (cell.ctx.style.effectiveTextAlign == TextAlign.right ||
                  cell.ctx.style.effectiveTextAlign == TextAlign.end);
        }
        final cellStyle = cell.ctx.style;
        if (cellStyle.display == CssDisplay.inlineBlock) inlineBlock = true;
        final w = cellStyle.width;
        if (w == null || w.isAuto) {
          // A shrink-to-fit cell (inline-block, e.g. a mobile logo) sizes to
          // its content and sits at the start of its column.
          continue;
        }
        if (w.unit == CssLengthUnit.percent) {
          percent = (percent == null || w.value > percent) ? w.value : percent;
        } else {
          final px = w.resolve(
            fontSize: row.cells[col].ctx.style.resolvedFontSize,
            rootFontSize: context.config.baseFontSize,
          );
          if (px != null && (fixedPx == null || px > fixedPx)) {
            fixedPx = px;
            fixedPad = _horizontalPadding(cellStyle, cell.ctx);
          }
        }
      }
      if (fixedPx != null &&
          tableWidth != null &&
          tableWidth.isFinite &&
          fixedPx > tableWidth + 0.5) {
        // A cell asking for MORE than the whole table width is a fill idiom
        // (a `width:100%`/full-width cell in px, e.g. Google's 720px cell in a
        // 664px table); give it flex so fixed sibling gutters keep their width
        // and this column takes the rest (an empty such column still collapses).
        // A cell whose width merely equals the table is a genuine fixed cell —
        // it keeps MaxColumnWidth below so the column grows to fit content +
        // padding (e.g. a 20px icon in a 20px-wide cell with padding).
        if (hasContent) hasFlex = true;
        widths[col] = hasContent
            ? const FlexColumnWidth(1)
            : const IntrinsicColumnWidth();
      } else if (fixedPx != null) {
        // The specified width is a minimum; the column grows only to its
        // min-content (the widest unbreakable child: a word or an image), never
        // to max-content. So a fixed-width text cell keeps its width and wraps
        // (not "Amount Paid" letter-by-letter, nor a 775px content panel
        // ballooning to the unwrapped text width on a wide screen), while a
        // tiny icon cell still grows to fit its image + padding. The CSS width
        // is content-box, so the column floor is width + the cell's padding.
        final specified = fixedPx + fixedPad;
        widths[col] = _FixedOrMinContentColumnWidth(
          imageOnly && imageFloor > specified ? imageFloor : specified,
        );
      } else if (percent != null &&
          percent >= 100 &&
          inlineBlock &&
          imageOnly &&
          hasImageOnlyCell) {
        // Some responsive email frameworks apply `width:100%!important` and
        // `display:inline-block` to every `.small-12` cell. When only an icon
        // cell has that class (its text sibling does not), the row cannot stack
        // and the override would give almost the whole row to a 40px image.
        // Keep that image-only cell content-sized instead.
        widths[col] = const IntrinsicColumnWidth();
      } else if (percent != null) {
        hasFlex = true;
        percentTotal += percent;
        widths[col] = FlexColumnWidth(percent);
      } else if (fixedLayout) {
        // `table-layout: fixed`: columns share the table width equally and
        // ignore content (content wraps), so the table never grows past its
        // container — e.g. a `width:100%` table of long IDs.
        hasFlex = true;
        widths[col] = const FlexColumnWidth(1);
      } else if (shrinkContentOnly &&
          hasShrinkContentCell &&
          rightAlignedOnly &&
          !(imageOnly && hasImageOnlyCell) &&
          !intrinsicColumns) {
        // Flutter's max-intrinsic width for a WidgetSpan-based inline-block is
        // often the whole available cell width. Give CTA-only columns a small
        // flex share instead: they stay compact while remaining responsive.
        // A percentage sibling uses percentage-sized flex weights, however:
        // 100 versus 0.5 leaves an inline badge only a few pixels wide. In
        // that mixed case reserve its shrink-to-fit content before letting
        // the percentage column absorb the remaining width.
        final percentSibling = rowData.any(
          (row) => row.cells.any(
            (cell) =>
                cell.ctx.style.width?.unit == CssLengthUnit.percent &&
                cell.ctx.style.width!.value > 0,
          ),
        );
        if (percentSibling) {
          widths[col] = const _ShrinkToFitColumnWidth(null);
        } else {
          hasFlex = true;
          widths[col] = const FlexColumnWidth(0.5);
        }
      } else if (columns == 1 &&
          imageOnly &&
          hasImageOnlyCell &&
          hasFillImage &&
          !intrinsicColumns) {
        // A one-column image-only email section often relies on an inner
        // `img { width:100% }` to fill the section's fixed/percent table width.
        // IntrinsicColumnWidth probes that percentage image at zero width, so
        // the whole hero row disappears. Let the sole column consume the
        // table width; small icon-only columns (without a fill image) retain
        // their intrinsic sizing below.
        hasFlex = true;
        widths[col] = const FlexColumnWidth(1);
      } else if ((imageOnly && hasImageOnlyCell) ||
          inlineBlock ||
          intrinsicColumns) {
        // Shrink-to-fit: an inline-block cell, or a shrink-to-fit table, sizes
        // every such column to its content.
        widths[col] = intrinsicColumns && imageOnly && !hasFillImage
            ? const _PreferredImageColumnWidth()
            : const IntrinsicColumnWidth();
      } else if (!hasContent) {
        // An empty gutter/spacer column (no width, no content) must collapse to
        // its content (≈0) instead of claiming an equal flex share — otherwise
        // empty gutters flanking a centred content cell steal its width and push
        // it into a narrow off-centre box (Google's footer/disclaimer grid).
        widths[col] = const IntrinsicColumnWidth();
      } else {
        // Fill the remaining width, but never collapse below the column's
        // min-content (its widest word/image) so a neighbouring fixed column
        // can't squeeze it to nothing (wrapping text character by character).
        // The floor is min-content, NOT max-content: a `width:100%` cell holding
        // a wide image (a desktop logo) must fill its container and let the image
        // shrink to fit, not balloon the column to the image's natural width.
        hasFlex = true;
        remainderColumns.add(col);
        widths[col] = const MaxColumnWidth(
          FlexColumnWidth(1),
          _FixedOrMinContentColumnWidth(0),
        );
      }
    }
    if (percentTotal > 0 && percentTotal < 100 && remainderColumns.isNotEmpty) {
      final remainder = (100 - percentTotal) / remainderColumns.length;
      for (final col in remainderColumns) {
        widths[col] = MaxColumnWidth(
          FlexColumnWidth(remainder),
          const _FixedOrMinContentColumnWidth(0),
        );
      }
    }
    return (widths: widths, hasFlex: hasFlex);
  }

  // --- Row-based fallback (colspan / ragged tables) ---

  Widget _buildFallback(
    dom.Element table,
    HtmlRenderContext context,
    List<dom.Element> rows,
    bool rtl,
    ({double h, double v}) cellSpacing,
  ) {
    // Email overlay trick (no position:absolute available): a `rowspan` media
    // cell (e.g. a video thumbnail) plus a full-width `colspan` cell holding a
    // small image (a play icon) that browsers paint on top. Render it as a
    // Stack so the icon sits over the thumbnail instead of dropping to its own
    // row.
    final overlay = _buildMediaOverlay(rows, context);
    if (overlay != null) return overlay;
    if (rows.any(
      (row) => _cellsOf(row, context).any(
        (cell) => (int.tryParse(cell.attributes['rowspan'] ?? '1') ?? 1) > 1,
      ),
    )) {
      return _buildSpanningGrid(table, rows, context, cellSpacing);
    }

    final cellPadding = _cellPaddingFor(table);
    // Share column widths across rows (a width on any cell sizes its whole
    // column) so rows stay aligned even when some cells omit the width.
    var columns = _sharedColumnSpecs(table, rows, context);
    if (rtl) columns = columns.reversed.toList();

    final children = <Widget>[];
    for (final tr in rows) {
      if (cellSpacing.v > 0 && children.isNotEmpty) {
        children.add(SizedBox(height: cellSpacing.v));
      }
      children.add(
        _stacksTr(tr, context)
            ? _buildStackedRow(tr, context)
            : _buildRowFallback(
                tr,
                context,
                cellPadding,
                rtl,
                cellSpacing,
                columns,
              ),
      );
    }
    final fixedHeight = _resolveHeightPx(context.style.height, context);
    // A one-row fallback table with a definite height must give that minimum
    // to its row, while allowing taller content to expand the table.
    // Otherwise bottom-aligned percentage children stop at the tallest child
    // and leave unused space above the table's bottom border (email charts are
    // commonly built from exactly this pattern).
    final Widget content;
    if (children.length == 1 && fixedHeight != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: (fixedHeight - cellSpacing.v * 2).clamp(
            0.0,
            double.infinity,
          ),
        ),
        child: IntrinsicHeight(child: children.single),
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    }
    Widget result = content;
    // `border-spacing` also insets the outer cells from the table edge — this
    // is what pads a single-cell box (e.g. a metric tile with no cell padding,
    // spacing coming only from `border-spacing:30px 10px`).
    if (cellSpacing.h > 0 || cellSpacing.v > 0) {
      result = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: cellSpacing.h,
          vertical: cellSpacing.v,
        ),
        child: result,
      );
    }
    return result;
  }

  /// Detects the "media + overlay" table hack and renders it as a [Stack].
  ///
  /// The pattern: a cell that spans every row (`rowspan` == row count) holding
  /// an image — the thumbnail — and a full-width `colspan` cell holding another
  /// image — the overlay icon. Browsers paint the overlay on top of the
  /// thumbnail; our row-by-row fallback would instead drop it to its own row
  /// (the play icon ends up below/left of the preview). Returns null when the
  /// table isn't this shape, so normal tables are unaffected.
  Widget? _buildMediaOverlay(
    List<dom.Element> rows,
    HtmlRenderContext context,
  ) {
    if (rows.length < 2) return null;
    dom.Element? media;
    final overlays = <dom.Element>[];
    var sawSpanningOverlay = false;
    var hasOtherContent = false;
    for (final tr in rows) {
      for (final cell in _cellsOf(tr, context)) {
        final images = cell.getElementsByTagName('img');
        if (images.isEmpty) {
          if (cell.text.trim().isNotEmpty || cell.children.isNotEmpty) {
            hasOtherContent = true;
          }
          continue;
        }
        final rs = int.tryParse(cell.attributes['rowspan'] ?? '1') ?? 1;
        final cs = int.tryParse(cell.attributes['colspan'] ?? '1') ?? 1;
        if (media == null && rs >= rows.length) {
          media = cell; // spans the whole table — the base image
        } else if (cs >= 2) {
          overlays.add(cell);
          sawSpanningOverlay = true; // overlaps the media column
        } else {
          hasOtherContent = true;
        }
      }
    }
    if (media == null ||
        overlays.length != 1 ||
        !sawSpanningOverlay ||
        hasOtherContent) {
      return null;
    }

    Widget render(dom.Element cell) {
      final cellCtx = context.builder.contextForDescendant(cell, context);
      return _wrapCellLink(
        context.builder.decorate(_cellContent(cell, cellCtx), cellCtx.style),
        cell,
        cellCtx,
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        render(media),
        for (final ov in overlays)
          Align(alignment: Alignment.center, child: render(ov)),
      ],
    );
  }

  Widget _buildSpanningGrid(
    dom.Element table,
    List<dom.Element> rows,
    HtmlRenderContext context,
    ({double h, double v}) spacing,
  ) {
    final occupied = <List<bool>>[];
    final cells = <Widget>[];
    final columnHints = <int, _ColSpec>{};
    var columnCount = 0;

    void ensure(int row, int columns) {
      while (occupied.length <= row) {
        occupied.add(<bool>[]);
      }
      while (occupied[row].length < columns) {
        occupied[row].add(false);
      }
    }

    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      ensure(rowIndex, columnCount);
      var column = 0;
      final rowCtx = context.builder.contextForDescendant(
        rows[rowIndex],
        context,
      );
      for (final element in _cellsOf(rows[rowIndex], context)) {
        while (column < occupied[rowIndex].length &&
            occupied[rowIndex][column]) {
          column++;
        }
        final rowSpan =
            (int.tryParse(element.attributes['rowspan'] ?? '1') ?? 1).clamp(
              1,
              rows.length - rowIndex,
            );
        final colSpan =
            (int.tryParse(element.attributes['colspan'] ?? '1') ?? 1).clamp(
              1,
              1000,
            );
        for (var r = rowIndex; r < rowIndex + rowSpan; r++) {
          ensure(r, column + colSpan);
          for (var c = column; c < column + colSpan; c++) {
            occupied[r][c] = true;
          }
        }
        if (column + colSpan > columnCount) columnCount = column + colSpan;

        final cellCtx = context.builder.contextForDescendant(element, rowCtx);
        final style = cellCtx.style;
        // Rowspans change the logical column index of later rows. Collect
        // hints here, after placing each cell, rather than indexing raw cells.
        if (colSpan == 1) {
          final hint = columnHints.putIfAbsent(column, _ColSpec.new);
          final width = style.width;
          if (width?.unit == CssLengthUnit.percent) {
            if (width!.value > hint.percent) hint.percent = width.value;
          } else if (width != null && !width.isAuto) {
            final px = width.resolve(
              fontSize: style.resolvedFontSize,
              rootFontSize: context.config.baseFontSize,
            );
            final borderBox = (px ?? 0) + _horizontalPadding(style, cellCtx);
            if (borderBox > hint.px) hint.px = borderBox;
          }
        }
        final decorated = context.builder.decorate(
          _alignVertically(
            _cellContent(element, cellCtx),
            style.verticalAlign,
            style.effectiveTextAlign,
          ),
          HtmlStyle(
            padding: style.padding ?? _toEdges(_cellPaddingFor(table)),
            backgroundColor:
                style.backgroundColor ?? rowCtx.style.backgroundColor,
            backgroundImage: style.backgroundImage,
            backgroundPositionX: style.backgroundPositionX,
            backgroundPositionY: style.backgroundPositionY,
            backgroundSize: style.backgroundSize,
            backgroundPosition: style.backgroundPosition,
            backgroundRepeat: style.backgroundRepeat,
            borders: style.borders,
            borderRadius: style.borderRadius,
            borderRadiusGeometry: style.borderRadiusGeometry,
            overflowHidden: style.overflowHidden,
            visibilityHidden: style.visibilityHidden,
          ),
        );
        cells.add(
          _SpanCell(
            row: rowIndex,
            column: column,
            rowSpan: rowSpan,
            columnSpan: colSpan,
            child: _wrapCellLink(decorated, element, cellCtx),
          ),
        );
        column += colSpan;
      }
    }

    if (columnCount == 0) return const SizedBox.shrink();
    final columnWidths = _colgroupSpecs(table, columnCount, context);
    for (final entry in columnHints.entries) {
      final spec = columnWidths[entry.key];
      if (spec.px == 0 && spec.percent == 0) {
        columnWidths[entry.key] = entry.value;
      }
    }
    return _SpanningTable(
      textDirection:
          context.style.textDirection ??
          Directionality.of(context.buildContext),
      rows: rows.length,
      columns: columnCount,
      columnWidths: columnWidths,
      horizontalSpacing: spacing.h,
      verticalSpacing: spacing.v,
      children: cells,
    );
  }

  /// Renders a "stacked" row: every cell is a full-width block, one under the
  /// other (responsive `th{display:inline-block;width:100%}` on mobile).
  Widget _buildStackedRow(dom.Element tr, HtmlRenderContext context) {
    final children = <Widget>[];
    for (final cellEl in _cellsOf(tr, context)) {
      final cellCtx = context.builder.contextForDescendant(cellEl, context);
      final style = cellCtx.style;
      Widget content = _cellContent(cellEl, cellCtx);
      if (_fullWidthBlock(style)) {
        content = SizedBox(width: double.infinity, child: content);
      }
      children.add(
        _wrapCellLink(
          context.builder.decorate(content, style),
          cellEl,
          cellCtx,
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// Whether a `<tr>` should stack (≥2 cells, each a full-width block/inline-
  /// block) — the responsive column-stacking pattern.
  bool _stacksTr(dom.Element tr, HtmlRenderContext context) {
    final cells = _cellsOf(tr, context);
    if (cells.length < 2) return false;
    return cells.every(
      (cellEl) => _fullWidthBlock(
        context.builder.contextForDescendant(cellEl, context).style,
      ),
    );
  }

  static bool _fullWidthBlock(HtmlStyle s) {
    final w = s.width;
    final full = w != null && w.unit == CssLengthUnit.percent && w.value >= 100;
    final blockish =
        s.display == CssDisplay.block || s.display == CssDisplay.inlineBlock;
    return full && blockish;
  }

  bool _rowStacks(_RowData row) {
    if (row.cells.length < 2) return false;
    return row.cells.every((c) => _fullWidthBlock(c.ctx.style));
  }

  Widget _buildRowFallback(
    dom.Element tr,
    HtmlRenderContext context,
    EdgeInsets cellPadding,
    bool rtl,
    ({double h, double v}) cellSpacing,
    List<_ColSpec> columns,
  ) {
    final rowCtx = context.builder.contextForDescendant(tr, context);
    final cells = <Widget>[];
    var cellEls = _cellsOf(tr, context);
    if (rtl) cellEls = cellEls.reversed.toList();
    final singleCellRow = cellEls.length == 1;
    var hasFlexible = false;
    for (var i = 0; i < cellEls.length; i++) {
      final cellEl = cellEls[i];
      if (cellSpacing.h > 0 && cells.isNotEmpty) {
        cells.add(SizedBox(width: cellSpacing.h));
      }
      final cellCtx = context.builder.contextForDescendant(cellEl, rowCtx);
      final style = cellCtx.style;
      Widget content = SizedBox(
        width: double.infinity,
        child: _cellContent(cellEl, cellCtx),
      );
      // A cell's (or row's) explicit height is a minimum — vital for the spacer
      // cells email layouts use for vertical rhythm (`<td height="48">&nbsp;`
      // with font-size:1px). The native path does this in [_nativeCell]; mirror
      // it here so colspan/ragged tables keep their spacing too.
      final minHeight = _resolveHeightPx(
        style.height ?? rowCtx.style.height,
        cellCtx,
      );
      if (minHeight != null) {
        content = ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: _alignVertically(
            content,
            style.verticalAlign,
            style.effectiveTextAlign,
          ),
        );
      } else {
        content = _alignVertically(
          content,
          style.verticalAlign,
          style.effectiveTextAlign,
        );
      }
      final decorated = context.builder.decorate(
        content,
        HtmlStyle(
          padding: style.padding ?? _toEdges(cellPadding),
          backgroundColor: style.backgroundColor,
          backgroundImage: style.backgroundImage,
          backgroundPositionX: style.backgroundPositionX,
          backgroundPositionY: style.backgroundPositionY,
          backgroundSize: style.backgroundSize,
          backgroundPosition: style.backgroundPosition,
          backgroundRepeat: style.backgroundRepeat,
          borders: style.borders,
          borderRadius: style.borderRadius,
          borderRadiusGeometry: style.borderRadiusGeometry,
          overflowHidden: style.overflowHidden,
        ),
      );
      final colspan = int.tryParse(cellEl.attributes['colspan'] ?? '1') ?? 1;
      final rowspan = int.tryParse(cellEl.attributes['rowspan'] ?? '1') ?? 1;
      // A spanning cell covers multiple columns; a single shared-column spec
      // would incorrectly shrink it to just the first column. Let the fallback
      // flex it across the row instead.
      final spec = colspan == 1 && rowspan == 1 && i < columns.length
          ? columns[i]
          : null;
      // A lone spanning cell occupies the entire row. Its authored width is
      // a table sizing hint, not a cap on its final content box.
      final fullRowSpan = singleCellRow && colspan > 1;
      final fixed = !fullRowSpan && _cellIsFixed(cellCtx, spec);
      if (!fixed) hasFlexible = true;
      final wrapped = _wrapCellLink(decorated, cellEl, cellCtx);
      cells.add(
        singleCellRow && !fixed
            ? SizedBox(width: double.infinity, child: wrapped)
            : _sizedCell(cellEl, cellCtx, wrapped, spec),
      );
    }
    if (cells.isEmpty) return const SizedBox.shrink();

    Widget row;
    if (singleCellRow && hasFlexible) {
      // A one-cell row has no horizontal alignment problem to solve. Putting
      // it in IntrinsicHeight + Row first estimates a deeply nested email
      // table, then constrains its real layout to that stale estimate. Let the
      // cell report its actual height directly so long footers are not clipped.
      row = cells.single;
    } else if (hasFlexible) {
      // Flexible cells absorb the remaining width; the row fills its container.
      row = IntrinsicHeight(
        child: Row(
          textDirection: TextDirection.ltr, // cells are already ordered above
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: cells,
        ),
      );
    } else {
      // All cells are fixed-width and can't shrink, so widths summing slightly
      // over the available space (e.g. cells totalling the table width inside a
      // 1px-bordered parent) would overflow. Scale the row down to fit instead
      // of overflowing; when it already fits, scaleDown leaves it untouched.
      row = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: IntrinsicHeight(
          child: Row(
            textDirection: TextDirection.ltr, // cells are already ordered above
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }
    final bg = rowCtx.style.backgroundColor;
    if (bg != null) row = ColoredBox(color: bg, child: row);
    return row;
  }

  /// Whether [_sizedCell] will give this cell a fixed (non-shrinkable) width.
  bool _cellIsFixed(HtmlRenderContext cellCtx, _ColSpec? column) {
    if (column != null) return column.px > 0 || column.intrinsic;
    final w = cellCtx.style.width;
    return w != null && !w.isAuto && w.unit != CssLengthUnit.percent;
  }

  List<_ColSpec> _colgroupSpecs(
    dom.Element table,
    int columns,
    HtmlRenderContext context,
  ) {
    if (columns <= 0) return const [];
    final specs = List.generate(columns, (_) => _ColSpec());
    var index = 0;
    for (final group in table.children.where(
      (e) => (e.localName ?? '').toLowerCase() == 'colgroup',
    )) {
      for (final col in group.children.where(
        (e) => (e.localName ?? '').toLowerCase() == 'col',
      )) {
        if (index >= columns) return specs;
        final span = (int.tryParse(col.attributes['span'] ?? '1') ?? 1).clamp(
          1,
          columns - index,
        );
        final colCtx = context.builder.contextForDescendant(col, context);
        final width = colCtx.style.width ?? _legacyWidth(col);
        if (width != null && !width.isAuto) {
          if (width.unit == CssLengthUnit.percent) {
            for (var i = 0; i < span; i++) {
              if (width.value > specs[index + i].percent) {
                specs[index + i].percent = width.value;
              }
            }
          } else {
            final px = width.resolve(
              fontSize: colCtx.style.resolvedFontSize,
              rootFontSize: context.config.baseFontSize,
            );
            if (px != null) {
              for (var i = 0; i < span; i++) {
                if (px > specs[index + i].px) specs[index + i].px = px;
              }
            }
          }
        }
        index += span;
      }
    }
    return specs;
  }

  CssLength? _legacyWidth(dom.Element element) {
    final raw = element.attributes['width']?.trim();
    if (raw == null || raw.isEmpty) return null;
    return CssLength.tryParse(raw) ?? CssLength.tryParse('${raw}px');
  }

  /// Computes a shared width per column from all rows. Returns an empty list
  /// when the table is ragged or uses col/rowspan (then cells size themselves).
  List<_ColSpec> _sharedColumnSpecs(
    dom.Element table,
    List<dom.Element> rows,
    HtmlRenderContext context,
  ) {
    final regularRows = <List<dom.Element>>[];
    for (final tr in rows) {
      final cells = _cellsOf(tr, context);
      // A spanning row (commonly an empty full-width spacer) does not describe
      // the ordinary column grid. Ignore it when deriving shared widths instead
      // of making every non-spanning cell independently flexible.
      final hasSpan = cells.any(
        (c) =>
            (int.tryParse(c.attributes['colspan'] ?? '1') ?? 1) != 1 ||
            (int.tryParse(c.attributes['rowspan'] ?? '1') ?? 1) != 1,
      );
      if (!hasSpan && cells.isNotEmpty) regularRows.add(cells);
    }
    if (regularRows.isEmpty) return const [];
    final columns = regularRows.first.length;
    if (columns == 0 || regularRows.any((cells) => cells.length != columns)) {
      return const [];
    }

    final specs = _colgroupSpecs(table, columns, context);
    for (var j = 0; j < columns; j++) {
      specs[j].intrinsic = regularRows.every((cells) {
        final cellCtx = context.builder.contextForDescendant(cells[j], context);
        final facts = _CellContentFacts.inspect(cells[j], cellCtx);
        return facts.onlyImages && !facts.hasFillImage;
      });
    }
    for (final cs in regularRows) {
      for (var j = 0; j < cs.length; j++) {
        final cellCtx = context.builder.contextForDescendant(cs[j], context);
        final style = cellCtx.style;
        final w = style.width;
        if (w == null || w.isAuto) continue;
        if (w.unit == CssLengthUnit.percent) {
          if (w.value > specs[j].percent) specs[j].percent = w.value;
        } else {
          final px = w.resolve(
            fontSize: style.resolvedFontSize,
            rootFontSize: context.config.baseFontSize,
          );
          if (px != null) {
            // Store the shared border-box width once. All rows then start their
            // next column at the same x even if a later cell omits width or has
            // different padding.
            final borderBox = px + _horizontalPadding(style, cellCtx);
            if (borderBox > specs[j].px) specs[j].px = borderBox;
          }
        }
      }
    }
    return specs;
  }

  Widget _sizedCell(
    dom.Element cell,
    HtmlRenderContext cellCtx,
    Widget child, [
    _ColSpec? column,
  ]) {
    late final emptyContent = !_CellContentFacts.inspect(
      cell,
      cellCtx,
    ).hasContent;
    // Prefer the shared column width so rows align (a fixed px column is sized
    // identically in every row, even where a cell omits its own width).
    if (column != null) {
      if (column.px > 0) {
        return SizedBox(width: column.px, child: child);
      }
      if (column.percent > 0) {
        return Expanded(
          flex: column.percent.round().clamp(1, 1000),
          child: child,
        );
      }
      if (column.intrinsic || emptyContent) {
        return IntrinsicWidth(child: child);
      }
      return Expanded(child: child);
    }
    final colspan = int.tryParse(cell.attributes['colspan'] ?? '1') ?? 1;
    final width = cellCtx.style.width;
    if (width != null && !width.isAuto && width.unit == CssLengthUnit.percent) {
      return Expanded(flex: width.value.round().clamp(1, 1000), child: child);
    }
    if (width != null && !width.isAuto) {
      // A fixed px width: bound it. (A `ConstrainedBox(minWidth:)` would leave
      // the max unbounded, and a non-flex child in a Row then gets infinite
      // width — which crashes any wrapping text inside the cell.)
      final px = width.resolve(
        fontSize: cellCtx.style.resolvedFontSize,
        rootFontSize: cellCtx.config.baseFontSize,
      );
      // Add the cell's padding: CSS `width` is content-box, so a padded
      // fixed-width cell's border box is width + padding (mirrors the native
      // path's _FixedOrMinContentColumnWidth).
      if (px != null) {
        return SizedBox(
          width: px + _horizontalPadding(cellCtx.style, cellCtx),
          child: child,
        );
      }
    }
    // Match the native table path: an un-sized empty gutter contributes only
    // its padding/border, not an equal share of the content column's width.
    if (emptyContent) return IntrinsicWidth(child: child);
    return Expanded(flex: colspan.clamp(1, 1000), child: child);
  }

  // --- Shared helpers ---

  /// Makes a cell tappable across its whole padded area when its sole content
  /// is a single `<a href>` link — an email "button" or social icon, where the
  /// visual box (the cell's background/padding/radius) is what the user aims at,
  /// but the link itself only wraps a small icon/label in the middle. Without
  /// this the dead padding ring around the icon swallows taps.
  Widget _wrapCellLink(Widget child, dom.Element cell, HtmlRenderContext ctx) {
    final onTap = ctx.config.onLinkTap;
    if (onTap == null) return child;
    final links = [
      for (final a in cell.getElementsByTagName('a'))
        if ((a.attributes['href'] ?? '').trim().isNotEmpty) a,
    ];
    if (links.length != 1) return child;
    final link = links.first;
    // All of the cell's text must live inside that link (an image-only icon has
    // none; a text button's label matches) — otherwise the cell mixes the link
    // with other content and the whole box shouldn't navigate.
    if (cell.text.trim() != link.text.trim()) return child;
    final href = link.attributes['href']!.trim();
    final attrs = attributesOf(link);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(href, attrs),
        child: child,
      ),
    );
  }

  /// The cell's left+right CSS padding in px (0 when it sets none).
  /// A fixed image is min-content for an explicitly sized icon column. The
  /// image render box itself reports zero min-content so responsive images may
  /// shrink; retain authored pixel widths here without expanding auto images.
  double _fixedImageMinimum(_CellData cell) {
    var minimum = 0.0;
    for (final image in cell.element.querySelectorAll('img')) {
      final ctx = cell.ctx.builder.contextForDescendant(image, cell.ctx);
      if (ctx.style.display == CssDisplay.none) continue;
      final width = ctx.style.width;
      if (width?.unit == CssLengthUnit.percent) continue;
      final px = width != null && !width.isAuto
          ? width.resolve(
              fontSize: ctx.style.resolvedFontSize,
              rootFontSize: ctx.config.baseFontSize,
            )
          : double.tryParse(image.attributes['width'] ?? '');
      if (px == null || px <= 0) continue;
      final margin = ctx.style.margin?.resolve(
        fontSize: ctx.style.resolvedFontSize,
        rootFontSize: ctx.config.baseFontSize,
      );
      final outer =
          px +
          (margin?.left ?? 0).clamp(0.0, double.infinity) +
          (margin?.right ?? 0).clamp(0.0, double.infinity);
      if (outer > minimum) minimum = outer;
    }
    return minimum == 0
        ? 0
        : minimum + _horizontalPadding(cell.ctx.style, cell.ctx);
  }

  double _horizontalPadding(HtmlStyle style, HtmlRenderContext ctx) {
    final p = style.padding;
    if (p == null) return 0;
    double resolve(CssLength? l) =>
        l?.resolve(
          fontSize: ctx.style.resolvedFontSize,
          rootFontSize: ctx.config.baseFontSize,
        ) ??
        0;
    return resolve(p.left) + resolve(p.right);
  }

  Widget _cellContent(dom.Element cell, HtmlRenderContext cellCtx) {
    if (cellCtx.style.overflowHidden == true &&
        cellCtx.style.textOverflow == 'ellipsis') {
      final meaningful = cell.nodes
          .where(
            (n) =>
                n is! dom.Comment && !(n is dom.Text && n.text.trim().isEmpty),
          )
          .toList();
      if (meaningful.length == 1 && meaningful.single is dom.Element) {
        final child = meaningful.single as dom.Element;
        final childCtx = cellCtx.builder.contextFor(
          child,
          cellCtx.childInherited,
        );
        if (childCtx.style.display == CssDisplay.inline &&
            childCtx.style.preventsWrapping) {
          // Keep the inline text in this paragraph so ellipsis can remove glyphs,
          // rather than treating the entire nowrap span as one atomic widget.
          return cellCtx.builder.flow(
            cellCtx.builder.buildChildNodes(child, childCtx.childInherited),
            childCtx.style.merge(
              const HtmlStyle(overflowHidden: true, textOverflow: 'ellipsis'),
            ),
          );
        }
      }
    }
    final results = cellCtx.builder.buildChildNodes(
      cell,
      cellCtx.childInherited,
    );
    return cellCtx.builder.flow(results, cellCtx.style);
  }

  List<dom.Element> _rowsOf(dom.Element table, HtmlRenderContext context) {
    final rows = <dom.Element>[];
    void visit(dom.Element parent) {
      for (final node in parent.nodes) {
        if (node is! dom.Element) continue;
        final tag = (node.localName ?? '').toLowerCase();
        if (tag == 'tr') {
          rows.add(node);
        } else if (tag == 'thead' || tag == 'tbody' || tag == 'tfoot') {
          final group = context.builder.contextForDescendant(node, context);
          if (group.style.display != CssDisplay.none) visit(node);
        }
      }
    }

    visit(table);
    return rows;
  }

  List<dom.Element> _cellsOf(dom.Element tr, HtmlRenderContext context) {
    final rowCtx = context.builder.contextForDescendant(tr, context);
    return [
      for (final node in tr.nodes)
        if (node is dom.Element &&
            (node.localName == 'td' || node.localName == 'th') &&
            // Skip cells hidden via display:none (e.g. a responsive email's
            // mobile-only logo that's hidden on the desktop layout we render).
            context.builder.contextForDescendant(node, rowCtx).style.display !=
                CssDisplay.none)
          node,
    ];
  }

  TableCellVerticalAlignment _verticalAlignment(String? valign) {
    switch (valign) {
      case 'top':
        return TableCellVerticalAlignment.top;
      case 'bottom':
        return TableCellVerticalAlignment.bottom;
      // Cells without an explicit valign are centered vertically (matches how
      // email clients render mixed-height rows, e.g. a short divider next to
      // padded text cells).
      default:
        return TableCellVerticalAlignment.middle;
    }
  }

  Widget _alignVertically(
    Widget child,
    String? valign, [
    TextAlign? textAlign,
  ]) {
    // Horizontal placement follows the cell's text-align so a centred/right cell
    // in the fallback path positions its content accordingly — otherwise the box
    // shrinks to content at the left and `text-align:center` has no visible
    // effect (the native path centres via column width instead).
    final x = switch (textAlign) {
      TextAlign.center => 0.0,
      TextAlign.right || TextAlign.end => 1.0,
      _ => -1.0,
    };
    final y = switch (valign) {
      'top' => -1.0,
      'bottom' => 1.0,
      _ => 0.0,
    };
    return Align(alignment: Alignment(x, y), child: child);
  }

  /// The table's cell spacing as (horizontal, vertical) px. `cellspacing="N"`
  /// is uniform; CSS `border-spacing` may give one value (uniform) or two
  /// (horizontal then vertical). The spacing sits between adjacent cells AND
  /// between the outer cells and the table edge — the latter is what gives an
  /// otherwise padding-less single-cell box its inner padding.
  ({double h, double v}) _cellSpacingFor(
    dom.Element table,
    HtmlRenderContext context,
  ) {
    // Browsers clamp negative presentational hints to 0 (and Flutter's
    // EdgeInsets/SizedBox assert on negatives), so never let one through.
    final attr = double.tryParse(table.attributes['cellspacing'] ?? '');
    if (attr != null) {
      final v = attr < 0 ? 0.0 : attr;
      return (h: v, v: v);
    }
    final style = table.attributes['style'];
    if (style != null) {
      final m = RegExp(
        r'border-spacing\s*:\s*([0-9.]+)(?:px)?(?:\s+([0-9.]+)(?:px)?)?',
      ).firstMatch(style);
      if (m != null) {
        final h = double.tryParse(m.group(1)!) ?? 0;
        final v = m.group(2) != null ? (double.tryParse(m.group(2)!) ?? h) : h;
        return (h: h < 0 ? 0 : h, v: v < 0 ? 0 : v);
      }
    }
    final fallback = context.config.defaultTableCellSpacing;
    return (h: fallback, v: fallback);
  }

  EdgeInsets _cellPaddingFor(dom.Element? table) {
    if (table == null) return const EdgeInsets.all(2);
    final raw = table.attributes['cellpadding'];
    if (raw == null) return const EdgeInsets.all(2);
    final value = double.tryParse(raw);
    if (value == null) return const EdgeInsets.all(2);
    return EdgeInsets.all(value < 0 ? 0 : value);
  }

  /// The table's own laid-out width in px: its explicit `width`/`max-width` if
  /// fixed, otherwise the width the email is being laid out at. Used to clamp a
  /// cell that asks for more than the table can give.
  double? _tableWidthPx(HtmlRenderContext context) {
    final w = context.style.width ?? context.style.maxWidth;
    if (w != null && !w.isAuto && w.unit != CssLengthUnit.percent) {
      final px = w.resolve(
        fontSize: context.style.resolvedFontSize,
        rootFontSize: context.config.baseFontSize,
      );
      if (px != null) return px;
    }
    return context.builder.availableWidth;
  }

  /// Widthless email CTA tables often put the visual button on the single
  /// table cell (`bgcolor`, padding, border) and keep the `<a>` as a plain text
  /// link inside it. A normal browser/email client shrink-wraps that table; if
  /// we let the table use a flex column it stretches the button across the
  /// whole content width.
  bool _isShrinkWrappedButtonTable(List<_RowData> rowData) {
    if (rowData.length != 1 || rowData.single.cells.length != 1) return false;
    final cell = rowData.single.cells.single;
    if (!_cellContainsOnlyOneLink(cell.element)) return false;

    final style = cell.ctx.style;
    final hasHorizontalPadding = _horizontalPadding(style, cell.ctx) > 0;
    final hasBackground =
        style.backgroundColor != null ||
        (cell.element.attributes['bgcolor'] ?? '').trim().isNotEmpty;
    final hasBorder = _hasVisibleBorder(style.borders);
    final hasRadius =
        style.borderRadius != null ||
        style.borderRadiusPercent != null ||
        style.borderRadiusGeometry != null;
    final minWidth = style.minWidth;
    final hasMinWidth = minWidth != null && !minWidth.isAuto;

    return hasHorizontalPadding ||
        hasBackground ||
        hasBorder ||
        hasRadius ||
        hasMinWidth;
  }

  bool _cellContainsOnlyOneLink(dom.Element cell) {
    final links = [
      for (final a in cell.getElementsByTagName('a'))
        if ((a.attributes['href'] ?? '').trim().isNotEmpty) a,
    ];
    if (links.length != 1) return false;
    return cell.text.trim() == links.single.text.trim();
  }

  bool _hasVisibleBorder(CssBorders? borders) {
    if (borders == null) return false;
    bool visible(CssBorderSide? side) =>
        side != null &&
        side.width > 0 &&
        side.color.a != 0 &&
        side.style != CssBorderStyle.none;
    return visible(borders.top) ||
        visible(borders.right) ||
        visible(borders.bottom) ||
        visible(borders.left);
  }

  TableBorder? _tableBorder(HtmlStyle tableStyle, {required bool drawInner}) {
    final b = tableStyle.borders;
    if (b == null ||
        (b.top == null &&
            b.right == null &&
            b.bottom == null &&
            b.left == null)) {
      return null;
    }
    // A zero-width or fully transparent side draws nothing (`border:0`); a bare
    // `BorderSide(width:0)` would otherwise render as a 1px hairline.
    BorderSide toSide(CssBorderSide? s) =>
        (s == null ||
            s.width <= 0 ||
            s.color.a == 0 ||
            s.style == CssBorderStyle.none)
        ? BorderSide.none
        : BorderSide(width: s.width, color: s.color);
    final top = toSide(b.top);
    final right = toSide(b.right);
    final bottom = toSide(b.bottom);
    final left = toSide(b.left);
    // A uniform box border (e.g. `<table border="1">` / `border:1px solid`)
    // also draws cell grid lines, matching browsers; asymmetric per-side
    // borders (e.g. `border-top` only) draw just those edges, no grid.
    final uniform =
        top == right &&
        right == bottom &&
        bottom == left &&
        top != BorderSide.none;
    final inside = uniform && drawInner ? top : BorderSide.none;
    return TableBorder(
      top: top,
      right: right,
      bottom: bottom,
      left: left,
      horizontalInside: inside,
      verticalInside: inside,
    );
  }

  /// Builds the outer table box. CSS borders live here (outside padding), while
  /// legacy HTML `border` stays on [Table] because it also draws the cell grid.
  HtmlStyle _boxOnly(HtmlStyle style, {required bool includeBorders}) =>
      HtmlStyle(
        margin: style.margin,
        padding: style.padding,
        backgroundColor: style.backgroundColor,
        backgroundImage: style.backgroundImage,
        backgroundPositionX: style.backgroundPositionX,
        backgroundPositionY: style.backgroundPositionY,
        backgroundSize: style.backgroundSize,
        backgroundPosition: style.backgroundPosition,
        backgroundRepeat: style.backgroundRepeat,
        borderRadius: style.borderRadius,
        borderRadiusGeometry: style.borderRadiusGeometry,
        overflowHidden: style.overflowHidden,
        borders: includeBorders ? _emailTableBorders(style.borders) : null,
        // `width` is applied by _buildTable as a min-width floor (a CSS table
        // grows past its width to fit content), not a hard width here.
        maxWidth: style.maxWidth,
        // A table's height is a floor: its rows must still fit their content.
        // A hard Container height collapses height="0" email sections while
        // their children keep painting over the following rows.
        minHeight: style.height,
        // Needed so a fixed-width table centers under an inherited
        // text-align:center (e.g. <td align="center">).
        textAlign: style.textAlign,
      );

  /// A one-CSS-pixel email rule otherwise looks heavy on high-density Flutter
  /// displays. A native zero-width BorderSide is a one-device-pixel hairline;
  /// [CssBorderSide.hairline] distinguishes it from authored `border:0`.
  CssBorders? _emailTableBorders(CssBorders? borders) {
    if (borders == null) return null;
    CssBorderSide? thin(CssBorderSide? side) {
      if (side == null || side.width <= 0 || side.width > 1) return side;
      if (side.style != CssBorderStyle.solid) return side;
      return CssBorderSide(
        width: 0,
        color: side.color,
        style: side.style,
        hairline: true,
      );
    }

    return CssBorders(
      top: thin(borders.top),
      right: thin(borders.right),
      bottom: thin(borders.bottom),
      left: thin(borders.left),
    );
  }

  static CssEdges _toEdges(EdgeInsets insets) => CssEdges(
    top: CssLength(insets.top, CssLengthUnit.px),
    right: CssLength(insets.right, CssLengthUnit.px),
    bottom: CssLength(insets.bottom, CssLengthUnit.px),
    left: CssLength(insets.left, CssLengthUnit.px),
  );
}

/// Resolve a table's percentage minimum against its containing block before
/// its fixed width narrows the constraints offered to the cell grid.
class _TablePercentMinWidth extends SingleChildRenderObjectWidget {
  const _TablePercentMinWidth({
    required this.preferredWidth,
    required this.minimumFactor,
    required super.child,
  });
  final double preferredWidth;
  final double minimumFactor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTablePercentMinWidth(preferredWidth, minimumFactor);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTablePercentMinWidth renderObject,
  ) {
    renderObject.update(preferredWidth, minimumFactor);
  }
}

class _RenderTablePercentMinWidth extends RenderProxyBox {
  _RenderTablePercentMinWidth(this.preferredWidth, this.minimumFactor);
  double preferredWidth;
  double minimumFactor;

  void update(double width, double factor) {
    if (width == preferredWidth && factor == minimumFactor) return;
    preferredWidth = width;
    minimumFactor = factor;
    markNeedsLayout();
  }

  double target(double basis) {
    final minimum = basis.isFinite ? basis * minimumFactor : 0.0;
    return minimum > preferredWidth ? minimum : preferredWidth;
  }

  @override
  double computeMinIntrinsicWidth(double height) => preferredWidth;

  @override
  double computeMaxIntrinsicWidth(double height) {
    final childWidth = child?.getMaxIntrinsicWidth(height) ?? 0;
    return childWidth > preferredWidth ? childWidth : preferredWidth;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(target(width)) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(target(width)) ?? 0;

  BoxConstraints childConstraints(BoxConstraints constraints) => constraints
      .tighten(width: constraints.constrainWidth(target(constraints.maxWidth)));

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    child?.getDryLayout(childConstraints(constraints)) ?? constraints.smallest,
  );

  @override
  void performLayout() {
    child?.layout(childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(child?.size ?? constraints.smallest);
  }
}

/// A column width that is at least [px] but grows to the cell's *min-content*
/// width (its widest unbreakable child — a long word or an image) when that is
/// larger. Unlike `MaxColumnWidth(FixedColumnWidth, IntrinsicColumnWidth)`,
/// which grows to *max-content* (the fully-unwrapped width) and so lets a
/// fixed-width text panel balloon to fill a wide viewport, this keeps such a
/// panel at its set width and wraps its text — matching how a browser sizes a
/// `width:Npx` table — while a small icon cell still expands to fit its image.
class _SpanCell extends ParentDataWidget<_SpanningTableParentData> {
  const _SpanCell({
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
  Type get debugTypicalAncestorWidgetClass => _SpanningTable;
}

class _SpanningTable extends MultiChildRenderObjectWidget {
  const _SpanningTable({
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
  final List<_ColSpec> columnWidths;
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
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSpanningTable renderObject,
  ) {
    renderObject
      ..rows = rows
      ..columns = columns
      ..columnWidths = columnWidths
      ..horizontalSpacing = horizontalSpacing
      ..verticalSpacing = verticalSpacing;
    renderObject.textDirection = textDirection;
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
  List<_ColSpec> _columnWidths;
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

  set columnWidths(List<_ColSpec> value) {
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
    final rowHeights = List<double>.filled(_rows, 0);

    RenderBox? child = firstChild;
    while (child != null) {
      final data = child.parentData! as _SpanningTableParentData;
      final spanWidth = _spanWidth(data, columnWidths);
      child.layout(BoxConstraints(maxWidth: spanWidth), parentUsesSize: true);
      if (data.rowSpan == 1 && child.size.height > rowHeights[data.row]) {
        rowHeights[data.row] = child.size.height;
      }
      child = data.nextSibling;
    }

    child = firstChild;
    while (child != null) {
      final data = child.parentData! as _SpanningTableParentData;
      if (data.rowSpan > 1) {
        var current = _verticalSpacing * (data.rowSpan - 1);
        for (var r = data.row; r < data.row + data.rowSpan; r++) {
          current += rowHeights[r];
        }
        final missing = child.size.height - current;
        if (missing > 0) {
          final share = missing / data.rowSpan;
          for (var r = data.row; r < data.row + data.rowSpan; r++) {
            rowHeights[r] += share;
          }
        }
      }
      child = data.nextSibling;
    }

    final rowOffsets = List<double>.filled(_rows, 0);
    for (var r = 1; r < _rows; r++) {
      rowOffsets[r] = rowOffsets[r - 1] + rowHeights[r - 1] + _verticalSpacing;
    }

    child = firstChild;
    while (child != null) {
      final data = child.parentData! as _SpanningTableParentData;
      final spanWidth = _spanWidth(data, columnWidths);
      var spanHeight = _verticalSpacing * (data.rowSpan - 1);
      for (var r = data.row; r < data.row + data.rowSpan; r++) {
        spanHeight += rowHeights[r];
      }
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

    final height =
        rowHeights.fold<double>(0, (sum, value) => sum + value) +
        _verticalSpacing * (_rows - 1);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Replaced images contribute their preferred (possibly max-width capped)
/// width before an adjacent text column is shrunk. Their render boxes report
/// a zero min-intrinsic width to permit responsive scaling elsewhere.
class _PreferredImageColumnWidth extends IntrinsicColumnWidth {
  const _PreferredImageColumnWidth();

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    final preferred = maxIntrinsicWidth(cells, containerWidth);
    return containerWidth.isFinite
        ? preferred.clamp(0, containerWidth)
        : preferred;
  }
}

class _ShrinkToFitColumnWidth extends TableColumnWidth {
  const _ShrinkToFitColumnWidth(this.maxWidth);

  final double? maxWidth;

  double _target(Iterable<RenderBox> cells, double containerWidth) {
    var minContent = 0.0;
    var maxContent = 0.0;
    for (final cell in cells) {
      final min = cell.getMinIntrinsicWidth(double.infinity);
      if (min > minContent) minContent = min;
      final max = cell.getMaxIntrinsicWidth(double.infinity);
      if (max > maxContent) maxContent = max;
    }

    var availableWidth = containerWidth;
    final cap = maxWidth;
    if (cap != null && cap.isFinite && cap > 0) {
      if (!availableWidth.isFinite ||
          availableWidth <= 0 ||
          cap < availableWidth) {
        availableWidth = cap;
      }
    }
    if (!availableWidth.isFinite || availableWidth <= 0) {
      return maxContent;
    }
    final available = availableWidth > minContent ? availableWidth : minContent;
    return maxContent < available ? maxContent : available;
  }

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    // A surrounding table must be able to shrink a linked button down to its
    // longest unbreakable content. Reporting the preferred (max-content)
    // width here prevents adjacent buttons from sharing a narrow row.
    var minimum = 0.0;
    for (final cell in cells) {
      final width = cell.getMinIntrinsicWidth(double.infinity);
      if (width > minimum) minimum = width;
    }
    return minimum;
  }

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      _target(cells, containerWidth);

  @override
  double? flex(Iterable<RenderBox> cells) => null;
}

class _FixedOrMinContentColumnWidth extends TableColumnWidth {
  const _FixedOrMinContentColumnWidth(this.px);

  final double px;

  double _target(Iterable<RenderBox> cells, double containerWidth) {
    var minContent = 0.0;
    for (final cell in cells) {
      final c = cell.getMinIntrinsicWidth(double.infinity);
      if (c > minContent) minContent = c;
    }
    var t = px > minContent ? px : minContent;
    // A specified width can exceed the table's real container (a `width="1456"`
    // wide-image cell in a ~550px column). Clamp to the container so the cell
    // fills the available space and stays centred, never overflowing — but
    // never below min-content (the widest unbreakable child).
    if (containerWidth.isFinite && containerWidth > 0 && t > containerWidth) {
      // The `px == 0` form is used as a min-content floor for flexible columns.
      // In email markup a full-width block wrapper (`display:block;width:100%`)
      // can make Flutter report max-content as min-content during table
      // intrinsic measurement. Trusting that value lets a flex column balloon
      // past a fixed-width email container (Rozetka order emails hit ~1800px
      // inside a 650px table). With no authored px floor, do not add any
      // intrinsic floor: the FlexColumnWidth side of MaxColumnWidth will take
      // the remaining space after fixed siblings (image/price columns), which
      // is the CSS table behavior for ordinary text columns.
      if (px <= 0) return 0;
      t = minContent > containerWidth ? minContent : containerWidth;
    }
    return t;
  }

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      _target(cells, containerWidth);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      _target(cells, containerWidth);

  @override
  double? flex(Iterable<RenderBox> cells) => null;
}

/// A shared column width for the Row-based path: a fixed px width, a percent
/// flex weight, or neither (0/0 -> flexible, equal share).
class _ColSpec {
  double px = 0;
  double percent = 0;
  bool intrinsic = false;
}

class _RowData {
  _RowData(this.ctx, this.cells);
  final HtmlRenderContext ctx;
  final List<_CellData> cells;
}

class _CellData {
  _CellData({required this.element, required this.ctx});
  final dom.Element element;
  final HtmlRenderContext ctx;
  late final _CellContentFacts content = _CellContentFacts.inspect(
    element,
    ctx,
  );

  bool get hasSpan {
    final colspan = int.tryParse(element.attributes['colspan'] ?? '1') ?? 1;
    final rowspan = int.tryParse(element.attributes['rowspan'] ?? '1') ?? 1;
    return colspan > 1 || rowspan > 1;
  }
}

/// All column classification facts from one traversal of the visible subtree.
/// Stored on a cell so width selection and rendering share the same result.
class _CellContentFacts {
  const _CellContentFacts({
    required this.hasContent,
    required this.onlyImages,
    required this.hasFillImage,
    required this.onlyInlineBlock,
  });

  final bool hasContent;
  final bool onlyImages;
  final bool hasFillImage;
  final bool onlyInlineBlock;

  factory _CellContentFacts.inspect(
    dom.Element cell,
    HtmlRenderContext context,
  ) {
    var hasContent = false;
    var onlyImages = true;
    var sawImage = false;
    var hasFillImage = false;
    var meaningfulChildren = 0;
    var inlineBlockChild = false;

    void visit(dom.Element element, HtmlRenderContext ctx) {
      if (ctx.style.display == CssDisplay.none) return;
      final width = ctx.style.width;
      // A percentage-width structural wrapper contributes no intrinsic
      // content when all its descendants are hidden. Treating width:100% as
      // content makes an otherwise empty column claim a flex share.
      if (width != null &&
          !width.isAuto &&
          width.unit != CssLengthUnit.percent &&
          width.value > 0) {
        hasContent = true;
      }
      if (element.localName == 'img') {
        sawImage = true;
        hasContent = true;
        final attr = element.attributes['width']?.trim() ?? '';
        final attrPercent = attr.endsWith('%')
            ? double.tryParse(attr.substring(0, attr.length - 1))
            : null;
        hasFillImage =
            hasFillImage ||
            (width?.unit == CssLengthUnit.percent && width!.value >= 99) ||
            (attrPercent != null && attrPercent >= 99);
        return;
      }
      for (final node in element.nodes) {
        if (node is dom.Text && node.data.trim().isNotEmpty) {
          hasContent = true;
          onlyImages = false;
          if (identical(element, cell)) meaningfulChildren++;
        } else if (node is dom.Element) {
          final child = context.builder.contextForDescendant(node, context);
          if (child.style.display == CssDisplay.none) continue;
          if (identical(element, cell)) {
            meaningfulChildren++;
            inlineBlockChild = child.style.display == CssDisplay.inlineBlock;
          }
          visit(node, child);
        }
      }
    }

    visit(cell, context);
    return _CellContentFacts(
      hasContent: hasContent,
      onlyImages: onlyImages && sawImage,
      hasFillImage: hasFillImage,
      onlyInlineBlock: meaningfulChildren == 1 && inlineBlockChild,
    );
  }
}
