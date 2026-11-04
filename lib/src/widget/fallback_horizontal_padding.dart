import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../analysis/html_document_insets.dart';

/// Supplies missing side gutters using laid-out text boxes, including the
/// renderer's fit-to-width transform. Image-only content is left unchanged.
class HtmlFallbackHorizontalPadding extends SingleChildRenderObjectWidget {
  const HtmlFallbackHorizontalPadding({
    super.key,
    required this.padding,
    required this.estimateInsets,
    required super.child,
  });

  final HtmlDocumentInsetsEstimate Function(double width) estimateInsets;
  final double padding;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHtmlFallbackHorizontalPadding(estimateInsets, padding);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderHtmlFallbackHorizontalPadding)
      ..estimateInsets = estimateInsets
      ..fallbackPadding = padding;
  }
}

class _RenderHtmlFallbackHorizontalPadding extends RenderShiftedBox {
  _RenderHtmlFallbackHorizontalPadding(this._estimateInsets, this._gutter)
    : super(null);

  double _gutter;
  static const _tolerance = 0.5;
  HtmlDocumentInsetsEstimate Function(double width) _estimateInsets;
  EdgeInsets _padding = EdgeInsets.zero;

  set fallbackPadding(double value) {
    if (_gutter == value) return;
    _gutter = value;
    markNeedsLayout();
  }

  set estimateInsets(HtmlDocumentInsetsEstimate Function(double width) value) {
    if (_estimateInsets == value) return;
    _estimateInsets = value;
    markNeedsLayout();
  }

  bool _containsText(RenderObject node) {
    if (node is RenderParagraph &&
        node.text.toPlainText(includePlaceholders: false).trim().isNotEmpty) {
      return true;
    }
    var found = false;
    node.visitChildren((child) => found = found || _containsText(child));
    return found;
  }

  Rect? _textBounds(RenderBox root) {
    Rect? bounds;
    void visit(RenderObject node) {
      if (node is RenderOffstage && node.offstage ||
          node is RenderOpacity && node.opacity == 0) {
        return;
      }
      final fittedText = node is RenderFittedBox && _containsText(node);
      final translatedText =
          node is RenderFractionalTranslation && _containsText(node);
      if (node is RenderBox &&
          (fittedText ||
              translatedText ||
              node is RenderParagraph &&
                  node.text
                      .toPlainText(includePlaceholders: false)
                      .trim()
                      .isNotEmpty)) {
        // A render object may only read its immediate child's size during
        // layout. Paragraph dry layout uses the same final text constraints.
        final textSize = node.getDryLayout(node.constraints);
        var localBounds = Offset.zero & textSize;
        if (node is RenderFractionalTranslation) {
          localBounds = localBounds.shift(
            Offset(
              node.translation.dx * textSize.width,
              node.translation.dy * textSize.height,
            ),
          );
        }
        final rect = MatrixUtils.transformRect(
          node.getTransformTo(root),
          localBounds,
        );
        if (!rect.isEmpty && rect.isFinite) {
          bounds = bounds?.expandToInclude(rect) ?? rect;
        }
        // The fitted box owns the text's scale and alignment. Its outer box is
        // the allocated text area; descendants need not be inspected again.
        if (fittedText || translatedText) return;
      }
      node.visitChildren(visit);
    }

    visit(root);
    return bounds;
  }

  EdgeInsets _missingGutters(RenderBox child, double width) {
    final insets = _estimateInsets(width);
    if (!insets.hasContent) return EdgeInsets.zero;
    // Known CSS insets distinguish short final lines from authored right space.
    // Fixed-width and spanning tables need the actual scaled text allocation.
    final bounds = insets.left == null || insets.right == null
        ? _textBounds(child)
        : null;
    final left = insets.left ?? bounds?.left;
    final right =
        insets.right ?? (bounds == null ? null : width - bounds.right);
    return EdgeInsets.only(
      left: left != null && left <= _tolerance ? _gutter : 0,
      right: right != null && right <= _tolerance ? _gutter : 0,
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      _padding = EdgeInsets.zero;
      size = constraints.smallest;
      return;
    }

    // Probe the author's layout first. Start from zero on every layout so a
    // resize, replaced message or loaded inline image cannot retain old gutters.
    child.layout(constraints, parentUsesSize: true);
    _padding = EdgeInsets.zero;
    final width = constraints.maxWidth;
    if (width.isFinite && width > 2 * _gutter) {
      _padding = _missingGutters(child, width);
      if (_padding != EdgeInsets.zero) {
        final inner = constraints.deflate(_padding);
        child.layout(inner, parentUsesSize: true);
        final stillMissing = _missingGutters(child, inner.maxWidth);
        // Narrowing the viewport can activate responsive author spacing. Keep
        // that document at its original width instead of stacking both gutters.
        if (_padding.left > 0 && stillMissing.left == 0 ||
            _padding.right > 0 && stillMissing.right == 0) {
          _padding = EdgeInsets.zero;
          child.layout(constraints, parentUsesSize: true);
        }
      }
    }
    (child.parentData! as BoxParentData).offset = Offset(_padding.left, 0);
    size = constraints.constrain(
      Size(child.size.width + _padding.horizontal, child.size.height),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize = child?.getDryLayout(constraints.deflate(_padding));
    return constraints.constrain(
      Size(
        (childSize?.width ?? 0) + _padding.horizontal,
        childSize?.height ?? 0,
      ),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      (child?.getMinIntrinsicWidth(height) ?? 0) + _padding.horizontal;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (child?.getMaxIntrinsicWidth(height) ?? 0) + _padding.horizontal;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(
        (width - _padding.horizontal).clamp(0, double.infinity),
      ) ??
      0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(
        (width - _padding.horizontal).clamp(0, double.infinity),
      ) ??
      0;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryBaseline(constraints.deflate(_padding), baseline);
}
