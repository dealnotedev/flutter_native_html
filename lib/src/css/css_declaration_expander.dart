/// Expands box shorthands before specificity and !important are compared.
/// Every generated longhand keeps the priority of its original declaration.
class CssDeclarationExpander {
  const CssDeclarationExpander._();

  static Map<String, String> expand(String property, String value) {
    final side = property.startsWith('border-')
        ? property.substring('border-'.length)
        : '';
    if (property == 'border' || _sides.contains(side)) {
      var width = 'medium', style = 'none', color = 'currentcolor';
      for (final token in _tokens(value)) {
        if (_borderStyles.contains(token.toLowerCase())) {
          style = token;
        } else if (_length.hasMatch(token) ||
            const {'thin', 'medium', 'thick'}.contains(token.toLowerCase())) {
          width = token;
        } else {
          color = token;
        }
      }
      return {
        for (final edge in property == 'border' ? _sides : [side]) ...{
          'border-$edge-width': width,
          'border-$edge-style': style,
          'border-$edge-color': color,
        },
      };
    }
    if (const {'width', 'style', 'color'}.contains(side)) {
      final values = _four(_tokens(value));
      return values == null
          ? const {}
          : {
              for (var i = 0; i < _sides.length; i++)
                'border-${_sides[i]}-$side': values[i],
            };
    }
    if (property != 'margin' && property != 'padding') {
      return {property: value};
    }
    final tokens = value.trim().split(RegExp(r'\s+'));
    if (tokens.isEmpty || tokens.length > 4) return const {};
    // An invalid shorthand must not partially overwrite an earlier value.
    if (tokens.any(
      (token) =>
          !_length.hasMatch(token) &&
          !(property == 'margin' && token.toLowerCase() == 'auto'),
    )) {
      return const {};
    }
    final values = _four(tokens)!;
    return {
      for (var i = 0; i < _sides.length; i++)
        '$property-${_sides[i]}': values[i],
    };
  }

  static const _sides = ['top', 'right', 'bottom', 'left'];
  static const _borderStyles = {
    'none',
    'hidden',
    'solid',
    'dashed',
    'dotted',
    'double',
  };

  static List<String>? _four(List<String> tokens) {
    if (tokens.isEmpty || tokens.length > 4) return null;
    final top = tokens[0];
    final right = tokens.length > 1 ? tokens[1] : top;
    return [
      top,
      right,
      tokens.length > 2 ? tokens[2] : top,
      tokens.length > 3 ? tokens[3] : right,
    ];
  }

  static List<String> _tokens(String value) {
    final result = <String>[];
    var start = 0, depth = 0;
    for (var i = 0; i <= value.length; i++) {
      if (i < value.length) {
        if (value[i] == '(') depth++;
        if (value[i] == ')') depth--;
      }
      if (i == value.length || (depth == 0 && _whitespace.hasMatch(value[i]))) {
        if (i > start) result.add(value.substring(start, i));
        start = i + 1;
      }
    }
    return result;
  }

  static final _whitespace = RegExp(r'\s');
  static final _length = RegExp(
    r'^-?(?:\d*\.)?\d+(?:px|pt|em|rem|%)?$',
    caseSensitive: false,
  );
}
