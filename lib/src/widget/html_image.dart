import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

Widget buildHtmlImage({
  required bool pauseOffscreenAnimations,
  required ImageProvider image,
  double? width,
  double? height,
  BoxFit? fit,
  AlignmentGeometry alignment = Alignment.center,
  String? semanticLabel,
  bool excludeFromSemantics = false,
  bool animate = true,
  ImageErrorWidgetBuilder? errorBuilder,
}) {
  final standardImage = Image(
    image: image,
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    semanticLabel: semanticLabel,
    excludeFromSemantics: excludeFromSemantics,
    errorBuilder: errorBuilder,
  );
  if (!pauseOffscreenAnimations || kIsWeb) return standardImage;
  if (!animate) return TickerMode(enabled: false, child: standardImage);
  return _HtmlImage(image: standardImage);
}

/// Keeps animated images from repainting the rest of the document or running
/// while clipped out of the viewport.
class _HtmlImage extends StatefulWidget {
  const _HtmlImage({required this.image});

  final Image image;

  @override
  State<_HtmlImage> createState() => _HtmlImageState();
}

class _HtmlImageState extends State<_HtmlImage> with WidgetsBindingObserver {
  final _rawImageKey = GlobalKey();
  late final _imageContext = DisposableBuildContext(this);
  late final _listener = ImageStreamListener(
    _onFrame,
    onError: _onError,
    reportErrors: false,
  );
  ImageStream? _stream;
  ImageStreamCompleterHandle? _keepAlive;
  ImageInfo? _frame;
  Object? _error;
  StackTrace? _stackTrace;
  bool _animated = false;
  bool _visible = true;
  bool _listening = false;
  bool _animationsEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animationsEnabled =
        TickerMode.valuesOf(context).enabled &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    _resolveImage();
    _updateSubscription();
  }

  @override
  void didUpdateWidget(covariant _HtmlImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image.image != oldWidget.image.image) _resolveImage();
    _updateSubscription();
  }

  void _resolveImage() {
    final stream = ScrollAwareImageProvider(
      context: _imageContext,
      imageProvider: widget.image.image,
    ).resolve(createLocalImageConfiguration(context));
    if (_stream != null && _stream!.key == stream.key) return;
    _stopListening();
    _keepAlive?.dispose();
    _keepAlive = null;
    _frame?.dispose();
    _frame = null;
    _error = null;
    _stackTrace = null;
    _animated = false;
    _visible = true;
    _stream = stream;
  }

  void _updateSubscription() {
    final shouldListen =
        _error == null && (_frame == null || (_animationsEnabled && _visible));
    if (shouldListen && !_listening) {
      final keepAlive = _keepAlive;
      _keepAlive = null;
      _listening = true;
      _stream!.addListener(_listener);
      keepAlive?.dispose();
    } else if (!shouldListen && _listening) {
      _keepAlive = _stream!.completer?.keepAlive();
      _stopListening();
    }
  }

  void _stopListening() {
    if (!_listening) return;
    _listening = false;
    _stream!.removeListener(_listener);
  }

  void _onFrame(ImageInfo frame, bool synchronousCall) {
    final previous = _frame;
    _frame = frame;
    final image =
        (_rawImageKey.currentContext as RenderObjectElement?)?.renderObject;
    if (_animated && image is RenderImage && previous?.scale == frame.scale) {
      // Rebuilding Image below LayoutBuilder schedules a layout pass. Update
      // the render object directly once the animation has its own layer.
      image.image = frame.image.clone();
    } else {
      setState(() {
        _animated =
            _animated || (previous != null && !frame.isCloneOf(previous));
      });
    }
    previous?.dispose();
    _updateSubscription();
  }

  void _onError(Object error, StackTrace? stackTrace) {
    if (widget.image.errorBuilder == null) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'HTML image',
        ),
      );
    }
    setState(() {
      _error = error;
      _stackTrace = stackTrace;
    });
    _updateSubscription();
  }

  void _updateVisibility(bool visible) {
    _visible = visible;
    _updateSubscription();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListening();
    _keepAlive?.dispose();
    _frame?.dispose();
    _imageContext.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.image;
    final error = _error;
    final errorBuilder = spec.errorBuilder;
    if (error != null && errorBuilder != null) {
      return errorBuilder(context, error, _stackTrace);
    }
    Widget image = RawImage(
      key: _rawImageKey,
      image: _frame?.image,
      debugImageLabel: _frame?.debugLabel,
      scale: _frame?.scale ?? 1,
      width: spec.width,
      height: spec.height,
      fit: spec.fit,
      alignment: spec.alignment,
      filterQuality: spec.filterQuality,
      invertColors:
          (MediaQuery.maybeInvertColorsOf(context) ?? false) ||
          SemanticsBinding.instance.accessibilityFeatures.invertColors,
    );
    if (!spec.excludeFromSemantics) {
      image = Semantics(
        container: spec.semanticLabel != null,
        image: true,
        label: spec.semanticLabel ?? '',
        child: image,
      );
    }
    return _animated
        ? _AnimatedImageBoundary(
            onVisibilityChanged: _updateVisibility,
            child: image,
          )
        : image;
  }
}

