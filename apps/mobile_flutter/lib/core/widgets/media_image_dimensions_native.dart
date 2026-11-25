import 'dart:ui' show Size;

import 'package:flutter/painting.dart' show ImageInfo;

/// Raw display pixels, without taking ownership of or disposing [info].
Size mediaImageDimensions(ImageInfo info) =>
    Size(info.image.width.toDouble(), info.image.height.toDouble());
