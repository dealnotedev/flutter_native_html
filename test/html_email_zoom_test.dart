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
  bool reverse = false,
  bool singleChild = false,
  double footerHeight = 0,
}) async {
  tester.view.physicalSize = const Size(400, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  final children = [
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
    if (footerHeight > 0) SizedBox(height: footerHeight),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: singleChild
            ? SingleChildScrollView(
                controller: scroll,
                reverse: reverse,
                child: Column(children: children),
              )
            : ListView(
                controller: scroll,
                reverse: reverse,
                children: children,
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
    expect(tester.getSize(view).height, closeTo(height * controller.scale, 1));
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

  testWidgets('a diagonal opening is tracked from the second touch', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    final scroll = await _pump(tester, controller: controller);
    scroll.jumpTo(100);
    await tester.pump();
    final left = await tester.startGesture(const Offset(150, 300));
    final right = await tester.startGesture(const Offset(250, 300));

    // The first motion has enough vertical travel to start a ListView drag,
    // but barely changes the span. The next motion expands it to 150 pixels.
    await right.moveTo(const Offset(250, 325));
    await left.moveTo(const Offset(106, 283));
    await tester.pump();

    expect(controller.scale, closeTo(1.5, 0.001));
    // The offset includes focal-point compensation, not a one-finger drag.
    expect(scroll.offset, closeTo(246, 1));
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the content under the fingers stays there in the next frame', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller);
    final text = find.text('Filler line 7');
    final center = tester.getCenter(text);
    final left = await tester.startGesture(center - const Offset(50, 0));
    final right = await tester.startGesture(center + const Offset(50, 0));

    // Both events are delivered before the same frame. The new midpoint
    // moves up 25 pixels and right 10 pixels while the span grows by 50%.
    await left.moveBy(const Offset(-15, -25));
    await right.moveBy(const Offset(35, -25));
    await tester.pump();

    expect(controller.scale, closeTo(1.5, 0.001));
    final expected = center + const Offset(10, -25);
    expect((tester.getCenter(text) - expected).distance, lessThan(0.01));
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
  });

  testWidgets('replacing a finger keeps the current scale and focal point', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller);
    final left = await tester.startGesture(const Offset(150, 300));
    final right = await tester.startGesture(const Offset(250, 300));
    await left.moveBy(const Offset(-50, 0));
    await right.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(controller.scale, closeTo(2, 0.001));
    final body = find.byType(HtmlEmailView);
    final before = tester.getTopLeft(body);

    await right.up();
    final replacement = await tester.startGesture(const Offset(300, 330));
    await tester.pump();
    expect(tester.getTopLeft(body), before);
    expect(controller.scale, closeTo(2, 0.001));

    await replacement.moveBy(const Offset(1, 0));
    await tester.pump();
    expect(controller.scale, closeTo(2.01, 0.001));
    expect(tester.getTopLeft(body).dy, closeTo(before.dy, 3));
    await left.up();
    await replacement.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a pinch pans and reverses immediately at the scale limits', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    final scroll = await _pump(
      tester,
      controller: controller,
      zoom: const HtmlZoomConfig(maxScale: 2),
    );
    final left = await tester.startGesture(const Offset(150, 300));
    final right = await tester.startGesture(const Offset(250, 300));
    await left.moveBy(const Offset(-75, 0));
    await right.moveBy(const Offset(75, 0));
    await tester.pump();
    expect(controller.scale, 2);
    final atMax = scroll.offset;

    // The two events briefly change the span, but the pair moves in parallel.
    await left.moveBy(const Offset(0, -50));
    await right.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(controller.scale, 2);
    expect(scroll.offset, closeTo(atMax + 50, 0.01));

    await right.moveBy(const Offset(-5, 0));
    await tester.pump();
    expect(controller.scale, lessThan(2));

    await right.moveBy(const Offset(-180, 0));
    await tester.pump();
    expect(controller.scale, 1);
    await right.moveBy(const Offset(5, 0));
    await tester.pump();
    expect(controller.scale, greaterThan(1));
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
  });

  for (final singleChild in [false, true]) {
    final host = singleChild ? 'SingleChildScrollView' : 'ListView';
    testWidgets('a short message zooms to the scroll edge in $host', (
      tester,
    ) async {
      final controller = HtmlZoomController();
      addTearDown(controller.dispose);
      final scroll = await _pump(
        tester,
        controller: controller,
        singleChild: singleChild,
        footerHeight: 30,
        html: '<div style="height:280px"><p>Top</p></div><p>Anchor</p>',
      );
      expect(scroll.position.maxScrollExtent, 0);
      final text = find.text('Anchor');
      final center = tester.getCenter(text);
      final left = await tester.startGesture(center - const Offset(50, 0));
      final right = await tester.startGesture(center + const Offset(50, 0));
      await left.moveBy(const Offset(-50, 0));
      await right.moveBy(const Offset(50, 0));
      await tester.pump();

      expect(controller.scale, closeTo(2, 0.001));
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      expect(scroll.offset, scroll.position.maxScrollExtent);
      expect(
        tester.getBottomLeft(find.byType(HtmlEmailView)).dy,
        closeTo(570, 0.01),
      );
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('a reversed list anchors zoom from its bottom edge', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller, reverse: true);
    final text = find.text('Filler line 37');
    final center = tester.getCenter(text);
    await _pinch(tester, center, 25);

    expect(controller.scale, closeTo(1.5, 0.001));
    expect((tester.getCenter(text) - center).distance, lessThan(0.01));
  });

  testWidgets('initial, programmatic and reset scales respect config bounds', (
    tester,
  ) async {
    final controller = HtmlZoomController();
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller: controller,
      zoom: const HtmlZoomConfig(minScale: 1.25, maxScale: 2),
    );
    expect(controller.scale, 1.25);

    controller.zoomTo(5);
    await tester.pump();
    expect(controller.scale, 2);

    controller.zoomTo(0.5);
    await tester.pump();
    expect(controller.scale, 1.25);

    controller.zoomTo(1.75);
    controller.reset();
    await tester.pump();
    expect(controller.scale, 1.25);
    expect(controller.offsetX, 0);
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

  testWidgets('a long press selects text in a zoomed message', (tester) async {
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
