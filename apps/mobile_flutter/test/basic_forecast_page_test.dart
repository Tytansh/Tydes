import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/basic_forecast_models.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/spots/basic_forecast_panel.dart';
import 'package:mobile_flutter/features/spots/pro_forecast_panel.dart';
import 'package:mobile_flutter/features/spots/spot_detail_page.dart';

import 'auth_session_test.dart' show MemorySessions;

const _spotId = 'basic-test-break';
const _modelName = 'ECMWF WAM 0.25° fixture';
final _widgetContainers = <ProviderContainer>[];

void _widgetTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      // End retained-provider timers inside the widget test's fake clock,
      // before Flutter checks for pending timers after unmounting the tree.
      await tester.pumpWidget(const SizedBox.shrink());
      for (final container in _widgetContainers) {
        container.dispose();
      }
      _widgetContainers.clear();
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}

UserProfile _user({
  String id = 'free-viewer',
  bool premium = false,
  bool verified = true,
  String? freeSpot = 'another-break',
}) => UserProfile.fromJson({
  'id': id,
  'email': '$id@example.com',
  'display_name': 'Surfer',
  'handle': id,
  'home_region': 'Bali',
  'locale': 'en',
  'email_verified': verified,
  'premium': premium,
  'free_live_spot_id': freeSpot,
  'favorite_spot_ids': <String>[],
});

String _date(DateTime value) => value.toIso8601String().substring(0, 10);

BasicForecastModel _basic({
  DateTime? now,
  DateTime? fetched,
  String? localDate,
  int offset = 8 * 60 * 60,
  double height = 1.1,
  String model = _modelName,
  List<BasicForecastDayModel>? days,
}) {
  final utc = (now ?? DateTime.now()).toUtc();
  final local = utc.add(Duration(seconds: offset));
  return BasicForecastModel(
    spotId: _spotId,
    available: true,
    source: 'open-meteo',
    marineModel: model,
    timezone: offset == 8 * 60 * 60 ? 'Asia/Makassar' : 'America/Los_Angeles',
    utcOffsetSeconds: offset,
    fetchedAt: fetched ?? utc.subtract(const Duration(minutes: 15)),
    localDate: localDate ?? _date(local),
    days:
        days ??
        [
          BasicForecastDayModel(day: _date(local), waveHeightM: height),
          BasicForecastDayModel(
            day: _date(local.add(const Duration(days: 1))),
            waveHeightM: 1.5,
          ),
          BasicForecastDayModel(
            day: _date(local.add(const Duration(days: 2))),
            waveHeightM: 2.2,
          ),
        ],
  );
}

class _Repository extends SurfRepository {
  _Repository(this.profile) : super(Dio(), MemorySessions());
  UserProfile profile;
  Object? accountFailure;
  Completer<UserProfile>? pendingAccount;
  Object? basicFailure;
  BasicForecastModel? basicResult;
  Completer<BasicForecastModel>? pendingBasic;
  int basicCalls = 0;
  int hourlyCalls = 0;
  int tideCalls = 0;
  int legacyDailyCalls = 0;
  int legacyWindowCalls = 0;

  Future<UserProfile> currentAccount() async {
    if (accountFailure != null) throw accountFailure!;
    return pendingAccount?.future ?? profile;
  }

  @override
  Future<SpotModel> fetchSpot(String spotId) async => SpotModel(
    id: spotId,
    name: 'Reliable Break',
    country: 'Indonesia',
    region: 'Bali',
    area: 'Bukit',
    latitude: -8.82,
    longitude: 115.08,
    difficulty: 'advanced',
    bestMonths: const ['May', 'Jun'],
    waveHeightM: 99.9,
    waterTempC: 88.8,
    imageUrl: '',
    summary: 'This static reef guide remains available independently.',
  );

  @override
  Future<List<AlertModel>> fetchAlerts() async => [];

  @override
  Future<BasicForecastModel> fetchBasicForecast(String spotId) async {
    basicCalls++;
    if (basicFailure != null) throw basicFailure!;
    return pendingBasic?.future ?? basicResult ?? _basic();
  }

  @override
  Future<DetailedForecastModel> fetchDetailedForecast(String spotId) async {
    hourlyCalls++;
    return DetailedForecastModel.unavailable(spotId);
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
    legacyDailyCalls++;
    return [];
  }

  @override
  Future<SurfWindowModel> fetchSurfWindow(String spotId) async {
    legacyWindowCalls++;
    throw StateError('No legacy/static forecast request is allowed.');
  }
}

ProviderContainer _container(_Repository repository) => ProviderContainer(
  overrides: [
    surfRepositoryProvider.overrideWithValue(repository),
    meProvider.overrideWith((_) => repository.currentAccount()),
  ],
);

