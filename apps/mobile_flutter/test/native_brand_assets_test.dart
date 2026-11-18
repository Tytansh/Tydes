import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../tool/generate_brand_assets.dart' as generator;

const _iosDirectory = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
const _launchDirectory =
    'ios/Runner/Assets.xcassets/TydesLaunchBlueV2.imageset';
const _androidIcons = {
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

img.Image _decode(File file) {
  expect(file.existsSync(), isTrue, reason: 'Missing native icon ${file.path}');
  final image = img.decodePng(file.readAsBytesSync());
  expect(image, isNotNull, reason: '${file.path} must be a PNG');
  return image!;
}

String _pixels(img.Image image) =>
    sha256.convert(image.getBytes(order: img.ChannelOrder.rgb)).toString();

Map<String, int> _iosSpecifications(File contents) {
  final json = jsonDecode(contents.readAsStringSync()) as Map<String, dynamic>;
  final specs = <String, int>{};
  for (final image in (json['images'] as List).cast<Map<String, dynamic>>()) {
    final file = image['filename'] as String?;
    expect(file, isNotNull, reason: 'Every declared iOS icon needs an image');
    final dimensions = (image['size'] as String)
        .split('x')
        .map(double.parse)
        .toList();
    expect(dimensions.first, dimensions.last);
    final scale = double.parse(
      (image['scale'] as String).replaceFirst('x', ''),
    );
    final pixels = (dimensions.first * scale).round();
    if (specs.containsKey(file)) expect(specs[file], pixels);
    specs[file!] = pixels;
  }
  return specs;
}

void _expectApprovedIcon(File file, int size, img.Image master) {
  final actual = _decode(file);
  expect((actual.width, actual.height), (size, size), reason: file.path);
  expect(actual.hasAlpha, isFalse, reason: '${file.path} must be opaque RGB');
  final expected = img.copyResize(
    master,
    width: size,
    height: size,
    interpolation: img.Interpolation.cubic,
  );
  expect(
    _pixels(actual),
    _pixels(expected),
    reason: '${file.path} must be the approved full-bleed blue-wave artwork',
  );
}

void main() {
  final project = Directory.current.absolute;
  late Directory fixture;
  late img.Image master;
  late Map<String, int> ios;
  late List<int> contentsBytes;

  setUpAll(() {
    fixture = Directory.systemTemp.createTempSync('tydes-all-native-brand-');
    master = _decode(
      File('${project.path}/assets/branding/tydes-wave-blue.png'),
    ).convert(numChannels: 3);
    expect((master.width, master.height), (1024, 1024));
    final contents = File('${project.path}/$_iosDirectory/Contents.json');
    ios = _iosSpecifications(contents);
    expect(ios.length, greaterThan(10));
    contentsBytes = contents.readAsBytesSync();
    for (final directory in [
      'assets/branding',
      _iosDirectory,
      _launchDirectory,
      'web/icons',
      for (final density in _androidIcons.keys)
        'android/app/src/main/res/$density',
    ]) {
      Directory('${fixture.path}/$directory').createSync(recursive: true);
    }
    File(
      '${project.path}/assets/branding/tydes-wave-blue.png',
    ).copySync('${fixture.path}/assets/branding/tydes-wave-blue.png');
    contents.copySync('${fixture.path}/$_iosDirectory/Contents.json');
    final previous = Directory.current;
    try {
      Directory.current = fixture;
      generator.main([]);
    } finally {
      Directory.current = previous;
    }
  });

  tearDownAll(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  test(
    'approved source contains blue/aqua and sand, never a blank or black icon',
    () {
      final ocean = master.getPixel(256, 256);
      expect(ocean.g, greaterThan(ocean.r + 20));
      expect(ocean.b, greaterThan(ocean.r + 20));
      final sand = master.getPixel(1023, 1023);
      expect(sand.r, greaterThan(180));
      expect(sand.g, greaterThan(130));
    },
  );

  test(
    'every iOS AppIcon Contents image exists and matches approved opaque artwork',
    () {
      for (final entry in ios.entries) {
        _expectApprovedIcon(
          File('${project.path}/$_iosDirectory/${entry.key}'),
          entry.value,
          master,
        );
      }
    },
  );

  test('all five Android launcher densities match approved opaque artwork', () {
    for (final entry in _androidIcons.entries) {
      _expectApprovedIcon(
        File(
          '${project.path}/android/app/src/main/res/${entry.key}/ic_launcher.png',
        ),
        entry.value,
        master,
      );
    }
  });

  test(
    'full isolated generator cannot restore historical black native icons',
    () {
      expect(Directory.current.absolute.path, project.path);
      for (final entry in ios.entries) {
        _expectApprovedIcon(
          File('${fixture.path}/$_iosDirectory/${entry.key}'),
          entry.value,
          master,
        );
      }
      for (final entry in _androidIcons.entries) {
        _expectApprovedIcon(
          File(
            '${fixture.path}/android/app/src/main/res/${entry.key}/ic_launcher.png',
          ),
          entry.value,
          master,
        );
      }
      _expectApprovedIcon(File('${fixture.path}/web/favicon.png'), 32, master);
      _expectApprovedIcon(
        File('${fixture.path}/web/icons/tydes-app-192.png'),
        192,
        master,
      );
      expect(
        File('${fixture.path}/$_iosDirectory/Contents.json').readAsBytesSync(),
        orderedEquals(contentsBytes),
        reason: 'Artwork regeneration must preserve the declared icon slots',
      );
      for (final file in [
        'TydesLaunchBlueV2.png',
        'TydesLaunchBlueV2@2x.png',
        'TydesLaunchBlueV2@3x.png',
      ]) {
        expect(
          File('${fixture.path}/$_launchDirectory/$file').existsSync(),
          isTrue,
        );
      }
      expect(
        Directory(
          '${fixture.path}/ios/Runner/Assets.xcassets/LaunchImage.imageset',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('legacy black-wave drawing code is removed, not left as a fallback', () {
    final source = File(
      '${project.path}/tool/generate_brand_assets.dart',
    ).readAsStringSync();
    for (final obsolete in [
      '_drawTydesMark',
      '_Point',
      '_cubic',
      '_drawStrokePath',
      'dart:math',
    ]) {
      expect(
        source,
        isNot(contains(obsolete)),
        reason: '$obsolete must not regenerate an old wave',
      );
    }
  });

  test(
    'versioned storyboard, image set and Xcode references cannot select the old launch identity',
    () {
      final storyboard = File(
        '${project.path}/ios/Runner/Base.lproj/TydesLaunchScreenV2.storyboard',
      );
      expect(storyboard.existsSync(), isTrue);
      final xml = storyboard.readAsStringSync();
      expect(xml, contains('image="TydesLaunchBlueV2"'));
      expect(xml, isNot(contains('image="LaunchImage"')));
      final contents =
          jsonDecode(
                File(
                  '${project.path}/$_launchDirectory/Contents.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final images = (contents['images'] as List).cast<Map<String, dynamic>>();
      expect(images.map((image) => image['filename']).toSet(), {
        'TydesLaunchBlueV2.png',
        'TydesLaunchBlueV2@2x.png',
        'TydesLaunchBlueV2@3x.png',
      });
      for (final image in images) {
        expect(
          File(
            '${project.path}/$_launchDirectory/${image['filename']}',
          ).existsSync(),
          isTrue,
        );
      }
      final plist = File(
        '${project.path}/ios/Runner/Info.plist',
      ).readAsStringSync();
      expect(
        RegExp(
          r'<key>UILaunchStoryboardName</key>\s*<string>TydesLaunchScreenV2</string>',
        ).hasMatch(plist),
        isTrue,
      );
      expect(plist, isNot(contains('<string>LaunchScreen</string>')));
      final pbx = File(
        '${project.path}/ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      expect(pbx, contains('Base.lproj/TydesLaunchScreenV2.storyboard'));
      expect(pbx, contains('TydesLaunchScreenV2.storyboard in Resources'));
      expect(RegExp(r'\bLaunchScreen\.storyboard\b').hasMatch(pbx), isFalse);
      expect(
        File(
          '${project.path}/ios/Runner/Base.lproj/LaunchScreen.storyboard',
        ).existsSync(),
        isFalse,
      );
      expect(
        Directory(
          '${project.path}/ios/Runner/Assets.xcassets/LaunchImage.imageset',
        ).existsSync(),
        isFalse,
      );
    },
  );
}
