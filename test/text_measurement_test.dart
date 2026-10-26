import 'package:flutter/material.dart';
import 'package:flutter_native_html/src/rendering/text_measurement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = TextStyle(fontSize: 10, fontFamily: 'Ahem');

  testWidgets('maxSingleLineTextSize returns the widest and tallest text', (
    tester,
  ) async {
    final short = TextMeasurement.singleLineTextSize(
      'aa',
      style: style,
      scaler: TextScaler.noScaling,
    );
    final wide = TextMeasurement.singleLineTextSize(
      'aaaa',
      style: style,
      scaler: TextScaler.noScaling,
    );

    final result = style.calculateMaxSingleLineTextSize(const [
      'aa',
      'aaaa',
    ], scaler: TextScaler.noScaling);

    expect(result.width, closeTo(wide.width, 0.01));
    expect(result.width, greaterThan(short.width));
    expect(result.height, closeTo(wide.height, 0.01));
  });

  testWidgets('maxSingleLineTextWidth respects text scaling', (tester) async {
    final normal = style.calculateMaxSingleLineTextWidth(
      const ['wide'],
      scaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
    );
    final scaled = style.calculateMaxSingleLineTextWidth(
      const ['wide'],
      scaler: const TextScaler.linear(2),
      direction: TextDirection.ltr,
    );

    expect(scaled, closeTo(normal * 2, 0.01));
  });

  testWidgets('maxUnbreakableTextWidth does not split non-breaking spaces', (
    tester,
  ) async {
    final split = style.calculateMaxUnbreakableTextWidth(const [
      'first second',
    ], scaler: TextScaler.noScaling);
    final nonBreaking = style.calculateMaxUnbreakableTextWidth(const [
      'first\u00A0second',
    ], scaler: TextScaler.noScaling);
    final full = style.calculateMaxSingleLineTextWidth(
      const ['first\u00A0second'],
      scaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
    );

    expect(nonBreaking, closeTo(full, 0.01));
    expect(nonBreaking, greaterThan(split));
  });
}
