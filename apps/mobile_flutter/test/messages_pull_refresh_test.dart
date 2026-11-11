import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/widgets/feed_refresh_indicator.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

const _spinner = ValueKey('feed-top-refresh-spinner');

class _MemoryThreads extends DemoPersistence {
  _MemoryThreads({this.empty = false});
  final bool empty;
  int reads = 0;
  int writes = 0;

  @override
  Future<List<Map<String, dynamic>>> loadDirectMessageThreadPayloads() async {
    reads++;
    return empty
        ? []
        : [
            const DirectMessageThread(
              id: 'milo',
              profileUserId: 'milo-user',
              name: 'Milo',
              handle: 'milo',
              initial: 'M',
              location: 'Bali',
              preview: 'Existing local message',
              time: 'Now',
              unreadCount: 2,
              online: false,
              requestAccepted: true,
              messages: [],
            ).toJson(),
          ];
  }

  @override
  Future<void> saveDirectMessageThreadPayloads(
    List<Map<String, dynamic>> threads,
  ) async {
    writes++;
  }
}

JoinedEventChatSummary _event(String title) => JoinedEventChatSummary(
  postId: title,
  title: title,
  hostName: 'Milo',
  meetupDate: '2030-11-12',
  sortDate: DateTime(2030, 11, 12),
);

Future<ProviderContainer> _show(
  WidgetTester tester, {
  required _MemoryThreads memory,
  required Future<List<JoinedEventChatSummary>> Function() events,
  required Future<void> Function() relationships,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      demoPersistenceProvider.overrideWithValue(memory),
      joinedEventChatsProvider.overrideWith((_) => events()),
      socialRelationshipHydrationProvider.overrideWith((_) => relationships()),
      meProvider.overrideWith((_) => throw StateError('Must not refresh auth')),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: DirectMessagesPage()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _touchPull(WidgetTester tester) async {
  final pull = await tester.startGesture(
    tester.getTopLeft(find.byType(ListView)) + const Offset(100, 350),
  );
  for (final distance in [125.0, 125.0, 125.0, 125.0]) {
    await pull.moveBy(Offset(0, distance));
    await tester.pump();
  }
  await pull.up();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _wheel(WidgetTester tester, Offset delta) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(find.byType(ListView)),
      scrollDelta: delta,
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'Messages touch refresh preserves threads, event cards and search',
    (tester) async {
      final memory = _MemoryThreads();
      final pending = Completer<List<JoinedEventChatSummary>>();
      var reads = 0;
      var relationshipReads = 0;
      final container = await _show(
        tester,
        memory: memory,
        events: () => ++reads == 1
            ? Future.value([_event('Milo sunrise surf')])
            : pending.future,
        relationships: () async => relationshipReads++,
      );
      await tester.enterText(find.byType(TextField), 'Milo');
      await tester.pump();
      final originalEvent = tester.element(find.text('Milo sunrise surf'));
      final originalThread = tester.element(
        find.text('Existing local message'),
      );
      final notifier = container.read(directMessageThreadsProvider.notifier);
      final localThreads = container.read(directMessageThreadsProvider);
      await _touchPull(tester);
      expect(reads, 2);
      expect(relationshipReads, 1);
      expect(find.byKey(_spinner), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        tester.element(find.text('Milo sunrise surf')),
        same(originalEvent),
      );
      expect(
        tester.element(find.text('Existing local message')),
        same(originalThread),
      );
      expect(
        container.read(directMessageThreadsProvider.notifier),
        same(notifier),
      );
      expect(container.read(directMessageThreadsProvider), same(localThreads));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Milo',
      );
      expect(memory.reads, 1);
      expect(memory.writes, 0);
      pending.complete([_event('Milo new event')]);
      await tester.pumpAndSettle();
      expect(find.byKey(_spinner), findsNothing);
      expect(find.text('Milo new event'), findsOneWidget);
      expect(find.text('Existing local message'), findsOneWidget);
      expect(find.textContaining('Loading your account'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty Messages inbox uses one wheel refresh and ignores clicks/horizontal motion',
    (tester) async {
      final pending = Completer<List<JoinedEventChatSummary>>();
      var reads = 0;
      await _show(
        tester,
        memory: _MemoryThreads(empty: true),
        events: () => ++reads == 1 ? Future.value([]) : pending.future,
        relationships: () async {},
      );
      expect(find.byType(FeedRefreshIndicator), findsOneWidget);
      expect(
        tester.widget<ListView>(find.byType(ListView)).physics,
        isA<AlwaysScrollableScrollPhysics>(),
      );
      final click = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
        kind: PointerDeviceKind.mouse,
      );
      await click.up();
      await tester.pumpAndSettle();
      await _wheel(tester, const Offset(-200, 0));
      expect(reads, 1);
      expect(find.byKey(_spinner), findsNothing);
      await _wheel(tester, const Offset(0, -140));
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 2);
      expect(find.byKey(_spinner), findsOneWidget);
      await _wheel(tester, const Offset(0, -300));
      expect(reads, 2);
      final spinner = tester.getRect(find.byKey(_spinner));
      expect(
        spinner.bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(ListView)).top),
      );
      await _wheel(tester, const Offset(0, 80));
      expect(find.byKey(_spinner), findsNothing);
      pending.complete([]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed Messages refresh keeps existing content and supports Retry',
    (tester) async {
      final pending = Completer<List<JoinedEventChatSummary>>();
      var reads = 0;
      await _show(
        tester,
        memory: _MemoryThreads(),
        events: () {
          reads++;
          if (reads == 1) return Future.value([_event('Milo sunrise surf')]);
          if (reads == 2) return pending.future;
          return Future.value([_event('Milo retry event')]);
        },
        relationships: () async {},
      );
      await _touchPull(tester);
      pending.completeError(StateError('Offline'));
      await tester.pumpAndSettle();
      expect(find.byKey(_spinner), findsNothing);
      expect(find.text('Existing local message'), findsOneWidget);
      expect(find.text('Milo sunrise surf'), findsOneWidget);
      expect(find.text('Could not refresh. Try again.'), findsOneWidget);
      expect(find.text('Could not load event chats'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(find.text('Milo retry event'), findsOneWidget);
      expect(find.text('Existing local message'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
