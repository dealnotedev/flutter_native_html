import 'dart:convert';
import 'dart:typed_data';

/// A minimal MIME (.eml) message parser for the demo.
///
/// It extracts the HTML body (falling back to plain text) and any inline
/// images (`Content-ID`) from a raw `.eml` file, decoding `quoted-printable` /
/// `base64` transfer encodings and common charsets. It is intentionally
/// compact — enough for displaying real downloaded emails — not a full RFC 5322
/// implementation.
class EmlMessage {
  EmlMessage({this.html, this.text, required this.inlineImages, this.subject});

  /// Decoded `text/html` body, if present.
  final String? html;

  /// Decoded `text/plain` body, if present.
  final String? text;

  /// `cid` (without `cid:`/`<>`) → image bytes, for inline images.
  final Map<String, Uint8List> inlineImages;

  final String? subject;

  /// The body to render: HTML when available, otherwise plain text wrapped in
  /// `<pre>`. Returns null if neither part exists.
  String? get renderableHtml {
    if (html != null && html!.trim().isNotEmpty) return html;
    if (text != null && text!.trim().isNotEmpty) {
      return '<pre style="white-space:pre-wrap;font-family:sans-serif">'
          '${_escape(text!)}</pre>';
    }
    return null;
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Parses raw `.eml` bytes.
  static EmlMessage parse(Uint8List raw) {
    // Decode 1:1 so transfer-encoded bodies survive; parts are charset-decoded
    // individually below.
    final source = latin1.decode(raw, allowInvalid: true);
    final root = _Entity.parse(source);

    String? html;
    String? text;
    final inline = <String, Uint8List>{};

    void visit(_Entity e) {
      if (e.children.isNotEmpty) {
        for (final child in e.children) {
          visit(child);
        }
        return;
      }
      final type = e.mediaType;
      if (type == 'text/html' && html == null && !e.isAttachment) {
        html = e.decodeText();
      } else if (type == 'text/plain' && text == null && !e.isAttachment) {
        text = e.decodeText();
      } else if (type.startsWith('image/') && e.contentId != null) {
        inline[e.contentId!] = Uint8List.fromList(e.decodeBytes());
      }
    }

    visit(root);
    return EmlMessage(
      html: html,
      text: text,
      inlineImages: inline,
      subject: _decodeHeader(root.headers['subject']),
    );
  }

  static String? _decodeHeader(String? value) {
    if (value == null) return null;
    return value.replaceAllMapped(RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]*)\?='), (
      match,
    ) {
      try {
        final encoding = match.group(2)!.toLowerCase();
        final payload = match.group(3)!;
        final bytes = encoding == 'b'
            ? base64.decode(payload)
            : _Entity._decodeQuotedPrintable(payload.replaceAll('_', ' '));
        // Strip an RFC 2231 `charset*lang` suffix before lookup.
        final charset = match.group(1)!.toLowerCase().split('*').first;
        return _Entity.decodeCharset(bytes, charset);
      } catch (_) {
        return match.group(0)!;
      }
    });
  }
}

/// One MIME entity (headers + body); a container if `multipart/*`.
class _Entity {
  _Entity({required this.headers, required this.body, required this.children});

  final Map<String, String> headers; // lower-cased keys
  final String body; // raw (still transfer-encoded) for leaf parts
  final List<_Entity> children;

  String get mediaType {
    final ct = headers['content-type'] ?? 'text/plain';
    return ct.split(';').first.trim().toLowerCase();
  }

  String? get _charset => _param('content-type', 'charset')?.toLowerCase();

  String? get contentId {
    final raw = headers['content-id'];
    if (raw == null) return null;
    return raw.trim().replaceAll(RegExp(r'^<|>$'), '');
  }

  bool get isAttachment => (headers['content-disposition'] ?? '')
      .toLowerCase()
      .contains('attachment');

  String get _transferEncoding =>
      (headers['content-transfer-encoding'] ?? '7bit').trim().toLowerCase();

  static _Entity parse(String content, [int depth = 0]) {
    final (headers, body) = _splitHeaders(content);
    final ct = (headers['content-type'] ?? '').toLowerCase();
    final children = <_Entity>[];

    // Bound nested multipart recursion so a hostile .eml can't overflow the
    // stack by nesting multipart/* into itself.
    if (ct.startsWith('multipart/') && depth < 20) {
      final boundary = _paramOf(headers['content-type'] ?? '', 'boundary');
      if (boundary != null) {
        for (final partText in _splitParts(body, boundary)) {
          children.add(_Entity.parse(partText, depth + 1));
        }
      }
    }
    return _Entity(headers: headers, body: body, children: children);
  }

  /// Decodes the (leaf) body bytes per Content-Transfer-Encoding.
  List<int> decodeBytes() {
    switch (_transferEncoding) {
      case 'base64':
        final cleaned = body.replaceAll(RegExp(r'\s'), '');
        try {
          return base64.decode(cleaned);
        } catch (_) {
          try {
            return base64.decode(_padBase64(cleaned));
          } catch (_) {
            return const [];
          }
        }
      case 'quoted-printable':
        return _decodeQuotedPrintable(body);
      default: // 7bit / 8bit / binary / none
        return latin1.encode(body);
    }
  }

  /// Decodes the (leaf) body as text using its charset.
  String decodeText() => decodeCharset(decodeBytes(), _charset);

  String? _param(String header, String name) =>
      _paramOf(headers[header] ?? '', name);

  // --- static helpers ---

