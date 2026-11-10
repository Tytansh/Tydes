import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app/app.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/public_preview_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/notifications/notification_service.dart';
import 'package:mobile_flutter/features/guest/guest_explore_page.dart';
import 'package:mobile_flutter/features/home/home_page.dart';

Map<String, dynamic> _spot(
  String id,
  String name,
  String country,
  String region,
  String area,
) => {
  'id': id,
  'name': name,
  'country': country,
  'region': region,
  'area': area,
  'summary': 'Public spot guide for $name.',
  'difficulty': 'intermediate',
  'best_months': ['May'],
  'latitude': -8.5,
  'longitude': 115.1,
};
final _spots = [
  _spot('batu', 'Batu Bolong', 'Indonesia', 'Bali', 'Canggu'),
  _spot('uluwatu', 'Uluwatu Peak', 'Indonesia', 'Bali', 'Uluwatu'),
  _spot('bondi', 'Bondi', 'Australia', 'New South Wales', 'Sydney'),
];
final _event = {
  'id': 'sunset',
  'body': 'Sunset surf together',
  'meetup_date': '2026-11-20',
  'meetup_end_date': null,
  'ended': false,
  'host': {'name': 'Maya Surfer', 'handle': 'maya', 'avatar_url': null},
  'spot': _spots.first,
};

class _NoSession extends DemoPersistence {
  @override
  Future<String?> loadAccessToken() async => null;
}

class _Notifications extends NotificationService {
  int initializations = 0;
  @override
  Future<bool> initialize() async {
    initializations++;
    return true;
  }
}

class _PublicTransport implements HttpClientAdapter {
  final requests = <String>[];
  bool failEvents = false;
  bool emptyEvents = false;
  bool emptySpots = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options.path);
    final Object data;
    var status = 200;
    if (options.path == '/public/spots') {
      data = emptySpots ? [] : _spots;
    } else if (options.path == '/public/events') {
      data = failEvents
          ? {'detail': 'Try again soon'}
          : emptyEvents
          ? []
          : [_event];
      if (failEvents) status = 503;
    } else if (options.path.startsWith('/public/spots/')) {
      data = _spots.firstWhere((s) => s['id'] == options.path.split('/').last);
    } else if (options.path == '/public/events/sunset') {
      data = _event;
    } else {
      throw StateError('Guest requested private endpoint ${options.path}');
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _show(
  WidgetTester tester,
  _PublicTransport transport,
  String path,
  _Notifications notifications, [
  bool signedIn = false,
]) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
    ..httpClientAdapter = transport;
  var started = false;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        surfRepositoryProvider.overrideWithValue(
          SurfRepository(dio, _NoSession()),
        ),
        notificationServiceProvider.overrideWithValue(notifications),
        if (signedIn)
          meProvider.overrideWith(
            (_) async => DemoSeed.me.copyWith(
              displayName: 'Surfer',
              handle: 'surfer',
              surfSkill: 'intermediate',
            ),
          ),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          if (!started) {
            ref.read(appRouterProvider).go(path);
            started = true;
          }
          return const SurfTravelApp();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(SurfTravelApp)));
}

