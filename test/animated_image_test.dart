import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'offscreen frames pause and visible frames only repaint the image',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final zoom = HtmlZoomController();
      addTearDown(zoom.dispose);
      final image = _TestImageProvider();
      await tester.pumpWidget(
        MaterialApp(
          home: SingleChildScrollView(
            controller: scroll,
            child: RepaintBoundary(
              child: HtmlEmailView(
                zoomController: zoom,
                html:
                    '<p>Email text</p><div style="height:500px"></div>'
                    '<p><img src="cid:animation" width="100" height="80"></p>',
                config: HtmlRenderConfig(
                  imageResolver: _Images(image),
                  pauseOffscreenImageAnimations: true,
                  enableTextSelection: false,
                  zoom: const HtmlZoomConfig(),
                ),
              ),
            ),
          ),
        ),
      );

      image.stream.emitFrame();
      await tester.pump();
      image.stream.emitFrame();
      await tester.pump();
      await tester.pump();
      expect(image.stream.listening, isFalse);

      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(image.stream.listening, isTrue);

      final paints = <RenderObject>{};
      final originalCallback = debugOnProfilePaint;
      debugOnProfilePaint = paints.add;
      final imageRender = tester.renderObject(find.byType(RawImage));
      final textRender = tester.renderObject(find.text('Email text'));
      try {
        image.stream.emitFrame();
        await tester.pump();
        expect(paints, contains(imageRender));
        expect(paints, isNot(contains(textRender)));
      } finally {
        debugOnProfilePaint = originalCallback;
      }

      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(image.stream.listening, isFalse);

      zoom.zoomTo(2);
      await tester.pumpAndSettle();
      expect(image.stream.listening, isFalse);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(image.stream.listening, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Images extends HtmlImageResolver {
  const _Images(this.provider);

  final ImageProvider provider;

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) =>
      HtmlImageResolution.image(provider);
}

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  final stream = _TestImageStream();

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _TestImageProvider key,
    ImageDecoderCallback decode,
  ) => stream;
}

class _TestImageStream extends ImageStreamCompleter {
  bool get listening => hasListeners;

  void emitFrame() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    setImage(ImageInfo(image: picture.toImageSync(20, 16)));
    picture.dispose();
  }
}
