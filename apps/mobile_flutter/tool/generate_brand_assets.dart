import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

final _offWhite = img.ColorRgb8(250, 248, 242);
final _ink = img.ColorRgb8(10, 18, 18);
final _teal = img.ColorRgb8(42, 167, 161);

void main() {
  final root = Directory.current;
  final icon = _buildIconMaster();
  final launch = _buildLaunchMaster();

  _writeIosIcons(root, icon);
  _writeAndroidIcons(root, icon);
  _writeWebIcons(root, icon);
  _writeLaunchImages(root, launch);
}

img.Image _buildIconMaster() {
  const size = 4096;
  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: _offWhite);

  _drawTydesMark(
    canvas,
    offsetX: 260,
    offsetY: 730,
    width: 3000,
    height: 2100,
    strokeWidth: 148,
    dotRadius: 104,
    color: _ink,
  );

  return canvas;
}

img.Image _buildLaunchMaster() {
  const scale = 4;
  final markCanvas = img.Image(width: 504 * scale, height: 555 * scale);
  img.fill(markCanvas, color: _offWhite);

  _drawTydesMark(
    markCanvas,
    offsetX: 34 * scale,
    offsetY: 78 * scale,
    width: 436 * scale,
    height: 252 * scale,
    strokeWidth: 16 * scale,
    dotRadius: 11 * scale,
    color: _ink,
  );

  final canvas = _resizeExact(markCanvas, 504, 555);
  _drawWordmark(canvas, 'Tydes', centerX: 252, baselineY: 414);
  return canvas;
}

void _drawTydesMark(
  img.Image canvas, {
  required int offsetX,
  required int offsetY,
  required int width,
  required int height,
  required num strokeWidth,
  required int dotRadius,
  required img.Color color,
}) {
  int x(num value) => (offsetX + value * width).round();
  int y(num value) => (offsetY + value * height).round();

  img.fillCircle(
    canvas,
    x: x(0.12),
    y: y(0.48),
    radius: dotRadius,
    color: color,
    antialias: true,
  );

  final crestPoints = <_Point>[
    ..._cubic(
      _Point(x(0.23), y(0.54)),
      _Point(x(0.36), y(0.51)),
      _Point(x(0.43), y(0.38)),
      _Point(x(0.56), y(0.31)),
    ),
    ..._cubic(
      _Point(x(0.56), y(0.31)),
      _Point(x(0.68), y(0.24)),
      _Point(x(0.86), y(0.28)),
      _Point(x(0.91), y(0.45)),
    ).skip(1),
  ];
  final swellPoints = _cubic(
    _Point(x(0.63), y(0.60)),
    _Point(x(0.74), y(0.54)),
    _Point(x(0.90), y(0.52)),
    _Point(x(1.04), y(0.61)),
  );

  _drawStrokePath(canvas, crestPoints, strokeWidth: strokeWidth, color: color);
  _drawStrokePath(
    canvas,
    swellPoints,
    strokeWidth: strokeWidth * 0.82,
    color: color,
  );
}

void _drawStrokePath(
  img.Image canvas,
  List<_Point> points, {
  required num strokeWidth,
  required img.Color color,
}) {
  final capRadius = (strokeWidth / 2).round();
  for (final point in points) {
    img.fillCircle(
      canvas,
      x: point.x,
      y: point.y,
      radius: capRadius,
      color: color,
      antialias: true,
    );
  }
}

void _drawWordmark(
  img.Image canvas,
  String text, {
  required int centerX,
  required int baselineY,
}) {
  img.drawString(
    canvas,
    text,
    font: img.arial48,
    x: centerX - 64,
    y: baselineY - 42,
    color: _ink,
  );
  img.fillRect(
    canvas,
    x1: centerX - 44,
    y1: baselineY + 20,
    x2: centerX + 44,
    y2: baselineY + 26,
    radius: 4,
    color: _teal,
  );
}

List<_Point> _cubic(
  _Point p0,
  _Point p1,
  _Point p2,
  _Point p3, {
  int steps = 96,
}) {
  final points = <_Point>[];
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    final u = 1 - t;
    final x =
        u * u * u * p0.x +
        3 * u * u * t * p1.x +
        3 * u * t * t * p2.x +
        t * t * t * p3.x;
    final y =
        u * u * u * p0.y +
        3 * u * u * t * p1.y +
        3 * u * t * t * p2.y +
        t * t * t * p3.y;
    points.add(_Point(x.round(), y.round()));
  }
  return points;
}

void _writeIosIcons(Directory root, img.Image master) {
  final dir = Directory(
    '${root.path}/ios/Runner/Assets.xcassets/AppIcon.appiconset',
  );
  final icons = {
    'Icon-App-20x20@1x.png': 20,
    'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58,
    'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40,
    'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
  };
  for (final entry in icons.entries) {
    _writePng('${dir.path}/${entry.key}', _resize(master, entry.value));
  }
}

void _writeAndroidIcons(Directory root, img.Image master) {
  final base = '${root.path}/android/app/src/main/res';
  final icons = {
    'mipmap-mdpi/ic_launcher.png': 48,
    'mipmap-hdpi/ic_launcher.png': 72,
    'mipmap-xhdpi/ic_launcher.png': 96,
    'mipmap-xxhdpi/ic_launcher.png': 144,
    'mipmap-xxxhdpi/ic_launcher.png': 192,
  };
  for (final entry in icons.entries) {
    _writePng('$base/${entry.key}', _resize(master, entry.value));
  }
}

void _writeWebIcons(Directory root, img.Image master) {
  final dir = '${root.path}/web';
  _writePng('$dir/favicon.png', _resize(master, 32));
  _writePng('$dir/icons/Icon-192.png', _resize(master, 192));
  _writePng('$dir/icons/Icon-512.png', _resize(master, 512));
  _writePng('$dir/icons/Icon-maskable-192.png', _resize(master, 192));
  _writePng('$dir/icons/Icon-maskable-512.png', _resize(master, 512));
}

void _writeLaunchImages(Directory root, img.Image master) {
  final dir = '${root.path}/ios/Runner/Assets.xcassets/LaunchImage.imageset';
  _writePng('$dir/LaunchImage.png', _resizeExact(master, 168, 185));
  _writePng('$dir/LaunchImage@2x.png', _resizeExact(master, 336, 370));
  _writePng('$dir/LaunchImage@3x.png', _resizeExact(master, 504, 555));
}

img.Image _resize(img.Image image, int size) {
  return img.copyResize(
    image,
    width: size,
    height: size,
    interpolation: img.Interpolation.cubic,
  );
}

img.Image _resizeExact(img.Image image, int width, int height) {
  return img.copyResize(
    image,
    width: width,
    height: height,
    interpolation: img.Interpolation.cubic,
  );
}

void _writePng(String path, img.Image image) {
  File(path).writeAsBytesSync(img.encodePng(image));
}

class _Point {
  const _Point(this.x, this.y);

  final int x;
  final int y;

  double distanceTo(_Point other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
