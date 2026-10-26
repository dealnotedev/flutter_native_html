import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// The result of resolving an `<img src>` to something renderable.
@immutable
class HtmlImageResolution {
  const HtmlImageResolution.image(this.provider) : blockedRemote = false;
  const HtmlImageResolution.blocked() : provider = null, blockedRemote = true;
  const HtmlImageResolution.unavailable()
    : provider = null,
      blockedRemote = false;

  /// The image to paint, or `null` when nothing should be shown.
  final ImageProvider? provider;

  /// True when a remote image was intentionally suppressed (privacy) — the UI
  /// can show a "load images" affordance for these.
  final bool blockedRemote;

  bool get hasImage => provider != null;
}

/// Decides how an `<img>` source is turned into an [ImageProvider].
///
/// Implement this to customize loading (e.g. authenticated fetches, disk
/// caching, custom `cid:` resolution). The default
/// [DefaultHtmlImageResolver] blocks remote images for privacy.
abstract class HtmlImageResolver {
  const HtmlImageResolver();

  HtmlImageResolution resolve(String src, Map<String, String> attributes);
}

extension HtmlImageResolverDocumentScope on HtmlImageResolver {
  /// A document-local resolver. Custom implementations retain their attribute-
  /// dependent behaviour; the default implementation reuses inline payloads.
  HtmlImageResolver forDocument() {
    final resolver = this;
    return resolver is DefaultHtmlImageResolver &&
            resolver.runtimeType == DefaultHtmlImageResolver
        ? _DocumentImageResolver(resolver)
        : resolver;
  }
}

/// Privacy-first resolver suited to email:
/// - `data:` URIs are decoded inline.
/// - `cid:` references resolve against [inlineAttachments] (Content-ID → bytes).
/// - `http(s):` images are **blocked** unless [allowRemoteImages] is true, so
///   tracking pixels don't phone home until the user opts in.
class DefaultHtmlImageResolver extends HtmlImageResolver {
  const DefaultHtmlImageResolver({
    this.allowRemoteImages = false,
    this.inlineAttachments = const {},
    this.maxInlineImageBytes = 5 * 1024 * 1024,
    this.maxDecodedImageDimension = 4096,
  }) : assert(maxInlineImageBytes > 0),
       assert(maxDecodedImageDimension > 0);

  final bool allowRemoteImages;

  /// Content-ID (without the `cid:` prefix or surrounding `<>`) → image bytes.
  final Map<String, Uint8List> inlineAttachments;

  /// Maximum decoded size of a data URI or CID attachment accepted in memory.
  final int maxInlineImageBytes;
  final int maxDecodedImageDimension;

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) {
    final value = src.trim();
    if (value.isEmpty) return const HtmlImageResolution.unavailable();

    final scheme = _schemeOf(value);
    switch (scheme) {
      case 'data':
        final bytes = _decodeDataUri(value, maxInlineImageBytes);
        return bytes == null
            ? const HtmlImageResolution.unavailable()
            : HtmlImageResolution.image(_bounded(MemoryImage(bytes)));
      case 'cid':
        final id = value.substring(4).replaceAll(RegExp(r'^<|>$'), '');
        final bytes = inlineAttachments[id];
        return bytes == null || bytes.length > maxInlineImageBytes
            ? const HtmlImageResolution.unavailable()
            : HtmlImageResolution.image(_bounded(MemoryImage(bytes)));
      case 'http':
      case 'https':
        return allowRemoteImages
            ? HtmlImageResolution.image(_bounded(NetworkImage(value)))
            : const HtmlImageResolution.blocked();
      default:
        return const HtmlImageResolution.unavailable();
    }
  }

  static String? _schemeOf(String url) {
    final idx = url.indexOf(':');
    if (idx <= 0) return null;
    return url.substring(0, idx).toLowerCase();
  }

  ImageProvider _bounded(ImageProvider provider) => ResizeImage(
    provider,
    width: maxDecodedImageDimension,
    height: maxDecodedImageDimension,
    policy: ResizeImagePolicy.fit,
  );

  static Uint8List? _decodeDataUri(String uri, int maxBytes) {
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    final meta = uri.substring(5, comma); // after "data:"
    final data = uri.substring(comma + 1);
    // Reject before allocating the decoded buffer. Base64 is at least 4/3 of
    // its decoded size; percent-encoded input can only decode smaller.
    final isBase64 = meta.toLowerCase().contains(';base64');
    if (data.length > (isBase64 ? maxBytes * 4 ~/ 3 + 16 : maxBytes * 3)) {
      return null;
    }
    try {
      if (isBase64) {
        final bytes = base64.decode(
          Uri.decodeFull(data.replaceAll(RegExp(r'\s'), '')),
        );
        return bytes.length <= maxBytes ? bytes : null;
      }
      // URI data may contain arbitrary binary bytes, not necessarily UTF-8.
      final bytes = UriData.parse(uri).contentAsBytes();
      return bytes.length <= maxBytes ? bytes : null;
    } catch (_) {
      return null;
    }
  }
}

/// Bounded LRU storage for providers and decoded inline bytes. Never shared
/// across documents/resolvers, so an image consent or CID-map change cannot
/// reuse a result prepared under another policy.
class _DocumentImageResolver extends HtmlImageResolver {
  _DocumentImageResolver(this.delegate);

  final DefaultHtmlImageResolver delegate;
  final _cache = <String, ({HtmlImageResolution value, int bytes})>{};
  static const _maxBytes = 10 * 1024 * 1024;
  static const _maxEntries = 256;
  int _bytes = 0;

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) {
    final key = src.trim();
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached.value;
    }
    final result = delegate.resolve(key, attributes);
    final provider = result.provider;
    final inner = provider is ResizeImage ? provider.imageProvider : provider;
    final cost =
        key.length * 2 + (inner is MemoryImage ? inner.bytes.length : 0) + 128;
    if (cost <= _maxBytes) {
      while (_cache.isNotEmpty &&
          (_bytes + cost > _maxBytes || _cache.length >= _maxEntries)) {
        _bytes -= _cache.remove(_cache.keys.first)!.bytes;
      }
      _cache[key] = (value: result, bytes: cost);
      _bytes += cost;
    }
    return result;
  }
}
