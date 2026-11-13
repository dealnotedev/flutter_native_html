import 'package:flutter/widgets.dart';

/// The product of building a DOM node: either an inline fragment (merged into a
/// surrounding text run) or a standalone block widget.
///
/// The tree builder collects a list of these for an element's children, then
/// "flows" them — coalescing runs of [InlineResult] into a single rich-text
/// paragraph and emitting [BlockResult]s as separate widgets.
sealed class HtmlBuildResult {
  const HtmlBuildResult();
}

/// Inline content contributing an [InlineSpan] to the current text run.
class InlineResult extends HtmlBuildResult {
  const InlineResult(this.span, {this.isWhitespaceOnly = false});

  final InlineSpan span;

  /// Marks spans that are pure collapsible whitespace, so the flow step can
  /// drop them at block boundaries.
  final bool isWhitespaceOnly;
}

/// Horizontal padding or margin in a text run. It reserves width without
/// changing the line-height distribution of the surrounding text.
class InlineSpacerSpan extends WidgetSpan {
  const InlineSpacerSpan({required super.child, super.alignment});
}

/// A block-level widget that breaks the current text run.
class BlockResult extends HtmlBuildResult {
  const BlockResult(this.widget, {this.clears = false});
  final Widget widget;

  /// CSS `clear`: the block starts below pending floats instead of beside.
  final bool clears;
}

/// An auto-sized CSS float sharing a row with the adjacent inline content.
class FloatResult extends HtmlBuildResult {
  const FloatResult(this.widget, this.side);
  final Widget widget;
  final String side;
}

/// A percent-width inline-block column (the MJML `mj-column-per-N` pattern).
/// The flow step lays a consecutive run of these out side by side in a [Row]
/// (flex = [percent]) when they fit, or stacks them when they don't (e.g. each
/// is 100% wide on a narrow layout).
class ColumnResult extends HtmlBuildResult {
  const ColumnResult(this.widget, this.percent, {this.float, this.floatWidth});
  final Widget widget;
  final double percent;

  /// For a legacy `align` float table: the px width it asks for, if known.
  final double? floatWidth;

  /// Side requested by CSS `float` for legacy email-layout columns.
  ///
  /// Keeping this metadata lets the flow step put unused row width between
  /// left- and right-floated groups instead of after all columns.
  final String? float;
}
