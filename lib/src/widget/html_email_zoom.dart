import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../config/html_render_config.dart';

/// Reads and resets the pinch-zoom state of an [HtmlEmailView] that has
/// [HtmlRenderConfig.zoom] set. One controller drives one view.
class HtmlZoomController extends ChangeNotifier {
  HtmlZoomConfig? _config;
  double? _scale;
  double _offsetX = 0;
  bool _configurationChanged = false;

  /// The current zoom factor. The initial factor is the configured minimum.
  double get scale => _scale ?? _config?.minScale ?? 1;

  /// How far a zoomed message is panned from its left edge, in screen px.
  double get offsetX => _offsetX;

  /// Back to the minimum scale, e.g. when the host shows another message.
  void reset() => _set(null, 0);

  /// Zooms to [scale] within the configured limits, keeping the left edge in
  /// place. [scale] must be finite and positive.
  void zoomTo(double scale) {
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and positive');
    }
    _set(scale, 0);
  }

  double _clampScale(double scale) {
    final config = _config;
    return config == null
        ? scale
        : scale.clamp(config.minScale, config.maxScale).toDouble();
  }

  void _set(double? scale, double offsetX) {
    final previous = this.scale;
    _scale = scale == null ? null : _clampScale(scale);
    if (this.scale == previous && offsetX == _offsetX) return;
    _offsetX = offsetX;
    _configurationChanged = false;
    notifyListeners();
  }

  void _configure(HtmlZoomConfig config) {
    final previous = scale;
    _config = config;
    final requested = _scale;
    if (requested != null) _scale = _clampScale(requested);
    if (scale == previous) return;
    _offsetX = 0;
    if (_configurationChanged) return;
    _configurationChanged = true;
    // The view can apply new bounds during its build. Notify host listeners
    // after the build so they can safely update their own widgets.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_configurationChanged) return;
      _configurationChanged = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _configurationChanged = false;
    super.dispose();
  }
}

/// Pinch-to-zoom for a message body that lives inside the host's scroll
/// view. The zoomed body reports its scaled height, so the host's vertical
/// scroll keeps working with one finger; two fingers zoom around their focal
/// point, one finger scrolls horizontally while zoomed, and a double tap toggles
/// between [HtmlZoomConfig.minScale] and [HtmlZoomConfig.doubleTapScale].
/// Links and text selection hit-test through the transform.
class HtmlEmailZoom extends StatefulWidget {
  const HtmlEmailZoom({
    super.key,
    required this.config,
    this.controller,
    required this.child,
  });

  final HtmlZoomConfig config;
  final HtmlZoomController? controller;
  final Widget child;

  @override
  State<HtmlEmailZoom> createState() => _HtmlEmailZoomState();
}

