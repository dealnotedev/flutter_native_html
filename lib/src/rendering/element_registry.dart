import 'element_handler.dart';
import 'handlers/anchor_handler.dart';
import 'handlers/break_handler.dart';
import 'handlers/image_handler.dart';
import 'handlers/list_handler.dart';
import 'handlers/rule_handler.dart';
import 'handlers/sub_sup_handler.dart';
import 'handlers/table_handler.dart';

/// Maps tag names to the [HtmlElementHandler] responsible for them.
///
/// Custom handlers (from config) are registered first so they win over the
/// built-ins for any overlapping tag. Tags with no registered handler fall
/// back to the builder's generic display-based rendering (which already covers
/// `div`, `p`, `span`, headings, `b/i/u`, `blockquote`, `pre`, …).
class ElementRegistry {
  ElementRegistry({List<HtmlElementHandler> custom = const []}) {
    for (final handler in [...custom, ..._builtIns]) {
      for (final tag in handler.tags) {
        _handlers.putIfAbsent(tag, () => handler);
      }
    }
  }

  final Map<String, HtmlElementHandler> _handlers = {};

  static final List<HtmlElementHandler> _builtIns = [
    const AnchorHandler(),
    const ImageHandler(),
    const BreakHandler(),
    const ListHandler(),
    const TableHandler(),
    const RuleHandler(),
    const SubSupHandler(),
  ];

  HtmlElementHandler? handlerFor(String tag) => _handlers[tag.toLowerCase()];
}
