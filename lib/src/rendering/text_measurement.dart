import 'package:flutter/widgets.dart';

/// Small plain-text measuring helper for places where the renderer needs a
/// precise text-only width before building a larger widget.
///
/// Keep this as a scalpel: it is intentionally limited to plain strings. Rich
/// HTML runs with nested widgets, images, or mixed spans should still rely on
/// Flutter's normal intrinsic layout.
class TextMeasurement {
  const TextMeasurement._();

  /// Measures one [text] as a single unwrapped line.
  static Size singleLineTextSize(
    String text, {
    required TextStyle style,
    required TextScaler scaler,
    TextDirection direction = TextDirection.ltr,
    Locale? locale,
  }) {
    final textPainter = TextPainter(
      text: TextSpan(style: style, text: text),
      textScaler: scaler,
      maxLines: 1,
      textDirection: direction,
      locale: locale,
    )..layout();
    try {
      return textPainter.size;
    } finally {
      textPainter.dispose();
    }
  }

  /// Returns the widest/tallest single-line size across [texts].
  static Size maxSingleLineTextSize(
    Iterable<String> texts, {
    required TextStyle style,
    required TextScaler scaler,
    TextDirection direction = TextDirection.ltr,
    Locale? locale,
  }) {
    var width = 0.0;
    var height = 0.0;

    for (final text in texts) {
      final size = singleLineTextSize(
        text,
        style: style,
        scaler: scaler,
        direction: direction,
        locale: locale,
      );
      if (width < size.width) width = size.width;
      if (height < size.height) height = size.height;
    }

    return Size(width, height);
  }

  /// Returns the widest single-line width across [texts].
  static double maxSingleLineTextWidth(
    Iterable<String> texts, {
    required TextStyle style,
    required TextScaler scaler,
    TextDirection direction = TextDirection.ltr,
    Locale? locale,
  }) => maxSingleLineTextSize(
    texts,
    style: style,
    scaler: scaler,
    direction: direction,
    locale: locale,
  ).width;

  /// Approximates CSS min-content width for plain text: the widest
  /// unbreakable segment in [texts].
  ///
  /// This treats ASCII whitespace as break opportunities and deliberately does
  /// not split on NBSP. It is meant for simple button/chip labels, not full
  /// Unicode line-breaking.
  static double maxUnbreakableTextWidth(
    Iterable<String> texts, {
    required TextStyle style,
    required TextScaler scaler,
    TextDirection direction = TextDirection.ltr,
    Locale? locale,
  }) {
    var width = 0.0;
    for (final text in texts) {
      for (final segment in _unbreakableSegments(text)) {
        final size = singleLineTextSize(
          segment,
          style: style,
          scaler: scaler,
          direction: direction,
          locale: locale,
        );
        if (width < size.width) width = size.width;
      }
    }
    return width;
  }

  static Iterable<String> _unbreakableSegments(String text) {
    final segments = text
        .split(RegExp(r'[ \t\r\n\f]+'))
        .where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? const [''] : segments;
  }
}

extension TextStyleMeasurementExt on TextStyle {
  Size calculateMaxSingleLineTextSize(
    Iterable<String> texts, {
    required TextScaler scaler,
    TextDirection? direction,
    Locale? locale,
  }) => TextMeasurement.maxSingleLineTextSize(
    texts,
    style: this,
    scaler: scaler,
    direction: direction ?? TextDirection.ltr,
    locale: locale,
  );

  double calculateMaxSingleLineTextWidth(
    Iterable<String> texts, {
    required TextScaler scaler,
    required TextDirection direction,
    Locale? locale,
  }) => TextMeasurement.maxSingleLineTextWidth(
    texts,
    style: this,
    scaler: scaler,
    direction: direction,
    locale: locale,
  );

  double calculateMaxUnbreakableTextWidth(
    Iterable<String> texts, {
    required TextScaler scaler,
    TextDirection? direction,
    Locale? locale,
  }) => TextMeasurement.maxUnbreakableTextWidth(
    texts,
    style: this,
    scaler: scaler,
    direction: direction ?? TextDirection.ltr,
    locale: locale,
  );
}
