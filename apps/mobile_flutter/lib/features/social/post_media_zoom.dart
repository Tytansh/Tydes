import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Leaves one-finger scrolling and carousel swipes to the parent until a
/// two-finger pinch starts. Desktop users can also hold a zoom with the button.
class PostMediaZoom extends StatefulWidget {
  const PostMediaZoom({
    super.key,
    required this.child,
    this.onZoomChanged,
    this.showControls = false,
  });

  final Widget child;
  final ValueChanged<bool>? onZoomChanged;
  final bool showControls;

  @override
  State<PostMediaZoom> createState() => _PostMediaZoomState();
}

class _PostMediaZoomState extends State<PostMediaZoom>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reset;
  Animation<Matrix4>? _animation;
  Matrix4 _matrix = Matrix4.identity();
  Size _size = Size.zero;
  Offset _lastFocalPoint = Offset.zero;
  Offset _doubleTapPosition = Offset.zero;
  double _startScale = 1;
  bool _pinned = false;
  bool _zooming = false;
  bool _gestureActive = false;
  bool _firstUpdate = false;

  @override
  void initState() {
    super.initState();
    _reset =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 180),
        )..addListener(() {
          setState(() => _matrix = _animation!.value);
        });
  }

  void _setZooming(bool zooming) {
    if (_zooming == zooming) return;
    _zooming = zooming;
    widget.onZoomChanged?.call(zooming);
  }

  void _start(ScaleStartDetails details) {
    _gestureActive = details.pointerCount >= 2 || _pinned;
    if (!_gestureActive) return;
    _reset.stop();
    _startScale = _matrix.getMaxScaleOnAxis();
    _lastFocalPoint = details.localFocalPoint;
    _firstUpdate = true;
    if (details.pointerCount >= 2) _pinned = false;
    _setZooming(true);
  }

  void _update(ScaleUpdateDetails details) {
    if (!_gestureActive ||
        !details.scale.isFinite ||
        details.scale <= 0 ||
        !details.localFocalPoint.isFinite ||
        !details.focalPointDelta.isFinite) {
      return;
    }
    final scale = (_startScale * details.scale).clamp(1.0, 4.0);
    final currentScale = _matrix.getMaxScaleOnAxis();
    // Rebase against the already bounded transform on every update. A fixed
    // initial anchor forces users to undo overscroll before a photo moves back
    // from its edge. The first delta also includes the pan that won the arena.
    final previousFocal = _firstUpdate
        ? details.localFocalPoint - details.focalPointDelta
        : _lastFocalPoint;
    final anchor = Offset(
      (previousFocal.dx - _matrix.storage[12]) / currentScale,
      (previousFocal.dy - _matrix.storage[13]) / currentScale,
    );
    final offset = details.localFocalPoint - anchor * scale;
    _lastFocalPoint = details.localFocalPoint;
    _firstUpdate = false;
    setState(() {
      _matrix = _transform(scale, offset);
    });
  }

  void _end(int pointerCount) {
    _gestureActive = false;
    // Scale recognizers also end on contact reconfiguration. Keep the zoom
    // while at least two fingers remain, and still reset if all fingers lift
    // without any intervening move that would restart the recognizer.
    if (pointerCount < 2 && !_pinned && _zooming && !_reset.isAnimating) {
      _resetZoom();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // At normal size the feed owns every scroll. While zoom is held, an
      // explicitly classified trackpad gesture pans the media. Do not guess
      // from wheel deltas: mouse wheels must still scroll the page.
      if (!_pinned ||
          _matrix.getMaxScaleOnAxis() <= 1 ||
          !event.scrollDelta.isFinite ||
          event.kind != PointerDeviceKind.trackpad) {
        return;
      }
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        _reset.stop();
        setState(() {
          _matrix = _transform(
            _matrix.getMaxScaleOnAxis(),
            Offset(_matrix.storage[12], _matrix.storage[13]) -
                event.scrollDelta,
          );
        });
      });
      return;
    }
    if (event is! PointerScaleEvent ||
        !event.scale.isFinite ||
        event.scale <= 0 ||
        event.scale == 1) {
      return;
    }
    // Browsers report trackpad pinch as a scale signal, not a two-pointer
    // touch gesture. Leave ordinary wheel scrolling to the surrounding feed.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final currentScale = _matrix.getMaxScaleOnAxis();
      final scale = (currentScale * event.scale).clamp(1.0, 4.0);
      if (scale == currentScale && !_reset.isAnimating) return;
      final anchor = Offset(
        (event.localPosition.dx - _matrix.storage[12]) / currentScale,
        (event.localPosition.dy - _matrix.storage[13]) / currentScale,
      );
      _reset.stop();
      setState(() {
        _pinned = scale > 1;
        _matrix = _transform(scale, event.localPosition - anchor * scale);
      });
      _setZooming(_pinned);
    });
  }

  Matrix4 _transform(double scale, Offset offset) => Matrix4.identity()
    ..setEntry(0, 0, scale)
    ..setEntry(1, 1, scale)
    ..setEntry(0, 3, offset.dx.clamp(_size.width * (1 - scale), 0.0))
    ..setEntry(1, 3, offset.dy.clamp(_size.height * (1 - scale), 0.0));

  Future<void> _resetZoom() async {
    _pinned = false;
    _animation = Matrix4Tween(
      begin: _matrix,
      end: Matrix4.identity(),
    ).animate(CurvedAnimation(parent: _reset, curve: Curves.easeOutCubic));
    try {
      await _reset.forward(from: 0).orCancel;
    } catch (_) {
      return;
    }
    if (mounted && !_pinned) _setZooming(false);
  }

  void _toggleZoom(Offset focalPoint) {
    if (_pinned || _matrix.getMaxScaleOnAxis() > 1.01) {
      _resetZoom();
      return;
    }
    _reset.stop();
    _pinned = true;
    _setZooming(true);
    setState(() => _matrix = _transform(2.5, focalPoint * -1.5));
  }

  @override
  void dispose() {
    _reset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      return Listener(
        onPointerSignal: _onPointerSignal,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  _PinchGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _PinchGestureRecognizer
                      >(() => _PinchGestureRecognizer(), (recognizer) {
                        recognizer
                          ..allowSinglePointerPan = _pinned
                          ..allowTrackpadPan = _matrix.getMaxScaleOnAxis() > 1
                          ..onStart = _start
                          ..onUpdate = _update
                          ..onEnd = (details) {
                            _end(details.pointerCount);
                          }
                          ..onContactEnd = _end;
                      }),
                },
                child: GestureDetector(
                  onDoubleTapDown: (details) =>
                      _doubleTapPosition = details.localPosition,
                  onDoubleTap: () => _toggleZoom(_doubleTapPosition),
                  child: Transform(
                    key: const ValueKey('post-media-zoom-transform'),
                    transform: _matrix,
                    child: widget.child,
                  ),
                ),
              ),
              if (widget.showControls)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.4),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: _pinned ? 'Reset zoom' : 'Zoom media',
                      color: Colors.white,
                      iconSize: 20,
                      onPressed: () => _toggleZoom(
                        Offset(_size.width / 2, _size.height / 2),
                      ),
                      icon: Icon(_pinned ? Icons.zoom_out : Icons.zoom_in),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _PinchGestureRecognizer extends ScaleGestureRecognizer {
  bool allowSinglePointerPan = false;
  bool allowTrackpadPan = false;
  ValueChanged<int>? onContactEnd;
  final Set<int> _panZoomPointers = {};
  bool _trackpadScaling = false;

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    if (_panZoomPointers.isEmpty) _trackpadScaling = false;
    _panZoomPointers.add(event.pointer);
    super.addAllowedPointerPanZoom(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerPanZoomUpdateEvent &&
        event.scale.isFinite &&
        (event.scale - 1).abs() > .0001) {
      _trackpadScaling = true;
    }
    super.handleEvent(event);
    if (event is PointerPanZoomEndEvent) _panZoomPointers.remove(event.pointer);
    if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerPanZoomEndEvent) {
      onContactEnd?.call(pointerCount);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _panZoomPointers.clear();
    _trackpadScaling = false;
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted &&
        ((pointerCount < 2 && !allowSinglePointerPan) ||
            (_panZoomPointers.isNotEmpty &&
                !allowTrackpadPan &&
                !_trackpadScaling))) {
      return;
    }
    super.resolve(disposition);
  }
}