class _AnimatedImageBoundary extends SingleChildRenderObjectWidget {
  const _AnimatedImageBoundary({
    required this.onVisibilityChanged,
    required super.child,
  });

  final ValueChanged<bool> onVisibilityChanged;

  @override
  _RenderAnimatedImageBoundary createRenderObject(BuildContext context) =>
      _RenderAnimatedImageBoundary(onVisibilityChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAnimatedImageBoundary renderObject,
  ) {
    renderObject.onVisibilityChanged = onVisibilityChanged;
  }
}

class _RenderAnimatedImageBoundary extends RenderRepaintBoundary {
  _RenderAnimatedImageBoundary(this.onVisibilityChanged);

  ValueChanged<bool> onVisibilityChanged;
  VoidCallback? _removeCompositionCallback;
  bool _reportedVisible = true;
  bool _visible = true;
  bool _reportScheduled = false;

  @override
  void performLayout() {
    super.performLayout();
    // Initially offstage render objects lay out without a paint pass.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) _reportVisibility(_intersectsViewport());
    });
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Runs even when the scroll viewport reuses this image's display list.
    _removeCompositionCallback ??= context.addCompositionCallback(_onCompose);
    super.paint(context, offset);
  }

  void _onCompose(Layer layer) {
    _queueVisibility(layer.attached && _intersectsViewport());
  }

  void _queueVisibility(bool visible) {
    _visible = visible;
    if (_reportScheduled || _visible == _reportedVisible) return;
    _reportScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (attached) _reportVisibility(_visible);
    });
  }

  void _reportVisibility(bool visible) {
    if (visible == _reportedVisible) return;
    _reportedVisible = visible;
    onVisibilityChanged(visible);
  }

  bool _intersectsViewport() {
    var bounds = MatrixUtils.transformRect(getTransformTo(null), paintBounds);
    // Render transforms include fit-to-width and zoom. Ancestor clips include
    // the scroll viewport and the horizontal crop applied during zoom.
    RenderObject node = this;
    for (var parent = node.parent; parent != null; parent = node.parent) {
      if (!parent.paintsChild(node)) return false;
      final clip = parent.describeApproximatePaintClip(node);
      if (clip != null) {
        bounds = bounds.intersect(
          MatrixUtils.transformRect(parent.getTransformTo(null), clip),
        );
      }
      if (bounds.isEmpty || !bounds.isFinite) return false;
      node = parent;
    }
    final viewBounds = node is RenderView ? node.paintBounds : null;
    return !bounds.isEmpty &&
        (viewBounds == null || bounds.overlaps(viewBounds));
  }

  @override
  void dispose() {
    _removeCompositionCallback?.call();
    super.dispose();
  }
}
