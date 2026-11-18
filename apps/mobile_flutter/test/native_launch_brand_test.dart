import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../tool/generate_brand_assets.dart' as generator;

const _launchDirectory = 'ios/Runner/Assets.xcassets/LaunchImage.imageset';
const _launchFiles = {
  'LaunchImage.png': (168, 185),
  'LaunchImage@2x.png': (336, 370),
  'LaunchImage@3x.png': (504, 555),
};

img.Image _decode(File file) {
  final image = img.decodePng(file.readAsBytesSync());
  expect(image, isNotNull, reason: '${file.path} must be a PNG');
  return image!;
}

String _pixels(img.Image image) =>
    sha256.convert(image.getBytes(order: img.ChannelOrder.rgb)).toString();

void main() {
  final project = Directory.current.absolute;
  late Directory fixture;
  late img.Image artwork;
  final sentinels = <String, List<int>>{};

  setUpAll(() {
    fixture = Directory.systemTemp.createTempSync('tydes-native-launch-brand-');
    final source = File('${project.path}/assets/branding/tydes-wave-blue.png');
    artwork = _decode(source);
    expect((artwork.width, artwork.height), (1024, 1024));
    final copy = File('${fixture.path}/assets/branding/tydes-wave-blue.png');
    copy.parent.createSync(recursive: true);
    source.copySync(copy.path);
    Directory('${fixture.path}/$_launchDirectory').createSync(recursive: true);
    for (final path in [
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
      'android/app/src/main/res/mipmap-mdpi/ic_launcher.png',
      'web/favicon.png',
      'web/icons/tydes-app-192.png',
      '$_launchDirectory/Contents.json',
    ]) {
      final bytes = 'KEEP THIS FILE UNCHANGED: $path'.codeUnits;
      final file = File('${fixture.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      sentinels[path] = bytes;
    }

    // Invoke the real generator only inside the isolated temporary project.
    // No checked-in icon, web clip, or launch asset is written by this test.
    final previous = Directory.current;
    try {
      Directory.current = fixture;
      generator.main(['--launch-only']);
    } finally {
      Directory.current = previous;
    }
  });

  tearDownAll(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  test('--launch-only preserves native app icons, web assets and metadata', () {
    expect(Directory.current.absolute.path, project.path);
    for (final entry in sentinels.entries) {
      expect(
        File('${fixture.path}/${entry.key}').readAsBytesSync(),
        orderedEquals(entry.value),
        reason: '--launch-only must not modify ${entry.key}',
      );
    }
  });

  test(
    'all native scale variants keep their dimensions and match one master',
    () {
      final master = _decode(
        File('${fixture.path}/$_launchDirectory/LaunchImage@3x.png'),
      );
      for (final entry in _launchFiles.entries) {
        final (width, height) = entry.value;
        final actual = _decode(
          File('${fixture.path}/$_launchDirectory/${entry.key}'),
        );
        expect((actual.width, actual.height), (width, height));
        final expected = img.copyResize(
          master,
          width: width,
          height: height,
          interpolation: img.Interpolation.cubic,
        );
        expect(_pixels(actual), _pixels(expected), reason: entry.key);
      }
    },
  );

  test(
    'launch master contains the approved white curl and blue/aqua artwork without stretching',
    () {
      final master = _decode(
        File('${fixture.path}/$_launchDirectory/LaunchImage@3x.png'),
      );
      final expectedArt = img.copyResize(
        artwork.convert(numChannels: 3),
        width: 384,
        height: 384,
        interpolation: img.Interpolation.cubic,
      );
      var whiteCurlSamples = 0;
      var blueAquaSamples = 0;
      // Stay inside the rounded corners; compare a two-dimensional grid so an
      // incorrect crop, stretched wave, or separately redrawn mark cannot pass.
      for (var y = 40; y < 344; y += 7) {
        for (var x = 40; x < 344; x += 7) {
          final expected = expectedArt.getPixel(x, y);
          final actual = master.getPixel(60 + x, 32 + y);
          for (var channel = 0; channel < 3; channel++) {
            expect(
              (actual[channel] - expected[channel]).abs(),
              lessThanOrEqualTo(2),
              reason:
                  'Approved artwork at local pixel ($x, $y), channel $channel',
            );
          }
          if (expected.r > 245 && expected.g > 245 && expected.b > 245) {
            whiteCurlSamples++;
          }
          if (expected.r < 120 && expected.g > 100 && expected.b > 120) {
            blueAquaSamples++;
          }
        }
      }
      expect(whiteCurlSamples, greaterThan(10));
      expect(blueAquaSamples, greaterThan(100));
      // Bound the artwork only, excluding the wordmark below it. Its physical
      // dimensions must remain square and centered on the launch canvas.
      var left = master.width, top = master.height, right = -1, bottom = -1;
      for (var y = 0; y < 430; y++) {
        for (var x = 0; x < master.width; x++) {
          final p = master.getPixel(x, y);
          if (p.r == 250 && p.g == 248 && p.b == 242) continue;
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
      expect((left, top, right, bottom), (60, 32, 443, 415));
      expect(right - left + 1, bottom - top + 1);
      expect((left + right + 1) / 2, master.width / 2);
    },
  );

  test('checked-in native launch files contain the generated blue brand', () {
    for (final name in _launchFiles.keys) {
      final bundled = _decode(File('${project.path}/$_launchDirectory/$name'));
      final expected = _decode(File('${fixture.path}/$_launchDirectory/$name'));
      expect(
        (bundled.width, bundled.height),
        (expected.width, expected.height),
      );
      expect(
        _pixels(bundled),
        _pixels(expected),
        reason: '$name must be regenerated from the approved blue-wave artwork',
      );
    }
  });

  test('iOS launch storyboard centers LaunchImage on both axes', () {
    final storyboard = File(
      '${project.path}/ios/Runner/Base.lproj/LaunchScreen.storyboard',
    ).readAsStringSync();
    final imageView = RegExp(
      r'<imageView\b[^>]*\bimage="LaunchImage"[^>]*>',
    ).firstMatch(storyboard);
    expect(imageView, isNotNull);
    final id = RegExp(
      r'\bid="([^"]+)"',
    ).firstMatch(imageView!.group(0)!)!.group(1)!;
    for (final axis in ['centerX', 'centerY']) {
      expect(
        RegExp(
          '<constraint[^>]*firstItem="$id"[^>]*firstAttribute="$axis"[^>]*secondAttribute="$axis"',
        ).hasMatch(storyboard),
        isTrue,
        reason: 'LaunchImage must be centered on $axis',
      );
    }
    expect(
      storyboard,
      contains('<image name="LaunchImage" width="168" height="185"'),
    );
    final plist = File(
      '${project.path}/ios/Runner/Info.plist',
    ).readAsStringSync();
    expect(
      RegExp(
        r'<key>UILaunchStoryboardName</key>\s*<string>LaunchScreen</string>',
      ).hasMatch(plist),
      isTrue,
    );
  });
}
