import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/widgets/media_image_dimensions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final shape in [
    const Size(80, 45),
    const Size(45, 80),
    const Size(50, 50),
  ]) {
    test(
      'native image metadata preserves $shape and ImageInfo ownership',
      () async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawColor(const ui.Color(0xFF009DA5), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          shape.width.toInt(),
          shape.height.toInt(),
        );
        picture.dispose();
        final info = ImageInfo(image: image, scale: 2);
        try {
          expect(mediaImageDimensions(info), shape);
          // A second metadata read remains valid: the helper must not dispose the
          // listener's ImageInfo. Raw dimensions must not be divided by scale.
          expect(mediaImageDimensions(info), shape);
          expect(image.debugGetOpenHandleStackTraces(), hasLength(1));
        } finally {
          info.dispose();
        }
      },
    );
  }
}
