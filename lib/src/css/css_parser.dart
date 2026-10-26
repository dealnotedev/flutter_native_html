import 'css_selector.dart';
import 'css_stylesheet.dart';
import 'css_declaration_expander.dart';

/// A small, dependency-free CSS parser tuned for the email subset.
///
/// It tokenizes only as much as it needs to: it strips comments, splits rule
/// blocks brace-aware, expands comma-separated selector groups, and parses
/// `prop: value` declarations. `@media (max-width/min-width)` queries are kept
/// and evaluated against the render width; other at-rules (`@font-face`,
/// `@import`, …) are skipped.
///
/// It is deliberately hidden behind [CssStylesheet]/[parseInlineDeclarations]
/// so the implementation can be swapped for a fuller engine later without
/// touching callers.
class CssParser {
  const CssParser._();

  /// Parses the concatenated text of all `<style>` blocks into a stylesheet.
  static CssStylesheet parseStylesheet(String css) {
    final clean = _stripComments(css);
    final rules = <CssRule>[];
    final order = _Counter();
    _parseRules(clean, rules, order, null);
    return CssStylesheet(rules);
  }

  /// Parses the rules in [css] into [rules]. [media] is applied to every rule
  /// found (for the body of an `@media` block); top-level calls pass null.
  static void _parseRules(
    String css,
    List<CssRule> rules,
    _Counter order,
    CssMediaQuery? media,
  ) {
    var i = 0;
    while (i < css.length) {
      final braceOpen = css.indexOf('{', i);
      if (braceOpen < 0) break;

      var prelude = css.substring(i, braceOpen);
      // Statement at-rules (`@import …;`) and stray semicolons end at a
      // top-level `;` and carry no block; drop everything up to the last one so
      // an `@import` doesn't swallow the rule that follows it.
      final semi = _lastTopLevelSemicolon(prelude);
      if (semi >= 0) prelude = prelude.substring(semi + 1);
      prelude = prelude.trim();

      final braceClose = _matchBrace(css, braceOpen);
      if (braceClose < 0) break;
      final body = css.substring(braceOpen + 1, braceClose);

      if (prelude.startsWith('@')) {
        final lower = prelude.toLowerCase();
        if (media == null && lower.startsWith('@media')) {
          // Parse the nested rules under the media condition. (Nested @media is
          // not expected; media is only applied at the top level.)
          _parseRules(body, rules, order, _parseMedia(prelude));
        }
        // Other at-rules (@font-face, @supports, @keyframes, …) are skipped.
        i = braceClose + 1;
        continue;
      }

      final declarations = parseInlineDeclarations(body);
      if (!declarations.isEmpty) {
        for (final selectorText in _splitTopLevelCommas(prelude)) {
          final selector = CssSelector.tryParse(selectorText);
          if (selector != null) {
            rules.add(
              CssRule(
                selector: selector,
                declarations: declarations,
                order: order.next(),
                media: media,
              ),
            );
          }
        }
      }
      i = braceClose + 1;
    }
  }

  /// Parses an `@media` prelude into a [CssMediaQuery]. The prelude is a
  /// comma-separated list of alternatives (CSS treats the comma as OR); each
  /// alternative is an AND of `(...)` features. Recognizes width features
  /// (`max-width`/`min-width` and their deprecated `*-device-width` forms,
  /// which we treat as the viewport width); any other feature (orientation,
  /// hover, …) or a `print` type makes THAT alternative non-applicable, so it
  /// never matches — but its siblings still can. A bare `@media screen` with no
  /// width feature is always-on.
  static CssMediaQuery _parseMedia(String prelude) {
    return CssMediaQuery([
      for (final part in _splitTopLevelCommas(prelude)) _parseMediaClause(part),
    ]);
  }

  static CssMediaClause _parseMediaClause(String prelude) {
    final lower = prelude.toLowerCase();
    if (lower.contains('print') ||
        lower.contains('speech') ||
        lower.contains('not screen')) {
      return const CssMediaClause(applicable: false);
    }
    final mediaType = lower
        .replaceAll(_anyFeature, ' ')
        .replaceFirst('@media', ' ')
        .replaceAll(RegExp(r'\b(only|screen|all|and)\b'), ' ')
        .trim();
    if (mediaType.isNotEmpty) {
      return const CssMediaClause(applicable: false);
    }
    double? maxWidth;
    double? minWidth;
    var applicable = true;
    for (final group in _anyFeature.allMatches(prelude)) {
      final m = _widthFeature.firstMatch(group.group(1)!.trim());
      if (m == null) {
        applicable = false; // a feature we don't understand
        continue;
      }
      var value = double.tryParse(m.group(2)!);
      if (value == null) {
        applicable = false;
      } else {
        final unit = m.group(3)!.toLowerCase();
        if (unit == 'em' || unit == 'rem') value *= 16;
      }
      if (value == null) {
        applicable = false;
      } else if (m.group(1)!.toLowerCase().startsWith('max')) {
        maxWidth = value;
      } else {
        minWidth = value;
      }
    }
    return CssMediaClause(
      minWidth: minWidth,
      maxWidth: maxWidth,
      applicable: applicable,
    );
  }

