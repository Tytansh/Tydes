import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/startup/app_startup.dart';

void main() {
  test(
    'web starts theme and logo together and still waits for the logo',
    () async {
      final theme = Completer<ThemeMode>();
      final logo = Completer<void>();
      final started = <String>[];
      var finished = false;

      final startup =
          prepareAppStartup(
            isWeb: true,
            loadTheme: () {
              started.add('theme');
              return theme.future;
            },
            loadFavoriteSpotIds: () =>
                throw StateError('Web must not use file IO'),
            warmBrandLogo: () {
              started.add('logo');
              return logo.future;
            },
          ).then((value) {
            finished = true;
            return value;
          });

      expect(started, ['theme', 'logo']);
      theme.complete(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);

      logo.complete();
      final result = await startup;
      expect(result.themeMode, ThemeMode.dark);
      expect(result.favoriteSpotIds, isEmpty);
    },
  );

  test('a ready web logo cannot bypass the saved theme read', () async {
    final theme = Completer<ThemeMode>();
    var finished = false;
    final startup =
        prepareAppStartup(
          isWeb: true,
          loadTheme: () => theme.future,
          loadFavoriteSpotIds: () =>
              throw StateError('Web must not use file IO'),
          warmBrandLogo: () async {},
        ).then((value) {
          finished = true;
          return value;
        });

    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    theme.complete(ThemeMode.light);
    expect((await startup).themeMode, ThemeMode.light);
  });

  test(
    'native starts theme and favorites together and restores favorites',
    () async {
      final theme = Completer<ThemeMode>();
      final favorites = Completer<List<String>>();
      final started = <String>[];
      var finished = false;

      final startup =
          prepareAppStartup(
            isWeb: false,
            loadTheme: () {
              started.add('theme');
              return theme.future;
            },
            loadFavoriteSpotIds: () {
              started.add('favorites');
              return favorites.future;
            },
            warmBrandLogo: () =>
                throw StateError('Native did not warm this image'),
          ).then((value) {
            finished = true;
            return value;
          });

      expect(started, ['theme', 'favorites']);
      theme.complete(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);

      favorites.complete(['uluwatu', 'bingin']);
      final result = await startup;
      expect(result.themeMode, ThemeMode.dark);
      expect(result.favoriteSpotIds, ['uluwatu', 'bingin']);
    },
  );

  test(
    'restored native favorites cannot bypass the saved theme read',
    () async {
      final theme = Completer<ThemeMode>();
      var finished = false;
      final startup =
          prepareAppStartup(
            isWeb: false,
            loadTheme: () => theme.future,
            loadFavoriteSpotIds: () async => ['uluwatu'],
            warmBrandLogo: () =>
                throw StateError('Native did not warm this image'),
          ).then((value) {
            finished = true;
            return value;
          });

      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      theme.complete(ThemeMode.system);
      final result = await startup;
      expect(result.themeMode, ThemeMode.system);
      expect(result.favoriteSpotIds, ['uluwatu']);
    },
  );
}
