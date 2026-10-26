import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../css/css_parser.dart';
import '../css/css_stylesheet.dart';
import 'html_sanitizer.dart';

/// The outcome of parsing an email body: the sanitized DOM root to render plus
/// the author stylesheet collected from all `<style>` blocks.
class ParsedEmail {
  ParsedEmail({required this.root, required this.stylesheet});

  /// The element whose children should be rendered (usually `<body>`).
  /// Treat this DOM as immutable while sharing or displaying the document.
  /// The view caches preparation; mutations require a new ParsedEmail instance.
  final dom.Element root;
  final CssStylesheet stylesheet;
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
  /// [maxDomNodes] while nesting thousands deep to overflow the stack. Reject
  /// pathological depth up front instead.
  final int maxDomDepth;
  final int maxCssCharacters;
  final int maxCssRules;

  ParsedEmail parse(String htmlSource) {
    if (htmlSource.length > maxHtmlCharacters) {
      throw const HtmlContentLimitException('HTML size limit exceeded');
    }
    final document = html_parser.parse(htmlSource);
    var nodes = 0;
    final pending = <(dom.Node, int)>[(document, 0)];
    while (pending.isNotEmpty) {
      final (node, depth) = pending.removeLast();
      nodes++;
      if (nodes > maxDomNodes) {
        throw const HtmlContentLimitException('DOM node limit exceeded');
      }
      if (depth > maxDomDepth) {
        throw const HtmlContentLimitException('DOM nesting depth exceeded');
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

    return ParsedEmail(root: body, stylesheet: stylesheet);
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
