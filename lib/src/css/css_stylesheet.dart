import 'package:html/dom.dart' as dom;

import 'css_selector.dart';

/// A parsed declaration block: property -> value, plus the set of properties
/// that were marked `!important`.
class CssDecls {
  const CssDecls(this.values, this.important);

  /// property -> value, lower-cased property names.
  final Map<String, String> values;

  /// Properties (subset of [values] keys) declared `!important`.
  final Set<String> important;

  static const CssDecls empty = CssDecls({}, {});

  bool get isEmpty => values.isEmpty;
}

/// A parsed `@media` condition — a comma-separated list of alternatives that
/// matches when ANY alternative matches (CSS treats the comma as OR). Each
/// alternative is an AND of width features ([CssMediaClause]); only width
/// features are understood. An alternative using a feature we don't recognise is
/// marked non-applicable (it never matches), but its siblings in the list still
/// can — so the very common `(max-device-width: 480px), (max-width: 480px)`
/// Gmail/Outlook query still activates on the `max-width` branch.
class CssMediaQuery {
  const CssMediaQuery(this.clauses);

  final List<CssMediaClause> clauses;

  /// Whether any alternative matches a render [width] (logical px). An empty
  /// list never matches.
  bool matches(double width) => clauses.any((c) => c.matches(width));
}

/// One alternative within a [CssMediaQuery]: an AND of width features.
class CssMediaClause {
  const CssMediaClause({this.minWidth, this.maxWidth, this.applicable = true});

  final double? minWidth;
  final double? maxWidth;

  /// False when the alternative uses a media feature we don't understand, so it
  /// can never match (the safe default for a static render).
  final bool applicable;

  bool matches(double width) {
    if (!applicable) return false;
    if (maxWidth != null && width > maxWidth!) return false;
    if (minWidth != null && width < minWidth!) return false;
    return true;
  }
}

/// A single style rule: one selector and its declaration block. A source rule
/// like `h1, h2 { ... }` is flattened into one [CssRule] per selector so each
/// carries its own specificity.
class CssRule {
  CssRule({
    required this.selector,
    required this.declarations,
    required this.order,
    this.media,
  });

  final CssSelector selector;

  /// property -> value (+ importance), already lower-cased property names.
  final CssDecls declarations;

  /// Source order, used as the final cascade tie-breaker.
  final int order;

  /// The `@media` condition guarding this rule, or null for an unconditional
  /// rule.
  final CssMediaQuery? media;
}

/// An author stylesheet (collected from all `<style>` blocks). Resolves the
/// winning declarations for an element by cascade (specificity, then order),
/// honoring `@media (max-width/min-width)` against the current render width and
/// letting `!important` declarations win.
class CssStylesheet {
  CssStylesheet(this.rules) {
    for (final rule in rules) {
      final selector = rule.selector;
      final id = selector.targetId;
      if (id != null) {
        (_byId[id] ??= []).add(rule);
      } else if (selector.targetClasses.isNotEmpty) {
        for (final className in selector.targetClasses) {
          (_byClass[className] ??= []).add(rule);
        }
      } else {
        final tag = selector.targetTag;
        if (tag != null && tag != '*') {
          (_byTag[tag] ??= []).add(rule);
        } else {
          _universal.add(rule);
        }
      }
    }
  }

  final List<CssRule> rules;
  final Map<String, List<CssRule>> _byId = {};
  final Map<String, List<CssRule>> _byClass = {};
  final Map<String, List<CssRule>> _byTag = {};
  final List<CssRule> _universal = [];

  static final CssStylesheet empty = CssStylesheet(const []);

  bool get isEmpty => rules.isEmpty;

  /// Returns the cascaded declarations matching [element] at render [width].
  /// Rules behind a `@media` query are included only when it matches [width].
  /// `!important` declarations override normal ones regardless of source.
  CssDecls declarationsFor(dom.Element element, double width) {
    final matched = <_Matched>[];
    final candidates = <CssRule>{..._universal};
    final id = element.id;
    if (id.isNotEmpty) candidates.addAll(_byId[id] ?? const []);
    candidates.addAll(
      _byTag[(element.localName ?? '').toLowerCase()] ?? const [],
    );
    for (final className in element.classes) {
      candidates.addAll(_byClass[className] ?? const []);
    }
    for (final rule in candidates) {
      final media = rule.media;
      if (media != null && !media.matches(width)) continue;
      if (rule.selector.matches(element)) matched.add(_Matched(rule));
    }
    if (matched.isEmpty) return CssDecls.empty;
    matched.sort(_compare);

    final normal = <String, String>{};
    final important = <String, String>{};
    for (final m in matched) {
      m.rule.declarations.values.forEach((prop, value) {
        if (m.rule.declarations.important.contains(prop)) {
          important.remove(prop);
          important[prop] = value;
        } else {
          normal.remove(prop);
          normal[prop] = value;
        }
      });
    }
    // Important declarations win over normal ones.
    final values = {...normal, ...important};
    return CssDecls(values, important.keys.toSet());
  }

  static int _compare(_Matched a, _Matched b) {
    final sa = a.rule.selector.specificity;
    final sb = b.rule.selector.specificity;
    final byId = sa.$1.compareTo(sb.$1);
    if (byId != 0) return byId;
    final byClass = sa.$2.compareTo(sb.$2);
    if (byClass != 0) return byClass;
    final byType = sa.$3.compareTo(sb.$3);
    if (byType != 0) return byType;
    return a.rule.order.compareTo(b.rule.order);
  }
}

class _Matched {
  _Matched(this.rule);
  final CssRule rule;
}
