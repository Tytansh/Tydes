import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

// A normal wheel/two-finger scroll belongs to the surrounding page. Touch
// pinch, native trackpad PanZoom, drag, and the existing gestures stay enabled.
const surfMapInteractionOptions = InteractionOptions(
  flags: InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
);

/// Adapts browser trackpad pinch without treating ordinary scrolling as zoom.
/// Flutter web emits PointerScaleEvent, which flutter_map 8.2 does not handle;
/// native PanZoom and touchscreen pinch already use its scale recognizer.
class SurfMapPinchGestures extends StatelessWidget {
  const SurfMapPinchGestures({
    super.key,
    required this.controller,
    required this.child,
  });

  final MapController controller;
  final Widget child;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScaleEvent ||
        !event.scale.isFinite ||
        event.scale <= 0 ||
        event.scale == 1) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final camera = controller.camera;
      final zoom = (camera.zoom + math.log(event.scale) / math.ln2)
          .clamp(camera.minZoom ?? 2, camera.maxZoom ?? 14)
          .toDouble();
      if (zoom == camera.zoom) return;
      controller.move(
        camera.focusedZoomCenter(event.localPosition, zoom),
        zoom,
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      Listener(onPointerSignal: _onPointerSignal, child: child);
}
