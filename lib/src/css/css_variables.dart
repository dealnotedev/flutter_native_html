/// Computed custom properties for one element. Inherited values are already
/// substituted, so a child's overrides cannot rewrite a parent's token aliases.
class CssVariables {
  CssVariables(this.local, [this.parent]);

  final Map<String, String> local;
  final CssVariables? parent;
  final Map<String, String?> _computed = {};
  final List<String> _pending = [];
  final Set<String> _cyclic = {};

  String? lookup(String name) {
    if (_computed.containsKey(name)) return _computed[name];
    if (!local.containsKey(name)) return parent?.lookup(name);
    final cycle = _pending.indexOf(name);
    if (cycle >= 0) {
      _cyclic.addAll(_pending.skip(cycle));
      return null;
    }
    if (_pending.length >= 32) return null;
    _pending.add(name);
    final raw = local[name]!;
    final result = switch (raw.trim()) {
      'inherit' || 'unset' => parent?.lookup(name),
      'initial' => null,
      _ => resolve(raw),
    };
    _pending.removeLast();
    return _computed[name] = _cyclic.contains(name) ? null : result;
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
