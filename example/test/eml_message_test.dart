import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_native_html_example/demo/eml_message.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(latin1.encode(s));

void main() {
  test('malformed MIME base64 does not throw and encoded subject decodes', () {
    final raw = Uint8List.fromList(
      'Subject: =?UTF-8?B?0KLQtdGB0YI=?=\r\n'
              'Content-Type: image/png\r\n'
              'Content-ID: <x>\r\n'
              'Content-Transfer-Encoding: base64\r\n\r\n%%%'
          .codeUnits,
    );
    final message = EmlMessage.parse(raw);
    // Preserve multibyte UTF-8 coverage for the encoded-word subject.
    expect(message.subject, '\u0422\u0435\u0441\u0442');
    expect(message.inlineImages['x'], isEmpty);
  });

  test('extracts quoted-printable HTML from multipart/alternative', () {
    const eml =
        'Subject: Hello\r\n'
        'MIME-Version: 1.0\r\n'
        'Content-Type: multipart/alternative; boundary="B1"\r\n'
        '\r\n'
        '--B1\r\n'
        'Content-Type: text/plain; charset=utf-8\r\n'
        '\r\n'
        'plain body\r\n'
        '--B1\r\n'
        'Content-Type: text/html; charset=utf-8\r\n'
        'Content-Transfer-Encoding: quoted-printable\r\n'
        '\r\n'
        '<p>Price =3D=2410 =E2=82=AC=\r\n'
        ' wrapped</p>\r\n'
        '--B1--\r\n';

    final msg = EmlMessage.parse(_bytes(eml));
    expect(msg.subject, 'Hello');
    expect(msg.text, contains('plain body'));
    // =3D -> '=', =24 -> '$', =E2=82=AC -> '€' (UTF-8), soft break removed.
    expect(msg.html, contains(r'Price =$10 € wrapped'));
    expect(msg.renderableHtml, startsWith('<p>'));
  });

  test('decodes base64 inline image referenced by Content-ID', () {
    final png = base64.encode(List<int>.generate(8, (i) => i));
    final eml =
        'Content-Type: multipart/related; boundary="X"\r\n'
        '\r\n'
        '--X\r\n'
        'Content-Type: text/html\r\n'
        '\r\n'
        '<img src="cid:logo@x">\r\n'
        '--X\r\n'
        'Content-Type: image/png\r\n'
        'Content-Transfer-Encoding: base64\r\n'
        'Content-ID: <logo@x>\r\n'
        '\r\n'
        '$png\r\n'
        '--X--\r\n';

    final msg = EmlMessage.parse(_bytes(eml));
    expect(msg.inlineImages.containsKey('logo@x'), isTrue);
    expect(msg.inlineImages['logo@x'], hasLength(8));
    expect(msg.html, contains('cid:logo@x'));
  });

  test('falls back to plain text wrapped in <pre>', () {
    const eml =
        'Content-Type: text/plain; charset=utf-8\r\n'
        '\r\n'
        'just text <not html>\r\n';
    final msg = EmlMessage.parse(_bytes(eml));
    expect(msg.html, isNull);
    expect(msg.renderableHtml, contains('<pre'));
    expect(msg.renderableHtml, contains('&lt;not html&gt;'));
  });

  test('decodes a windows-1251 (Cyrillic) body', () {
    // Windows-1251 bytes for a Cyrillic greeting. Unicode escapes below keep
    // the expected decoded text independent of the source file's encoding.
    final bodyBytes = [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2];
    final eml =
        'Content-Type: text/plain; charset=windows-1251\r\n'
        '\r\n'
        '${String.fromCharCodes(bodyBytes)}\r\n';
    final msg = EmlMessage.parse(_bytes(eml));
    expect(msg.text, contains('\u041f\u0440\u0438\u0432\u0435\u0442'));
  });

  test('decodes a windows-1251 RFC 2047 encoded-word subject', () {
    // Base64 of the same Windows-1251 greeting used in the body test.
    final b64 = base64.encode([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]);
    final eml =
        'Subject: =?windows-1251?B?$b64?=\r\n'
        'Content-Type: text/plain; charset=utf-8\r\n'
        '\r\n'
        'body\r\n';
    final msg = EmlMessage.parse(_bytes(eml));
    expect(msg.subject, '\u041f\u0440\u0438\u0432\u0435\u0442');
  });
}
