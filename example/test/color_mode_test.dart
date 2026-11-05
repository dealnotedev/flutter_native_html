import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_native_html_example/main.dart';

void main() {
  testWidgets('app and message themes switch separately on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const FlutterHtmlDemoApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Toggle app theme'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.byKey(const ValueKey('message-color-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Original').last);
    await tester.pumpAndSettle();
    expect(find.text('Original'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });
}
