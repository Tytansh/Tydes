import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/spots/spot_detail_page.dart';

UserProfile _user({
  bool premium = false,
  String? freeSpot,
  DateTime? changed,
}) => UserProfile.fromJson({
  'id': 'test-user',
  'email': 'test@example.com',
  'display_name': 'Surfer',
  'handle': 'surfer',
  'home_region': 'Bali',
  'locale': 'en',
  'premium': premium,
  'free_live_spot_id': freeSpot,
  'free_live_spot_changed_at': changed?.toIso8601String(),
  'favorite_spot_ids': [],
});

class _Repository extends SurfRepository {
  _Repository(this.profile) : super(Dio(), DemoPersistence());
  UserProfile profile;
  bool failDetail = false;
  bool failUnlock = false;
  int detailCalls = 0;
  int tideCalls = 0;
  int dailyCalls = 0;
  int oldWindowCalls = 0;
  int alertCalls = 0;
  List<AlertModel> alerts = [];
  bool failAlerts = false;

  @override
  Future<List<AlertModel>> fetchAlerts() async {
    alertCalls++;
    if (failAlerts) throw StateError('Alert service unavailable.');
    return alerts;
  }

  @override
  Future<SpotModel> fetchSpot(String spotId) async => SpotModel(
    id: spotId,
    name: 'Uluwatu Peak',
    country: 'Indonesia',
    region: 'Bali',
    area: 'Uluwatu',
    latitude: -8.82,
    longitude: 115.08,
    difficulty: 'advanced',
    bestMonths: ['May', 'Jun'],
    waveHeightM: 99.9,
    waterTempC: 88.8,
    imageUrl: '',
    summary: 'Reef break guide, not current conditions.',
  );

  @override
  Future<DetailedForecastModel> fetchDetailedForecast(String spotId) async {
    detailCalls++;
    if (failDetail) throw StateError('Forecast service unavailable.');
    return DetailedForecastModel(
      spotId: spotId,
      available: true,
      source: 'open-meteo',
      timezone: 'Asia/Makassar',
      hours: const [
        HourlyForecastModel(
          time: '2036-01-01T00:00:00Z',
          localDate: '2036-01-01',
          localTime: '08:00',
          waveHeightM: 2.2,
          swellHeightM: 1.9,
          swellPeriodS: 14,
          swellDirectionDeg: 210,
          windKts: 6,
          windGustsKts: 9,
          seaSurfaceTemperatureC: 27,
        ),
        HourlyForecastModel(
          time: '2036-01-01T01:00:00Z',
          localDate: '2036-01-01',
          localTime: '09:00',
          waveHeightM: 2.4,
          swellHeightM: 2.1,
          swellPeriodS: 14,
          swellDirectionDeg: 210,
          windKts: 7,
          windGustsKts: 10,
          seaSurfaceTemperatureC: 27,
        ),
      ],
    );
  }

  @override
  Future<TideForecastModel> fetchTides(String spotId) async {
    tideCalls++;
    return TideForecastModel.unavailable(spotId);
  }

  @override
  Future<List<ForecastModel>> fetchForecasts({
    String? spotId,
    ForecastFreshness freshness = ForecastFreshness.fresh,
  }) async {
    dailyCalls++;
    return [];
  }

  @override
  Future<SurfWindowModel> fetchSurfWindow(String spotId) async {
    oldWindowCalls++;
    throw StateError('Legacy heuristic should not be requested.');
  }

  @override
  Future<UserProfile> setFreeLiveSpot(String spotId) async {
    if (failUnlock) throw StateError('Spot selection rejected.');
    profile = _user(freeSpot: spotId, changed: DateTime.now());
    return profile;
  }
}

