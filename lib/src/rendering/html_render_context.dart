import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../config/html_image_resolver.dart';
import '../config/html_render_config.dart';
import '../css/html_style.dart';
import 'html_build_result.dart';
import 'html_tree_builder.dart';

/// Everything an element handler needs to render itself and recurse into its
/// children. Created fresh per element by the [HtmlTreeBuilder].
class HtmlRenderContext {
  HtmlRenderContext({
    required this.builder,
    required this.buildContext,
    required this.style,
    required this.childInherited,
    this.element,
  });

  final HtmlTreeBuilder builder;
  final dom.Element? element;

  /// The Flutter context (for `Theme`, `MediaQuery`, etc.).
  final BuildContext buildContext;

  /// The fully-resolved style of the element being handled.
  final HtmlStyle style;

  /// Inherited-only style to hand down to this element's children.
  final HtmlStyle childInherited;

  HtmlRenderConfig get config => builder.config;
  HtmlImageResolver get imageResolver => builder.imageResolver;

  /// Builds the element's children into a flat result list (inline + block).
  List<HtmlBuildResult> buildChildren(dom.Element element) =>
      builder.buildChildNodes(element, childInherited);

  /// Flows the element's children into a single block widget, applying this
  /// element's box decoration (margin/padding/background/border/alignment).
  Widget buildBlock(dom.Element element) => builder.buildBlock(element, this);

  /// Attempts to render the element purely inline; returns `null` if it
  /// contains block content (caller should fall back to a block widget).
  InlineSpan? buildInline(dom.Element element) =>
      builder.buildInline(element, this);
}
