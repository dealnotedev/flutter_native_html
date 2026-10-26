import 'dart:convert';
import 'dart:typed_data';

import 'eml_message.dart';

const maxEmailInputBytes = 20 * 1024 * 1024;

/// Cancels the input stream as soon as its payload exceeds the file budget.
Future<Uint8List> readEmailStream(
  Stream<List<int>> stream, {
  int maxBytes = maxEmailInputBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > maxBytes - bytes.length) {
      throw const FormatException('File is too large to render safely');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

/// Sendable input/output for Flutter compute: MIME decoding stays off the UI
/// isolate, while both file chooser and drag-and-drop use the same path.
EmlMessage decodeEmailFile((String, Uint8List) input) {
  final (name, bytes) = input;
  final lower = name.toLowerCase();
  return lower.endsWith('.html') || lower.endsWith('.htm')
      ? EmlMessage(
          html: utf8.decode(bytes, allowMalformed: true),
          inlineImages: const {},
        )
      : EmlMessage.parse(bytes);
}