Future<ProviderContainer> _show(
  WidgetTester tester,
  _Repository repository, {
  double width = 390,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        surfRepositoryProvider.overrideWithValue(repository),
        meProvider.overrideWith((_) async => repository.profile),
      ],
      child: Builder(
        builder: (context) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
            theme: theme ?? AppTheme.light(),
            home: const SpotDetailPage(spotId: 'uluwatu'),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('spot page shows only this break\'s confirmed alerts', (
    tester,
  ) async {
    final repo = _Repository(_user(premium: true));
    final now = DateTime.now().toUtc();
    AlertModel alert(String id, String spotId) => AlertModel(
      id: id,
      spotId: spotId,
      waveEnabled: true,
      minWaveHeightM: 1.5,
      windEnabled: true,
      maxWindKts: 12,
      tideEnabled: false,
      tideType: null,
      tideOffsetHours: null,
      enabled: true,
      status: 'triggered',
      lastEvaluatedAt: now.toIso8601String(),
      nextCheckAt: now.add(const Duration(hours: 4)).toIso8601String(),
    );
    repo.alerts = [alert('here', 'uluwatu'), alert('elsewhere', 'bondi')];
    await _show(tester, repo);
    await tester.ensureVisible(find.byKey(const ValueKey('spot-alert-panel')));
    expect(find.text('Your surf alert'), findsOneWidget);
    expect(find.text('Surf alert matched'), findsOneWidget);
    expect(find.text('Manage alerts'), findsOneWidget);
    expect(repo.alertCalls, 1);
    expect(repo.detailCalls, 1);
    expect(repo.tideCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed alert status does not hide a working forecast', (
    tester,
  ) async {
    final repo = _Repository(_user(premium: true))..failAlerts = true;
    await _show(tester, repo);
    expect(find.text('Alert status unavailable'), findsOneWidget);
    expect(find.text('FORECAST DESK'), findsOneWidget);
    repo.failAlerts = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Alert status unavailable'), findsNothing);
    expect(repo.alertCalls, 2);
    expect(repo.detailCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark forecast page and locked card use readable dark surfaces', (
    tester,
  ) async {
    final theme = ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF67D8CB),
        brightness: Brightness.dark,
      ),
      cardColor: const Color(0xFF17292D),
      scaffoldBackgroundColor: const Color(0xFF101C20),
    );
    await _show(tester, _Repository(_user()), theme: theme);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      theme.scaffoldBackgroundColor,
    );
    final unlock = tester.widget<Container>(
      find.byKey(const ValueKey('forecast-unlock-card')),
    );
    expect(
      (unlock.decoration! as BoxDecoration).color,
      theme.colorScheme.surfaceContainerHigh,
    );
    final title = tester.widget<Text>(
      find.text('One break free. Every break with Premium.'),
    );
    expect(title.style!.color, theme.colorScheme.onSurface);
    await tester.ensureVisible(find.text('BREAK GUIDE'));
    await tester.pumpAndSettle();
    final guide = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('BREAK GUIDE'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((guide.decoration! as BoxDecoration).color, theme.cardColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Premium spot page displays model desk, not seeded current readings or old scores',
    (tester) async {
      final repo = _Repository(_user(premium: true));
      await _show(tester, repo);
      expect(find.text('Uluwatu Peak'), findsOneWidget);
      expect(find.text('FORECAST DESK'), findsOneWidget);
      expect(find.text('OFFSHORE WAVES'), findsOneWidget);
      expect(find.textContaining('99.9'), findsNothing);
      expect(find.textContaining('88.8'), findsNothing);
      expect(find.text('Best Time Today'), findsNothing);
      expect(find.text('Epic'), findsNothing);
      expect(repo.detailCalls, 1);
      expect(repo.tideCalls, 1);
      expect(repo.dailyCalls, 0);
      expect(repo.oldWindowCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unchosen free spot shows real unlock without requesting protected forecasts',
    (tester) async {
      final repo = _Repository(_user());
      await _show(tester, repo);
      expect(
        find.text('One break free. Every break with Premium.'),
        findsOneWidget,
      );
      expect(find.text('Use my free spot here'), findsOneWidget);
      expect(find.text('FORECAST DESK'), findsNothing);
      expect(repo.detailCalls, 0);
      expect(repo.tideCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'forecast failure keeps spot guide and exposes retry instead of fake charts',
    (tester) async {
      final repo = _Repository(_user(premium: true))..failDetail = true;
      await _show(tester, repo);
      expect(find.text('Hourly outlook unavailable'), findsOneWidget);
      expect(
        find.textContaining('Forecast service unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Retry forecast'), findsOneWidget);
      expect(find.byKey(const ValueKey('wave-swell-chart')), findsNothing);
      await tester.tap(find.text('Retry forecast'));
      await tester.pumpAndSettle();
      expect(repo.detailCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed free-spot save never enables the forecast desk', (
    tester,
  ) async {
    final repo = _Repository(_user())..failUnlock = true;
    await _show(tester, repo);
    await tester.tap(find.byKey(const ValueKey('select-free-forecast-spot')));
    await tester.pumpAndSettle();
    expect(find.text('Spot selection rejected.'), findsOneWidget);
    expect(find.text('FORECAST DESK'), findsNothing);
    expect(repo.detailCalls, 0);
    expect(repo.tideCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'successful free-spot save refreshes profile and reveals real model data',
    (tester) async {
      final repo = _Repository(_user());
      await _show(tester, repo);
      await tester.tap(find.byKey(const ValueKey('select-free-forecast-spot')));
      await tester.pumpAndSettle();
      expect(find.text('Your free forecast spot'), findsOneWidget);
      expect(find.text('FORECAST DESK'), findsOneWidget);
      expect(repo.detailCalls, 1);
      expect(repo.tideCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'profile permission changes discard the previously visible model desk',
    (tester) async {
      final repo = _Repository(_user(premium: true));
      final container = await _show(tester, repo);
      expect(find.text('FORECAST DESK'), findsOneWidget);
      repo.profile = _user();
      container.invalidate(meProvider);
      await tester.pumpAndSettle();
      expect(find.text('FORECAST DESK'), findsNothing);
      expect(
        find.text('One break free. Every break with Premium.'),
        findsOneWidget,
      );
      expect(repo.detailCalls, 1);
      expect(repo.tideCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
