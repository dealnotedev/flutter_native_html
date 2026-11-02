import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester,
  String html, {
  double width = 600,
}) async {
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HtmlEmailView(
            html: html,
            config: const HtmlRenderConfig(baseFontSize: 16, fitToWidth: true),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Finder _text(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);

void main() {
  for (final width in [600.0, 360.0]) {
    testWidgets('Twitch login text keeps symmetric gutters at $width px', (
      tester,
    ) async {
      // Reduced from the login email. The 20px outer cellpadding provides the
      // grey surround; the centered 80% divs provide the white card's gutters.
      await _pump(tester, '''
<body style="background:#eee">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
  <table width="600" cellpadding="20" cellspacing="0"><tr><td align="center">
    <table width="100%" cellpadding="0" cellspacing="0" style="background:#fff">
      <tr><td align="center">
        <div style="width:80%;text-align:center;padding:20px 0;font-size:20px">
          <b>Your Twitch Account - Successful Log-in</b>
        </div>
      </td></tr>
      <tr><td><table width="100%" cellpadding="1" cellspacing="0">
        <tr><td align="center">
          <div style="width:80%;text-align:left;padding-bottom:20px;font-size:14px">
            Dear reader,
          </div>
        </td></tr>
        <tr><td align="center">
          <div style="width:80%;text-align:left;padding-bottom:20px;font-size:14px">
            A new login occurred on your account.
          </div>
        </td></tr>
      </table></td></tr>
    </table>
  </td></tr></table>
</td></tr></table>
</body>
''', width: width);

      final card = tester.getRect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color == Colors.white,
        ),
      );
      final scale = width / 600;
      expect(card.width, closeTo(560 * scale, 0.01));
      for (final text in [
        'Dear reader,',
        'A new login occurred on your account.',
      ]) {
        final paragraph = tester.getRect(_text(text));
        expect(paragraph.width, closeTo(446.4 * scale, 0.01));
        expect(paragraph.center.dx, closeTo(card.center.dx, 0.01));
        expect(paragraph.left - card.left, closeTo(56.8 * scale, 0.01));
        expect(tester.widget<RichText>(_text(text)).textAlign, TextAlign.left);
      }
      expect(
        tester
            .getRect(_text('Your Twitch Account - Successful Log-in'))
            .center
            .dx,
        closeTo(card.center.dx, 0.01),
      );
    });
  }

  for (final (align, expectedLeft) in [
    ('left', 0.0),
    ('center', 60.0),
    ('right', 120.0),
  ]) {
    testWidgets('an undecorated percentage block honors cell align=$align', (
      tester,
    ) async {
      await _pump(tester, '''
<table width="600" cellpadding="0" cellspacing="0"><tr><td align="$align">
  <div style="width:80%;text-align:left">Login notification</div>
</td></tr></table>
''');
      final paragraph = tester.getRect(_text('Login notification'));
      expect(paragraph.width, closeTo(480, 0.01));
      expect(paragraph.left, closeTo(expectedLeft, 0.01));
      expect(
        tester.widget<RichText>(_text('Login notification')).textAlign,
        TextAlign.left,
      );
    });
  }

  testWidgets('CSS cell alignment overrides its legacy HTML hint', (
    tester,
  ) async {
    await _pump(tester, '''
<style>.cell { text-align:left }</style>
<table width="600" cellpadding="0" cellspacing="0"><tr>
<td align="center" class="cell">
  <div style="width:80%;text-align:left;padding-bottom:20px">Login notification</div>
</td></tr></table>
''');
    final paragraph = tester.getRect(_text('Login notification'));
    expect(paragraph.width, closeTo(480, 0.01));
    expect(paragraph.left, closeTo(0, 0.01));
  });

  for (final (style, expectedLeft, expectedWidth) in [
    ('max-width:300px', 150.0, 300.0),
    ('margin:0 auto 0 0', 0.0, 480.0),
    ('margin:0 0 0 auto', 120.0, 480.0),
    ('float:left', 0.0, 480.0),
  ]) {
    testWidgets('cell alignment respects percentage block $style', (
      tester,
    ) async {
      await _pump(tester, '''
<table width="600" cellpadding="0" cellspacing="0"><tr><td align="center">
  <div style="width:80%;text-align:left;$style">Login notification</div>
</td></tr></table>
''');
      final paragraph = tester.getRect(_text('Login notification'));
      expect(paragraph.width, closeTo(expectedWidth, 0.01));
      expect(paragraph.left, closeTo(expectedLeft, 0.01));
      expect(
        tester.widget<RichText>(_text('Login notification')).textAlign,
        TextAlign.left,
      );
    });
  }

  testWidgets('cell box alignment does not propagate into nested blocks', (
    tester,
  ) async {
    await _pump(tester, '''
<table width="600" cellpadding="0" cellspacing="0"><tr><td align="center">
  <div style="width:80%;text-align:left">
    <div style="width:50%">Login notification</div>
  </div>
</td></tr></table>
''');
    final paragraph = tester.getRect(_text('Login notification'));
    expect(paragraph.width, closeTo(240, 0.01));
    expect(paragraph.left, closeTo(60, 0.01));
  });

  testWidgets('CSS text alignment does not center a percentage progress fill', (
    tester,
  ) async {
    await _pump(tester, '''
<div style="text-align:center">
  <div style="width:80%;height:6px;background:#9147ff"></div>
</div>
''');
    final fill = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color ==
                const Color(0xff9147ff),
      ),
    );
    expect(fill.width, closeTo(480, 0.01));
    expect(fill.left, closeTo(0, 0.01));
  });
}
