import 'dart:ui';

/// Parses CSS color values into Flutter [Color]s.
///
/// Supports the forms common in email HTML: `#rgb`, `#rrggbb`, `#rrggbbaa`,
/// `rgb()/rgba()`, `hsl()/hsla()`, the `transparent` keyword and the standard
/// named colors, including literal fallbacks for unresolved `var()` tokens.
/// Returns `null` for anything it does not understand so the
/// caller can fall back to inheritance.
class CssColor {
  const CssColor._();

  static Color? tryParse(String? raw) {
    if (raw == null) return null;
    var value = raw.trim().toLowerCase();
    // Email design systems often export a custom-property reference with a
    // literal fallback but no variable definition. Keep that fallback even
    // though this renderer does not evaluate custom-property declarations.
    for (var nesting = 0; value.startsWith('var('); nesting++) {
      if (nesting >= 32 || !value.endsWith(')')) return null;
      var depth = 0;
      int? comma;
      for (var i = 4; i < value.length - 1; i++) {
        final ch = value[i];
        if (ch == '(') depth++;
        if (ch == ')') {
          if (depth == 0) return null;
          depth--;
        }
        if (ch == ',' && depth == 0 && comma == null) comma = i;
      }
      if (depth != 0 || comma == null) return null;
      final name = value.substring(4, comma).trim();
      if (!RegExp(r'^--[\w-]+$').hasMatch(name)) return null;
      value = value.substring(comma + 1, value.length - 1).trim();
    }
    if (value.isEmpty) return null;

    if (value == 'transparent') return const Color(0x00000000);
    if (value == 'currentcolor') return null; // resolved by caller via inherit

    if (value.startsWith('#')) return _parseHex(value.substring(1));
    if (value.startsWith('rgb')) return _parseRgb(value);
    if (value.startsWith('hsl')) return _parseHsl(value);

    return _named[value];
  }

  static Color? _parseHex(String hex) {
    String full;
    switch (hex.length) {
      case 3: // rgb
        full = 'ff${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
        break;
      case 4: // rgba
        full =
            '${hex[3]}${hex[3]}${hex[0]}${hex[0]}'
            '${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
        break;
      case 6: // rrggbb
        full = 'ff$hex';
        break;
      case 8: // rrggbbaa -> aarrggbb
        full = '${hex.substring(6, 8)}${hex.substring(0, 6)}';
        break;
      default:
        return null;
    }
    final intValue = int.tryParse(full, radix: 16);
    return intValue == null ? null : Color(intValue);
  }

  static Color? _parseRgb(String value) {
    final parts = _argsOf(value);
    if (parts.length < 3) return null;
    final r = _channel(parts[0]);
    final g = _channel(parts[1]);
    final b = _channel(parts[2]);
    if (r == null || g == null || b == null) return null;
    final a = parts.length >= 4 ? _alpha(parts[3]) : 255;
    if (a == null) return null;
    return Color.fromARGB(a, r, g, b);
  }

  static Color? _parseHsl(String value) {
    final parts = _argsOf(value);
    if (parts.length < 3) return null;
    final h = double.tryParse(parts[0].replaceAll('deg', '').trim());
    final s = _percent(parts[1]);
    final l = _percent(parts[2]);
    if (h == null || s == null || l == null) return null;
    final a = parts.length >= 4 ? _alpha(parts[3]) : 255;
    if (a == null) return null;
    final rgb = _hslToRgb(h % 360, s, l);
    return Color.fromARGB(a, rgb[0], rgb[1], rgb[2]);
  }

