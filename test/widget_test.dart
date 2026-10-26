import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(String html, {HtmlRenderConfig? config}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: HtmlEmailView(
        html: html,
        config: config ?? const HtmlRenderConfig(),
      ),
    ),
  ),
);

void main() {
  testWidgets('renders basic text and headings', (tester) async {
    await tester.pumpWidget(_host('<h1>Title</h1><p>Hello <b>world</b></p>'));
    expect(find.textContaining('Title'), findsOneWidget);
    expect(find.byType(RichText), findsWidgets);
  });

  testWidgets('forwards link taps instead of navigating', (tester) async {
    String? tapped;
    await tester.pumpWidget(
      _host(
        '<p>Go to <a href="https://example.com">site</a></p>',
        config: HtmlRenderConfig(onLinkTap: (url, _) => tapped = url),
      ),
    );

    final recognizers = <Object>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      rt.text.visitChildren((span) {
        if (span is TextSpan && span.recognizer != null) {
          recognizers.add(span.recognizer!);
        }
        return true;
      });
    }
    expect(recognizers, isNotEmpty);
    (recognizers.first as dynamic).onTap();
    expect(tapped, 'https://example.com');
  });

  testWidgets('blocks remote images and shows a placeholder', (tester) async {
    await tester.pumpWidget(
      _host('<img src="https://example.com/x.png" alt="banner">'),
    );
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('renders a table layout without exceptions', (tester) async {
    await tester.pumpWidget(
      _host('<table width="100%"><tr><td>A</td><td>B</td></tr></table>'),
    );
    expect(find.textContaining('A'), findsWidgets);
    expect(find.textContaining('B'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drops display:none content', (tester) async {
    await tester.pumpWidget(
      _host('<p>visible</p><p style="display:none">hidden</p>'),
    );
    expect(find.textContaining('visible'), findsOneWidget);
    expect(find.textContaining('hidden'), findsNothing);
  });
}