  static (Map<String, String>, String) _splitHeaders(String content) {
    // Headers end at the first blank line (handle CRLF and LF).
    final match = RegExp(r'\r?\n\r?\n').firstMatch(content);
    final headerText = match == null
        ? content
        : content.substring(0, match.start);
    final body = match == null ? '' : content.substring(match.end);

    final headers = <String, String>{};
    String? currentKey;
    for (final rawLine in headerText.split(RegExp(r'\r?\n'))) {
      if (rawLine.isEmpty) continue;
      if ((rawLine.startsWith(' ') || rawLine.startsWith('\t')) &&
          currentKey != null) {
        headers[currentKey] = '${headers[currentKey]} ${rawLine.trim()}';
        continue;
      }
      final colon = rawLine.indexOf(':');
      if (colon <= 0) continue;
      currentKey = rawLine.substring(0, colon).trim().toLowerCase();
      headers[currentKey] = rawLine.substring(colon + 1).trim();
    }
    return (headers, body);
  }

  static List<String> _splitParts(String body, String boundary) {
    final parts = <String>[];
    final delimiter = RegExp(
      '(?:^|\\r?\\n)--${RegExp.escape(boundary)}(--)?[ \\t]*(?:\\r?\\n|\$)',
    );
    final matches = delimiter.allMatches(body).toList();
    for (var i = 0; i < matches.length; i++) {
      if (matches[i].group(1) == '--') break;
      final start = matches[i].end;
      final end = i + 1 < matches.length ? matches[i + 1].start : body.length;
      if (end >= start) parts.add(body.substring(start, end));
    }
    return parts;
  }

  static String? _paramOf(String headerValue, String name) {
    for (final part in _splitHeaderParameters(headerValue).skip(1)) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      if (key != name.toLowerCase()) continue;
      var value = part.substring(eq + 1).trim();
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      return value;
    }
    return null;
  }

  static List<String> _splitHeaderParameters(String value) {
    final parts = <String>[];
    final buffer = StringBuffer();
    String? quote;
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (quote != null) {
        buffer.write(ch);
        if (ch == quote && (i == 0 || value[i - 1] != r'\')) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
        buffer.write(ch);
      } else if (ch == ';') {
        parts.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    parts.add(buffer.toString());
    return parts;
  }

  static List<int> _decodeQuotedPrintable(String input) {
    final bytes = <int>[];
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '=') {
        if (i + 1 < input.length &&
            (input[i + 1] == '\n' || input[i + 1] == '\r')) {
          // Soft line break: skip the CR/LF (and a following LF after CR).
          if (input[i + 1] == '\r' &&
              i + 2 < input.length &&
              input[i + 2] == '\n') {
            i += 2;
          } else {
            i += 1;
          }
          continue;
        }
        if (i + 2 < input.length) {
          final hex = input.substring(i + 1, i + 3);
          final value = int.tryParse(hex, radix: 16);
          if (value != null) {
            bytes.add(value);
            i += 2;
            continue;
          }
        }
        bytes.add(ch.codeUnitAt(0)); // stray '='
      } else {
        bytes.add(ch.codeUnitAt(0) & 0xFF);
      }
    }
    return bytes;
  }

  static String _padBase64(String s) {
    final remainder = s.length % 4;
    return remainder == 0 ? s : s + '=' * (4 - remainder);
  }

  /// Decodes [bytes] with the named [charset], covering the encodings real
  /// email uses: Latin-1, Windows-1252, and — common in RU/UA mail —
  /// Windows-1251. Unknown/UTF-8 charsets fall back to lenient UTF-8.
  static String decodeCharset(List<int> bytes, String? charset) {
    switch (charset) {
      case 'iso-8859-1':
      case 'latin1':
        return latin1.decode(bytes, allowInvalid: true);
      case 'windows-1252':
      case 'cp1252':
        return String.fromCharCodes(bytes.map(_windows1252CodePoint));
      case 'windows-1251':
      case 'cp1251':
        return String.fromCharCodes(bytes.map(_windows1251CodePoint));
      case 'us-ascii':
      case 'ascii':
      case 'utf-8':
      case 'utf8':
      case null:
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static int _windows1252CodePoint(int byte) => _windows1252[byte] ?? byte;

  /// Windows-1251 (Cyrillic): ASCII below 0x80, the alphabet block
  /// `0xC0..0xFF` maps linearly to `U+0410..U+044F`, and `0x80..0xBF` uses the
  /// explicit table below (punctuation and Russian/Ukrainian letter extensions).
  static int _windows1251CodePoint(int b) {
    if (b < 0x80) return b;
    if (b >= 0xC0) return 0x0410 + (b - 0xC0);
    return _windows1251High[b - 0x80];
  }

  static const List<int> _windows1251High = [
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, // 80-87
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F, // 88-8F
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90-97
    0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F, // 98-9F
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, // A0-A7
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407, // A8-AF
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, // B0-B7
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457, // B8-BF
  ];

  static const Map<int, int> _windows1252 = {
    0x80: 0x20AC,
    0x82: 0x201A,
    0x83: 0x0192,
    0x84: 0x201E,
    0x85: 0x2026,
    0x86: 0x2020,
    0x87: 0x2021,
    0x88: 0x02C6,
    0x89: 0x2030,
    0x8A: 0x0160,
    0x8B: 0x2039,
    0x8C: 0x0152,
    0x8E: 0x017D,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201C,
    0x94: 0x201D,
    0x95: 0x2022,
    0x96: 0x2013,
    0x97: 0x2014,
    0x98: 0x02DC,
    0x99: 0x2122,
    0x9A: 0x0161,
    0x9B: 0x203A,
    0x9C: 0x0153,
    0x9E: 0x017E,
    0x9F: 0x0178,
  };
}
