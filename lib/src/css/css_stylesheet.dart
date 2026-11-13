import 'dart:ui' show Brightness;

import 'package:html/dom.dart' as dom;

import 'css_selector.dart';

/// A parsed declaration block: property -> value, plus the set of properties
/// that were marked `!important`.
class CssDecls {
  const CssDecls(
    this.values,
    this.important, [
    this.pendingShorthands = const {},
  ]);

  /// property -> value; custom-property names retain their case.
  final Map<String, String> values;

  /// Properties (subset of [values] keys) declared `!important`.
  final Set<String> important;

  /// Longhand -> shorthand whose value awaits custom-property substitution.
  final Map<String, String> pendingShorthands;

  static const CssDecls empty = CssDecls({}, {});

  bool get isEmpty => values.isEmpty;
}

/// A parsed `@media` condition — a comma-separated list of alternatives that
/// matches when ANY alternative matches (CSS treats the comma as OR). Each
/// alternative is an AND of width and color-scheme features ([CssMediaClause]).
/// An alternative using a feature we don't recognise is
/// marked non-applicable (it never matches), but its siblings in the list still
/// can — so the very common `(max-device-width: 480px), (max-width: 480px)`
/// Gmail/Outlook query still activates on the `max-width` branch.
class CssMediaQuery {
  const CssMediaQuery(this.clauses);

  final List<CssMediaClause> clauses;

  /// Whether any alternative matches a render [width] (logical px). An empty
  /// list never matches.
  bool matches(double width, {Brightness brightness = Brightness.light}) =>
      clauses.any((c) => c.matches(width, brightness: brightness));

  /// Conjoin nested media queries without losing comma-separated alternatives.
  CssMediaQuery and(CssMediaQuery other) {
    if (clauses.length * other.clauses.length > 64) {
      return const CssMediaQuery([]);
    }
    return CssMediaQuery([
      for (final a in clauses)
        for (final b in other.clauses)
          CssMediaClause(
            minWidth: _max(a.minWidth, b.minWidth),
            maxWidth: _min(a.maxWidth, b.maxWidth),
            brightness: a.brightness ?? b.brightness,
            applicable:
                a.applicable &&
                b.applicable &&
                (a.brightness == null ||
                    b.brightness == null ||
                    a.brightness == b.brightness),
          ),
    ]);
  }

  static double? _min(double? a, double? b) => a == null
      ? b
      : b == null
      ? a
      : (a < b ? a : b);
  static double? _max(double? a, double? b) => a == null
      ? b
      : b == null
      ? a
      : (a > b ? a : b);
}

/// One alternative: an AND of width and color-scheme features.
class CssMediaClause {
  const CssMediaClause({
    this.minWidth,
    this.maxWidth,
    this.brightness,
    this.applicable = true,
  });

  final double? minWidth;
  final double? maxWidth;
  final Brightness? brightness;

  /// False when the alternative uses a media feature we don't understand, so it
  /// can never match (the safe default for a static render).
  final bool applicable;

  bool matches(double width, {Brightness brightness = Brightness.light}) {
    if (!applicable) return false;
    if (this.brightness != null && this.brightness != brightness) return false;
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
/// honoring width/color-scheme media conditions and `!important` declarations.
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
  CssDecls declarationsFor(
    dom.Element element,
    double width, {
    Brightness brightness = Brightness.light,
    CssMatchContext? matchContext,
  }) {
    final matched = <_Matched>[];
    for (final rule in _candidatesFor(element)) {
      matchContext?.visit();
      final media = rule.media;
      if (media != null && !media.matches(width, brightness: brightness)) {
        continue;
      }
      if (rule.selector.matches(element, matchContext)) {
        matched.add(_Matched(rule));
      }
    }
    if (matched.isEmpty) return CssDecls.empty;
    matched.sort(_compare);

    final normal = <String, String>{};
    final important = <String, String>{};
    final normalPending = <String, String>{};
    final importantPending = <String, String>{};
    for (final m in matched) {
      m.rule.declarations.values.forEach((prop, value) {
        if (m.rule.declarations.important.contains(prop)) {
          important.remove(prop);
          important[prop] = value;
          _replacePending(importantPending, prop, m.rule.declarations);
        } else {
          normal.remove(prop);
          normal[prop] = value;
          _replacePending(normalPending, prop, m.rule.declarations);
        }
      });
    }
    normal.removeWhere((property, _) => important.containsKey(property));
    normalPending.removeWhere((property, _) => important.containsKey(property));
    return CssDecls(
      {...normal, ...important},
      important.keys.toSet(),
      {...normalPending, ...importantPending},
    );
  }

  static void _replacePending(
    Map<String, String> pending,
    String property,
    CssDecls source,
  ) {
    if (source.pendingShorthands[property] case final shorthand?) {
      pending[property] = shorthand;
    } else {
      pending.remove(property);
    }
  }

  /// A dark-only rule must match real content and affect a supported theme
  /// property. An unused selector or an empty marker is not a dark theme.
  bool hasDarkStylesFor(
    dom.Element element,
    double width, {
    CssMatchContext? matchContext,
  }) => _candidatesFor(element).any((rule) {
    matchContext?.visit();
    final media = rule.media;
    return media != null &&
        media.matches(width, brightness: Brightness.dark) &&
        !media.matches(width, brightness: Brightness.light) &&
        rule.selector.matches(element, matchContext) &&
        rule.declarations.values.keys.any(
          (p) =>
              p.startsWith('--') ||
              p == 'color' ||
              p.startsWith('background') ||
              p == 'display' ||
              p == 'visibility' ||
              p.startsWith('border'),
        );
  });

  Set<CssRule> _candidatesFor(dom.Element element) {
    final candidates = <CssRule>{..._universal};
    final id = element.id;
    if (id.isNotEmpty) candidates.addAll(_byId[id] ?? const []);
    candidates.addAll(
      _byTag[(element.localName ?? '').toLowerCase()] ?? const [],
    );
    for (final className in element.classes) {
      candidates.addAll(_byClass[className] ?? const []);
    }
    return candidates;
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