class _HtmlEmailZoomState extends State<HtmlEmailZoom>
    with SingleTickerProviderStateMixin {
  HtmlZoomController? _internal;
  HtmlZoomController get _controller =>
      widget.controller ?? (_internal ??= HtmlZoomController());

  final _boxKey = GlobalKey();
  ({double ratio, Offset from, Offset to})? _pendingZoom;
  int? _zoomFrame;
  late final _fling = AnimationController.unbounded(vsync: this)
    ..addListener(_applyFling);
  double? _flingScale;

  Offset? _doubleTapAt;

  void _reconcileViewport() {
    if (!mounted) return;
    final controller = _controller;
    final offset = _clampOffset(controller.offsetX, controller.scale);
    if (offset != controller.offsetX) {
      _fling.stop();
      controller._set(controller.scale, offset);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller._configure(widget.config);
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant HtmlEmailZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.controller ?? _internal;
    if (!identical(old, _controller)) {
      old?.removeListener(_changed);
      _controller.addListener(_changed);
    }
    if (!identical(old, _controller) || oldWidget.config != widget.config) {
      _cancelZoomFrame();
      _fling.stop();
      _controller._configure(widget.config);
    }
  }

  @override
  void dispose() {
    _cancelZoomFrame();
    _fling.dispose();
    _controller.removeListener(_changed);
    _internal?.dispose();
    super.dispose();
  }

  void _changed() {
    _cancelZoomFrame();
    if (_fling.isAnimating &&
        (_controller.scale != _flingScale ||
            _controller.offsetX != _fling.value)) {
      _fling.stop();
    }
    setState(() {});
  }

  void _cancelZoomFrame() {
    final frame = _zoomFrame;
    if (frame != null) WidgetsBinding.instance.cancelFrameCallbackWithId(frame);
    _zoomFrame = null;
    _pendingZoom = null;
  }

  _RenderEmailZoom? get _box =>
      _boxKey.currentContext?.findRenderObject() as _RenderEmailZoom?;

  double _clampOffset(double offsetX, double scale) =>
      offsetX.clamp(0.0, _box?.maxOffsetAtScale(scale) ?? 0.0).toDouble();

  ScrollPosition? get _scroll =>
      Scrollable.maybeOf(context, axis: Axis.vertical)?.position;

  void _scheduleZoom(double ratio, Offset from, Offset to) {
    _fling.stop();
    final pending = _pendingZoom;
    // Compose movement from both fingers before applying the zoom limits.
    // A pair moving in parallel may momentarily change span between events.
    _pendingZoom = pending == null
        ? (ratio: ratio, from: from, to: to)
        : (
            ratio: pending.ratio * ratio,
            from: pending.from,
            to: to + (pending.to - from) * ratio,
          );
    _zoomFrame ??= WidgetsBinding.instance.scheduleFrameCallback((_) {
      _zoomFrame = null;
      final zoom = _pendingZoom!;
      _pendingZoom = null;
      _zoomAround(zoom.ratio, zoom.from, zoom.to);
    });
  }

  /// Moves the content under [previousFocal] to [focal] while scaling.
  void _zoomAround(double requestedRatio, Offset previousFocal, Offset focal) {
    final box = _box;
    if (box == null || !box.hasSize) return;
    final currentScale = _controller.scale;
    final scale = _controller._clampScale(currentScale * requestedRatio);
    final ratio = scale / currentScale;
    final from = box.globalToLocal(previousFocal);
    final to = box.globalToLocal(focal);
    final x = (from.dx + _controller.offsetX) * ratio - to.dx;
    final scroll = _scroll;
    _controller._set(scale, _clampOffset(x, scale));
    if (scroll != null && scroll.hasPixels && scroll.hasContentDimensions) {
      _scrollAround(
        scroll,
        box,
        box.heightAtScale(scale) - box.size.height,
        from.dy * ratio - to.dy,
      );
    }
  }

  void _scrollAround(
    ScrollPosition scroll,
    _RenderEmailZoom box,
    double heightChange,
    double delta,
  ) {
    // A reversed viewport positions the body from its bottom edge.
    final correction = scroll.axisDirection == AxisDirection.up
        ? heightChange - delta
        : delta;
    final min = scroll.minScrollExtent;
    var trailingEdge = scroll.maxScrollExtent;
    if (heightChange != 0 && trailingEdge == min) {
      // A non-scrolling viewport can have unused space. Recover the
      // unclamped trailing edge before adding the new body height.
      final viewport = RenderAbstractViewport.maybeOf(box.parent);
      if (viewport case RenderObjectWithChildMixin<RenderBox>(:final child?)) {
        trailingEdge = viewport!.getOffsetToReveal(child, 1).offset;
      } else if (viewport is RenderViewport &&
          identical(viewport.offset, scroll) &&
          viewport.center == viewport.firstChild &&
          viewport.childCount == 1 &&
          viewport.anchor == 0) {
        final extent = viewport.firstChild?.geometry?.scrollExtent;
        if (extent != null) trailingEdge = extent - scroll.viewportDimension;
      }
    }
    final max = math.max(min, trailingEdge + heightChange);
    final pixels = (scroll.pixels + correction).clamp(min, max).toDouble();
    if (pixels == scroll.pixels) return;
    // Update before layout so the new scale and scroll offset paint together.
    scroll.jumpTo(pixels);
    // A short or lazy viewport can report a different extent after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(scroll, _scroll) || !scroll.outOfRange) return;
      scroll.jumpTo(
        scroll.pixels
            .clamp(scroll.minScrollExtent, scroll.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  void _panBy(double dx) {
    final scale = _controller.scale;
    _controller._set(scale, _clampOffset(_controller.offsetX - dx, scale));
  }

  void _startFling(DragEndDetails details) {
    final box = _box;
    if (box == null || !box.hasSize) return;
    final scale = _controller.scale;
    final maxOffset = box.maxOffsetAtScale(scale);
    if (maxOffset == 0) return;
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: maxOffset,
      pixels: _controller.offsetX,
      viewportDimension: box.size.width,
      axisDirection: AxisDirection.right,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    final simulation = const ClampingScrollPhysics().createBallisticSimulation(
      metrics,
      -details.velocity.pixelsPerSecond.dx,
    );
    if (simulation == null) return;
    _flingScale = scale;
    _fling.animateWith(simulation);
  }

  void _applyFling() {
    final scale = _controller.scale;
    final offset = _clampOffset(_fling.value, scale);
    if (offset != _fling.value) _fling.stop();
    _controller._set(scale, offset);
  }

  void _doubleTap() {
    final at = _doubleTapAt;
    final target = widget.config.doubleTapScale;
    if (at == null || target == null) return;
    final scale = _controller.scale;
    final minimum = widget.config.minScale;
    _scheduleZoom((scale > minimum + 0.01 ? minimum : target) / scale, at, at);
  }

  @override
  Widget build(BuildContext context) {
    final zoomed = _controller.scale > 1.0001;
    final gestures = <Type, GestureRecognizerFactory>{
      _PinchGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<_PinchGestureRecognizer>(
            () => _PinchGestureRecognizer(debugOwner: this),
            (recognizer) => recognizer.onUpdate = _scheduleZoom,
          ),
      if (widget.config.doubleTapScale != null)
        DoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              () => DoubleTapGestureRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onDoubleTapDown = (details) {
                  _doubleTapAt = details.globalPosition;
                }
                ..onDoubleTap = _doubleTap,
            ),
      // Only while zoomed: otherwise horizontal swipes belong to the host
      // (e.g. paging between messages).
      if (zoomed)
        HorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer
            >(() => HorizontalDragGestureRecognizer(debugOwner: this), (
              recognizer,
            ) {
              recognizer.onDown = (_) => _fling.stop();
              recognizer.onUpdate = (details) => _panBy(details.delta.dx);
              recognizer.onEnd = _startFling;
            }),
    };
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: gestures,
      child: _EmailZoomBox(
        key: _boxKey,
        scale: _controller.scale,
        offsetX: _controller.offsetX,
        onViewportChanged: _reconcileViewport,
        child: widget.child,
      ),
    );
  }
}

/// Recognises only two-finger pinches. A single finger never wins, so the
/// host's vertical scroll (and taps) keep the one-finger gestures.
class _PinchGestureRecognizer extends OneSequenceGestureRecognizer {
  _PinchGestureRecognizer({super.debugOwner})
    : super(supportedDevices: const {PointerDeviceKind.touch});

  void Function(double ratio, Offset previousFocal, Offset focal)? onUpdate;

  final _points = <int, Offset>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _points[event.pointer] = event.position;
    // Claim both arenas on the second touch, before either axis drag can win.
    if (_points.length >= 2) resolve(GestureDisposition.accepted);
  }

  @override
  void handleNonAllowedPointer(PointerDownEvent event) {}

  @override
  void handleEvent(PointerEvent event) {
    if (!_points.containsKey(event.pointer)) return;
    if (event is PointerMoveEvent) {
      _move(event);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      _stopPointer(event.pointer);
    }
  }

  void _move(PointerMoveEvent event) {
    final first = _points.entries.first;
    final second = _points.length >= 2 ? _points.entries.elementAt(1) : null;
    _points[event.pointer] = event.position;
    if (second == null ||
        (event.pointer != first.key && event.pointer != second.key)) {
      return;
    }
    final span = (first.value - second.value).distance;
    final a = _points[first.key]!;
    final b = _points[second.key]!;
    // Use consecutive positions of the same pair. A replacement pointer
    // starts from its own position and keeps the scale already on screen.
    if (span > 0) {
      onUpdate?.call(
        (a - b).distance / span,
        (first.value + second.value) / 2,
        (a + b) / 2,
      );
    }
  }

  @override
  void rejectGesture(int pointer) {
    _stopPointer(pointer);
    resolvePointer(pointer, GestureDisposition.rejected);
  }

  void _stopPointer(int pointer) {
    _points.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'pinch';
}

class _EmailZoomBox extends SingleChildRenderObjectWidget {
  const _EmailZoomBox({
    super.key,
    required this.scale,
    required this.offsetX,
    required this.onViewportChanged,
    super.child,
  });

  final double scale;
  final double offsetX;
  final VoidCallback onViewportChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEmailZoom(scale, offsetX, onViewportChanged);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderEmailZoom)
      ..scale = scale
      ..offsetX = offsetX
      ..onViewportChanged = onViewportChanged;
  }
}

