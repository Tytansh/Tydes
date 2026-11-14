import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart'
    show travelFeedSpotsProvider;
import 'package:mobile_flutter/features/spots/spot_detail_page.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

import 'auth_session_test.dart' show MemorySessions;

UserProfile _account(String id, {bool premium = true}) => UserProfile.fromJson({
  'id': id,
  'email': '$id@example.invalid',
  'display_name': id,
  'handle': id,
  'home_region': 'Bali',
  'surf_skill': 'skilled',
  'locale': 'en',
  'email_verified': true,
  'premium': premium,
});

class _SpotRepository extends SurfRepository {
  _SpotRepository() : super(Dio(), MemorySessions());

  UserProfile account = _account('viewer');
  var hourlyCalls = 0;
  var tideCalls = 0;
  var spotCalls = 0;
  var catalogCalls = 0;
  bool unavailable = false;
  bool nonFinite = false;
  bool stale = false;
  bool partialWeather = false;
  Duration hourlyAge = Duration.zero;
  Duration tideAge = Duration.zero;

  @override
  Future<List<AlertModel>> fetchAlerts() async => [];

  @override
  Future<List<SpotModel>> fetchSpots() async {
    catalogCalls++;
    return [_guide()];
  }

  @override
  Future<SpotModel> fetchSpot(String spotId) async {
    spotCalls++;
    return _guide(id: spotId);
  }

  @override
  Future<DetailedForecastModel> fetchDetailedForecast(String spotId) async {
    hourlyCalls++;
    final now = DateTime.now().toUtc();
    return DetailedForecastModel(
      spotId: spotId,
      available: !unavailable,
      source: account.id,
      weatherModel: partialWeather ? 'Temporarily unavailable' : 'test-weather',
      timezone: 'UTC',
      utcOffsetSeconds: 0,
      localDate: now.toIso8601String().substring(0, 10),
      fetchedAt: stale
          ? now.subtract(const Duration(days: 1))
          : now.subtract(hourlyAge),
      hours: [
        HourlyForecastModel(
          time: now.toIso8601String(),
          localDate: now.toIso8601String().substring(0, 10),
          localTime: '12:00',
          waveHeightM: nonFinite ? double.nan : 1.8,
        ),
      ],
    );
  }

  @override
  Future<TideForecastModel> fetchTides(String spotId) async {
    tideCalls++;
    final now = DateTime.now().toUtc();
    return TideForecastModel(
      spotId: spotId,
      available: !unavailable,
      stationName: 'Station',
      stationDistanceKm: 1,
      source: account.id,
      note: null,
      fetchedAt: stale
          ? now.subtract(const Duration(days: 1))
          : now.subtract(tideAge),
      events: [
        TideEventModel(
          type: 'high',
          time: now.add(const Duration(hours: 1)).toIso8601String(),
          localDate: now.toIso8601String().substring(0, 10),
          localTime: '13:00',
          heightM: nonFinite ? double.nan : 1.2,
        ),
      ],
    );
  }
}

SpotModel _guide({String id = 'test-spot'}) => SpotModel(
  id: id,
  name: 'Known break',
  country: 'Indonesia',
  region: 'Bali',
  area: 'Uluwatu',
  latitude: -8.82,
  longitude: 115.08,
  difficulty: 'advanced',
  bestMonths: const ['May'],
  waveHeightM: 1,
  waterTempC: 25,
  imageUrl: '',
  summary: 'Static spot guide',
);

class _ForecastProbe extends ConsumerWidget {
  const _ForecastProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hourly = ref.watch(spotDetailedForecastProvider('test-spot'));
    final tide = ref.watch(spotTideProvider('test-spot'));
    return Column(
      children: [
        Text('Hourly: ${hourly.valueOrNull?.source ?? 'loading'}'),
        Text('Tide: ${tide.valueOrNull?.source ?? 'loading'}'),
      ],
    );
  }
}

