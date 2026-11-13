import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../config/html_render_config.dart';

/// Reads and resets the pinch-zoom state of an [HtmlEmailView] that has
/// [HtmlRenderConfig.zoom] set. One controller drives one view.
class HtmlZoomController extends ChangeNotifier {
  double _scale = 1;
  double _offsetX = 0;

  /// The current zoom factor (1 = unzoomed).
  double get scale => _scale;

  /// How far a zoomed message is panned from its left edge, in screen px.
  double get offsetX => _offsetX;

  /// Back to scale 1, e.g. when the host shows another message.
  void reset() => _set(1, 0);

  /// Zooms to [scale] keeping the left edge in place.
  void zoomTo(double scale) => _set(scale, 0);

  void _set(double scale, double offsetX) {
    if (scale == _scale && offsetX == _offsetX) return;
    _scale = scale;
    _offsetX = offsetX;
    notifyListeners();
  }
}

/// Pinch-to-zoom for a message body that lives inside the host's scroll
/// view. The zoomed body reports its scaled height, so the host's vertical
/// scroll keeps working with one finger; two fingers zoom around their focal
/// point, one finger pans horizontally while zoomed, and a double tap toggles
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

class _HtmlEmailZoomState extends State<HtmlEmailZoom> {
  HtmlZoomController? _internal;
  HtmlZoomController get _controller =>
      widget.controller ?? (_internal ??= HtmlZoomController());

  final _boxKey = GlobalKey();

  // Pinch state, captured when the gesture starts.
  double _startScale = 1;
  Offset _startContent = Offset.zero; // content point under the fingers
  double? _startScroll;
  double _startTop = 0; // the body's global top at the start

  Offset? _doubleTapAt;

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _internal?.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  _RenderEmailZoom? get _box =>
      _boxKey.currentContext?.findRenderObject() as _RenderEmailZoom?;

  double _clampScale(double scale) =>
      scale.clamp(widget.config.minScale, widget.config.maxScale).toDouble();

  double _clampOffset(double offsetX, double scale) {
    final box = _box;
    if (box == null || !box.hasSize) return 0;
    final max = math.max(0.0, box.contentWidth * scale - box.size.width);
    return offsetX.clamp(0.0, max).toDouble();
  }

  ScrollPosition? get _scroll {
    final position = Scrollable.maybeOf(context)?.position;
    return position != null && position.axis == Axis.vertical
        ? position
        : null;
  }

  void _begin(Offset globalFocal) {
    final box = _box;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(globalFocal);
    _startScale = _controller.scale;
    _startContent = Offset(
      (local.dx + _controller.offsetX) / _startScale,
      local.dy / _startScale,
    );
    _startScroll = _scroll?.pixels;
    _startTop = box.localToGlobal(Offset.zero).dy;
  }

  /// Zooms to [scale] keeping the content point captured by [_begin] under
  /// [globalFocal]: horizontally by panning, vertically by scrolling the host.
  void _zoomAround(double scale, Offset globalFocal) {
    final box = _box;
    if (box == null || !box.hasSize) return;
    scale = _clampScale(scale);
    final focalX = globalFocal.dx - box.localToGlobal(Offset.zero).dx;
    _controller._set(
      scale,
      _clampOffset(_startContent.dx * scale - focalX, scale),
    );
    final scroll = _scroll;
    final startScroll = _startScroll;
    if (scroll == null || startScroll == null) return;
    // The content point should end at the focal point: move the body's top
    // to focal.y - content.y * scale.
    final target =
        startScroll + _startTop - (globalFocal.dy - _startContent.dy * scale);
    // After the next layout the scroll extent reflects the new height.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasContentDimensions) return;
      scroll.jumpTo(
        target.clamp(scroll.minScrollExtent, scroll.maxScrollExtent).toDouble(),
      );
    });
  }

  void _panBy(double dx) {
    final scale = _controller.scale;
    _controller._set(scale, _clampOffset(_controller.offsetX - dx, scale));
  }

  void _doubleTap() {
    final at = _doubleTapAt;
    final target = widget.config.doubleTapScale;
    if (at == null || target == null) return;
    _begin(at);
    final zoomed = _controller.scale > widget.config.minScale + 0.01;
    _zoomAround(zoomed ? widget.config.minScale : target, at);
  }

  @override
  Widget build(BuildContext context) {
    final zoomed = _controller.scale > 1.0001;
    final gestures = <Type, GestureRecognizerFactory>{
      _PinchGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<_PinchGestureRecognizer>(
            () => _PinchGestureRecognizer(debugOwner: this),
            (recognizer) => recognizer
              ..onStart = _begin
              ..onUpdate = (scale, focal) =>
                  _zoomAround(_startScale * scale, focal),
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
            >(
              () => HorizontalDragGestureRecognizer(debugOwner: this),
              (recognizer) =>
                  recognizer.onUpdate = (details) => _panBy(details.delta.dx),
            ),
    };
    return RawGestureDetector(
      gestures: gestures,
      child: _EmailZoomBox(
        key: _boxKey,
        scale: _controller.scale,
        offsetX: _controller.offsetX,
        child: widget.child,
      ),
    );
  }
}

/// Recognises only two-finger pinches. A single finger never wins, so the
/// host's vertical scroll (and taps) keep the one-finger gestures.
class _PinchGestureRecognizer extends OneSequenceGestureRecognizer {
  _PinchGestureRecognizer({super.debugOwner});

  void Function(Offset focal)? onStart;
  void Function(double scale, Offset focal)? onUpdate;

  final _points = <int, Offset>{};
  double? _initialSpan;
  bool _accepted = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _points[event.pointer] = event.position;
    if (_points.length == 2) _initialSpan = _span;
  }

  double get _span {
    final values = _points.values.take(2).toList();
    return (values[0] - values[1]).distance;
  }

  Offset get _focal {
    final values = _points.values.take(2).toList();
    return (values[0] + values[1]) / 2;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _points[event.pointer] = event.position;
      final initial = _initialSpan;
      if (_points.length < 2 || initial == null || initial <= 0) return;
      if (!_accepted) {
        if ((_span - initial).abs() < kScaleSlop) return;
        _accepted = true;
        resolve(GestureDisposition.accepted);
        onStart?.call(_focal);
        _initialSpan = _span;
        return;
      }
      onUpdate?.call(_span / _initialSpan!, _focal);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _points.remove(event.pointer);
      stopTrackingPointer(event.pointer);
      if (_points.length < 2) _initialSpan = null;
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _points.clear();
    _initialSpan = null;
    _accepted = false;
  }

  @override
  void rejectGesture(int pointer) {
    _points.remove(pointer);
    if (_points.length < 2) _initialSpan = null;
    super.rejectGesture(pointer);
  }

  @override
  String get debugDescription => 'pinch';
}

class _EmailZoomBox extends SingleChildRenderObjectWidget {
  const _EmailZoomBox({
    super.key,
    required this.scale,
    required this.offsetX,
    super.child,
  });

  final double scale;
  final double offsetX;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEmailZoom(scale, offsetX);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderEmailZoom)
      ..scale = scale
      ..offsetX = offsetX;
  }
}

/// Lays the body out at the host's width, paints it scaled and panned, and
/// reports the scaled height so the host's scroll view grows with the zoom.
class _RenderEmailZoom extends RenderProxyBox {
  _RenderEmailZoom(this._scale, this._offsetX);

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
  }

  double get contentWidth => child?.size.width ?? 0;

  bool get _identity => _scale == 1 && _offsetX == 0;

  Matrix4 get _transform => Matrix4.translationValues(-_offsetX, 0, 0)
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
}
