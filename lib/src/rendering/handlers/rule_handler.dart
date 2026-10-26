import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../../css/css_length.dart';
import '../../css/html_style.dart';
import '../element_handler.dart';
import '../html_build_result.dart';
import '../html_render_context.dart';

/// Renders `<hr>` as a horizontal rule, honoring the element's resolved margins,
/// border/color, and — for the ubiquitous `hr{border:none;height:2px;
/// background:#e0e0e0}` reset idiom — its CSS `height`, `background-color` and
/// `width`.
class RuleHandler extends HtmlElementHandler {
  const RuleHandler();

  @override
  Set<String> get tags => const {'hr'};

  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    final style = context.style;
    final borderTop = style.borders?.top;
    final hasBorder =
        borderTop != null &&
        borderTop.width > 0 &&
        borderTop.style != CssBorderStyle.none;

    // Color: an explicit border wins; otherwise the background (the reset
    // idiom), then a faded text color, then a default hairline.
    final color = hasBorder
        ? borderTop.color
        : (style.backgroundColor ??
              style.color?.withValues(alpha: 0.3) ??
              const Color(0x33000000));

    // Thickness: border width, else an absolute CSS height, else 1px.
    var thickness = hasBorder ? borderTop.width : 1.0;
    final height = style.height;
    if (!hasBorder &&
        height != null &&
        !height.isAuto &&
        height.unit != CssLengthUnit.percent) {
      final px = height.resolve(
        fontSize: style.resolvedFontSize,
        rootFontSize: context.config.baseFontSize,
      );
      if (px != null && px > 0) thickness = px;
    }

    final rule = Container(height: thickness, color: color);
    // Apply margins plus any explicit width/max-width (`hr{width:50%}`); the
    // line itself already represents the border.
    final spacing = context.builder.decorate(
      rule,
      HtmlStyle(
        margin: style.margin,
        width: style.width,
        maxWidth: style.maxWidth,
      ),
    );
    return [BlockResult(spacing)];
  }
}
