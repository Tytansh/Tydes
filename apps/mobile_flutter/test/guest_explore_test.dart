import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
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
  'latitude': country == 'Australia'
      ? -33.9
      : id == 'batu'
      ? -8.65
      : -8.82,
  'longitude': country == 'Australia' ? 151.2 : 115.13,
};
final _spots = [
  _spot('batu', 'Batu Bolong', 'Indonesia', 'Bali', 'Canggu'),
  _spot('uluwatu', 'Uluwatu Peak', 'Indonesia', 'Bali', 'Uluwatu'),
  _spot('bondi', 'Bondi', 'Australia', 'New South Wales', 'Sydney'),
  _spot('spot_padang_padang', 'Padang Padang', 'Indonesia', 'Bali', 'Uluwatu'),
  _spot('desert', 'Desert Point', 'Indonesia', 'Lombok', 'Sekotong'),
];
final _event = {
  'id': 'sunset',
  'body': 'Sunset surf together',
  'meetup_date': DateTime.now()
      .add(const Duration(days: 2))
      .toIso8601String()
      .substring(0, 10),
  'meetup_end_date': null,
  'ended': false,
  'host': {'name': 'Maya Surfer', 'handle': 'maya', 'avatar_url': null},
  'spot': _spots.first,
};

class _NoSession extends DemoPersistence {
  @override
  Future<String?> loadAccessToken() async => null;
}

