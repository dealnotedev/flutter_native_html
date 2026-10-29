import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_native_html/src/css/html_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final (platform, fallback) in [
    (TargetPlatform.windows, 'Arial'),
    (TargetPlatform.android, 'sans-serif'),
    (TargetPlatform.linux, 'DejaVu Sans'),
  ]) {
    test('$platform Helvetica retains a sans-serif text fallback', () {
      debugDefaultTargetPlatformOverride = platform;
      final style = const HtmlStyle(fontFamilies: ['Helvetica']).toTextStyle();
      expect(style.fontFamily, 'Helvetica');
      expect(style.fontFamilyFallback!.first, fallback);
    });
  }

  test(
    'Windows preserves the default fallback for other named font families',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final style = const HtmlStyle(
        fontFamilies: ['Helvetica Neue'],
      ).toTextStyle();
      expect(style.fontFamily, 'Helvetica Neue');
      expect(style.fontFamilyFallback!.first, 'Times New Roman');
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    for (final alias in ['-apple-system', 'BlinkMacSystemFont', 'system-ui']) {
      for (final size in [17.0, 20.0, 24.0]) {
        test('$platform $alias at $size uses Flutter system font proxy', () {
          debugDefaultTargetPlatformOverride = platform;
          final style = HtmlStyle(
            fontFamilies: [alias, 'sans-serif'],
            fontSize: size,
            fontWeight: FontWeight.w300,
          ).toTextStyle();
          expect(
            style.fontFamily,
            size < 20 ? 'CupertinoSystemText' : 'CupertinoSystemDisplay',
          );
          expect(style.fontFamilyFallback!.first, 'Helvetica');
          expect(style.fontWeight, FontWeight.w300);
        });
      }
    }
    for (final (generic, concrete) in [
      ('sans-serif', 'Helvetica'),
      ('serif', 'Times New Roman'),
      ('monospace', 'Courier'),
    ]) {
      test('$platform resolves CSS $generic before emoji fallback', () {
        debugDefaultTargetPlatformOverride = platform;
        final style = HtmlStyle(fontFamilies: [generic]).toTextStyle();
        expect(style.fontFamily, concrete);
        expect(style.fontFamilyFallback, contains('Apple Color Emoji'));
      });
    }
    test('$platform resolves generic fallback after a missing custom font', () {
      debugDefaultTargetPlatformOverride = platform;
      final style = const HtmlStyle(
        fontFamilies: ['Missing Email Font'],
      ).toTextStyle();
      expect(style.fontFamily, 'Missing Email Font');
      expect(style.fontFamilyFallback!.first, 'Times New Roman');
    });
    test(
      '$platform standalone system alias keeps a concrete text fallback',
      () {
        debugDefaultTargetPlatformOverride = platform;
        final style = const HtmlStyle(
          fontFamilies: ['SYSTEM-UI'],
        ).toTextStyle();
        expect(style.fontFamily, 'CupertinoSystemText');
        expect(style.fontFamilyFallback!.first, 'Helvetica');
      },
    );
  }
}
