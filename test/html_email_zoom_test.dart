import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

final _body = StringBuffer()
  ..write('<p>First paragraph with words</p>')
  ..write('<p><a href="https://example.test/x">Tap link</a></p>')
  ..writeAll([for (var i = 0; i < 40; i++) '<p>Filler line $i</p>']);

Future<ScrollController> _pump(
  WidgetTester tester, {
  String? html,
  HtmlZoomConfig? zoom = const HtmlZoomConfig(),
  HtmlZoomController? controller,
  HtmlLinkTapCallback? onLinkTap,
}) async {
  tester.view.physicalSize = const Size(400, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 100, child: Text('Message header')),
            HtmlEmailView(
              html: html ?? _body.toString(),
              zoomController: controller,
              config: HtmlRenderConfig(
                enableTextSelection: false,
                zoom: zoom,
                onLinkTap: onLinkTap,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return scroll;
}

/// Two fingers at [center] ±50px moving apart by [spread] px each.
Future<void> _pinch(WidgetTester tester, Offset center, double spread) async {
  final a = await tester.startGesture(center - const Offset(50, 0), pointer: 1);
  final b = await tester.startGesture(center + const Offset(50, 0), pointer: 2);
  const steps = 10;
  for (var i = 0; i < steps; i++) {
    await a.moveBy(Offset(-spread / steps, 0));
    await b.moveBy(Offset(spread / steps, 0));
    await tester.pump();
  }
  await a.up();
  await b.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('zoom is off by default', (tester) async {
    await _pump(tester, zoom: null);
    expect(find.byType(HtmlEmailZoom), findsNothing);
  });

  testWidgets('a pinch zooms the body and grows its reported height', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller);
    final view = find.byType(HtmlEmailView);
    final height = tester.getSize(view).height;
    final text = find.textContaining('First paragraph');
    final width = tester.getRect(text).width;

    await _pinch(tester, tester.getCenter(text), 50);

    expect(controller.scale, greaterThan(1.5));
    expect(controller.scale, lessThanOrEqualTo(3));
    expect(
      tester.getSize(view).height,
      closeTo(height * controller.scale, 1),
    );
    expect(tester.getRect(text).width, closeTo(width * controller.scale, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the zoom stays within maxScale', (tester) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller: controller,
      zoom: const HtmlZoomConfig(maxScale: 1.5, doubleTapScale: 1.5),
    );
    await _pinch(
      tester,
      tester.getCenter(find.textContaining('First paragraph')),
      120,
    );
    expect(controller.scale, 1.5);
  });

  testWidgets('one finger still scrolls the host', (tester) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    final scroll = await _pump(tester, controller: controller);
    await tester.dragFrom(const Offset(200, 400), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(100));
    expect(controller.scale, 1);
  });

  testWidgets('a horizontal drag pans a zoomed message', (tester) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller);
    controller.zoomTo(2);
    await tester.pump();
    final text = find.textContaining('First paragraph');
    final left = tester.getRect(text).left;

    await tester.dragFrom(const Offset(300, 200), const Offset(-150, 0));
    await tester.pumpAndSettle();

    expect(controller.offsetX, greaterThan(100));
    expect(tester.getRect(text).left, closeTo(left - controller.offsetX, 1));
    // Panning stops at the right edge of the zoomed body.
    await tester.dragFrom(const Offset(300, 200), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(controller.offsetX, closeTo(400, 1));
  });

  testWidgets('links stay tappable while zoomed', (tester) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    String? tapped;
    await _pump(
      tester,
      controller: controller,
      zoom: const HtmlZoomConfig(doubleTapScale: null),
      onLinkTap: (url, _) => tapped = url,
    );
    controller.zoomTo(2);
    await tester.pump();
    // The paragraph spans the line; the short link starts at its left.
    final link = tester.getRect(find.textContaining('Tap link'));
    await tester.tapAt(Offset(link.left + 20, link.center.dy));
    expect(tapped, 'https://example.test/x');
  });

  testWidgets('with double tap on, a link fires after its timeout', (
    tester,
  ) async {
    String? tapped;
    await _pump(tester, onLinkTap: (url, _) => tapped = url);
    final link = tester.getRect(find.textContaining('Tap link'));
    await tester.tapAt(Offset(link.left + 20, link.center.dy));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(tapped, 'https://example.test/x');
  });

  testWidgets('a long press selects text in a zoomed message', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ListView(
            children: [
              HtmlEmailView(
                html: _body.toString(),
                zoomController: controller,
                config: const HtmlRenderConfig(zoom: HtmlZoomConfig()),
              ),
            ],
          ),
        ),
      ),
    );
    controller.zoomTo(2);
    await tester.pump();
    final text = tester.getRect(find.textContaining('First paragraph'));
    await tester.longPressAt(Offset(text.left + 30, text.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('a double tap toggles the zoom', (tester) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller);
    final at = tester.getCenter(find.textContaining('First paragraph'));
    Future<void> doubleTap() async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
    }

    await doubleTap();
    expect(controller.scale, 2);
    await doubleTap();
    expect(controller.scale, 1);
  });

  testWidgets('a new message starts unzoomed', (tester) async {
    await _pump(tester);
    await _pinch(
      tester,
      tester.getCenter(find.textContaining('First paragraph')),
      50,
    );
    await _pump(tester, html: '<p>Second message</p>');
    final text = find.textContaining('Second message');
    expect(
      tester.getRect(text).width,
      closeTo(tester.renderObject<RenderBox>(text).size.width, 0.5),
    );
  });
}
