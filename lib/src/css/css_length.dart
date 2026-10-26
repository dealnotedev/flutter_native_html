import 'package:flutter/widgets.dart';

/// Supported CSS length units.
///
/// Kept intentionally small for the email subset; extend here and in
/// [CssLength.resolve] when new units are needed.
enum CssLengthUnit { px, pt, em, rem, percent, auto, zero }

/// An immutable CSS length value (number + unit) that can be resolved to
/// logical pixels once the surrounding context (parent font size, percentage
/// base) is known.
@immutable
class CssLength {
  const CssLength(this.value, this.unit);

  final double value;
  final CssLengthUnit unit;

  static const CssLength zero = CssLength(0, CssLengthUnit.zero);
  static const CssLength auto = CssLength(0, CssLengthUnit.auto);

  bool get isAuto => unit == CssLengthUnit.auto;

  /// Parses a single CSS length token such as `12px`, `1.5em`, `80%`, `0`,
  /// `auto`. Returns `null` when the value is unparseable so callers can fall
  /// back to inheritance/defaults.
  static CssLength? tryParse(String? raw) {
    if (raw == null) return null;
    final input = raw.trim().toLowerCase();
    if (input.isEmpty) return null;
    if (input == 'auto') return auto;
    if (input == '0') return zero;

    final match = _pattern.firstMatch(input);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null || !number.isFinite) return null;
    final unit = switch (match.group(2)) {
      'px' || '' => CssLengthUnit.px,
      'pt' => CssLengthUnit.pt,
      'em' => CssLengthUnit.em,
      'rem' => CssLengthUnit.rem,
      '%' => CssLengthUnit.percent,
      _ => null, // vw/vh/ex/... unsupported for now
    };
    if (unit == null) return null;
    return CssLength(number, unit);
  }

  static final RegExp _pattern = RegExp(r'^(-?\d*\.?\d+)\s*(px|pt|em|rem|%|)$');

  /// Resolves this length to logical pixels.
  ///
  /// [fontSize] is the current (parent) font size for `em`; [rootFontSize] for
  /// `rem`; [percentBase] is the value `%` is relative to (e.g. container
  /// width). When a base is unknown pass `null` and the fallback is returned.
  double? resolve({
    required double fontSize,
    required double rootFontSize,
    double? percentBase,
    double? fallback,
  }) {
    switch (unit) {
      case CssLengthUnit.zero:
        return 0;
      case CssLengthUnit.px:
        return value;
      case CssLengthUnit.pt:
        return value * 96.0 / 72.0;
      case CssLengthUnit.em:
        return value * fontSize;
      case CssLengthUnit.rem:
        return value * rootFontSize;
      case CssLengthUnit.percent:
        return percentBase == null ? fallback : value / 100.0 * percentBase;
      case CssLengthUnit.auto:
        return fallback;
    }
  }

  @override
  String toString() => 'CssLength($value, $unit)';
}
