import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

/// Checks both source web assets and a release build before publication.
///
/// Run from the Flutter project:
///   dart run tool/verify_web_icons.dart [web-or-release-directory]
void main(List<String> arguments) {
  verifyWebIcons(Directory(arguments.isEmpty ? 'web' : arguments.single));
  stdout.writeln(
    'Home-screen icons verified: blue-wave artwork, opaque PNGs, correct '
    'sizes, manifest and public-page metadata.',
  );
}

void verifyWebIcons(Directory webRoot) {
  final masterFile = File('assets/branding/tydes-wave-blue.png');
  final master = img.decodePng(masterFile.readAsBytesSync());
  _check(master != null, 'The approved blue-wave master must be a PNG.');
  final source = master!.convert(numChannels: 3);

  img.Image verifyPng(String relativePath, int size) {
    final file = File('${webRoot.path}/$relativePath');
    _check(file.existsSync(), 'Missing home-screen asset: $relativePath');
    final bytes = file.readAsBytesSync();
    final decoded = img.decodePng(bytes);
    _check(decoded != null, '$relativePath must be a real PNG, not HTML.');
    final icon = decoded!;
    _check(
      icon.width == size && icon.height == size,
      '$relativePath must be ${size}x$size.',
    );
    _check(!icon.hasAlpha, '$relativePath must be opaque RGB artwork.');
    final expected = img.copyResize(
      source,
      width: size,
      height: size,
      interpolation: img.Interpolation.cubic,
    );
    // Sample the full canvas, including the white wave and colored corners.
    // This catches a T monogram, the old white logo, and rounded transparency.
    for (var y = 0; y < size; y += (size / 24).floor().clamp(1, size)) {
      for (var x = 0; x < size; x += (size / 24).floor().clamp(1, size)) {
        final actualPixel = icon.getPixel(x, y);
        final expectedPixel = expected.getPixel(x, y);
        _check(
          (actualPixel.r - expectedPixel.r).abs() <= 1 &&
              (actualPixel.g - expectedPixel.g).abs() <= 1 &&
              (actualPixel.b - expectedPixel.b).abs() <= 1,
          '$relativePath differs from the approved blue-wave artwork.',
        );
      }
    }
    return icon;
  }

  for (final entry in const {
    'favicon.png': 32,
    'apple-touch-icon.png': 180,
    'apple-touch-icon-180x180.png': 180,
    'apple-touch-icon-precomposed.png': 180,
    'icons/tydes-apple-touch-180.png': 180,
    'icons/tydes-apple-touch-v3.png': 180,
    'icons/tydes-app-192.png': 192,
    'icons/tydes-app-512.png': 512,
    'icons/Icon-192.png': 192,
    'icons/Icon-512.png': 512,
    'icons/Icon-maskable-192.png': 192,
    'icons/Icon-maskable-512.png': 512,
  }.entries) {
    verifyPng(entry.key, entry.value);
  }

  final manifest =
      jsonDecode(File('${webRoot.path}/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  _check(manifest['name'] == 'TYDES', 'The installed app must be named TYDES.');
  _check(manifest['short_name'] == 'TYDES', 'Use the TYDES home-screen label.');
  _check(manifest['id'] == '/', 'Keep the existing installed-app identity.');
  _check(
    manifest['scope'] == '/',
    'The installed app must cover TYDES routes.',
  );
  _check(
    manifest['start_url'] == '/',
    'Start installed apps at the main route.',
  );
  _check(
    manifest['display'] == 'standalone',
    'Use an app-like standalone view.',
  );
  final icons = (manifest['icons'] as List).cast<Map<String, dynamic>>();
  _check(icons.length >= 2, 'Publish both 192px and 512px manifest icons.');
  final sizes = <String>{};
  for (final icon in icons) {
    _check(icon['type'] == 'image/png', 'Manifest icons must be PNGs.');
    _check(icon['purpose'] == 'any', 'Use the full-bleed approved artwork.');
    final size = icon['sizes'] as String;
    sizes.add(size);
    final dimension = int.parse(size.split('x').first);
    final uri = Uri.parse(icon['src'] as String);
    _check(!uri.hasScheme && !uri.hasAuthority, 'Use same-origin icon assets.');
    _check(uri.query.isNotEmpty, 'Revision manifest icon URLs after changes.');
    verifyPng(uri.path.replaceFirst(RegExp(r'^/'), ''), dimension);
  }
  _check(
    sizes.containsAll({'192x192', '512x512'}),
    'Both common manifest icon sizes must be declared.',
  );

  for (final name in const [
    'index.html',
    'about/index.html',
    'support/index.html',
    'privacy/index.html',
    'terms/index.html',
  ]) {
    final html = File('${webRoot.path}/$name').readAsStringSync();
    final links = RegExp(r'<link\b[^>]*>').allMatches(html).map((m) => m[0]!);
    final appleLinks = links.where(
      (link) => link.contains('rel="apple-touch-icon"'),
    );
    _check(
      appleLinks.length == 1,
      '$name should declare one unambiguous Apple icon.',
    );
    final apple = appleLinks.single;
    _check(
      apple.contains('sizes="180x180"'),
      '$name must specify the iPhone size.',
    );
    _check(
      apple.contains('href="/icons/tydes-apple-touch-v3.png"'),
      '$name must use the current blue-wave home-screen icon.',
    );
    _check(
      html.contains('name="apple-mobile-web-app-title" content="TYDES"'),
      '$name must set the installed shortcut label.',
    );
    _check(
      links.any(
        (link) =>
            link.contains('rel="manifest"') &&
            link.contains('href="/manifest.json?v=tydes-wave-3"'),
      ),
      '$name must reference the current same-origin web manifest.',
    );
  }
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