ProviderContainer _container(_SpotRepository repository) => ProviderContainer(
  overrides: [
    surfRepositoryProvider.overrideWithValue(repository),
    meProvider.overrideWith((_) async => repository.account),
  ],
);

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container, {
  bool visible = true,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: visible ? const _ForecastProbe() : const SizedBox.shrink(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _cleanup(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  for (final catalog in [spotsProvider, travelFeedSpotsProvider]) {
    test(
      'loaded ${catalog == spotsProvider ? 'Spots' : 'Feed'} catalog avoids another spot-detail GET',
      () async {
        final repository = _SpotRepository();
        final container = _container(repository);
        addTearDown(container.dispose);
        final known = await container.read(catalog.future);
        final detail = await container.read(
          spotDetailProvider('test-spot').future,
        );
        expect(detail, same(known.single));
        expect(repository.spotCalls, 0);
        expect(repository.catalogCalls, 1);
      },
    );
  }

  test('direct spot links do not start a whole catalog request', () async {
    final repository = _SpotRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    final detail = await container.read(spotDetailProvider('test-spot').future);
    expect(detail.id, 'test-spot');
    expect(repository.spotCalls, 1);
    expect(repository.catalogCalls, 0);
  });

  testWidgets('repeat spot navigation reuses two-minute successful reads', (
    tester,
  ) async {
    final repository = _SpotRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await _mount(tester, container);
    expect(repository.hourlyCalls, 1);
    expect(repository.tideCalls, 1);
    await _mount(tester, container, visible: false);
    await _mount(tester, container);
    expect(repository.hourlyCalls, 1);
    expect(repository.tideCalls, 1);
    await _cleanup(tester, container);
  });

  testWidgets('successful navigation cache expires after two minutes', (
    tester,
  ) async {
    final repository = _SpotRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await _mount(tester, container);
    await _mount(tester, container, visible: false);
    await tester.pump(const Duration(minutes: 2, seconds: 1));
    await _mount(tester, container);
    expect(repository.hourlyCalls, 2);
    expect(repository.tideCalls, 2);
    await _cleanup(tester, container);
  });

  testWidgets('navigation retention never extends source freshness limits', (
    tester,
  ) async {
    final repository = _SpotRepository()
      ..hourlyAge = const Duration(hours: 2, minutes: 59, seconds: 59)
      ..tideAge = const Duration(hours: 11, minutes: 59, seconds: 59);
    final container = _container(repository);
    addTearDown(container.dispose);
    await _mount(tester, container);
    await _mount(tester, container, visible: false);
    await tester.pump(const Duration(seconds: 2));
    await _mount(tester, container);
    expect(repository.hourlyCalls, 2);
    expect(repository.tideCalls, 2);
    await _cleanup(tester, container);
  });

  testWidgets('partial weather keeps its shorter one-minute retry boundary', (
    tester,
  ) async {
    final repository = _SpotRepository()
      ..partialWeather = true
      ..hourlyAge = const Duration(seconds: 59);
    final container = _container(repository);
    addTearDown(container.dispose);
    await _mount(tester, container);
    await _mount(tester, container, visible: false);
    await tester.pump(const Duration(seconds: 2));
    await _mount(tester, container);
    expect(repository.hourlyCalls, 2);
    expect(repository.tideCalls, 1);
    await _cleanup(tester, container);
  });

  testWidgets(
    'closing a spot during identity loading does not start late requests',
    (tester) async {
      final repository = _SpotRepository();
      final pending = Completer<UserProfile>();
      final container = ProviderContainer(
        overrides: [
          surfRepositoryProvider.overrideWithValue(repository),
          meProvider.overrideWith((_) => pending.future),
        ],
      );
      addTearDown(container.dispose);
      await _mount(tester, container);
      await _mount(tester, container, visible: false);
      pending.complete(repository.account);
      await tester.pumpAndSettle();
      expect(repository.hourlyCalls, 0);
      expect(repository.tideCalls, 0);
      expect(tester.takeException(), isNull);
      await _cleanup(tester, container);
    },
  );

  for (final rejected in ['unavailable', 'non-finite', 'stale']) {
    testWidgets('$rejected data is never retained for navigation', (
      tester,
    ) async {
      final repository = _SpotRepository()
        ..unavailable = rejected == 'unavailable'
        ..nonFinite = rejected == 'non-finite'
        ..stale = rejected == 'stale';
      final container = _container(repository);
      addTearDown(container.dispose);
      await _mount(tester, container);
      await _mount(tester, container, visible: false);
      await _mount(tester, container);
      expect(repository.hourlyCalls, 2);
      expect(repository.tideCalls, 2);
      await _cleanup(tester, container);
    });
  }

  testWidgets('manual retry invalidates both retained successful reads', (
    tester,
  ) async {
    final repository = _SpotRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await _mount(tester, container);
    container.invalidate(spotDetailedForecastProvider('test-spot'));
    container.invalidate(spotTideProvider('test-spot'));
    await tester.pumpAndSettle();
    expect(repository.hourlyCalls, 2);
    expect(repository.tideCalls, 2);
    await _cleanup(tester, container);
  });

  testWidgets(
    'new accounts cannot reuse the previous account navigation cache',
    (tester) async {
      final repository = _SpotRepository();
      final container = _container(repository);
      addTearDown(container.dispose);
      await _mount(tester, container);
      await _mount(tester, container, visible: false);
      repository.account = _account('second-viewer');
      container.invalidate(meProvider);
      await _mount(tester, container);
      expect(repository.hourlyCalls, 2);
      expect(repository.tideCalls, 2);
      expect(find.text('Hourly: second-viewer'), findsOneWidget);
      expect(find.text('Tide: second-viewer'), findsOneWidget);
      await _cleanup(tester, container);
    },
  );

  testWidgets('lost entitlement cannot reuse retained Premium readings', (
    tester,
  ) async {
    final repository = _SpotRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await _mount(tester, container);
    await _mount(tester, container, visible: false);
    repository.account = _account('viewer', premium: false);
    container.invalidate(meProvider);
    await _mount(tester, container);
    expect(repository.hourlyCalls, 1);
    expect(repository.tideCalls, 1);
    expect(
      container
          .read(spotDetailedForecastProvider('test-spot'))
          .requireValue
          .available,
      isFalse,
    );
    expect(
      container.read(spotTideProvider('test-spot')).requireValue.available,
      isFalse,
    );
    await _cleanup(tester, container);
  });

  testWidgets('verification requirements invalidate cached successful reads', (
    tester,
  ) async {
    final repository = _SpotRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await _mount(tester, container);
    await _mount(tester, container, visible: false);
    container.read(emailVerificationRequiredTokenProvider.notifier).state =
        'blocked';
    await _mount(tester, container);
    expect(
      container.read(spotDetailedForecastProvider('test-spot')).hasError,
      isTrue,
    );
    expect(container.read(spotTideProvider('test-spot')).hasError, isTrue);
    expect(repository.hourlyCalls, 1);
    expect(repository.tideCalls, 1);
    await _cleanup(tester, container);
  });
}