Future<void> _pump(WidgetTester tester) async {
  for (var index = 0; index < 5; index++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<ProviderContainer> _show(
  WidgetTester tester,
  _Repository repository, {
  double width = 390,
  bool dark = false,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = _container(repository);
  _widgetContainers.add(container);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: const SpotDetailPage(spotId: _spotId),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _pump(tester);
  }
  return container;
}

void _expectOnlyBasicRequests(_Repository repository, {int calls = 1}) {
  expect(repository.basicCalls, calls);
  expect(repository.hourlyCalls, 0);
  expect(repository.tideCalls, 0);
  expect(repository.legacyDailyCalls, 0);
  expect(repository.legacyWindowCalls, 0);
}

void main() {
  for (final width in [390.0, 1440.0]) {
    for (final dark in [false, true]) {
      _widgetTest(
        'free unselected outlook is real daily data at $width in ${dark ? 'dark' : 'light'} mode',
        (tester) async {
          final forecast = _basic();
          final repository = _Repository(_user())..basicResult = forecast;
          await _show(tester, repository, width: width, dark: dark);
          expect(find.byType(BasicForecastPanel), findsOneWidget);
          expect(find.byType(ProForecastPanel), findsNothing);
          expect(find.text('Basic daily outlook'), findsOneWidget);
          expect(find.text('Model estimate'), findsOneWidget);
          expect(
            find.text('Daily mean significant wave height'),
            findsOneWidget,
          );
          for (final value in ['1.1 m', '1.5 m', '2.2 m']) {
            expect(find.text(value), findsOneWidget);
          }
          expect(find.textContaining(_modelName), findsWidgets);
          expect(find.textContaining('Open-Meteo'), findsWidgets);
          expect(find.textContaining('Asia/Makassar'), findsWidgets);
          expect(find.textContaining('Fetched'), findsWidgets);
          final fetched = forecast.fetchedAt!.toUtc();
          final time =
              '${fetched.hour.toString().padLeft(2, '0')}:${fetched.minute.toString().padLeft(2, '0')}';
          final labels = tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data ?? '')
              .join('\n');
          expect(labels, contains(time));
          expect(labels, contains('UTC'));
          expect(find.text('Reliable Break'), findsOneWidget);
          // The additive daily details make the panel taller on phones; the
          // independent guide remains below it in the existing lazy ListView.
          await tester.scrollUntilVisible(
            find.text('BREAK GUIDE'),
            400,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('BREAK GUIDE'), findsOneWidget);
          expect(labels, isNot(contains('99.9')));
          expect(labels, isNot(contains('88.8')));
          _expectOnlyBasicRequests(repository);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  _widgetTest('slow basic data never holds the independent guide', (
    tester,
  ) async {
    final pending = Completer<BasicForecastModel>();
    final repository = _Repository(_user())..pendingBasic = pending;
    await _show(tester, repository, settle: false);
    expect(find.text('Loading basic daily outlook'), findsOneWidget);
    expect(find.text('Reliable Break'), findsOneWidget);
    expect(find.text('BREAK GUIDE'), findsOneWidget);
    expect(find.text('1.1 m'), findsNothing);
    expect(find.byType(ProForecastPanel), findsNothing);
    _expectOnlyBasicRequests(repository);
    pending.complete(_basic());
    await tester.pumpAndSettle();
    expect(find.text('1.1 m'), findsOneWidget);
  });

  for (final failure in ['error', 'unavailable']) {
    _widgetTest(
      'basic $failure retains guide and explicit retry requests only basic',
      (tester) async {
        final repository = _Repository(_user());
        if (failure == 'error') {
          repository.basicFailure = StateError(
            'The basic model is temporarily unavailable.',
          );
        } else {
          repository.basicResult = BasicForecastModel.unavailable(_spotId);
        }
        await _show(tester, repository);
        expect(find.text('Basic outlook unavailable'), findsOneWidget);
        expect(find.text('BREAK GUIDE'), findsOneWidget);
        expect(find.text('1.1 m'), findsNothing);
        expect(
          find.byKey(const ValueKey('basic-forecast-retry')),
          findsOneWidget,
        );
        _expectOnlyBasicRequests(repository);
        repository.basicFailure = null;
        repository.basicResult = _basic();
        await tester.tap(find.byKey(const ValueKey('basic-forecast-retry')));
        await tester.pumpAndSettle();
        expect(find.text('1.1 m'), findsOneWidget);
        expect(find.text('Basic outlook unavailable'), findsNothing);
        _expectOnlyBasicRequests(repository, calls: 2);
      },
    );
  }

  for (final premium in [false, true]) {
    _widgetTest(
      '${premium ? 'Premium' : 'chosen free break'} keeps only the existing Pro path',
      (tester) async {
        final repository = _Repository(
          _user(premium: premium, freeSpot: _spotId),
        );
        await _show(tester, repository);
        expect(find.byType(ProForecastPanel), findsOneWidget);
        expect(find.byType(BasicForecastPanel), findsNothing);
        expect(repository.basicCalls, 0);
        expect(repository.hourlyCalls, 1);
        expect(repository.tideCalls, 1);
        expect(repository.legacyDailyCalls, 0);
        expect(repository.legacyWindowCalls, 0);
      },
    );
  }

  _widgetTest('no basic request starts before the account is confirmed', (
    tester,
  ) async {
    final pending = Completer<UserProfile>();
    final repository = _Repository(_user())..pendingAccount = pending;
    await _show(tester, repository, settle: false);
    _expectOnlyBasicRequests(repository, calls: 0);
    expect(find.byType(BasicForecastPanel), findsNothing);
    expect(find.text('Reliable Break'), findsOneWidget);
    pending.complete(repository.profile);
    await tester.pumpAndSettle();
    _expectOnlyBasicRequests(repository);
    expect(find.text('1.1 m'), findsOneWidget);
  });

  _widgetTest('unverified accounts never request or display basic data', (
    tester,
  ) async {
    final repository = _Repository(_user(verified: false));
    await _show(tester, repository);
    _expectOnlyBasicRequests(repository, calls: 0);
    expect(find.byType(BasicForecastPanel), findsNothing);
    expect(find.text('BREAK GUIDE'), findsOneWidget);
  });

  _widgetTest('account loading hides an already displayed basic outlook', (
    tester,
  ) async {
    final repository = _Repository(_user());
    final container = await _show(tester, repository);
    expect(find.text('1.1 m'), findsOneWidget);
    final pending = Completer<UserProfile>();
    repository.pendingAccount = pending;
    container.invalidate(meProvider);
    await _pump(tester);
    expect(find.byType(BasicForecastPanel), findsNothing);
    expect(find.text('1.1 m'), findsNothing);
    repository.profile = _user(id: 'replacement');
    repository.basicResult = _basic(height: 2.6);
    pending.complete(repository.profile);
    await tester.pumpAndSettle();
    expect(find.text('2.6 m'), findsOneWidget);
    expect(find.text('1.1 m'), findsNothing);
  });

  _widgetTest(
    'successful basic reads survive navigation but expire after two minutes',
    (tester) async {
      final repository = _Repository(_user());
      final container = await _show(tester, repository);
      Future<void> mount(bool visible) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: visible
                  ? const SpotDetailPage(spotId: _spotId)
                  : const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      _expectOnlyBasicRequests(repository);
      await mount(false);
      await mount(true);
      _expectOnlyBasicRequests(repository);
      await mount(false);
      await tester.pump(const Duration(minutes: 2, seconds: 1));
      await mount(true);
      _expectOnlyBasicRequests(repository, calls: 2);
      expect(find.text('1.1 m'), findsOneWidget);
    },
  );

  _widgetTest(
    'stale available responses show no chart or static seeded heights',
    (tester) async {
      final now = DateTime.now().toUtc();
      final repository = _Repository(_user())
        ..basicResult = _basic(
          now: now,
          fetched: now.subtract(const Duration(hours: 25)),
          height: 7.7,
        );
      await _show(tester, repository);
      expect(find.text('Basic outlook unavailable'), findsOneWidget);
      expect(find.text('7.7 m'), findsNothing);
      expect(find.text('BREAK GUIDE'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('basic-forecast-retry')),
        findsOneWidget,
      );
      _expectOnlyBasicRequests(repository);
    },
  );

  _widgetTest(
    'revoking Premium switches to basic without re-requesting protected data',
    (tester) async {
      final repository = _Repository(_user(premium: true));
      final container = await _show(tester, repository);
      expect(find.byType(ProForecastPanel), findsOneWidget);
      repository.profile = _user();
      container.invalidate(meProvider);
      await tester.pumpAndSettle();
      expect(find.byType(ProForecastPanel), findsNothing);
      expect(find.byType(BasicForecastPanel), findsOneWidget);
      expect(find.text('1.1 m'), findsOneWidget);
      expect(repository.basicCalls, 1);
      expect(repository.hourlyCalls, 1);
      expect(repository.tideCalls, 1);
      expect(repository.legacyDailyCalls, 0);
      expect(repository.legacyWindowCalls, 0);
    },
  );

  _widgetTest(
    'late previous-account basic result cannot replace new account data',
    (tester) async {
      final old = Completer<BasicForecastModel>();
      final repository = _Repository(_user())..pendingBasic = old;
      final container = await _show(tester, repository, settle: false);
      repository.pendingBasic = null;
      repository.basicResult = _basic(height: 2.6);
      repository.profile = _user(id: 'replacement');
      container.invalidate(meProvider);
      await tester.pumpAndSettle();
      expect(find.text('2.6 m'), findsOneWidget);
      old.complete(_basic(height: 7.7, model: 'Old account model'));
      await tester.pumpAndSettle();
      expect(find.text('2.6 m'), findsOneWidget);
      expect(find.text('7.7 m'), findsNothing);
      expect(find.textContaining('Old account model'), findsNothing);
      _expectOnlyBasicRequests(repository, calls: 2);
    },
  );

  for (final change in [
    'sign-out',
    'unverified',
    'verification-latch',
    'premium',
    'selected-free',
  ]) {
    _widgetTest('late basic result stays hidden after $change', (tester) async {
      final old = Completer<BasicForecastModel>();
      final repository = _Repository(_user())..pendingBasic = old;
      final container = await _show(tester, repository, settle: false);
      switch (change) {
        case 'sign-out':
          repository.accountFailure = StateError('Sign in required.');
          container.invalidate(meProvider);
        case 'unverified':
          repository.profile = _user(verified: false);
          container.invalidate(meProvider);
        case 'verification-latch':
          container
                  .read(emailVerificationRequiredTokenProvider.notifier)
                  .state =
              'blocked-fixture-session';
        case 'premium':
          repository.profile = _user(premium: true);
          container.invalidate(meProvider);
        case 'selected-free':
          repository.profile = _user(freeSpot: _spotId);
          container.invalidate(meProvider);
      }
      await _pump(tester);
      old.complete(_basic(height: 7.7, model: 'Revoked basic response'));
      await tester.pumpAndSettle();
      expect(find.byType(BasicForecastPanel), findsNothing);
      expect(find.text('7.7 m'), findsNothing);
      expect(find.textContaining('Revoked basic response'), findsNothing);
      expect(repository.basicCalls, 1);
    });
  }

  test(
    'basic provider preserves authentication and verification errors',
    () async {
      for (final status in [401, 403]) {
        final options = RequestOptions(path: '/forecasts/basic');
        final error = DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: status,
            data: {'detail': 'Authorization required'},
          ),
          type: DioExceptionType.badResponse,
        );
        final repository = _Repository(_user())..basicFailure = error;
        final container = _container(repository);
        await container.read(meProvider.future);
        final subscription = container.listen(
          spotBasicForecastProvider(_spotId),
          (_, _) {},
        );
        try {
          await expectLater(
            container.read(spotBasicForecastProvider(_spotId).future),
            throwsA(same(error)),
          );
          _expectOnlyBasicRequests(repository);
        } finally {
          subscription.close();
          container.dispose();
        }
      }
    },
  );

  test(
    'basic eligibility provider never fetches for entitled/unverified accounts',
    () async {
      for (final profile in [
        _user(premium: true),
        _user(freeSpot: _spotId),
        _user(verified: false),
      ]) {
        final repository = _Repository(profile);
        final container = _container(repository);
        await container.read(meProvider.future);
        final subscription = container.listen(
          spotBasicForecastProvider(_spotId),
          (_, _) {},
        );
        try {
          final result = await container.read(
            spotBasicForecastProvider(_spotId).future,
          );
          expect(result.available, isFalse);
          _expectOnlyBasicRequests(repository, calls: 0);
        } finally {
          subscription.close();
          container.dispose();
        }
      }
    },
  );

  test(
    'basic freshness follows the spot local day on both sides of UTC midnight',
    () {
      final asiaNow = DateTime.utc(2026, 11, 14, 20);
      final westNow = DateTime.utc(2026, 11, 15, 3);
      expect(_basic(now: asiaNow).localDate, '2026-11-15');
      expect(_basic(now: asiaNow).isCurrentAt(asiaNow), isTrue);
      expect(
        _basic(now: westNow, offset: -8 * 60 * 60).localDate,
        '2026-11-14',
      );
      expect(
        _basic(now: westNow, offset: -8 * 60 * 60).isCurrentAt(westNow),
        isTrue,
      );
      expect(
        _basic(
          now: asiaNow,
        ).isCurrentAt(asiaNow.add(const Duration(hours: 21))),
        isFalse,
      );
    },
  );

  test(
    'stale, future-dated or wrong local-date data never becomes a current chart',
    () {
      final now = DateTime.utc(2026, 11, 15, 6);
      for (final forecast in [
        _basic(now: now, fetched: now.subtract(const Duration(hours: 25))),
        _basic(now: now, fetched: now.add(const Duration(hours: 6))),
        _basic(now: now, localDate: '2026-11-14'),
        _basic(now: now, localDate: '2026-11-16'),
        _basic(
          now: now,
          days: const [
            BasicForecastDayModel(day: '2026-04-15', waveHeightM: 1.2),
          ],
        ),
        _basic(
          now: now,
          days: const [
            BasicForecastDayModel(day: '2099-04-15', waveHeightM: 1.2),
          ],
        ),
      ]) {
        expect(forecast.isCurrentAt(now), isFalse);
      }
    },
  );
}
