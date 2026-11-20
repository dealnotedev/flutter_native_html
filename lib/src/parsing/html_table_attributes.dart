final _integerPrefix = RegExp(r'^[\t\n\f\r ]*\+?([0-9]+)');

/// HTML cellpadding accepts an integer prefix even when a unit follows it.
/// Missing attributes use the browser default, while invalid values use zero.
double parseHtmlCellPadding(String? raw) {
  if (raw == null) return 1;
  final digits = _integerPrefix.firstMatch(raw)?.group(1);
  final value = digits == null ? null : double.tryParse(digits);
  return value != null && value.isFinite ? value : 0;
}
