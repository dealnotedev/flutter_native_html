import 'package:html/dom.dart' as dom;

/// Combinator between two compound selectors.
enum CssCombinator { descendant, child, adjacentSibling, generalSibling }

/// An attribute selector operator. `[attr]` is [exists]; the rest take a value.
enum CssAttrOp {
  exists,
  equals,
  includesWord,
  dashMatch,
  prefix,
  suffix,
  contains,
}

/// A single attribute selector, e.g. `[class="cell"]` or `[data-x^="on"]`.
class CssAttrSelector {
  CssAttrSelector(this.name, this.op, this.value);

  final String name; // lower-cased attribute name
  final CssAttrOp op;
  final String? value;

  bool matches(dom.Element element) {
    final actual = element.attributes[name];
    if (actual == null) return false;
    final v = value ?? '';
    switch (op) {
      case CssAttrOp.exists:
        return true;
      case CssAttrOp.equals:
        return actual == v;
      case CssAttrOp.includesWord:
        return v.isNotEmpty && actual.split(RegExp(r'\s+')).contains(v);
      case CssAttrOp.dashMatch:
        return actual == v || actual.startsWith('$v-');
      case CssAttrOp.prefix:
        return v.isNotEmpty && actual.startsWith(v);
      case CssAttrOp.suffix:
        return v.isNotEmpty && actual.endsWith(v);
      case CssAttrOp.contains:
        return v.isNotEmpty && actual.contains(v);
    }
  }
}

/// A compound selector: an optional type/`*`, optional id, zero or more
/// classes, and zero or more attribute selectors — e.g. `td.cell[class="x"]`.
class CssCompoundSelector {
  CssCompoundSelector({
    this.tag,
    this.id,
    Set<String>? classes,
    List<CssAttrSelector>? attrs,
    this.firstChild = false,
    this.lastChild = false,
    this.link = false,
    this.nthChild,
    this.not,
  }) : classes = classes ?? <String>{},
       attrs = attrs ?? const [];

  final String? tag; // lowercase, or null / '*' for universal
  final String? id;
  final Set<String> classes;
  final List<CssAttrSelector> attrs;
  final bool firstChild;
  final bool lastChild;
  final bool link;
  final String? nthChild;
  final CssCompoundSelector? not;

  bool matches(dom.Element element) {
    if (tag != null && tag != '*') {
      if ((element.localName ?? '').toLowerCase() != tag) return false;
    }
    if (id != null && element.id != id) return false;
    // Email rendering has no visited-history state. Hyperlinks use :link;
    // hover/active/visited selectors remain outside this static subset.
    if (link &&
        (!(const {'a', 'area'}.contains(element.localName)) ||
            !element.attributes.containsKey('href'))) {
      return false;
    }
    for (final c in classes) {
      if (!element.classes.contains(c)) return false;
    }
    for (final a in attrs) {
      if (!a.matches(element)) return false;
    }
    final siblings = element.parent?.children;
    if (firstChild &&
        (siblings == null || siblings.isEmpty || siblings.first != element)) {
      return false;
    }
    if (lastChild &&
        (siblings == null || siblings.isEmpty || siblings.last != element)) {
      return false;
    }
    if (nthChild != null) {
      if (siblings == null) return false;
      final index = siblings.indexOf(element) + 1;
      if (!_matchesNth(nthChild!, index)) return false;
    }
    if (not?.matches(element) ?? false) return false;
    return true;
  }

  /// Tests the 1-based [index] against a CSS `An+B` micro-syntax expression
  /// (`2n`, `2n+1`, `odd`, `even`, `3`, `-n+3`, …). An element matches when
  /// `index == a*n + b` for some non-negative integer `n`.
  static bool _matchesNth(String raw, int index) {
    final expr = raw.trim().toLowerCase().replaceAll(' ', '');
    int a;
    int b;
    if (expr == 'odd') {
      a = 2;
      b = 1;
    } else if (expr == 'even') {
      a = 2;
      b = 0;
    } else if (expr.contains('n')) {
      final parts = expr.split('n');
      final left = parts[0];
      final right = parts.length > 1 ? parts[1] : '';
      if (left.isEmpty || left == '+') {
        a = 1;
      } else if (left == '-') {
        a = -1;
      } else {
        final pa = int.tryParse(left);
        if (pa == null) return false;
        a = pa;
      }
      if (right.isEmpty) {
        b = 0;
      } else {
        final pb = int.tryParse(right);
        if (pb == null) return false;
        b = pb;
      }
    } else {
      final exact = int.tryParse(expr);
      if (exact == null) return false;
      a = 0;
      b = exact;
    }
    final diff = index - b;
    if (a == 0) return diff == 0;
    if (diff == 0) return true; // n == 0
    // n = diff / a must be a positive integer.
    return diff.remainder(a) == 0 && (diff > 0) == (a > 0);
  }

