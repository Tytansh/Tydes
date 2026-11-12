// LOCAL UI PREVIEW ONLY — never publish a build using this entrypoint.
// Renders the real central verification gate using an explicitly local sample.
// Networking, credentials, verification, logout, and account changes are blocked.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_flutter/app/app.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/theme_preference.dart';
import 'package:mobile_flutter/core/theme/theme_preference_store.dart';
import 'package:mobile_flutter/features/home/home_page.dart' show meProvider;

final _sample = UserProfile(
  id: 'local-verification-preview',
  email: 'preview@example.invalid',
  displayName: 'Local Preview Surfer',
  handle: 'localpreview',
  bio: '',
  surfSkill: 'intermediate',
  avatarUrl: null,
  homeRegion: '',
  locale: 'en',
  premium: false,
  emailVerified: false,
  freeLiveSpotId: null,
  adsEnabled: true,
  favoriteSpotIds: const [],
);

void main() {
  final api = _blockedApi();
  final persistence = _BlockedPersistence();
  runApp(
    ProviderScope(
      overrides: [
        meProvider.overrideWith((_) async => _sample),
        routerInitialLocationProvider.overrideWithValue('/messages'),
        dioProvider.overrideWithValue(api),
        demoPersistenceProvider.overrideWithValue(persistence),
        surfRepositoryProvider.overrideWithValue(
          _BlockedRepository(api, persistence),
        ),
        initialThemeModeProvider.overrideWithValue(ThemeMode.light),
        themePreferenceStoreProvider.overrideWithValue(_MemoryAppearance()),
      ],
      child: const _LocalPreview(),
    ),
  );
}

class _LocalPreview extends ConsumerWidget {
  const _LocalPreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = ref.watch(themeModeProvider) == ThemeMode.dark;
    return MediaQuery.fromView(
      view: View.of(context),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 12, color: Colors.white),
          child: Column(
            children: [
              ColoredBox(
                color: const Color(0xFF193D48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'LOCAL UI PREVIEW · no emails/account changes',
                          style: TextStyle(fontSize: 11, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Semantics(
                        button: true,
                        label: 'Toggle local preview theme',
                        child: GestureDetector(
                          onTap: () => ref
                              .read(themeModeProvider.notifier)
                              .setMode(dark ? ThemeMode.light : ThemeMode.dark),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              dark ? 'Light theme' : 'Dark theme',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Expanded(
                child: SurfTravelApp(
                  enableAlertMonitor: false,
                  enableInboxPolling: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

StateError _blocked() => StateError(
  'Local UI preview only. No emails or account changes are allowed.',
);

class _BlockedPersistence extends DemoPersistence {
  @override
  Future<String?> loadAccessToken() async => null;
  @override
  Future<void> saveAccessToken(String token) async => throw _blocked();
  @override
  Future<void> clearAccessToken() async => throw _blocked();
  @override
  Future<bool> clearAccessTokenIfMatches(String expectedToken) async =>
      throw _blocked();
  @override
  Future<List<String>> loadFavoriteSpotIds() async => const [];
  @override
  Future<void> saveFavoriteSpotIds(List<String> spotIds) async =>
      throw _blocked();
}

class _BlockedRepository extends SurfRepository {
  _BlockedRepository(super.dio, super.persistence);
  @override
  Future<UserProfile> fetchMe() async => throw _blocked();
  @override
  Future<UserProfile> logout() async => throw _blocked();
  @override
  Future<UserProfile> deleteAccount() async => throw _blocked();
}

class _MemoryAppearance extends ThemePreferenceStore {
  String? _value;
  @override
  Future<String?> load() async => _value;
  @override
  Future<void> save(String mode) async => _value = mode;
}

Dio _blockedApi() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          message: 'Local UI preview cannot access any backend.',
        ),
      ),
    ),
  );