  static final RegExp _anyFeature = RegExp(r'\(([^)]*)\)');
  static final RegExp _widthFeature = RegExp(
    r'^(max-width|min-width|max-device-width|min-device-width)\s*:\s*([0-9.]+)\s*(px|em|rem)$',
    caseSensitive: false,
  );

  /// Parses a declaration block (`color:red; font-weight:bold !important`) into
  /// values + the set of `!important` properties.
  static CssDecls parseInlineDeclarations(String text) {
    final values = <String, String>{};
    final important = <String>{};
    for (final part in _splitDeclarations(text)) {
      final colon = part.indexOf(':');
      if (colon <= 0) continue;
      final prop = part.substring(0, colon).trim().toLowerCase();
      var value = part.substring(colon + 1).trim();
      if (prop.isEmpty || value.isEmpty) continue;
      final hadImportant = _importantPattern.hasMatch(value);
      if (hadImportant) {
        value = value.replaceAll(_importantPattern, '').trim();
        if (value.isEmpty) continue;
      }
      // Within one block, `!important` beats a later normal declaration of the
      // same property regardless of source order (`color:red!important;
      // color:blue` stays red), matching the cascade.
      for (final entry in CssDeclarationExpander.expand(prop, value).entries) {
        if (!hadImportant && important.contains(entry.key)) continue;
        // Reinsertion also preserves order for overlapping supported properties
        // that haven't been expanded (for example font and font-size).
        values.remove(entry.key);
        values[entry.key] = entry.value;
        if (hadImportant) important.add(entry.key);
      }
    }
    return CssDecls(values, important);
  }

  static final RegExp _importantPattern = RegExp(
    r'\s*!\s*important\s*$',
    caseSensitive: false,
  );

  /// Splits a declaration block on `;`, but not on semicolons inside
  /// parentheses (e.g. data URIs) or quotes.
  static List<String> _splitDeclarations(String text) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var depth = 0;
    String? quote;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quote != null) {
        buffer.write(ch);
        if (ch == quote) quote = null;
        continue;
      }
      switch (ch) {
        case '"':
        case "'":
          quote = ch;
          buffer.write(ch);
          break;
        case '(':
          depth++;
          buffer.write(ch);
          break;
        case ')':
          if (depth > 0) depth--;
          buffer.write(ch);
          break;
        case ';':
          if (depth == 0) {
            parts.add(buffer.toString());
            buffer.clear();
          } else {
            buffer.write(ch);
          }
          break;
        default:
          buffer.write(ch);
      }
    }
    if (buffer.isNotEmpty) parts.add(buffer.toString());
    return parts;
  }

  /// Index of the last `;` that sits outside parentheses and quotes, or -1.
  static int _lastTopLevelSemicolon(String s) {
    var depth = 0;
    String? quote;
    var last = -1;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (quote != null) {
        if (ch == quote) quote = null;
        continue;
      }
      switch (ch) {
        case '"':
        case "'":
          quote = ch;
          break;
        case '(':
          depth++;
          break;
        case ')':
          if (depth > 0) depth--;
          break;
        case ';':
          if (depth == 0) last = i;
          break;
      }
    }
    return last;
  }

  static List<String> _splitTopLevelCommas(String text) {
    final result = <String>[];
    final buffer = StringBuffer();
    var squareDepth = 0;
    var roundDepth = 0;
    String? quote;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quote != null) {
        buffer.write(ch);
        if (ch == quote && (i == 0 || text[i - 1] != r'\')) quote = null;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '[') {
        squareDepth++;
      } else if (ch == ']') {
        if (squareDepth > 0) squareDepth--;
      } else if (ch == '(') {
        roundDepth++;
      } else if (ch == ')') {
        if (roundDepth > 0) roundDepth--;
      } else if (ch == ',' && squareDepth == 0 && roundDepth == 0) {
        result.add(buffer.toString());
        buffer.clear();
        continue;
      }
      buffer.write(ch);
    }
    result.add(buffer.toString());
    return result;
  }

  static String _stripComments(String css) {
    final out = StringBuffer();
    String? quote;
    var i = 0;
    while (i < css.length) {
      final ch = css[i];
      if (quote != null) {
        out.write(ch);
        if (ch == quote && (i == 0 || css[i - 1] != r'\')) quote = null;
        i++;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        out.write(ch);
        i++;
        continue;
      }
      if (ch == '/' && i + 1 < css.length && css[i + 1] == '*') {
        final end = css.indexOf('*/', i + 2);
        i = end < 0 ? css.length : end + 2;
        continue;
      }
      // CDO/CDC markers (`<!--` / `-->`) from `<style><!-- … --></style>`
      // wrappers are ignored tokens per the CSS spec — drop them so they don't
      // poison the first/last rule's selector.
      if (ch == '<' && css.startsWith('<!--', i)) {
        i += 4;
        continue;
      }
      if (ch == '-' && css.startsWith('-->', i)) {
        i += 3;
        continue;
      }
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  /// Returns the index of the `}` matching the `{` at [open], handling nesting
  /// (for `@media`). Returns -1 if unbalanced.
  static int _matchBrace(String text, int open) {
    var depth = 0;
    String? quote;
    for (var i = open; i < text.length; i++) {
      final ch = text[i];
      if (quote != null) {
        if (ch == quote && text[i - 1] != r'\') quote = null;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }
}

class _Counter {
  int _value = 0;
  int next() => _value++;
}
