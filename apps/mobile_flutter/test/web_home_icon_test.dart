import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/verify_web_icons.dart' as web_icons;

Directory _webFixture() {
  final fixture = Directory.systemTemp.createTempSync('tydes-web-icons-');
  addTearDown(() => fixture.deleteSync(recursive: true));
  for (final file in Directory(
    'web',
  ).listSync(recursive: true).whereType<File>()) {
    final relative = file.path.substring('web${Platform.pathSeparator}'.length);
    final target = File('${fixture.path}${Platform.pathSeparator}$relative');
    target.parent.createSync(recursive: true);
    file.copySync(target.path);
  }
  return fixture;
}

void _expectInvalidMainPage(
  String Function(String html) change,
  String diagnostic,
) {
  final fixture = _webFixture();
  final page = File('${fixture.path}/index.html');
  page.writeAsStringSync(change(page.readAsStringSync()));
  expect(
    () => web_icons.verifyWebIcons(fixture),
    throwsA(
      isA<StateError>().having(
        (error) => error.message,
        'diagnostic',
        contains(diagnostic),
      ),
    ),
  );
}

void main() {
  test('Every public page installs the approved opaque blue-wave icon', () {
    web_icons.verifyWebIcons(Directory('web'));
  });

  test('404 page cannot silently lose its Apple home-screen icon', () {
    final fixture = _webFixture();
    final page = File('${fixture.path}/404.html');
    page.writeAsStringSync(
      page.readAsStringSync().replaceAll(
        RegExp(r'<link\b[^>]*rel="apple-touch-icon"[^>]*>'),
        '',
      ),
    );
    expect(
      () => web_icons.verifyWebIcons(fixture),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'diagnostic',
          contains('404.html should declare one unambiguous Apple icon'),
        ),
      ),
    );
  });

  test('new nested HTML pages are included in home-screen metadata checks', () {
    final fixture = _webFixture();
    final page = File('${fixture.path}/nested/help.html');
    page.parent.createSync();
    page.writeAsStringSync(
      '<!doctype html><html><head></head><body>Help</body></html>',
    );
    expect(
      () => web_icons.verifyWebIcons(fixture),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'diagnostic',
          contains('help.html should declare one unambiguous Apple icon'),
        ),
      ),
    );
  });

  test('404 page cannot silently lose its web manifest link', () {
    final fixture = _webFixture();
    final page = File('${fixture.path}/404.html');
    page.writeAsStringSync(
      page.readAsStringSync().replaceAll(
        RegExp(r'<link\b[^>]*rel="manifest"[^>]*>'),
        '',
      ),
    );
    expect(
      () => web_icons.verifyWebIcons(fixture),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'diagnostic',
          contains(
            '404.html must reference the current same-origin web manifest',
          ),
        ),
      ),
    );
  });

  test('the fallback HTML page must remain in release artifacts', () {
    final fixture = _webFixture();
    File('${fixture.path}/404.html').deleteSync();
    expect(
      () => web_icons.verifyWebIcons(fixture),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'diagnostic',
          contains('Missing public home-screen metadata page: 404.html'),
        ),
      ),
    );
  });

  for (final entry in {
    'Apple icon': RegExp(r'<link\b[^>]*rel="apple-touch-icon"[^>]*>'),
    'manifest': RegExp(r'<link\b[^>]*rel="manifest"[^>]*>'),
  }.entries) {
    test(
      '${entry.key} discovery must precede the main Flutter script preload',
      () {
        _expectInvalidMainPage((html) {
          final link = entry.value.firstMatch(html)![0]!;
          return html
              .replaceFirst(link, '')
              .replaceFirst('</head>', '$link\n</head>');
        }, 'index.html install metadata must precede the main Flutter preload');
      },
    );
  }

  test('Apple image preload must use the exact declared icon URL', () {
    _expectInvalidMainPage(
      (html) => html.replaceFirst(
        '<link rel="preload" as="image" type="image/png" href="/icons/tydes-apple-touch-v3.png">',
        '<link rel="preload" as="image" type="image/png" href="/apple-touch-icon.png">',
      ),
      'index.html must preload its exact Apple icon URL as a PNG image',
    );
  });

  test('Apple image preload keeps normal same-origin image request mode', () {
    _expectInvalidMainPage(
      (html) => html.replaceFirst(
        '<link rel="preload" as="image" type="image/png" href="/icons/tydes-apple-touch-v3.png">',
        '<link rel="preload" as="image" type="image/png" href="/icons/tydes-apple-touch-v3.png" crossorigin="anonymous">',
      ),
      'index.html Apple icon preload must not set crossorigin',
    );
  });

  test('main page keeps the approved 192px generic PNG bookmark fallback', () {
    _expectInvalidMainPage(
      (html) => html.replaceFirst(
        RegExp(r'<link\b[^>]*rel="icon"[^>]*sizes="192x192"[^>]*>'),
        '',
      ),
      'index.html must declare the approved 192px generic PNG icon',
    );
  });
}
