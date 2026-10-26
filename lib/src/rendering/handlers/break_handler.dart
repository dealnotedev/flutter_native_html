import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../element_handler.dart';
import '../html_build_result.dart';
import '../html_render_context.dart';

/// Renders `<br>` as a hard line break within the current text run.
class BreakHandler extends HtmlElementHandler {
  const BreakHandler();

  @override
  Set<String> get tags => const {'br', 'wbr'};

  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    final newline = (element.localName ?? '').toLowerCase() == 'wbr'
        ? '​'
        : '\n';
    return [
      InlineResult(TextSpan(text: newline, style: context.style.toTextStyle())),
    ];
  }
}
