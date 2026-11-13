import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

ImageProvider remoteImageProvider(Uri uri, int maxBytes) =>
    _BoundedNetworkImage(uri, maxBytes);

class _BoundedNetworkImage extends ImageProvider<_BoundedNetworkImage> {
  const _BoundedNetworkImage(this.uri, this.maxBytes);

  final Uri uri;
  final int maxBytes;
  static const _timeout = Duration(seconds: 20);

  @override
  Future<_BoundedNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _BoundedNetworkImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: key._load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final bytes = await _read(client).timeout(_timeout);
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _read(HttpClient client) async {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    if (response.contentLength > maxBytes) {
      throw const FormatException('Remote image exceeds its byte limit');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (chunk.length > maxBytes - bytes.length) {
        throw const FormatException('Remote image exceeds its byte limit');
      }
      bytes.add(chunk);
    }
    if (bytes.isEmpty) throw const FormatException('Empty remote image');
    return bytes.takeBytes();
  }

  @override
  bool operator ==(Object other) =>
      other is _BoundedNetworkImage &&
      uri == other.uri &&
      maxBytes == other.maxBytes;

  @override
  int get hashCode => Object.hash(uri, maxBytes);
}