  static List<String> _argsOf(String value) {
    final open = value.indexOf('(');
    final close = value.lastIndexOf(')');
    if (open < 0 || close < open) return const [];
    return value
        .substring(open + 1, close)
        // Comma syntax `rgb(r,g,b)` and modern space syntax `rgb(r g b / a)`
        // both split on any run of commas, slashes and whitespace.
        .split(RegExp(r'[\s,/]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static int? _channel(String raw) {
    if (raw.endsWith('%')) {
      final p = _percent(raw);
      return p == null ? null : (p * 255).round().clamp(0, 255);
    }
    final v = double.tryParse(raw);
    return v?.round().clamp(0, 255);
  }

  static int? _alpha(String raw) {
    if (raw.endsWith('%')) {
      final p = _percent(raw);
      return p == null ? null : (p * 255).round().clamp(0, 255);
    }
    final v = double.tryParse(raw);
    return v == null ? null : (v * 255).round().clamp(0, 255);
  }

  static double? _percent(String raw) {
    final v = double.tryParse(raw.replaceAll('%', '').trim());
    return v == null ? null : (v / 100.0).clamp(0.0, 1.0);
  }

  static List<int> _hslToRgb(double h, double s, double l) {
    double f(double n) {
      final k = (n + h / 30) % 12;
      final a = s * (l < 0.5 ? l : 1 - l);
      // max(-1, min(k - 3, 9 - k, 1))
      final m = [k - 3, 9 - k, 1.0].reduce((x, y) => x < y ? x : y);
      return l - a * (m > -1 ? m : -1);
    }

    return [
      (f(0) * 255).round().clamp(0, 255),
      (f(8) * 255).round().clamp(0, 255),
      (f(4) * 255).round().clamp(0, 255),
    ];
  }

  /// The full set of CSS named colors (CSS Color Level 4), including the
  /// `grey`/`gray`, `cyan`/`aqua`, `magenta`/`fuchsia` aliases and
  /// `rebeccapurple`. Emails use these freely (both in CSS and legacy
  /// `bgcolor="aliceblue"` attributes), so the complete table is required.
  static const Map<String, Color> _named = {
    'transparent': Color(0x00000000),
    'aliceblue': Color(0xFFF0F8FF),
    'antiquewhite': Color(0xFFFAEBD7),
    'aqua': Color(0xFF00FFFF),
    'aquamarine': Color(0xFF7FFFD4),
    'azure': Color(0xFFF0FFFF),
    'beige': Color(0xFFF5F5DC),
    'bisque': Color(0xFFFFE4C4),
    'black': Color(0xFF000000),
    'blanchedalmond': Color(0xFFFFEBCD),
    'blue': Color(0xFF0000FF),
    'blueviolet': Color(0xFF8A2BE2),
    'brown': Color(0xFFA52A2A),
    'burlywood': Color(0xFFDEB887),
    'cadetblue': Color(0xFF5F9EA0),
    'chartreuse': Color(0xFF7FFF00),
    'chocolate': Color(0xFFD2691E),
    'coral': Color(0xFFFF7F50),
    'cornflowerblue': Color(0xFF6495ED),
    'cornsilk': Color(0xFFFFF8DC),
    'crimson': Color(0xFFDC143C),
    'cyan': Color(0xFF00FFFF),
    'darkblue': Color(0xFF00008B),
    'darkcyan': Color(0xFF008B8B),
    'darkgoldenrod': Color(0xFFB8860B),
    'darkgray': Color(0xFFA9A9A9),
    'darkgrey': Color(0xFFA9A9A9),
    'darkgreen': Color(0xFF006400),
    'darkkhaki': Color(0xFFBDB76B),
    'darkmagenta': Color(0xFF8B008B),
    'darkolivegreen': Color(0xFF556B2F),
    'darkorange': Color(0xFFFF8C00),
    'darkorchid': Color(0xFF9932CC),
    'darkred': Color(0xFF8B0000),
    'darksalmon': Color(0xFFE9967A),
    'darkseagreen': Color(0xFF8FBC8F),
    'darkslateblue': Color(0xFF483D8B),
    'darkslategray': Color(0xFF2F4F4F),
    'darkslategrey': Color(0xFF2F4F4F),
    'darkturquoise': Color(0xFF00CED1),
    'darkviolet': Color(0xFF9400D3),
    'deeppink': Color(0xFFFF1493),
    'deepskyblue': Color(0xFF00BFFF),
    'dimgray': Color(0xFF696969),
    'dimgrey': Color(0xFF696969),
    'dodgerblue': Color(0xFF1E90FF),
    'firebrick': Color(0xFFB22222),
    'floralwhite': Color(0xFFFFFAF0),
    'forestgreen': Color(0xFF228B22),
    'fuchsia': Color(0xFFFF00FF),
    'gainsboro': Color(0xFFDCDCDC),
    'ghostwhite': Color(0xFFF8F8FF),
    'gold': Color(0xFFFFD700),
    'goldenrod': Color(0xFFDAA520),
    'gray': Color(0xFF808080),
    'grey': Color(0xFF808080),
    'green': Color(0xFF008000),
    'greenyellow': Color(0xFFADFF2F),
    'honeydew': Color(0xFFF0FFF0),
    'hotpink': Color(0xFFFF69B4),
    'indianred': Color(0xFFCD5C5C),
    'indigo': Color(0xFF4B0082),
    'ivory': Color(0xFFFFFFF0),
    'khaki': Color(0xFFF0E68C),
    'lavender': Color(0xFFE6E6FA),
    'lavenderblush': Color(0xFFFFF0F5),
    'lawngreen': Color(0xFF7CFC00),
    'lemonchiffon': Color(0xFFFFFACD),
    'lightblue': Color(0xFFADD8E6),
    'lightcoral': Color(0xFFF08080),
    'lightcyan': Color(0xFFE0FFFF),
    'lightgoldenrodyellow': Color(0xFFFAFAD2),
    'lightgray': Color(0xFFD3D3D3),
    'lightgrey': Color(0xFFD3D3D3),
    'lightgreen': Color(0xFF90EE90),
    'lightpink': Color(0xFFFFB6C1),
    'lightsalmon': Color(0xFFFFA07A),
    'lightseagreen': Color(0xFF20B2AA),
    'lightskyblue': Color(0xFF87CEFA),
    'lightslategray': Color(0xFF778899),
    'lightslategrey': Color(0xFF778899),
    'lightsteelblue': Color(0xFFB0C4DE),
    'lightyellow': Color(0xFFFFFFE0),
    'lime': Color(0xFF00FF00),
    'limegreen': Color(0xFF32CD32),
    'linen': Color(0xFFFAF0E6),
    'magenta': Color(0xFFFF00FF),
    'maroon': Color(0xFF800000),
    'mediumaquamarine': Color(0xFF66CDAA),
    'mediumblue': Color(0xFF0000CD),
    'mediumorchid': Color(0xFFBA55D3),
    'mediumpurple': Color(0xFF9370DB),
    'mediumseagreen': Color(0xFF3CB371),
    'mediumslateblue': Color(0xFF7B68EE),
    'mediumspringgreen': Color(0xFF00FA9A),
    'mediumturquoise': Color(0xFF48D1CC),
    'mediumvioletred': Color(0xFFC71585),
    'midnightblue': Color(0xFF191970),
    'mintcream': Color(0xFFF5FFFA),
    'mistyrose': Color(0xFFFFE4E1),
    'moccasin': Color(0xFFFFE4B5),
    'navajowhite': Color(0xFFFFDEAD),
    'navy': Color(0xFF000080),
    'oldlace': Color(0xFFFDF5E6),
    'olive': Color(0xFF808000),
    'olivedrab': Color(0xFF6B8E23),
    'orange': Color(0xFFFFA500),
    'orangered': Color(0xFFFF4500),
    'orchid': Color(0xFFDA70D6),
    'palegoldenrod': Color(0xFFEEE8AA),
    'palegreen': Color(0xFF98FB98),
    'paleturquoise': Color(0xFFAFEEEE),
    'palevioletred': Color(0xFFDB7093),
    'papayawhip': Color(0xFFFFEFD5),
    'peachpuff': Color(0xFFFFDAB9),
    'peru': Color(0xFFCD853F),
    'pink': Color(0xFFFFC0CB),
    'plum': Color(0xFFDDA0DD),
    'powderblue': Color(0xFFB0E0E6),
    'purple': Color(0xFF800080),
    'rebeccapurple': Color(0xFF663399),
    'red': Color(0xFFFF0000),
    'rosybrown': Color(0xFFBC8F8F),
    'royalblue': Color(0xFF4169E1),
    'saddlebrown': Color(0xFF8B4513),
    'salmon': Color(0xFFFA8072),
    'sandybrown': Color(0xFFF4A460),
    'seagreen': Color(0xFF2E8B57),
    'seashell': Color(0xFFFFF5EE),
    'sienna': Color(0xFFA0522D),
    'silver': Color(0xFFC0C0C0),
    'skyblue': Color(0xFF87CEEB),
    'slateblue': Color(0xFF6A5ACD),
    'slategray': Color(0xFF708090),
    'slategrey': Color(0xFF708090),
    'snow': Color(0xFFFFFAFA),
    'springgreen': Color(0xFF00FF7F),
    'steelblue': Color(0xFF4682B4),
    'tan': Color(0xFFD2B48C),
    'teal': Color(0xFF008080),
    'thistle': Color(0xFFD8BFD8),
    'tomato': Color(0xFFFF6347),
    'turquoise': Color(0xFF40E0D0),
    'violet': Color(0xFFEE82EE),
    'wheat': Color(0xFFF5DEB3),
    'white': Color(0xFFFFFFFF),
    'whitesmoke': Color(0xFFF5F5F5),
    'yellow': Color(0xFFFFFF00),
    'yellowgreen': Color(0xFF9ACD32),
  };
}
