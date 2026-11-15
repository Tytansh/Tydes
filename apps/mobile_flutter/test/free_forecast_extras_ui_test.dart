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

const _spotId = 'free-extras-break';
const _weatherModel = 'Wind and daylight model fixture';
const _marineModel = 'Marine temperature model fixture';
final _containers = <ProviderContainer>[];

void _widgetTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final container in _containers) {
        container.dispose();
      }
      _containers.clear();
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}

String _date(DateTime value) => value.toIso8601String().substring(0, 10);

BasicForecastModel _forecast({
  String timezone = 'Asia/Makassar',
  int offset = 8 * 60 * 60,
  String? weatherModel = _weatherModel,
  bool extras = true,
  bool partialWeather = false,
  double temperature = 27.4,
  double wind = 8.6,
}) {
  final now = DateTime.now().toUtc();
  final day = _date(now.add(Duration(seconds: offset)));
  return BasicForecastModel(
    spotId: _spotId,
    available: true,
    source: 'open-meteo',
    marineModel: _marineModel,
    weatherModel: weatherModel,
    timezone: timezone,
    utcOffsetSeconds: offset,
    fetchedAt: now.subtract(const Duration(minutes: 5)),
    localDate: day,
    days: [
      BasicForecastDayModel(
        day: day,
        waveHeightM: 1.7,
        windKts: extras && !partialWeather ? wind : null,
        windDirectionDeg: extras && !partialWeather ? 315 : null,
        windDirectionStatus: extras && !partialWeather
            ? 'available'
            : 'unavailable',
        seaSurfaceTemperatureC: extras ? temperature : null,
        sunriseLocal: extras && !partialWeather ? '05:52' : null,
        sunsetLocal: extras && !partialWeather ? '18:07' : null,
      ),
    ],
  );
}

BasicForecastModel _withDays(List<BasicForecastDayModel> days) {
  final base = _forecast();
  return BasicForecastModel(
    spotId: base.spotId,
    available: base.available,
    source: base.source,
    marineModel: base.marineModel,
    weatherModel: base.weatherModel,
    timezone: base.timezone,
    utcOffsetSeconds: base.utcOffsetSeconds,
    fetchedAt: base.fetchedAt,
    localDate: base.localDate,
    days: days,
  );
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

class _Repository extends SurfRepository {
  _Repository(this.profile) : super(Dio(), MemorySessions());
  UserProfile profile;
  BasicForecastModel? result;
  Completer<BasicForecastModel>? pending;
  int basicCalls = 0, hourlyCalls = 0, tideCalls = 0, legacyCalls = 0;

  @override
  Future<BasicForecastModel> fetchBasicForecast(String spotId) async {
    basicCalls++;
    return pending?.future ?? result ?? _forecast();
  }

  @override
  Future<SpotModel> fetchSpot(String spotId) async => SpotModel(
    id: spotId,
    name: 'Free Extras Break',
    country: 'Indonesia',
    region: 'Bali',
    area: 'Bukit',
    latitude: -8.82,
    longitude: 115.08,
    difficulty: 'advanced',
    bestMonths: const ['May'],
    waveHeightM: 99.9,
    waterTempC: 88.8,
    imageUrl: '',
    summary: 'Independent static break guide.',
  );

  @override
  Future<List<AlertModel>> fetchAlerts() async => [];

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
    legacyCalls++;
    return [];
  }
}

Future<void> _pump(WidgetTester tester) async {
  for (var index = 0; index < 5; index++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void _viewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _panel(
  WidgetTester tester,
  BasicForecastModel forecast, {
  double width = 390,
  bool dark = false,
  double textScale = 1,
}) async {
  _viewport(tester, width);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 1800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: BasicForecastPanel(forecast: forecast, onRetry: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _page(
  WidgetTester tester,
  _Repository repository, {
  bool settle = true,
}) async {
  _viewport(tester, 390);
  final container = ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(repository),
      meProvider.overrideWith((_) async => repository.profile),
    ],
  );
  _containers.add(container);
  await _mountPage(tester, container);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _pump(tester);
  }
  return container;
}

Future<void> _mountPage(
  WidgetTester tester,
  ProviderContainer container, {
  bool dark = false,
}) => tester.pumpWidget(
  UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: const SpotDetailPage(spotId: _spotId),
    ),
  ),
);

