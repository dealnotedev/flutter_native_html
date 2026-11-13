/// Computed custom properties for one element. Inherited values are already
/// substituted, so a child's overrides cannot rewrite a parent's token aliases.
class CssVariables {
  CssVariables(this.local, [this.parent]);

  final Map<String, String> local;
  final CssVariables? parent;
  final Map<String, String?> _computed = {};
  final List<String> _pending = [];
  late final Set<String> _dependencyCycles = _findCycles();
  static final _references = RegExp(
    r'''\\.|"[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*'|var\(\s*(--[\w-]+)\s*[,)]''',
  );

  String? lookup(String name) {
    if (_computed.containsKey(name)) return _computed[name];
    if (!local.containsKey(name)) return parent?.lookup(name);
    if (_dependencyCycles.contains(name)) return _computed[name] = null;
    if (_pending.length >= 32 || _pending.contains(name)) return null;
    _pending.add(name);
    final raw = local[name]!;
    final result = switch (raw.trim()) {
      'inherit' || 'unset' => parent?.lookup(name),
      'initial' => null,
      _ => resolve(raw),
    };
    _pending.removeLast();
    return _computed[name] = result;
  }

  // The dependency graph includes references in fallbacks, even when
  // substitution would never select them. Only local definitions form cycles.
  Set<String> _findCycles() {
    final forward = <String, Set<String>>{};
    final reverse = <String, List<String>>{};
    for (final MapEntry(key: name, value: value) in local.entries) {
      final edges = <String>{
        for (final match in _references.allMatches(value))
          if (match.group(1) case final String target)
            if (local.containsKey(target)) target,
      };
      forward[name] = edges;
      for (final target in edges) {
        (reverse[target] ??= []).add(name);
      }
    }

    final visited = <String>{};
    final order = <String>[];
    for (final name in forward.keys) {
      if (!visited.add(name)) continue;
      final stack = [(name, forward[name]!.iterator)];
      while (stack.isNotEmpty) {
        final (current, children) = stack.last;
        if (!children.moveNext()) {
          order.add(current);
          stack.removeLast();
        } else if (visited.add(children.current)) {
          stack.add((children.current, forward[children.current]!.iterator));
        }
      }
    }

    visited.clear();
    final cycles = <String>{};
    for (final name in order.reversed) {
      if (!visited.add(name)) continue;
      final pending = [name];
      final group = <String>[];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        group.add(current);
        for (final parent in reverse[current] ?? const <String>[]) {
          if (visited.add(parent)) pending.add(parent);
        }
      }
      if (group.length > 1 || forward[name]!.contains(name)) {
        cycles.addAll(group);
      }
    }
    return cycles;
  }

  String? resolve(String value, [int depth = 0]) {
    if (depth >= 32 || value.length > 65536) return null;
    final output = StringBuffer();
    String? quote;
    for (var i = 0; i < value.length;) {
      final ch = value[i];
      if (ch == r'\' && i + 1 < value.length) {
        output.write(value.substring(i, i + 2));
        i += 2;
        continue;
      }
      if (quote != null) {
        output.write(ch);
        if (ch == quote) quote = null;
        i++;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        output.write(ch);
        i++;
        continue;
      }
      if (!value.startsWith('var(', i)) {
        output.write(ch);
        i++;
        continue;
      }
      var nesting = 1;
      int? comma;
      var end = i + 4;
      String? innerQuote;
      for (; end < value.length; end++) {
        final c = value[end];
        if (c == r'\') {
          end++;
          continue;
        }
        if (innerQuote != null) {
          if (c == innerQuote) innerQuote = null;
        } else if (c == '"' || c == "'") {
          innerQuote = c;
        } else if (c == '(') {
          nesting++;
        } else if (c == ')') {
          if (--nesting == 0) break;
        } else if (c == ',' && nesting == 1 && comma == null) {
          comma = end;
        }
      }
      if (end >= value.length) return null;
      final name = value.substring(i + 4, comma ?? end).trim();
      if (!RegExp(r'^--[\w-]+$').hasMatch(name)) return null;
      final replacement =
          lookup(name) ??
          (comma == null
              ? null
              : resolve(value.substring(comma + 1, end), depth + 1));
      if (replacement == null) return null;
      output.write(replacement);
      if (output.length > 65536) return null;
      i = end + 1;
    }
    return output.length > 65536 ? null : output.toString();
  }
}
