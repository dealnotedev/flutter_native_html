import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_native_html/demo/email_demo_widget.dart';
import 'package:flutter_native_html/demo/email_input.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file reader accepts empty and exact-size streams', () async {
    expect(await readEmailStream(const Stream.empty(), maxBytes: 0), isEmpty);
    expect(
      await readEmailStream(
        Stream.fromIterable([
          [1, 2],
          [3],
        ]),
        maxBytes: 3,
      ),
      [1, 2, 3],
    );
  });

  test('file reader cancels an oversized stream before later chunks', () async {
    var chunksRead = 0;
    Stream<List<int>> input() async* {
      for (final chunk in [
        [1, 2],
        [3, 4],
        [5, 6],
      ]) {
        chunksRead++;
        yield chunk;
      }
    }

    await expectLater(
      readEmailStream(input(), maxBytes: 3),
      throwsFormatException,
    );
    expect(chunksRead, 2);
  });

  test('file decoding preserves HTML and decodes MIME before rendering', () {
    final html = decodeEmailFile((
      'test.HTML',
      Uint8List.fromList('<p>body</p>'.codeUnits),
    ));
    expect(html.renderableHtml, '<p>body</p>');
    final eml = decodeEmailFile((
      'test.eml',
      Uint8List.fromList('Content-Type: text/plain\r\n\r\nhello'.codeUnits),
    ));
    expect(eml.renderableHtml, contains('hello'));
  });

  testWidgets('demo starts with remote images blocked', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: EmailDemoWidget()));
    final view = tester.widget<HtmlEmailView>(find.byType(HtmlEmailView));
    expect(
      (view.config.imageResolver as DefaultHtmlImageResolver).allowRemoteImages,
      isFalse,
    );
  });
}