String _text(WidgetTester tester, {Finder? within}) => tester
    .widgetList<Text>(
      within == null
          ? find.byType(Text)
          : find.descendant(of: within, matching: find.byType(Text)),
    )
    .map((widget) => widget.data ?? '')
    .join('\n');

void _expectNoProtectedRequests(_Repository repository, {int basic = 1}) {
  expect(repository.basicCalls, basic);
  expect(repository.hourlyCalls, 0);
  expect(repository.tideCalls, 0);
  expect(repository.legacyCalls, 0);
}

void main() {
  for (final width in [390.0, 1440.0]) {
    for (final dark in [false, true]) {
      _widgetTest(
        'free extras render at $width in ${dark ? 'dark' : 'light'} mode',
        (tester) async {
          await _panel(tester, _forecast(), width: width, dark: dark);
          final text = _text(tester);
          expect(find.text('1.7 m'), findsOneWidget);
          expect(text, contains('8.6'));
          expect(text, contains('NW'));
          expect(text.toLowerCase(), contains('from'));
          expect(text, matches(RegExp(r'27\.4\s*°C')));
          expect(text.toLowerCase(), contains('model'));
          expect(text, contains('05:52'));
          expect(text, contains('18:07'));
          expect(text.toLowerCase(), contains('spot local time'));
          expect(text, contains(_marineModel));
          expect(text, contains(_weatherModel));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final dark in [false, true]) {
    _widgetTest(
      '320px and large text keeps every daily metric readable (${dark ? 'dark' : 'light'})',
      (tester) async {
        await _panel(tester, _forecast(), width: 320, dark: dark, textScale: 2);
        expect(_text(tester), contains('05:52'));
        expect(_text(tester), contains('18:07'));
        expect(_text(tester), contains('NW'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  _widgetTest('calm and variable wind never invent a north direction', (
    tester,
  ) async {
    final today = DateTime.parse('${_forecast().localDate}T00:00:00Z');
    final forecast = _withDays([
      BasicForecastDayModel(
        day: _date(today),
        waveHeightM: 1.7,
        windKts: 0.2,
        windDirectionStatus: 'calm',
      ),
      BasicForecastDayModel(
        day: _date(today.add(const Duration(days: 1))),
        waveHeightM: 1.8,
        windKts: 6.2,
        windDirectionStatus: 'variable',
      ),
    ]);
    await _panel(tester, forecast);
    final text = _text(tester);
    expect(text.toLowerCase(), contains('calm'));
    expect(text.toLowerCase(), contains('variable'));
    expect(text, isNot(matches(RegExp(r'\bN\b|\b0°'))));
    expect(find.text('1.7 m'), findsOneWidget);
    expect(find.text('1.8 m'), findsOneWidget);
  });

  _widgetTest(
    'missing wind direction retains a real speed but never fabricates a compass',
    (tester) async {
      final forecast = _withDays([
        BasicForecastDayModel(
          day: _forecast().localDate!,
          waveHeightM: 1.7,
          windKts: 8.6,
          windDirectionStatus: 'unavailable',
        ),
      ]);
      await _panel(tester, forecast);
      final text = _text(tester);
      expect(text, contains('8.6'));
      expect(text.toLowerCase(), contains('unavailable'));
      expect(text, isNot(matches(RegExp(r'\bN\b|\b0°'))));
    },
  );

  _widgetTest('a real zero-degree FROM bearing is north, not unavailable', (
    tester,
  ) async {
    final day = _forecast().localDate!;
    await _panel(
      tester,
      _withDays([
        BasicForecastDayModel(
          day: day,
          waveHeightM: 1.7,
          windKts: 8.6,
          windDirectionDeg: 0,
          windDirectionStatus: 'available',
        ),
      ]),
    );
    expect(
      _text(tester, within: find.byKey(ValueKey('basic-wind-$day'))),
      contains('8.6 kt · FROM N'),
    );
  });

  _widgetTest(
    'missing model water temperature does not hide wind or daylight',
    (tester) async {
      final day = _forecast().localDate!;
      await _panel(
        tester,
        _withDays([
          BasicForecastDayModel(
            day: day,
            waveHeightM: 1.7,
            windKts: 8.6,
            windDirectionDeg: 315,
            windDirectionStatus: 'available',
            sunriseLocal: '05:52',
            sunsetLocal: '18:07',
          ),
        ]),
      );
      final water = _text(
        tester,
        within: find.byKey(ValueKey('basic-water-$day')),
      );
      expect(water, contains('Model water temp'));
      expect(water, contains('Unavailable'));
      expect(water, isNot(contains('0.0°C')));
      expect(_text(tester), contains('8.6 kt · FROM NW'));
      expect(_text(tester), contains('05:52'));
      expect(_text(tester), contains('18:07'));
      expect(find.text('1.7 m'), findsOneWidget);
    },
  );

  _widgetTest(
    'contradictory daylight is unavailable without discarding waves',
    (tester) async {
      final day = _forecast().localDate!;
      await _panel(
        tester,
        _withDays([
          BasicForecastDayModel(
            day: day,
            waveHeightM: 1.7,
            sunriseLocal: '18:07',
            sunsetLocal: '05:52',
          ),
        ]),
      );
      expect(
        _text(tester, within: find.byKey(ValueKey('basic-sunrise-$day'))),
        contains('Unavailable'),
      );
      expect(
        _text(tester, within: find.byKey(ValueKey('basic-sunset-$day'))),
        contains('Unavailable'),
      );
      expect(find.text('1.7 m'), findsOneWidget);
      expect(find.text('Basic outlook unavailable'), findsNothing);
    },
  );

  _widgetTest(
    'one absent daylight endpoint preserves the other real local time',
    (tester) async {
      final day = _forecast().localDate!;
      await _panel(
        tester,
        _withDays([
          BasicForecastDayModel(
            day: day,
            waveHeightM: 1.7,
            sunsetLocal: '18:07',
          ),
        ]),
      );
      expect(
        _text(tester, within: find.byKey(ValueKey('basic-sunrise-$day'))),
        contains('Unavailable'),
      );
      expect(
        _text(tester, within: find.byKey(ValueKey('basic-sunset-$day'))),
        contains('18:07'),
      );
      expect(find.text('1.7 m'), findsOneWidget);
    },
  );

  _widgetTest(
    'partial weather preserves marine waves and model temperature without invented wind or sun times',
    (tester) async {
      await _panel(tester, _forecast(partialWeather: true, weatherModel: null));
      final text = _text(tester);
      expect(find.text('1.7 m'), findsOneWidget);
      expect(text, matches(RegExp(r'27\.4\s*°C')));
      expect(find.text('Basic outlook unavailable'), findsNothing);
      expect(text, isNot(matches(RegExp(r'\b0(?:\.0)?\s*kt\b|\bN\b|\b0°'))));
      expect(text, isNot(contains('05:52')));
      expect(text, isNot(contains('18:07')));
      expect(text, isNot(contains('null')));
    },
  );

  _widgetTest(
    'negative model SST remains valid rather than being replaced by a seed or zero',
    (tester) async {
      await _panel(tester, _forecast(temperature: -1.5));
      final text = _text(tester);
      expect(text, matches(RegExp(r'[-−]1\.5\s*°C')));
      expect(text, isNot(contains('88.8')));
      expect(text.toLowerCase(), isNot(contains('measured at the beach')));
      expect(find.text('1.7 m'), findsOneWidget);
    },
  );

  for (final region in [
    ('Pacific/Honolulu', -10 * 60 * 60),
    ('Pacific/Auckland', 13 * 60 * 60),
  ]) {
    _widgetTest(
      'daylight is already ${region.$1} spot-local HH:mm, not converted again',
      (tester) async {
        await _panel(tester, _forecast(timezone: region.$1, offset: region.$2));
        final text = _text(tester);
        expect(text, contains('05:52'));
        expect(text, contains('18:07'));
        expect(text.toLowerCase(), contains('spot local time'));
        expect(text, contains(region.$1));
        expect(text, isNot(contains('15:52')));
        expect(text, isNot(contains('04:07')));
      },
    );
  }

  _widgetTest(
    'old wave-only wire payloads remain usable with unavailable optional metrics',
    (tester) async {
      final base = _forecast(extras: false, weatherModel: null);
      final forecast = BasicForecastModel.fromJson({
        'spot_id': base.spotId,
        'available': true,
        'source': 'open-meteo',
        'marine_model': base.marineModel,
        'timezone': base.timezone,
        'utc_offset_seconds': base.utcOffsetSeconds,
        'fetched_at': base.fetchedAt!.toIso8601String(),
        'local_date': base.localDate,
        'days': [
          {'day': base.localDate, 'wave_height_m': 1.7},
        ],
      });
      await _panel(tester, forecast);
      final text = _text(tester);
      expect(find.text('1.7 m'), findsOneWidget);
      expect(find.text('Basic outlook unavailable'), findsNothing);
      expect(text, isNot(matches(RegExp(r'\b0(?:\.0)?\s*kt\b|\bN\b|\b0°'))));
      expect(text, isNot(contains('27.4')));
      expect(text, isNot(contains('05:52')));
      expect(tester.takeException(), isNull);
    },
  );

  _widgetTest(
    'extras reuse one basic request through resize/theme rebuilds and never request protected APIs',
    (tester) async {
      final repository = _Repository(_user());
      final container = await _page(tester, repository);
      expect(find.byType(BasicForecastPanel), findsOneWidget);
      expect(find.byType(ProForecastPanel), findsNothing);
      expect(_text(tester), contains(_weatherModel));
      _expectNoProtectedRequests(repository);
      tester.view.physicalSize = const Size(1440, 1800);
      await _mountPage(tester, container, dark: true);
      await tester.pumpAndSettle();
      expect(_text(tester), contains('05:52'));
      expect(_text(tester), contains(_weatherModel));
      _expectNoProtectedRequests(repository);
    },
  );

  for (final profile in [
    _user(premium: true),
    _user(freeSpot: _spotId),
    _user(verified: false),
  ]) {
    _widgetTest(
      'free extras keep entitlement gates for premium=${profile.premium}, selected=${profile.freeLiveSpotId == _spotId}, verified=${profile.emailVerified}',
      (tester) async {
        final repository = _Repository(profile);
        await _page(tester, repository);
        expect(find.byType(BasicForecastPanel), findsNothing);
        expect(_text(tester), isNot(contains(_weatherModel)));
        expect(repository.basicCalls, 0);
        expect(repository.legacyCalls, 0);
        expect(
          repository.hourlyCalls,
          profile.emailVerified && profile.canAccessLiveForecast(_spotId)
              ? 1
              : 0,
        );
        expect(
          repository.tideCalls,
          profile.emailVerified && profile.canAccessLiveForecast(_spotId)
              ? 1
              : 0,
        );
      },
    );
  }

  _widgetTest('late old-account extras cannot leak after an account switch', (
    tester,
  ) async {
    final pending = Completer<BasicForecastModel>();
    final repository = _Repository(_user())..pending = pending;
    final container = await _page(tester, repository, settle: false);
    repository.pending = null;
    repository.profile = _user(id: 'replacement');
    repository.result = _forecast(
      temperature: 19.8,
      wind: 4.4,
      weatherModel: 'Replacement weather model',
    );
    container.invalidate(meProvider);
    await tester.pumpAndSettle();
    expect(_text(tester), contains('Replacement weather model'));
    pending.complete(_forecast());
    await tester.pumpAndSettle();
    expect(_text(tester), contains('Replacement weather model'));
    expect(_text(tester), isNot(contains(_weatherModel)));
    expect(_text(tester), isNot(matches(RegExp(r'27\.4\s*°C'))));
    _expectNoProtectedRequests(repository, basic: 2);
  });

  _widgetTest(
    'verification revocation immediately removes displayed extras and starts no new forecast request',
    (tester) async {
      final repository = _Repository(_user());
      final container = await _page(tester, repository);
      expect(_text(tester), contains('05:52'));
      container.read(emailVerificationRequiredTokenProvider.notifier).state =
          'blocked-fixture';
      await _pump(tester);
      expect(find.byType(BasicForecastPanel), findsNothing);
      expect(_text(tester), isNot(contains(_weatherModel)));
      _expectNoProtectedRequests(repository);
    },
  );
}