  /// Specificity contribution as (#id, #class, #type). Attribute selectors
  /// count at the class level, like CSS.
  (int, int, int) get specificity => (
    (id != null ? 1 : 0) + (not?.specificity.$1 ?? 0),
    classes.length +
        attrs.length +
        (firstChild ? 1 : 0) +
        (lastChild ? 1 : 0) +
        (link ? 1 : 0) +
        (nthChild == null ? 0 : 1) +
        (not?.specificity.$2 ?? 0),
    ((tag != null && tag != '*') ? 1 : 0) + (not?.specificity.$3 ?? 0),
  );
}

class _SeqItem {
  _SeqItem(this.compound, this.comboBefore);
  final CssCompoundSelector compound;
  final CssCombinator? comboBefore; // null for the first item
}

/// A full complex selector (a chain of compound selectors joined by
/// combinators), e.g. `table.body td > a`.
class CssSelector {
  CssSelector(this._items);

  final List<_SeqItem> _items;

  bool get isEmpty => _items.isEmpty;

  String? get targetId => _items.isEmpty ? null : _items.last.compound.id;
  String? get targetTag => _items.isEmpty ? null : _items.last.compound.tag;
  Set<String> get targetClasses =>
      _items.isEmpty ? const {} : _items.last.compound.classes;

  /// Tests whether [element] matches this selector, walking ancestors for
  /// descendant/child combinators (matched right-to-left, like browsers).
  bool matches(dom.Element element) {
    if (_items.isEmpty) return false;
    final last = _items.length - 1;
    if (!_items[last].compound.matches(element)) return false;
    // Keep every viable ancestor/sibling, not only the nearest match. A later
    // child combinator can reject the nearest while an earlier one succeeds.
    // Deduplicate each frontier and shared walks to avoid exponential paths
    // and recursion for long selectors.
    var candidates = <dom.Element>{element};
    for (var j = last; j > 0; j--) {
      final combo = _items[j].comboBefore ?? CssCombinator.descendant;
      final comp = _items[j - 1].compound;
      final next = <dom.Element>{};
      final visited = <dom.Element>{};
      final sibling =
          combo == CssCombinator.adjacentSibling ||
          combo == CssCombinator.generalSibling;
      final single =
          combo == CssCombinator.child ||
          combo == CssCombinator.adjacentSibling;
      for (final candidate in candidates) {
        var node = sibling
            ? candidate.previousElementSibling
            : candidate.parent;
        while (node != null && visited.add(node)) {
          if (comp.matches(node)) next.add(node);
          if (single) break;
          node = sibling ? node.previousElementSibling : node.parent;
        }
      }
      if (next.isEmpty) return false;
      candidates = next;
    }
    return true;
  }

  (int, int, int) get specificity {
    var ids = 0, classes = 0, types = 0;
    for (final item in _items) {
      final s = item.compound.specificity;
      ids += s.$1;
      classes += s.$2;
      types += s.$3;
    }
    return (ids, classes, types);
  }

