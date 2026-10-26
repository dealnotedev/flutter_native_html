import 'package:flutter_native_html/src/parsing/html_email_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final parser = HtmlEmailParser();

  test('removes script elements', () {
    final result = parser.parse('<p>hi</p><script>evil()</script>');
    expect(result.root.querySelector('script'), isNull);
    expect(result.root.text, contains('hi'));
  });

  test('strips on* event handlers', () {
    final result = parser.parse('<p onclick="x()" onmouseover="y()">hi</p>');
    final p = result.root.querySelector('p')!;
    expect(p.attributes.containsKey('onclick'), isFalse);
    expect(p.attributes.containsKey('onmouseover'), isFalse);
  });

  test('neutralizes javascript: URLs but keeps http links', () {
    final result = parser.parse(
      '<a href="javascript:alert(1)">a</a><a href="https://ok.test">b</a>',
    );
    final links = result.root.querySelectorAll('a');
    expect(links[0].attributes.containsKey('href'), isFalse);
    expect(links[1].attributes['href'], 'https://ok.test');
  });

  test('collects <style> css before stripping the element', () {
    final result = parser.parse(
      '<html><head><style>.x{color:red}</style></head><body><p class="x">hi</p></body></html>',
    );
    expect(result.root.querySelector('style'), isNull);
    expect(result.stylesheet.rules, isNotEmpty);
  });

  test('keeps data: image sources on img', () {
    final result = parser.parse(
      '<img src="data:image/png;base64,AAAA"><img src="javascript:1">',
    );
    final imgs = result.root.querySelectorAll('img');
    expect(imgs[0].attributes['src'], startsWith('data:'));
    expect(imgs[1].attributes.containsKey('src'), isFalse);
  });

  test('strips javascript: obfuscated with control chars in the scheme', () {
    // Entity-decoded to `java\tscript:` / `java\nscript:` at parse time; browsers
    // strip the control char and execute, so the sanitizer must too.
    final result = parser.parse(
      '<a href="java&#9;script:alert(1)">a</a>'
      '<a href="java&#10;script:alert(1)">b</a>'
      '<a href="  javascript:alert(1)">c</a>',
    );
    for (final a in result.root.querySelectorAll('a')) {
      expect(
        a.attributes.containsKey('href'),
        isFalse,
        reason: 'obfuscated javascript: survived on ${a.outerHtml}',
      );
    }
  });

  test('keeps genuine relative and anchor URLs', () {
    final result = parser.parse(
      '<a href="/path/page">a</a><a href="#section">b</a>'
      '<a href="../x">c</a>',
    );
    final links = result.root.querySelectorAll('a');
    expect(links[0].attributes['href'], '/path/page');
    expect(links[1].attributes['href'], '#section');
    expect(links[2].attributes['href'], '../x');
  });

  test('rejects DOM nested beyond the depth limit', () {
    final deep = HtmlEmailParser(maxDomDepth: 50);
    final html = '${'<div>' * 200}x${'</div>' * 200}';
    expect(() => deep.parse(html), throwsA(isA<HtmlContentLimitException>()));
    // Shallow content of the same size is fine.
    expect(
      () => deep.parse('<div>${'<span></span>' * 200}</div>'),
      returnsNormally,
    );
  });
}
