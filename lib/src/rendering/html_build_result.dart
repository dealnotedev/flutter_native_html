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

/// A block-level widget that breaks the current text run.
class BlockResult extends HtmlBuildResult {
  const BlockResult(this.widget);
  final Widget widget;
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
  const ColumnResult(this.widget, this.percent, {this.float});
  final Widget widget;
  final double percent;

  /// Side requested by CSS `float` for legacy email-layout columns.
  ///
  /// Keeping this metadata lets the flow step put unused row width between
  /// left- and right-floated groups instead of after all columns.
  final String? float;
}
