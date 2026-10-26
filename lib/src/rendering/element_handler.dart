import 'package:html/dom.dart' as dom;

import 'html_build_result.dart';
import 'html_render_context.dart';

/// Renders one (or several) HTML tags into [HtmlBuildResult]s.
///
/// This is the primary extension point: register a custom handler via
/// `HtmlRenderConfig.handlers` to override built-in rendering or add support
/// for new tags. Custom handlers take precedence over built-ins for the same
/// tag.
abstract class HtmlElementHandler {
  const HtmlElementHandler();

  /// Lower-case tag names this handler is responsible for.
  Set<String> get tags;

  /// Produces the rendered output for [element].
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context);
}
