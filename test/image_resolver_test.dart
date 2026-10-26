import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

class _AttributeResolver extends DefaultHtmlImageResolver {
  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      attributes['blocked'] == 'true'
      ? const HtmlImageResolution.blocked()
      : const HtmlImageResolution.unavailable();
}

void main() {
  test('one document reuses data URI providers and decoded bytes', () {
    final resolver = const DefaultHtmlImageResolver().forDocument();
    const uri = 'data:image/png;base64,AQID';
    final first = resolver.resolve(uri, const {}).provider;
    expect(first, isNotNull);
    expect(identical(first, resolver.resolve(uri, const {}).provider), isTrue);
  });

  test('image cache evicts old entries at its entry limit', () {
    final resolver = const DefaultHtmlImageResolver().forDocument();
    String uri(int index) =>
        'data:image/png;base64,${base64Encode([index & 255, index >> 8])}';
    final first = resolver.resolve(uri(0), const {}).provider;
    for (var i = 1; i <= 256; i++) {
      resolver.resolve(uri(i), const {});
    }
    expect(
      identical(first, resolver.resolve(uri(0), const {}).provider),
      isFalse,
    );
  });

  test('image cache also bounds retained payload bytes', () {
    final resolver = const DefaultHtmlImageResolver().forDocument();
    String uri(int byte) =>
        'data:image/png;base64,${base64Encode(Uint8List(2 * 1024 * 1024)..fillRange(0, 2 * 1024 * 1024, byte))}';
    final a = uri(1);
    final first = resolver.resolve(a, const {}).provider;
    expect(first, isNotNull);
    expect(resolver.resolve(uri(2), const {}).hasImage, isTrue);
    expect(identical(first, resolver.resolve(a, const {}).provider), isFalse);
  });

  test('document caches do not share remote-image consent', () {
    final allowed = const DefaultHtmlImageResolver(
      allowRemoteImages: true,
    ).forDocument();
    final blocked = const DefaultHtmlImageResolver().forDocument();
    const uri = 'https://example.test/image.png';
    expect(allowed.resolve(uri, const {}).hasImage, isTrue);
    expect(blocked.resolve(uri, const {}).blockedRemote, isTrue);
  });

  test('custom resolvers retain attribute-dependent results', () {
    final source = _AttributeResolver();
    final resolver = source.forDocument();
    expect(identical(source, resolver), isTrue);
    expect(
      resolver.resolve('same', const {'blocked': 'true'}).blockedRemote,
      isTrue,
    );
    expect(resolver.resolve('same', const {}).blockedRemote, isFalse);
  });

  test('non-base64 image data decodes binary percent escapes', () {
    const resolver = DefaultHtmlImageResolver(maxInlineImageBytes: 3);
    final result = resolver.resolve('data:image/png,%89%50%FF', const {});
    final provider =
        (result.provider! as ResizeImage).imageProvider as MemoryImage;
    expect(provider.bytes, [0x89, 0x50, 0xff]);
    expect(
      resolver.resolve('data:image/png,%89%50%FF%01', const {}).hasImage,
      isFalse,
    );
  });
}
