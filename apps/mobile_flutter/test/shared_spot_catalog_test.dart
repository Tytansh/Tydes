import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_error_message.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/public_preview_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/auth/auth_account_refresh.dart';
import 'package:mobile_flutter/features/guest/guest_explore_page.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart'
    show travelFeedSpotsProvider;
import 'package:mobile_flutter/features/spots/spots_page.dart';
import 'package:mobile_flutter/features/trips/trips_page.dart';

import 'auth_session_test.dart' show MemorySessions;

final _catalogs = {
  'Feed': travelFeedSpotsProvider,
  'Spots': spotsProvider,
  'Travel': travelSpotsProvider,
};

class _CatalogRepository extends SurfRepository {
  _CatalogRepository() : super(Dio(), MemorySessions());
  int calls = 0;
  int publicCalls = 0;
  bool verificationRequired = false;
  Completer<List<SpotModel>>? pending;
  List<SpotModel> records = [DemoSeed.spots.first];

  @override
  Future<List<SpotModel>> fetchSpots() async {
    calls++;
    if (verificationRequired) throw EmailVerificationRequiredException();
    return pending?.future ?? records;
  }

  @override
  Future<List<PublicMapSpotPreview>> fetchPublicSpots() async {
    publicCalls++;
    return [];
  }
}

ProviderContainer _container(_CatalogRepository repository) =>
    ProviderContainer(
      overrides: [surfRepositoryProvider.overrideWithValue(repository)],
    );

void main() {
  test('three cold tab reads share one catalog download and decode', () async {
    final repository = _CatalogRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    final results = await Future.wait([
      for (final catalog in _catalogs.values) container.read(catalog.future),
    ]);
    expect(repository.calls, 1);
    expect(results[1], same(results[0]));
    expect(results[2], same(results[0]));
  });

  for (final entry in _catalogs.entries) {
    test(
      '${entry.key} refresh invalidates the shared catalog for all tabs',
      () async {
        final repository = _CatalogRepository();
        final container = _container(repository);
        addTearDown(container.dispose);
        final original = await container.read(travelFeedSpotsProvider.future);
        repository.records = [DemoSeed.spots.last];
        container.invalidate(entry.value);
        final results = await Future.wait([
          for (final catalog in _catalogs.values)
            container.read(catalog.future),
        ]);
        expect(repository.calls, 2);
        expect(results.first, isNot(same(original)));
        expect(results.first.single.id, DemoSeed.spots.last.id);
        expect(results[1], same(results[0]));
        expect(results[2], same(results[0]));
      },
    );
  }

  test(
    'verification errors stay errors and explicit refresh can retry',
    () async {
      final repository = _CatalogRepository()..verificationRequired = true;
      final container = _container(repository);
      addTearDown(container.dispose);
      await expectLater(
        Future.wait([
          for (final catalog in _catalogs.values)
            container.read(catalog.future),
        ]),
        throwsA(isA<EmailVerificationRequiredException>()),
      );
      expect(repository.calls, 1);
      expect(repository.publicCalls, 0);
      repository.verificationRequired = false;
      container.invalidate(spotsProvider);
      expect(await container.read(travelSpotsProvider.future), isNotEmpty);
      expect(repository.calls, 2);
    },
  );

  test('ordinary profile refresh does not fetch the catalog again', () async {
    final repository = _CatalogRepository();
    final container = ProviderContainer(
      overrides: [
        surfRepositoryProvider.overrideWithValue(repository),
        meProvider.overrideWith((_) async => DemoSeed.me),
      ],
    );
    addTearDown(container.dispose);
    await container.read(meProvider.future);
    await container.read(spotsProvider.future);
    container.invalidate(meProvider);
    await container.read(meProvider.future);
    await container.read(travelSpotsProvider.future);
    expect(repository.calls, 1);
  });

  test('verification transition rejects an already cached catalog', () async {
    final repository = _CatalogRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await container.read(spotsProvider.future);
    repository.verificationRequired = true;
    container.read(accountVerificationRefreshKeyProvider.notifier).state++;
    await expectLater(
      container.read(travelSpotsProvider.future),
      throwsA(isA<EmailVerificationRequiredException>()),
    );
    expect(repository.calls, 2);
    expect(repository.publicCalls, 0);
  });

  test(
    'guest catalog remains independent and uses only the public endpoint',
    () async {
      final repository = _CatalogRepository();
      final container = _container(repository);
      addTearDown(container.dispose);
      expect(await container.read(guestSpotsProvider.future), isEmpty);
      expect(repository.publicCalls, 1);
      expect(repository.calls, 0);
      await container.read(travelSpotsProvider.future);
      expect(repository.calls, 1);
      expect(await container.read(guestSpotsProvider.future), isEmpty);
      expect(repository.publicCalls, 1);
    },
  );

  testWidgets('account reset ignores an old in-flight catalog response', (
    tester,
  ) async {
    final old = Completer<List<SpotModel>>();
    final repository = _CatalogRepository()..pending = old;
    final container = _container(repository);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final catalog = ref.watch(travelSpotsProvider);
              return Column(
                children: [
                  Text(catalog.valueOrNull?.single.name ?? 'Loading catalog'),
                  TextButton(
                    onPressed: () => refreshAuthenticatedAccount(ref),
                    child: const Text('Reset account'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(repository.calls, 1);
    repository.pending = null;
    repository.records = [DemoSeed.spots.last];
    await tester.tap(find.text('Reset account'));
    await tester.pumpAndSettle();
    expect(repository.calls, 2);
    expect(find.text(DemoSeed.spots.last.name), findsOneWidget);
    old.complete([DemoSeed.spots.first]);
    await tester.pumpAndSettle();
    expect(find.text(DemoSeed.spots.last.name), findsOneWidget);
    for (final catalog in _catalogs.values) {
      expect(
        (await container.read(catalog.future)).single.id,
        DemoSeed.spots.last.id,
      );
    }
    expect(repository.calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
