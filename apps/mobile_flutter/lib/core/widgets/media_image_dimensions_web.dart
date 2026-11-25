import 'dart:ui' show Size;

import 'package:flutter/painting.dart' show ImageInfo;

// Flutter has no public dimension accessor for HTML-only ImageInfo. Reading
// ImageInfo.image throws for a CORS fallback, although the <img> is decoded.
// Use Flutter's typed metadata (as RawWebImage does), not another image fetch.
// Keep this dependency isolated and compile/test it with Flutter upgrades.
// ignore: implementation_imports
import 'package:flutter/src/painting/_web_image_info_web.dart'
    show WebImageInfo;

/// Raw display pixels, without taking ownership of or disposing [info].
Size mediaImageDimensions(ImageInfo info) {
  if (info is WebImageInfo) {
    return Size(
      info.htmlImage.naturalWidth.toDouble(),
      info.htmlImage.naturalHeight.toDouble(),
    );
  }
  return Size(info.image.width.toDouble(), info.image.height.toDouble());
}