class _MemoryTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
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
        guestTileProviderFactory.overrideWithValue(_MemoryTiles.new),
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
  test(
    'event grouping excludes ended, undated, unknown and invalid locations',
    () {
      final now = DateTime.now();
      final today = DateUtils.dateOnly(now).toIso8601String().substring(0, 10);
      final yesterday = now
          .subtract(const Duration(days: 1))
          .toIso8601String()
          .substring(0, 10);
      final groups = buildGuestEventGroups(
        spots: _spots.map(PublicMapSpotPreview.fromJson).toList(),
        now: now,
        events: [
          PublicEventPreview.fromJson(_event),
          PublicEventPreview.fromJson({
            ..._event,
            'id': 'ongoing',
            'meetup_date': yesterday,
            'meetup_end_date': today,
          }),
          PublicEventPreview.fromJson({
            ..._event,
            'id': 'ended',
            'ended': true,
          }),
          PublicEventPreview.fromJson({
            ..._event,
            'id': 'expired',
            'meetup_date': yesterday,
          }),
          PublicEventPreview.fromJson({
            ..._event,
            'id': 'undated',
            'meetup_date': null,
          }),
          PublicEventPreview.fromJson({
            ..._event,
            'id': 'unknown',
            'spot': _spot('missing', 'Unknown', 'Indonesia', 'Bali', 'Canggu'),
          }),
        ],
      );
      expect(groups, hasLength(1));
      expect(groups.single.events.map((e) => e.id), ['ongoing', 'sunset']);
      expect(
        buildGuestEventGroups(
          spots: [],
          events: [PublicEventPreview.fromJson(_event)],
          now: now,
        ),
        isEmpty,
      );
      expect(
        buildGuestEventGroups(
          spots: _spots.map(PublicMapSpotPreview.fromJson).toList(),
          events: [PublicEventPreview.fromJson(_event)],
          now: now,
          country: 'Australia',
        ),
        isEmpty,
      );
    },
  );

  test('public map search matches place, region and event host', () {
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
    expect(
      guestEventMatches(PublicEventPreview.fromJson(_event), query: 'maya'),
      isTrue,
    );
  });

  test(
    'popular list uses only existing editorial picks; scoped lists keep every match',
    () {
      final catalog = [
        ..._spots.map(PublicMapSpotPreview.fromJson),
        PublicMapSpotPreview.fromJson(
          _spot(
            'spot_surfers_point',
            'Surfers Point',
            'Australia',
            'Western Australia',
            'Margaret River',
          ),
        ),
        PublicMapSpotPreview.fromJson(
          _spot(
            'spot_siargao',
            'Cloud 9',
            'Philippines',
            'Siargao',
            'General Luna',
          ),
        ),
      ];
      expect(guestBrowseSpots(catalog, popularOnly: true).map((s) => s.id), [
        'spot_padang_padang',
        'spot_surfers_point',
        'spot_siargao',
      ]);
      final indonesia = catalog
          .where((s) => guestSpotMatches(s, country: 'Indonesia'))
          .toList();
      expect(
        guestBrowseSpots(indonesia, popularOnly: false).map((s) => s.name),
        ['Padang Padang', 'Batu Bolong', 'Desert Point', 'Uluwatu Peak'],
      );
      final bali = indonesia
          .where((s) => guestSpotMatches(s, region: 'Bali'))
          .toList();
      expect(guestBrowseSpots(bali, popularOnly: false).map((s) => s.name), [
        'Padang Padang',
        'Batu Bolong',
        'Uluwatu Peak',
      ]);
      expect(guestBrowseSpots([], popularOnly: true), isEmpty);
    },
  );

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'popular spots appear below map and country/region filters update the list at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final transport = _PublicTransport();
        await _show(tester, transport, '/explore', _Notifications());
        await tester.ensureVisible(find.text('Popular spots'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('guest-list-spot_padang_padang')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('guest-list-batu')), findsNothing);
        await tester.ensureVisible(find.byType(Switch));
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Indonesia').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<String>).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bali').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Spots in Bali'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('guest-list-spot_padang_padang')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('guest-list-bondi')), findsNothing);
        expect(find.byKey(const ValueKey('guest-list-desert')), findsNothing);
        expect(transport.requests.toSet(), {'/public/spots', '/public/events'});
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a beach list card opens the public spot guide without signing in',
    (tester) async {
      final transport = _PublicTransport();
      await _show(tester, transport, '/explore', _Notifications());
      final card = find.byKey(const ValueKey('guest-list-spot_padang_padang'));
      await tester.dragFrom(const Offset(4, 300), const Offset(0, -450));
      await tester.pumpAndSettle();
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text('About this break'), findsOneWidget);
      expect(transport.requests.last, '/public/spots/spot_padang_padang');
      expect(transport.requests.every((p) => p.startsWith('/public/')), isTrue);
    },
  );

  testWidgets('short narrow screens can scroll from map to the beach list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _PublicTransport();
    await _show(tester, transport, '/explore', _Notifications());
    await tester.dragFrom(const Offset(4, 300), const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('guest-list-spot_padang_padang')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final path in ['/explore', '/explore/map', '/explore/events']) {
    testWidgets('$path enters one map with events switched on', (tester) async {
      final transport = _PublicTransport();
      final notifications = _Notifications();
      final container = await _show(tester, transport, path, notifications);
      expect(
        container
            .read(appRouterProvider)
            .routeInformationProvider
            .value
            .uri
            .path,
        '/explore',
      );
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.byType(GuestMapCanvas), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('guest-event-batu')), findsOneWidget);
      expect(transport.requests.toSet(), {'/public/spots', '/public/events'});
      expect(notifications.initializations, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final next in [
    '/spot/bondi',
    '/post/sunset',
    '/explore/events',
    '/spots-map',
  ]) {
    testWidgets(
      'Explore as guest ignores the sign-in return destination $next',
      (tester) async {
        final transport = _PublicTransport();
        final container = await _show(
          tester,
          transport,
          Uri(path: '/login', queryParameters: {'next': next}).toString(),
          _Notifications(),
        );
        final guest = find.byKey(const ValueKey('explore-as-guest'));
        await tester.ensureVisible(guest);
        await tester.tap(guest);
        await tester.pumpAndSettle();
        expect(
          container
              .read(appRouterProvider)
              .routeInformationProvider
              .value
              .uri
              .path,
          '/explore',
        );
        expect(find.byType(GuestMapCanvas), findsOneWidget);
        expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
        expect(transport.requests.toSet(), {'/public/spots', '/public/events'});
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'returning through sign in restarts the guest map and clears old filters at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final transport = _PublicTransport();
        final container = await _show(
          tester,
          transport,
          '/explore',
          _Notifications(),
        );
        await tester.tap(find.byType(Switch));
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Australia').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Spots in Australia'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('guest-list-bondi')));
        await tester.pumpAndSettle();
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
          '/spot/bondi',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('explore-as-guest')),
        );
        await tester.tap(find.byKey(const ValueKey('explore-as-guest')));
        await tester.pumpAndSettle();
        expect(
          container
              .read(appRouterProvider)
              .routeInformationProvider
              .value
              .uri
              .path,
          '/explore',
        );
        expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
        expect(
          tester.widget<GuestMapCanvas>(find.byType(GuestMapCanvas)).spots,
          hasLength(_spots.length),
        );
        final page = tester.widget<CustomScrollView>(
          find.byKey(const ValueKey('guest-explore-scroll')),
        );
        expect(page.controller!.offset, 0);
        expect(find.text('All countries'), findsOneWidget);
        expect(find.text('All regions'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'events can toggle without losing spots or fetching private data at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final transport = _PublicTransport();
        await _show(tester, transport, '/explore', _Notifications());
        expect(find.byType(GuestEventMarker), findsOneWidget);
        final requests = transport.requests.length;
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(find.byType(GuestEventMarker), findsNothing);
        expect(find.byKey(const ValueKey('guest-spot-batu')), findsOneWidget);
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(find.byType(GuestEventMarker), findsOneWidget);
        expect(transport.requests.length, requests);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'event marker opens public popup and join requires sign-in at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final transport = _PublicTransport();
        final container = await _show(
          tester,
          transport,
          '/explore',
          _Notifications(),
        );
        await tester.tap(find.byKey(const ValueKey('guest-event-batu')));
        await tester.pumpAndSettle();
        expect(find.byType(GuestEventPopup), findsOneWidget);
        expect(find.text('Maya Surfer'), findsOneWidget);
        expect(find.text('Sunset surf together'), findsOneWidget);
        expect(find.text('View event'), findsOneWidget);
        expect(transport.requests.toSet(), {'/public/spots', '/public/events'});
        await tester.ensureVisible(find.text('Sign in to join'));
        await tester.tap(find.text('Sign in to join'));
        await tester.pumpAndSettle();
        expect(
          container
              .read(appRouterProvider)
              .routeInformationProvider
              .value
              .uri
              .queryParameters['next'],
          '/post/sunset',
        );
        expect(
          transport.requests.every((p) => p.startsWith('/public/')),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('view event opens its public detail page without signing in', (
    tester,
  ) async {
    final transport = _PublicTransport();
    await _show(tester, transport, '/explore', _Notifications());
    await tester.tap(find.byKey(const ValueKey('guest-event-batu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View event'));
    await tester.pumpAndSettle();
    expect(find.text('Hosted by Maya Surfer'), findsOneWidget);
    expect(transport.requests.last, '/public/events/sunset');
  });

  testWidgets('spot guide still opens from map with events hidden', (
    tester,
  ) async {
    final transport = _PublicTransport();
    await _show(tester, transport, '/explore', _Notifications());
    await tester.tap(find.byType(Switch));
    await tester.enterText(find.byType(TextField), 'Canggu');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guest-spot-batu')));
    await tester.pumpAndSettle();
    expect(find.text('About this break'), findsOneWidget);
    expect(transport.requests.last, '/public/spots/batu');
  });

  testWidgets('host search filters the map without additional API requests', (
    tester,
  ) async {
    final transport = _PublicTransport();
    await _show(tester, transport, '/explore', _Notifications());
    await tester.enterText(find.byType(TextField), 'maya');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GuestMapCanvas>(find.byType(GuestMapCanvas))
          .spots
          .single
          .name,
      'Batu Bolong',
    );
    expect(find.byType(GuestEventMarker), findsOneWidget);
    expect(transport.requests.toSet(), {'/public/spots', '/public/events'});
  });

  testWidgets('failed event read keeps spot map usable and retry is honest', (
    tester,
  ) async {
    final transport = _PublicTransport()..failEvents = true;
    await _show(tester, transport, '/explore', _Notifications());
    expect(find.byType(GuestMapCanvas), findsOneWidget);
    expect(find.byType(GuestEventMarker), findsNothing);
    expect(find.text('Retry events'), findsOneWidget);
    expect(
      find.text(
        'No upcoming public events yet. Only public events with a date and mapped spot appear here.',
      ),
      findsNothing,
    );
    transport.failEvents = false;
    await tester.tap(find.text('Retry events'));
    await tester.pumpAndSettle();
    expect(find.byType(GuestEventMarker), findsOneWidget);
  });

  testWidgets('no public events keeps map, switch and real empty state', (
    tester,
  ) async {
    final transport = _PublicTransport()..emptyEvents = true;
    await _show(tester, transport, '/explore', _Notifications());
    expect(find.byType(GuestMapCanvas), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.text(
        'No upcoming public events yet. Only public events with a date and mapped spot appear here.',
      ),
      findsOneWidget,
    );
    expect(find.byType(GuestEventMarker), findsNothing);
  });

  testWidgets('empty catalog has no fabricated spots', (tester) async {
    await _show(
      tester,
      _PublicTransport()..emptySpots = true,
      '/explore',
      _Notifications(),
    );
    expect(find.byType(GuestMapCanvas), findsNothing);
    expect(
      find.text(
        'No mapped spots match. Try another place or clear your filters.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'guest account never starts notifications even when already signed in',
    (tester) async {
      final notifications = _Notifications();
      final transport = _PublicTransport();
      await _show(tester, transport, '/explore', notifications, true);
      expect(notifications.initializations, 0);
      expect(transport.requests.every((p) => p.startsWith('/public/')), isTrue);
    },
  );

  testWidgets('scrolling the mouse wheel over the map reaches the beach list', (
    tester,
  ) async {
    final transport = _PublicTransport();
    await _show(tester, transport, '/explore', _Notifications());
    final scroll = tester
        .widget<CustomScrollView>(
          find.byKey(const ValueKey('guest-explore-scroll')),
        )
        .controller!;
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(
      map.options.interactionOptions.flags & InteractiveFlag.scrollWheelZoom,
      0,
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(FlutterMap)),
        scrollDelta: const Offset(0, 500),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(
      find.byKey(const ValueKey('guest-list-spot_padang_padang')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