  /// Parses a single complex selector. Returns `null` when it contains tokens
  /// outside the supported subset (attribute/pseudo selectors), so the caller
  /// can skip it rather than mis-apply it.
  static CssSelector? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    // Pseudo-classes/elements are unsupported; skipping is safer than a partial
    // match. (Attribute selectors ARE supported — common in responsive email,
    // e.g. `table[class="table"]{width:100%}`.) A `:` inside an attribute value
    // like `[href="https://…"]` is fine, so only bail on a `:` outside brackets.
    final items = <_SeqItem>[];
    CssCombinator? pendingCombo;
    final tokens = _tokenize(text);
    for (final token in tokens) {
      if (token == '>') {
        pendingCombo = CssCombinator.child;
        continue;
      }
      if (token == '+') {
        pendingCombo = CssCombinator.adjacentSibling;
        continue;
      }
      if (token == '~') {
        pendingCombo = CssCombinator.generalSibling;
        continue;
      }
      final compound = _parseCompound(token);
      if (compound == null) return null;
      items.add(
        _SeqItem(
          compound,
          items.isEmpty ? null : (pendingCombo ?? CssCombinator.descendant),
        ),
      );
      pendingCombo = null;
    }
    return items.isEmpty ? null : CssSelector(items);
  }

  static CssCompoundSelector? _parseCompound(String token) {
    // Pull out any `[...]` attribute selectors first, then parse the remaining
    // tag/.class/#id text.
    final attrs = <CssAttrSelector>[];
    var failed = false;
    var rest = token.replaceAllMapped(_attrBlock, (m) {
      final attr = _parseAttr(m.group(1)!);
      if (attr == null) {
        failed = true;
      } else {
        attrs.add(attr);
      }
      return '';
    });
    if (failed) return null;

    var firstChild = false;
    var lastChild = false;
    var link = false;
    String? nthChild;
    CssCompoundSelector? not;
    rest = rest.replaceAllMapped(_pseudoPattern, (match) {
      final name = match.group(1)!.toLowerCase();
      final argument = match.group(2);
      if (name == 'first-child') {
        firstChild = true;
      } else if (name == 'last-child') {
        lastChild = true;
      } else if (name == 'link') {
        if (argument != null) {
          failed = true;
        } else {
          link = true;
        }
      } else if (name == 'nth-child') {
        if (argument == null) {
          failed = true;
        } else {
          nthChild = argument;
        }
      } else if (name == 'not') {
        if (argument == null || argument.contains(':')) {
          failed = true;
        } else {
          not = _parseCompound(argument.trim());
          if (not == null) failed = true;
        }
      }
      return '';
    });
    if (failed || rest.contains(':')) return null;

    String? tag;
    String? id;
    final classes = <String>{};
    if (rest.isNotEmpty) {
      final matches = RegExp(r'([.#]?)([A-Za-z0-9_*-]+)').allMatches(rest);
      var consumed = 0;
      for (final m in matches) {
        consumed += m.group(0)!.length;
        final prefix = m.group(1)!;
        final name = m.group(2)!;
        switch (prefix) {
          case '.':
            classes.add(name);
            break;
          case '#':
            id = name;
            break;
          default:
            tag = name.toLowerCase();
        }
      }
      if (consumed != rest.length) return null; // stray unsupported chars
    }
    final hasPseudo =
        firstChild || lastChild || link || nthChild != null || not != null;
    if (tag == null &&
        id == null &&
        classes.isEmpty &&
        attrs.isEmpty &&
        !hasPseudo) {
      return null;
    }
    return CssCompoundSelector(
      tag: tag,
      id: id,
      classes: classes,
      attrs: attrs,
      firstChild: firstChild,
      lastChild: lastChild,
      link: link,
      nthChild: nthChild,
      not: not,
    );
  }

  static final RegExp _attrBlock = RegExp(r'\[([^\]]*)\]');
  static final RegExp _pseudoPattern = RegExp(
    r':(first-child|last-child|nth-child|not|link)(?![\w-])(?:\(([^()]*)\))?',
    caseSensitive: false,
  );
  static final RegExp _attrPattern = RegExp(
    r'''^\s*([A-Za-z_][\w-]*)\s*(?:([~^$*|]?=)\s*("[^"]*"|'[^']*'|[^\s\]]+))?\s*$''',
  );

  /// Parses the inside of an attribute selector (`class="cell"`, `id`,
  /// `data-x^="on"`). Returns null when it isn't a shape we understand.
  static CssAttrSelector? _parseAttr(String inner) {
    final m = _attrPattern.firstMatch(inner);
    if (m == null) return null;
    final name = m.group(1)!.toLowerCase();
    final opStr = m.group(2);
    if (opStr == null) return CssAttrSelector(name, CssAttrOp.exists, null);
    var value = m.group(3) ?? '';
    if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    final op = switch (opStr) {
      '=' => CssAttrOp.equals,
      '~=' => CssAttrOp.includesWord,
      '|=' => CssAttrOp.dashMatch,
      '^=' => CssAttrOp.prefix,
      r'$=' => CssAttrOp.suffix,
      '*=' => CssAttrOp.contains,
      _ => null,
    };
    return op == null ? null : CssAttrSelector(name, op, value);
  }

  /// Splits a complex selector into compound tokens and `>` combinators,
  /// without breaking inside `[...]` attribute selectors or quotes.
  static List<String> _tokenize(String text) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var depth = 0;
    String? quote;
    void flush() {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
    }

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
        case '[':
        case '(':
          depth++;
          buffer.write(ch);
        case ']':
        case ')':
          if (depth > 0) depth--;
          buffer.write(ch);
        case '>' when depth == 0:
        case '+' when depth == 0:
        case '~' when depth == 0:
          flush();
          tokens.add(ch);
        case ' ' when depth == 0:
        case '\t' when depth == 0:
        case '\n' when depth == 0:
          flush();
        default:
          buffer.write(ch);
      }
    }
    flush();
    return tokens;
  }
}
