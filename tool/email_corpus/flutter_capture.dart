// Flutter side of the browser-parity harness. Generated shard tests call
// [runShard] with a JSON spec written by run_flutter.mjs. Each job renders one
// email at one width and writes a layout dump (words, images, errors) and a
// PNG next to the Chrome capture of the same job.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';

void runShard(String specPath) {
  final spec =
      jsonDecode(File(specPath).readAsStringSync()) as Map<String, dynamic>;
  final outDir = spec['outDir'] as String;
  final assetsDir = spec['assetsDir'] as String;
  final assetIndex =
      (jsonDecode(File('$assetsDir/index.json').readAsStringSync()) as Map)
          .cast<String, dynamic>();
  final jobs = (spec['jobs'] as List).cast<Map<String, dynamic>>();
  final cfg = (spec['config'] as Map).cast<String, dynamic>();
  final writePng = spec['png'] as bool? ?? true;

  setUpAll(() async {
    for (final font in (spec['fonts'] as List).cast<Map<String, dynamic>>()) {
      final loader = FontLoader(font['name'] as String);
      for (final file in (font['files'] as List).cast<String>()) {
        loader.addFont(
          Future.value(ByteData.sublistView(File(file).readAsBytesSync())),
        );
      }
      await loader.load();
    }
  });

  for (final job in jobs) {
    testWidgets(
      job['key'] as String,
      (tester) => _captureJob(
        tester,
        job,
        cfg,
        outDir,
        assetsDir,
        assetIndex,
        writePng: writePng,
      ),
      timeout: const Timeout(Duration(seconds: 120)),
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}

class _HarnessImages extends HtmlImageResolver {
  _HarnessImages(this.assetsDir, this.index);

  final String assetsDir;
  final Map<String, dynamic> index;
  final providers = <String, MemoryImage>{};
  final urlOf = Map<ImageProvider, String>.identity();
  final missing = <String>{};
  static const _inline = DefaultHtmlImageResolver();

  @override
  HtmlImageResolution resolve(String src, Map<String, String> attributes) {
    var url = src.trim();
    if (url.startsWith('//')) url = 'https:$url';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return _inline.resolve(src, attributes);
    }
    final provider = providerFor(url);
    if (provider == null) {
      missing.add(url);
      return const HtmlImageResolution.unavailable();
    }
    return HtmlImageResolution.image(provider);
  }

  MemoryImage? providerFor(String url) {
    final existing = providers[url];
    if (existing != null) return existing;
    final entry = index[url] as Map<String, dynamic>?;
    final file = entry?['file'] as String?;
    if (file == null) return null;
    final provider = MemoryImage(File('$assetsDir/$file').readAsBytesSync());
    providers[url] = provider;
    urlOf[provider] = url;
    return provider;
  }
}

/// Decodes [providers] for real (outside fake async) so widgets resolve them
/// synchronously from the image cache. Returns the decoded images by url; the
/// completers stay alive (see [handles]) so the cache cannot evict them.
Future<Map<String, ui.Image>> _decode(
  Map<String, MemoryImage> providers,
  List<ImageStreamCompleterHandle> handles,
) async {
  final decoded = <String, ui.Image>{};
  await Future.wait([
    for (final MapEntry(key: url, value: provider) in providers.entries)
      () async {
        final completer = Completer<void>();
        final stream = provider.resolve(ImageConfiguration.empty);
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            decoded[url] = info.image.clone();
            info.dispose();
            if (!completer.isCompleted) completer.complete();
          },
          onError: (_, _) {
            if (!completer.isCompleted) completer.complete();
          },
        );
        stream.addListener(listener);
        final handle = stream.completer?.keepAlive();
        if (handle != null) handles.add(handle);
        await completer.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );
        stream.removeListener(listener);
      }(),
  ]);
  return decoded;
}

