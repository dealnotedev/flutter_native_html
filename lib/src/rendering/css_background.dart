import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../config/html_image_resolver.dart';
import '../css/css_color.dart';
import '../css/html_style.dart';
import '../widget/html_image.dart';
import 'css_border_radius.dart';

/// Draws a CSS `background-image` behind [content], offset by
/// `background-position` and clipped to the box (CSS sprites). Honors the
/// image policy, so a remote sprite is shown only when remote images are
/// allowed; otherwise the content renders without it.
Widget paintCssBackground(
  Widget content,
  HtmlStyle style, {
  required HtmlImageResolver imageResolver,
  required bool allowDataUriImages,
  required bool pauseOffscreenAnimations,
}) {
  final url = style.backgroundImage;
  if (url == null || url.isEmpty) return content;
  if (url.trimLeft().toLowerCase().startsWith('linear-gradient(')) {
    final gradient = _linearGradient(url);
    if (gradient == null) return content;
    Widget result = DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: content,
    );
    final radius = cssBorderRadius(style);
    if (radius != null) {
      result = ClipRRect(borderRadius: radius, child: result);
    }
    return result;
  }
  if (url.trimLeft().toLowerCase().startsWith('data:') && !allowDataUriImages) {
    return content;
  }
  final resolution = imageResolver.resolve(url, const {});
  if (!resolution.hasImage) return content;

  // Clip the background (and its overflow) to the box, rounding the corners
  // when the box has a border-radius — e.g. a hero banner with rounded edges.
  final radius = cssBorderRadius(style);
  Widget clip(Widget child) => radius != null
      ? ClipRRect(borderRadius: radius, child: child)
      : ClipRect(child: child);

  final size = style.backgroundSize;
  final spriteWidth = (size != null && size.endsWith('px'))
      ? double.tryParse(size.substring(0, size.length - 2))
      : null;
  final fit = switch (size) {
    'cover' => BoxFit.cover,
    'contain' => BoxFit.contain,
    '100%' => BoxFit.fitWidth,
    _ => null,
  };
  final alignment =
      style.backgroundPosition ??
      (fit == null ? Alignment.topLeft : Alignment.center);
  final offset = Offset(
    style.backgroundPositionX ?? 0,
    style.backgroundPositionY ?? 0,
  );
  final repeat = _imageRepeat(style.backgroundRepeat);
  if (repeat != ImageRepeat.noRepeat && size == null) {
    return clip(
      _TiledBackground(
        image: resolution.provider!,
        repeat: repeat,
        alignment: alignment,
        offset: offset,
        child: content,
      ),
    );
  }
  final image = buildHtmlImage(
    pauseOffscreenAnimations: pauseOffscreenAnimations,
    image: resolution.provider!,
    width: spriteWidth,
    fit: offset == Offset.zero ? fit : null,
    alignment: alignment,
    excludeFromSemantics: true,
    errorBuilder: _emptyBackground,
  );
  final Widget background;
  if (fit != null) {
    // Fit and move the entire bitmap before clipping to the background box.
    background = Positioned.fill(
      child: offset == Offset.zero
          ? image
          : Transform.translate(
              offset: offset,
              child: FittedBox(fit: fit, alignment: alignment, child: image),
            ),
    );
  } else if (alignment.x.abs() == 1 && alignment.y.abs() == 1) {
    background = Positioned(
      left: alignment.x < 0 ? offset.dx : null,
      right: alignment.x > 0 ? -offset.dx : null,
      top: alignment.y < 0 ? offset.dy : null,
      bottom: alignment.y > 0 ? -offset.dy : null,
      child: image,
    );
  } else {
    // Centre or position a full-size sprite relative to the free space. The
    // image may be taller or wider than its box, which must stay unchanged.
    background = Positioned.fill(
      child: OverflowBox(
        alignment: alignment,
        minWidth: 0,
        minHeight: 0,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: offset == Offset.zero
            ? image
            : Transform.translate(offset: offset, child: image),
      ),
    );
  }
  return clip(
    Stack(clipBehavior: Clip.hardEdge, children: [background, content]),
  );
}

Widget _emptyBackground(
  BuildContext context,
  Object error,
  StackTrace? stack,
) => const SizedBox.shrink();

