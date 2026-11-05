import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Leaves one-finger scrolling and carousel swipes to the parent until a
/// two-finger pinch starts. Desktop users can also hold a zoom with the button.
class PostMediaZoom extends StatefulWidget {
  const PostMediaZoom({
    super.key,
    required this.child,
    this.onZoomChanged,
    this.showControls = kIsWeb,
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
  Offset _anchor = Offset.zero;
  Offset _doubleTapPosition = Offset.zero;
  double _startScale = 1;
  bool _pinned = false;
  bool _zooming = false;

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
    _reset.stop();
    _startScale = _matrix.getMaxScaleOnAxis();
    _anchor = Offset(
      (details.localFocalPoint.dx - _matrix.storage[12]) / _startScale,
      (details.localFocalPoint.dy - _matrix.storage[13]) / _startScale,
    );
    if (details.pointerCount >= 2) _pinned = false;
    _setZooming(true);
  }

  void _update(ScaleUpdateDetails details) {
    final scale = (_startScale * details.scale).clamp(1.0, 4.0);
    final offset = details.localFocalPoint - _anchor * scale;
    setState(() {
      _matrix = _transform(scale, offset);
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
    if (_matrix.getMaxScaleOnAxis() > 1.01) {
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
      return ClipRect(
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
                        ..onStart = _start
                        ..onUpdate = _update
                        ..onEnd = (_) {
                          if (!_pinned) _resetZoom();
                        };
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
            if (widget.showControls || _pinned)
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
                    onPressed: () =>
                        _toggleZoom(Offset(_size.width / 2, _size.height / 2)),
                    icon: Icon(_pinned ? Icons.zoom_out : Icons.zoom_in),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _PinchGestureRecognizer extends ScaleGestureRecognizer {
  bool allowSinglePointerPan = false;

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted &&
        pointerCount < 2 &&
        !allowSinglePointerPan) {
      return;
    }
    super.resolve(disposition);
  }
}
