import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../css/css_parser.dart';
import '../css/css_stylesheet.dart';
import 'html_sanitizer.dart';

/// The outcome of parsing an email body: the sanitized DOM root to render plus
/// the author stylesheet collected from all `<style>` blocks.
class ParsedEmail {
  ParsedEmail({
    required this.root,
    required this.stylesheet,
    this.colorScheme,
    this.lineHeightQuirk = false,
  });

  /// The author's doctype puts the document in quirks or limited-quirks mode
  /// (e.g. XHTML 1.0 Transitional, the classic email doctype), as a browser
  /// or Apple Mail renders it. Then a block's own font (its "strut") only
  /// sizes lines that hold the block's direct text: a line made only of
  /// `<span>`s or images takes their height alone. A document without a
  /// doctype stays in standards mode, as webmail shows it.
  final bool lineHeightQuirk;

  /// The element whose children should be rendered (usually `<body>`).
  /// Treat this DOM as immutable while sharing or displaying the document.
  /// The view caches preparation; mutations require a new ParsedEmail instance.
  final dom.Element root;
  final CssStylesheet stylesheet;

  /// The head's color-scheme hint, including the legacy supported-color-schemes
  /// spelling. It is data for rendering policy, never active HTML.
  final String? colorScheme;
}

class HtmlContentLimitException implements Exception {
  const HtmlContentLimitException(this.message);
  final String message;
  @override
  String toString() => 'HtmlContentLimitException: $message';
}

/// Turns a raw HTML email string into a [ParsedEmail].
///
/// Pipeline: lenient HTML5 parse → collect `<style>` CSS → sanitize the DOM →
/// hand back the body for the tree builder. `<style>` text is gathered *before*
/// sanitization (which strips the elements) so author CSS survives.
class HtmlEmailParser {
  HtmlEmailParser({
    HtmlSanitizer? sanitizer,
    this.maxHtmlCharacters = 2 * 1024 * 1024,
    this.maxDomNodes = 50000,
    this.maxDomDepth = 512,
    this.maxCssCharacters = 512 * 1024,
    this.maxCssRules = 10000,
  }) : sanitizer = sanitizer ?? const HtmlSanitizer();

  final HtmlSanitizer sanitizer;
  final int maxHtmlCharacters;
  final int maxDomNodes;

  /// Maximum element nesting depth. The sanitizer and tree builder both recurse
  /// one stack frame per level, so an attacker can keep the node *count* under
  /// [maxDomNodes] while nesting thousands deep to overflow the stack. Like
  /// Blink's parser (which stops nesting at 512 open elements), nodes below
  /// this depth are inserted as siblings at the limit rather than children,
  /// so a legacy email with hundreds of unclosed `<font>` tags still renders.
  final int maxDomDepth;
  final int maxCssCharacters;
  final int maxCssRules;

  ParsedEmail parse(String htmlSource) {
    if (htmlSource.length > maxHtmlCharacters) {
      throw const HtmlContentLimitException('HTML size limit exceeded');
    }
    final parser = html_parser.HtmlParser(htmlSource, generateSpans: false);
    final document = parser.parse();
    // The HTML parser applies the spec's doctype table; a missing doctype
    // also reads as quirks there, which webmail (and fragments) never get.
    final lineHeightQuirk =
        document.nodes.any((node) => node is dom.DocumentType) &&
        parser.compatMode != 'no quirks';
    var nodes = 0;
    final pending = <(dom.Node, int)>[(document, 0)];
    while (pending.isNotEmpty) {
      final (node, depth) = pending.removeLast();
      nodes++;
      if (nodes > maxDomNodes) {
        throw const HtmlContentLimitException('DOM node limit exceeded');
      }
      if (depth >= maxDomDepth && node.nodes.isNotEmpty) {
        // The hoisted nodes become childless siblings already behind the
        // walk, so count them here.
        nodes += _hoistDescendants(node);
        if (nodes > maxDomNodes) {
          throw const HtmlContentLimitException('DOM node limit exceeded');
        }
      }
      for (final child in node.nodes) {
        pending.add((child, depth + 1));
      }
    }

    final stylesheet = _collectStylesheet(document);

    final body =
        document.body ??
        document.documentElement ??
        document.createElement('body');
    sanitizer.sanitize(body);

    String? colorScheme;
    for (final meta
        in document.head?.querySelectorAll('meta') ?? <dom.Element>[]) {
      final name = meta.attributes['name']?.toLowerCase();
      if (name == 'color-scheme' || name == 'supported-color-schemes') {
        colorScheme = meta.attributes['content'];
        if (name == 'color-scheme') break;
      }
    }
    return ParsedEmail(
      root: body,
      stylesheet: stylesheet,
      colorScheme: colorScheme,
      lineHeightQuirk: lineHeightQuirk,
    );
  }

  /// Moves every descendant of [node] (in document order, each emptied of its
  /// own children) to follow [node] as siblings, as Blink inserts elements
  /// opened past its depth limit. Iterative, so depth costs no stack.
  static int _hoistDescendants(dom.Node node) {
    final parent = node.parent;
    if (parent == null) return 0;
    final flat = <dom.Node>[];
    final stack = <dom.Node>[...node.nodes.reversed];
    for (final child in node.nodes.toList()) {
      child.remove();
    }
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      final children = current.nodes.toList();
      for (final child in children) {
        child.remove();
      }
      flat.add(current);
      stack.addAll(children.reversed);
    }
    var index = parent.nodes.indexOf(node);
    for (final moved in flat) {
      parent.nodes.insert(++index, moved);
    }
    return flat.length;
  }

  CssStylesheet _collectStylesheet(dom.Document document) {
    final styleNodes = document.querySelectorAll('style');
    if (styleNodes.isEmpty) return CssStylesheet.empty;
    final buffer = StringBuffer();
    for (final node in styleNodes) {
      buffer.writeln(node.text);
      if (buffer.length > maxCssCharacters) {
        throw const HtmlContentLimitException('CSS size limit exceeded');
      }
    }
    final stylesheet = CssParser.parseStylesheet(buffer.toString());
    if (stylesheet.rules.length > maxCssRules) {
      throw const HtmlContentLimitException('CSS rule limit exceeded');
    }
    return stylesheet;
  }
}
