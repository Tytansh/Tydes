import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/social_feed_page.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/feed_pagination.dart';

void main() {
  testWidgets(
    'only a nearby vertical outer scroll starts one next-page request',
    (tester) async {
      final pending = Completer<SocialFeedPage>();
      final calls = <String?>[];
      final controller = FeedPaginationController(
        accountId: 'viewer',
        loadPage: (cursor) {
          calls.add(cursor);
          return cursor == null
              ? Future.value(
                  const SocialFeedPage(items: [], nextCursor: 'next'),
                )
              : pending.future;
        },
      );
      await controller.refreshInitial();
      final container = ProviderContainer(
        overrides: [feedPaginationProvider.overrideWith((_) => controller)],
      );
      addTearDown(container.dispose);
      final outer = ScrollController();
      final horizontal = ScrollController();
      final nested = ScrollController();
      addTearDown(outer.dispose);
      addTearDown(horizontal.dispose);
      addTearDown(nested.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: FeedPaginationScrollListener(
                child: ListView(
                  controller: outer,
                  children: [
                    const Text('Existing feed'),
                    SizedBox(
                      height: 150,
                      child: ListView(
                        controller: horizontal,
                        scrollDirection: Axis.horizontal,
                        children: const [SizedBox(width: 3000)],
                      ),
                    ),
                    SizedBox(
                      height: 150,
                      child: ListView(
                        controller: nested,
                        children: const [SizedBox(height: 3000)],
                      ),
                    ),
                    const SizedBox(height: 3000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(controller.state.canLoadMore, isTrue);
      expect(container.read(feedPaginationProvider).canLoadMore, isTrue);
      horizontal.jumpTo(horizontal.position.maxScrollExtent - 100);
      nested.jumpTo(nested.position.maxScrollExtent - 100);
      outer.jumpTo(400);
      await tester.pump();
      await tester.pump();
      expect(calls, [null]);
      outer.jumpTo(0);
      await tester.pump();
      expect(calls, [null]);
      outer.jumpTo(outer.position.maxScrollExtent - 500);
      await tester.pump();
      await tester.pump();
      expect(calls, [null, 'next']);
      outer.jumpTo(outer.position.maxScrollExtent - 300);
      await tester.pump();
      expect(calls, [null, 'next']);
      pending.complete(const SocialFeedPage(items: []));
      await tester.pumpAndSettle();
      outer.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Existing feed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
