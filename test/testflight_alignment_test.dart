import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'TestFlight inline alignment overrides stylesheet justification',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 360,
                child: HtmlEmailView(
                  // Reduced from Apple's TestFlight email. The author sets
                  // justification globally, then overrides each visible block.
                  html: '''
<style>
BODY, TD, P, h1 {
  font-family: -apple-system, BlinkMacSystemFont, sans-serif;
  font-size: 14px; line-height: 18px; font-weight: 300;
  text-align: justify;
}
@media only screen and (max-width:580px) {
  table[class="table"], td[class="cell"] { width:100% !important; }
}
</style>
<table class="table" width="580" cellspacing="0" cellpadding="0"><tr><td align="center">
<table class="table" width="580" cellspacing="0" cellpadding="0">
  <tr><td class="cell" align="center" style="text-align:center">
    <h1 style="font-size:24px;line-height:26px;margin:0;text-align:center;font-family:-apple-system,BlinkMacSystemFont,sans-serif">
      Friday AI Email Writer 1.1.24 (758) is ready to test on iOS.
    </h1>
  </td></tr>
  <tr><td class="cell" align="left">
    <p style="font-size:17px;margin:0;line-height:1.4em;text-align:left;font-family:-apple-system,BlinkMacSystemFont,sans-serif">
      To test this app, open <a href="https://testflight.apple.com">TestFlight</a> on your iOS device using iOS 15.6 or later and install the update.
    </p>
  </td></tr>
</table>
</td></tr></table>
''',
                  config: const HtmlRenderConfig(enableTextSelection: false),
                ),
              ),
            ),
          ),
        ),
      );
      final texts = tester.widgetList<RichText>(find.byType(RichText));
      final heading = texts.singleWhere(
        (text) => text.text.toPlainText().contains('is ready to test'),
      );
      final paragraph = texts.singleWhere(
        (text) => text.text.toPlainText().contains('To test this app'),
      );
      expect(heading.textAlign, TextAlign.center);
      expect(paragraph.textAlign, TextAlign.left);
      expect(heading.text.style?.fontFamily, 'CupertinoSystemDisplay');
      expect(paragraph.text.style?.fontFamily, 'CupertinoSystemText');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