LinearGradient? _linearGradient(String value) {
  final match = RegExp(
    r'^linear-gradient\((.*)\)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(value.trim());
  if (match == null) return null;
  final parts = <String>[];
  var depth = 0, start = 0;
  final body = match.group(1)!;
  for (var i = 0; i < body.length; i++) {
    if (body[i] == '(') depth++;
    if (body[i] == ')') depth--;
    if (body[i] == ',' && depth == 0) {
      parts.add(body.substring(start, i).trim());
      start = i + 1;
    }
  }
  parts.add(body.substring(start).trim());
  var begin = Alignment.topCenter, end = Alignment.bottomCenter;
  if (parts.first.toLowerCase().startsWith('to ')) {
    final direction = parts.removeAt(0).toLowerCase();
    final ends = switch (direction) {
      'to bottom' => (Alignment.topCenter, Alignment.bottomCenter),
      'to top' => (Alignment.bottomCenter, Alignment.topCenter),
      'to right' => (Alignment.centerLeft, Alignment.centerRight),
      'to left' => (Alignment.centerRight, Alignment.centerLeft),
      'to bottom right' ||
      'to right bottom' => (Alignment.topLeft, Alignment.bottomRight),
      'to bottom left' ||
      'to left bottom' => (Alignment.topRight, Alignment.bottomLeft),
      'to top right' ||
      'to right top' => (Alignment.bottomLeft, Alignment.topRight),
      'to top left' ||
      'to left top' => (Alignment.bottomRight, Alignment.topLeft),
      _ => null,
    };
    if (ends == null) return null;
    begin = ends.$1;
    end = ends.$2;
  }
  final colors = parts.map(CssColor.tryParse).toList();
  if (colors.length < 2 || colors.any((color) => color == null)) return null;
  return LinearGradient(begin: begin, end: end, colors: colors.cast<Color>());
}

ImageRepeat _imageRepeat(CssBackgroundRepeat? repeat) {
  return switch (repeat) {
    // CSS defaults `background-repeat` to `repeat`. Paint tiling in a custom
    // paint-only layer so it never participates in layout.
    CssBackgroundRepeat.repeat || null => ImageRepeat.repeat,
    CssBackgroundRepeat.repeatX => ImageRepeat.repeatX,
    CssBackgroundRepeat.repeatY => ImageRepeat.repeatY,
    CssBackgroundRepeat.noRepeat => ImageRepeat.noRepeat,
  };
}

class _TiledBackground extends StatefulWidget {
  const _TiledBackground({
    required this.image,
    required this.repeat,
    required this.alignment,
    required this.offset,
    required this.child,
  });

  final ImageProvider image;
  final ImageRepeat repeat;
  final AlignmentGeometry alignment;
  final Offset offset;
  final Widget child;

  @override
  State<_TiledBackground> createState() => _TiledBackgroundState();
}

class _TiledBackgroundState extends State<_TiledBackground> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _imageInfo;
  bool _acceptedFrameForStream = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(_TiledBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolveImage();
  }

  @override
  void dispose() {
    _removeStreamListener();
    _imageInfo?.dispose();
    super.dispose();
  }

  void _resolveImage() {
    final listener = _listener ??= ImageStreamListener(
      _handleImage,
      onError: (_, _) => _removeStreamListener(),
      reportErrors: false,
    );
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _removeStreamListener();
    _imageInfo?.dispose();
    _imageInfo = null;
    _acceptedFrameForStream = false;
    _stream = stream;
    stream.addListener(listener);
  }

  void _handleImage(ImageInfo imageInfo, bool synchronousCall) {
    if (_acceptedFrameForStream) {
      imageInfo.dispose();
      return;
    }
    _acceptedFrameForStream = true;
    final oldInfo = _imageInfo;
    if (oldInfo?.image == imageInfo.image &&
        oldInfo?.scale == imageInfo.scale) {
      imageInfo.dispose();
      return;
    }
    _imageInfo = imageInfo;
    oldInfo?.dispose();
    // Repeated backgrounds are decorative tiles. Freezing them at the first
    // decoded frame prevents animated GIF backgrounds from invalidating and
    // repainting the whole tiled layer on every frame.
    _removeStreamListener();
    if (mounted) setState(() {});
  }

  void _removeStreamListener() {
    final listener = _listener;
    final stream = _stream;
    if (listener != null && stream != null) {
      stream.removeListener(listener);
    }
    _stream = null;
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _imageInfo == null
          ? null
          : _TiledBackgroundPainter(
              imageInfo: _imageInfo!,
              repeat: widget.repeat,
              offset: widget.offset,
              alignment: widget.alignment.resolve(
                Directionality.maybeOf(context),
              ),
            ),
      child: widget.child,
    );
  }
}

class _TiledBackgroundPainter extends CustomPainter {
  const _TiledBackgroundPainter({
    required this.imageInfo,
    required this.repeat,
    required this.alignment,
    required this.offset,
  });

  final ImageInfo imageInfo;
  final ImageRepeat repeat;
  final Alignment alignment;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final image = imageInfo.image;
    final scale = imageInfo.scale;
    if (image.width <= 0 || image.height <= 0 || scale <= 0) return;

    final tileSize = Size(image.width / scale, image.height / scale);
    if (tileSize.isEmpty) return;

    final repeatX =
        repeat == ImageRepeat.repeat || repeat == ImageRepeat.repeatX;
    final repeatY =
        repeat == ImageRepeat.repeat || repeat == ImageRepeat.repeatY;
    final origin =
        alignment.alongOffset(
          Offset(size.width - tileSize.width, size.height - tileSize.height),
        ) +
        offset;
    final logicalRect = Rect.fromLTWH(
      repeatX ? 0 : origin.dx,
      repeatY ? 0 : origin.dy,
      repeatX ? size.width : tileSize.width,
      repeatY ? size.height : tileSize.height,
    ).intersect(Offset.zero & size);
    if (logicalRect.isEmpty) return;

    // `paintImage(repeat: ...)` expands repeats by drawing many image rects.
    // A small footer tile plus an animated GIF elsewhere in the email can then
    // repaint thousands of tiny images per second. Use an ImageShader instead:
    // one draw call fills the repeated area, while non-repeated axes are clipped
    // to the tile's natural extent so they don't stretch.
    final paint = Paint()
      ..isAntiAlias = false
      ..shader = ui.ImageShader(
        image,
        repeatX ? ui.TileMode.repeated : ui.TileMode.clamp,
        repeatY ? ui.TileMode.repeated : ui.TileMode.clamp,
        Matrix4.identity().storage,
      );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(1 / scale, 1 / scale);
    canvas.drawRect(
      Rect.fromLTWH(
        (logicalRect.left - origin.dx) * scale,
        (logicalRect.top - origin.dy) * scale,
        logicalRect.width * scale,
        logicalRect.height * scale,
      ),
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TiledBackgroundPainter oldDelegate) {
    return oldDelegate.imageInfo.image != imageInfo.image ||
        oldDelegate.imageInfo.scale != imageInfo.scale ||
        oldDelegate.repeat != repeat ||
        oldDelegate.alignment != alignment ||
        oldDelegate.offset != offset;
  }
}