void main() {
  testWidgets(
    'guest browsing pauses notifications even with an existing account',
    (tester) async {
      final transport = _PublicTransport();
      final notifications = _Notifications();
      await _show(tester, transport, '/explore', notifications, true);
      expect(notifications.initializations, 0);
      expect(transport.requests, ['/public/spots']);
    },
  );
  test(
    'guest filters cover countries, regions, areas and public event hosts',
    () {
      final spot = PublicMapSpotPreview.fromJson(_spots.first);
      expect(
        guestSpotMatches(
          spot,
          country: 'Indonesia',
          region: 'Bali',
          query: 'canggu',
        ),
        isTrue,
      );
      expect(guestSpotMatches(spot, country: 'Australia'), isFalse);
      final event = PublicEventPreview.fromJson(_event);
      expect(
        guestEventMatches(
          event,
          country: 'Indonesia',
          region: 'Bali',
          query: 'maya',
        ),
        isTrue,
      );
      expect(guestEventMatches(event, region: 'Lombok'), isFalse);
      expect(
        guestEventMatches(
          PublicEventPreview.fromJson({..._event, 'ended': true}),
        ),
        isFalse,
      );
    },
  );

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'guest spots load only public API and no notifications at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1050);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final transport = _PublicTransport();
        final notifications = _Notifications();
        await _show(tester, transport, '/explore', notifications);
        expect(find.text('Batu Bolong'), findsOneWidget);
        expect(find.text('Bondi'), findsOneWidget);
        expect(transport.requests, ['/public/spots']);
        expect(notifications.initializations, 0);
        expect(find.text('Feed'), findsNothing);
        expect(find.text('Alerts'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField), 'Canggu');
        await tester.pumpAndSettle();
        expect(find.text('Batu Bolong'), findsOneWidget);
        expect(find.text('Bondi'), findsNothing);
        expect(transport.requests, ['/public/spots']);
      },
    );
  }

  testWidgets('guest can open a spot then sign in without losing its link', (
    tester,
  ) async {
    final transport = _PublicTransport();
    final container = await _show(
      tester,
      transport,
      '/explore',
      _Notifications(),
    );
    await tester.tap(find.text('Batu Bolong'));
    await tester.pumpAndSettle();
    expect(find.text('About this break'), findsOneWidget);
    expect(transport.requests, ['/public/spots', '/public/spots/batu']);
    await tester.ensureVisible(find.text('Sign in to explore this spot'));
    await tester.tap(find.text('Sign in to explore this spot'));
    await tester.pumpAndSettle();
    expect(
      container
          .read(appRouterProvider)
          .routeInformationProvider
          .value
          .uri
          .queryParameters['next'],
      '/spot/batu',
    );
    await tester.ensureVisible(find.text('Explore as guest'));
    await tester.tap(find.text('Explore as guest'));
    await tester.pumpAndSettle();
    expect(find.text('About this break'), findsOneWidget);
    expect(transport.requests.every((p) => p.startsWith('/public/')), isTrue);
  });

  testWidgets('guest sees events and opens a preview, not attendees or chat', (
    tester,
  ) async {
    final transport = _PublicTransport();
    await _show(tester, transport, '/explore/events', _Notifications());
    expect(find.text('Sunset surf together'), findsOneWidget);
    expect(transport.requests.toSet(), {'/public/spots', '/public/events'});
    await tester.ensureVisible(find.text('Sunset surf together'));
    await tester.tap(find.text('Sunset surf together'));
    await tester.pumpAndSettle();
    expect(find.text('Hosted by Maya Surfer'), findsOneWidget);
    expect(find.text('Join now'), findsNothing);
    expect(transport.requests.last, '/public/events/sunset');
  });

  testWidgets('empty guest event list has no fabricated events', (
    tester,
  ) async {
    final transport = _PublicTransport()..emptyEvents = true;
    await _show(tester, transport, '/explore/events', _Notifications());
    expect(
      find.text(
        'No upcoming public events here yet. Try another place or check back soon.',
      ),
      findsOneWidget,
    );
    expect(find.text('Sunset surf together'), findsNothing);
  });

  testWidgets('failed event read offers retry instead of fake success', (
    tester,
  ) async {
    final transport = _PublicTransport()..failEvents = true;
    await _show(tester, transport, '/explore/events', _Notifications());
    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.text(
        'No upcoming public events here yet. Try another place or check back soon.',
      ),
      findsNothing,
    );
    transport.failEvents = false;
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Sunset surf together'), findsOneWidget);
  });

  testWidgets(
    'direct guest map link does not require login or request private data',
    (tester) async {
      final transport = _PublicTransport()..emptySpots = true;
      final notifications = _Notifications();
      await _show(tester, transport, '/explore/map', notifications);
      expect(
        find.text('No spots match. Try another place or clear your filters.'),
        findsOneWidget,
      );
      expect(notifications.initializations, 0);
      expect(transport.requests, ['/public/spots']);
    },
  );
}