/// Lays the body out at the host's width, paints it scaled and panned, and
/// reports the scaled height so the host's scroll view grows with the zoom.
class _RenderEmailZoom extends RenderProxyBox {
  _RenderEmailZoom(this._scale, this._offsetX, this.onViewportChanged);

  VoidCallback onViewportChanged;
  bool _reconcileScheduled = false;

  double _scale;
  set scale(double value) {
    if (value == _scale) return;
    _scale = value;
    markNeedsLayout();
  }

  double _offsetX;
  set offsetX(double value) {
    if (value == _offsetX) return;
    _offsetX = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  double maxOffsetAtScale(double scale) => hasSize
      ? math.max(0.0, (child?.size.width ?? 0) * scale - size.width)
      : 0;

  double heightAtScale(double scale) =>
      constraints.constrainHeight((child?.size.height ?? 0) * scale);

  double get _paintOffset =>
      _offsetX.clamp(0.0, maxOffsetAtScale(_scale)).toDouble();

  bool get _identity => _scale == 1 && _paintOffset == 0;

  Matrix4 get _transform =>
      Matrix4.translationValues(-_paintOffset, 0, 0)
        ..multiply(Matrix4.diagonal3Values(_scale, _scale, 1));

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, child.size.height * _scale),
    );
    if (_offsetX != _paintOffset && !_reconcileScheduled) {
      _reconcileScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _reconcileScheduled = false;
        if (attached) onViewportChanged();
      });
    }
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final childSize = child.getDryLayout(constraints);
    return constraints.constrain(
      Size(childSize.width, childSize.height * _scale),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      super.computeMinIntrinsicHeight(width) * _scale;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      super.computeMaxIntrinsicHeight(width) * _scale;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_identity) {
      context.paintChild(child, offset);
      return;
    }
    // The zoomed body is wider than the screen: show only the panned slice.
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.pushTransform(
        needsCompositing,
        offset,
        _transform,
        (context, offset) => context.paintChild(child, offset),
      ),
      oldLayer: layer is ClipRectLayer ? layer as ClipRectLayer : null,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    if (_identity) return child.hitTest(result, position: position);
    if (!(Offset.zero & size).contains(position)) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (!_identity) transform.multiply(_transform);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _identity ? null : Offset.zero & size;
}