Future<void> _captureJob(
  WidgetTester tester,
  Map<String, dynamic> job,
  Map<String, dynamic> cfg,
  String outDir,
  String assetsDir,
  Map<String, dynamic> assetIndex, {
  required bool writePng,
}) async {
  final width = (job['width'] as num).toDouble();
  final key = job['key'] as String;
  final html = File(job['file'] as String).readAsStringSync();
  final images = _HarnessImages(assetsDir, assetIndex);
  for (final url in (job['images'] as List).cast<String>()) {
    images.providerFor(url);
  }
  final errors = <String>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString().split('\n').first;
    if (errors.length < 50) errors.add(text);
  };
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  final result = <String, dynamic>{'id': job['id'], 'width': width};
  final capture = <String, dynamic>{
    'key': job['cacheKey'],
    'settingsKey': job['settingsKey'],
    'sourceHash': job['sourceHash'],
    'complete': false,
    'png': false,
  };
  result['capture'] = capture;
  final handles = <ImageStreamCompleterHandle>[];
  var decoded = <String, ui.Image>{};
  try {
    PaintingBinding.instance.imageCache
      ..maximumSize = 100000
      ..maximumSizeBytes = 4 << 30;
    decoded =
        await tester.runAsync(() => _decode(images.providers, handles)) ?? {};
    final boundary = GlobalKey();
    final config = HtmlRenderConfig(
      imageResolver: images,
      // Layout runs compare the light presentation; dark runs pass
      // `--color-mode auto|dark --brightness dark` (an app in dark theme).
      colorMode: HtmlEmailColorMode.values.byName(
        cfg['colorMode'] as String? ?? 'original',
      ),
      brightness: cfg['brightness'] == 'dark'
          ? Brightness.dark
          : Brightness.light,
      enableTextSelection: false,
      fitToWidth: false,
      baseFontSize: (cfg['baseFontSize'] as num).toDouble(),
      defaultTableCellSpacing: (cfg['defaultTableCellSpacing'] as num)
          .toDouble(),
      defaultFontFamily: cfg['defaultFontFamily'] as String?,
    );
    final watch = Stopwatch()..start();
    final textScale = (cfg['textScale'] as num?)?.toDouble() ?? 1.0;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        // `--text-scale 1.5`: the phone's accessibility font size.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Material(
          color: const Color(0xffffffff),
          child: SingleChildScrollView(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: width,
                child: HtmlEmailView(html: html, config: config),
              ),
            ),
          ),
        ),
      ),
    );
    result['ms'] = watch.elapsedMilliseconds;
    // Images the resolver met only during build (URL spelling differences).
    final late = Map.of(images.providers)
      ..removeWhere((url, _) => decoded.containsKey(url));
    if (late.isNotEmpty) {
      decoded = {
        ...decoded,
        ...?await tester.runAsync(() => _decode(late, handles)),
      };
      await tester.pump();
    }
    await tester.pump();
    final root =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // Wait until every <img> has pixels (data: URIs decode only now; a
    // decoded image may also need a frame to reach its RenderImage).
    int pendingImages() {
      var pending = 0;
      void visit(RenderObject node) {
        if (node is RenderImage && node.image == null) pending++;
        node.visitChildren(visit);
      }

      visit(root);
      return pending;
    }

    for (var i = 0; i < 40 && pendingImages() > 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    result['pendingImages'] = pendingImages();
    result.addAll(_Dumper(root, images, decoded).dump());
    result['missingImages'] = images.missing.toList();
    final size = root.size;
    if (writePng && size.height <= 16000 && size.height > 0) {
      final saved = await tester.runAsync(() async {
        final image = await root.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '$outDir/$key.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          return true;
        } finally {
          image.dispose();
        }
      });
      if (saved != true) throw StateError('PNG capture did not complete');
      capture['png'] = true;
    }
    capture['complete'] = true;
  } catch (error, stack) {
    errors.add(
      'harness: $error ${stack.toString().split('\n').take(3).join(' | ')}',
    );
  } finally {
    for (final image in decoded.values) {
      image.dispose();
    }
    for (final handle in handles) {
      handle.dispose();
    }
    FlutterError.onError = previousOnError;
    result['errors'] = errors;
    var nonFinite = 0;
    Object? finite(Object? value) => switch (value) {
      double v when !v.isFinite => () {
        nonFinite++;
        return null;
      }(),
      Map m => m.map((k, v) => MapEntry(k, finite(v))),
      List l => l.map(finite).toList(),
      _ => value,
    };
    final encodable = finite(result) as Map;
    if (nonFinite > 0) {
      (encodable['errors'] as List).add(
        'non-finite geometry: $nonFinite values',
      );
      // Words without a usable position cannot be compared.
      encodable['words'] = [
        for (final w in (encodable['words'] as List? ?? const []))
          if ((w as Map).values.every((v) => v != null)) w,
      ];
    }
    File('$outDir/$key.json').writeAsStringSync(jsonEncode(encodable));
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

class _Run {
  _Run(this.start, this.end, this.style);
  final int start;
  final int end;
  final TextStyle style;
}

class _Dumper {
  _Dumper(this.root, this.images, this.decoded);

  final RenderBox root;
  final _HarnessImages images;
  final Map<String, ui.Image> decoded;
  final words = <Map<String, dynamic>>[];
  final imageBoxes = <Map<String, dynamic>>[];
  double maxRight = 0;

  Map<String, dynamic> dump() {
    _visit(root, null, 1);
    return {
      'words': words,
      'images': imageBoxes,
      'docWidth': maxRight,
      'docHeight': root.size.height,
    };
  }

  Rect _global(RenderBox box, Rect local) =>
      MatrixUtils.transformRect(box.getTransformTo(root), local);

  bool _clipsChildren(RenderObject node) {
    if (node is RenderClipRect ||
        node is RenderClipRRect ||
        node is RenderClipOval ||
        node is RenderClipPath) {
      return true;
    }
    if (node is RenderFlex) return node.clipBehavior != Clip.none;
    if (node is RenderStack) return node.clipBehavior != Clip.none;
    return false;
  }

  void _visit(RenderObject node, Rect? clip, double opacity) {
    if (node is RenderOffstage && node.offstage) return;
    if (node is RenderOpacity) opacity *= node.opacity;
    if (node is RenderAnimatedOpacity) opacity *= node.opacity.value;
    if (node is RenderBox && node.hasSize) {
      if (_clipsChildren(node)) {
        final bounds = _global(node, Offset.zero & node.size);
        clip = clip == null ? bounds : clip.intersect(bounds);
      }
      final right = _global(node, Offset.zero & node.size).right;
      if (right > maxRight && node is! RenderRepaintBoundary) {
        // Only painted leaves count toward horizontal overflow.
        if (node is RenderParagraph || node is RenderImage) maxRight = right;
      }
    }
    if (node is RenderParagraph) {
      // After a layout error a subtree can stay dirty; skip it, the error is
      // already recorded.
      if (!node.debugNeedsLayout) _paragraph(node, clip, opacity);
      return;
    }
    if (node is RenderImage) _image(node, clip, opacity);
    if (node is RenderDecoratedBox) _decorationImage(node, clip, opacity);
    node.visitChildren((child) => _visit(child, clip, opacity));
  }

  bool _visible(Rect rect, Rect? clip, double opacity) {
    if (rect.width <= 0 || rect.height <= 0 || opacity <= 0.1) return false;
    if (rect.right <= 0 || rect.bottom <= 0) return false;
    if (clip != null) {
      final visible = rect.intersect(clip);
      if (visible.width <= 0 ||
          visible.height <= 0 ||
          visible.width * visible.height / (rect.width * rect.height) < 0.5) {
        return false;
      }
    }
    return true;
  }

  List<_Run> _runs(InlineSpan span) {
    final runs = <_Run>[];
    var offset = 0;
    void walk(InlineSpan span, TextStyle inherited) {
      final own = span.style;
      final style = own == null
          ? inherited
          : (own.inherit ? inherited.merge(own) : own);
      if (span is TextSpan) {
        final text = span.text ?? '';
        if (text.isNotEmpty) {
          runs.add(_Run(offset, offset + text.length, style));
        }
        offset += text.length;
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child, style);
        }
      } else if (span is PlaceholderSpan) {
        runs.add(_Run(offset, offset + 1, style));
        offset += 1;
      }
    }

    walk(span, const TextStyle(fontSize: 14));
    return runs;
  }

  TextStyle _styleAt(List<_Run> runs, int offset) {
    for (final run in runs) {
      if (offset >= run.start && offset < run.end) return run.style;
    }
    return runs.isEmpty ? const TextStyle() : runs.last.style;
  }

  String _color(Color? color) {
    if (color == null) return 'rgb(0, 0, 0)';
    int c(double v) => (v * 255).round();
    return color.a >= 1
        ? 'rgb(${c(color.r)}, ${c(color.g)}, ${c(color.b)})'
        : 'rgba(${c(color.r)}, ${c(color.g)}, ${c(color.b)}, ${color.a.toStringAsFixed(2)})';
  }

  void _paragraph(RenderParagraph p, Rect? clip, double opacity) {
    final plain = p.text.toPlainText(
      includeSemanticsLabels: false,
      includePlaceholders: true,
    );
    final runs = _runs(p.text);
    final children = <RenderObject>[];
    p.visitChildren(children.add);
    // Visit inline widgets (inline-blocks, images) at their text position so
    // the word stream keeps document order, like the DOM walk in Chrome.
    final positions = <int>[
      for (var i = 0; i < plain.length; i++)
        if (plain.codeUnitAt(i) == 0xFFFC) i,
    ];
    var placeholder = 0;
    void flushPlaceholdersBefore(int offset) {
      while (placeholder < positions.length &&
          positions[placeholder] < offset &&
          placeholder < children.length) {
        _visit(children[placeholder], clip, opacity);
        placeholder++;
      }
    }

    for (final match in RegExp(r'[^\s￼]+').allMatches(plain)) {
      flushPlaceholdersBefore(match.start);
      final word = match.group(0)!.replaceAll('\u200b', '');
      if (word.isEmpty) continue;
      final boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      if (boxes.isEmpty) continue;
      var local = boxes.first.toRect();
      final tops = <int>{};
      for (final box in boxes) {
        local = local.expandToInclude(box.toRect());
        tops.add(box.top.round());
      }
      final rect = _global(p, local);
      final style = _styleAt(runs, match.start);
      final fontSize = style.fontSize ?? 14;
      final color = style.color ?? style.foreground?.color;
      if (fontSize < 2 || (color != null && color.a == 0)) continue;
      if (!_visible(rect, clip, opacity)) continue;
      words.add({
        't': word,
        'x': rect.left,
        'y': rect.top,
        'w': rect.width,
        'h': rect.height,
        'lines': tops.length,
        'fs': fontSize,
        'fw': (style.fontWeight ?? FontWeight.w400).value,
        'it': style.fontStyle == FontStyle.italic,
        'c': _color(color),
        'u': style.decoration?.contains(TextDecoration.underline) ?? false,
        'ff': [style.fontFamily, ...?style.fontFamilyFallback].join(','),
      });
    }
    flushPlaceholdersBefore(plain.length + 1);
    while (placeholder < children.length) {
      _visit(children[placeholder++], clip, opacity);
    }
  }

  String? _urlOfImage(ui.Image? image) {
    if (image == null) return null;
    for (final MapEntry(key: url, value: decodedImage) in decoded.entries) {
      if (image.isCloneOf(decodedImage)) return url;
    }
    return null;
  }

  void _image(RenderImage node, Rect? clip, double opacity) {
    if (!node.hasSize) return;
    final rect = _global(node, Offset.zero & node.size);
    if (!_visible(rect, clip, opacity)) return;
    imageBoxes.add({
      'src': _urlOfImage(node.image),
      'x': rect.left,
      'y': rect.top,
      'w': rect.width,
      'h': rect.height,
      'nw': node.image?.width,
      'nh': node.image?.height,
    });
  }

  void _decorationImage(RenderDecoratedBox node, Rect? clip, double opacity) {
    final decoration = node.decoration;
    if (decoration is! BoxDecoration || decoration.image == null) return;
    if (!node.hasSize) return;
    final rect = _global(node, Offset.zero & node.size);
    if (!_visible(rect, clip, opacity)) return;
    imageBoxes.add({
      'src': images.urlOf[decoration.image!.image],
      'bg': true,
      'x': rect.left,
      'y': rect.top,
      'w': rect.width,
      'h': rect.height,
    });
  }
}
