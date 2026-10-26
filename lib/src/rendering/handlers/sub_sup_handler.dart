import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../element_handler.dart';
import '../html_build_result.dart';
import '../html_render_context.dart';

class SubSupHandler extends HtmlElementHandler {
  const SubSupHandler();

  @override
  Set<String> get tags => const {'sub', 'sup'};

  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    final content = context.builder.flow(
      context.buildChildren(element),
      context.style,
    );
    final size = context.style.resolvedFontSize;
    final isSub = (element.localName ?? '').toLowerCase() == 'sub';
    return [
      InlineResult(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Transform.translate(
            offset: Offset(0, isSub ? size * 0.25 : -size * 0.3),
            child: content,
          ),
        ),
      ),
    ];
  }
}
