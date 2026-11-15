import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

// A normal mouse wheel belongs to the surrounding page. Touch pinch, native
// trackpad PanZoom, drag, and the existing gestures stay enabled.
const surfMapInteractionOptions = InteractionOptions(
  flags: InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
);

/// Adapts browser trackpad pinch and two-finger pan without wheel-to-zoom.
/// Flutter web emits PointerScaleEvent and trackpad PointerScrollEvent, which
/// flutter_map 8.2 does not handle together. Mouse/unknown scroll stays with the
/// page; native PanZoom and touch already use the map's scale recognizer.
class SurfMapPinchGestures extends StatelessWidget {
  const SurfMapPinchGestures({
    super.key,
    required this.controller,
    required this.child,
  });

  final MapController controller;
  final Widget child;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent &&
        event.kind == PointerDeviceKind.trackpad &&
        event.scrollDelta.dx.isFinite &&
        event.scrollDelta.dy.isFinite &&
        event.scrollDelta != Offset.zero) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        final camera = controller.camera;
        // Scroll deltas are screen-space and opposite the fingers' movement.
        // Camera conversion handles rotation without coupling pan to zoom or
        // guessing a gesture timeout/contact state that browsers do not send.
        final center = camera.screenOffsetToLatLng(
          camera.nonRotatedSize.center(Offset.zero) + event.scrollDelta,
        );
        controller.move(center, camera.zoom);
      });
      return;
    }
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
