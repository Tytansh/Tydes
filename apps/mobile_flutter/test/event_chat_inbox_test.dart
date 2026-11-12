import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/features/home/home_page.dart' show meProvider;
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/event_chat_page.dart';

void main() {
  testWidgets('joined event group chats appear in Messages', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith((_) async => DemoSeed.me),
          directMessageThreadsProvider.overrideWith(
            (_) => DirectMessageThreadsNotifier.testing([]),
          ),
          joinedEventChatsProvider.overrideWith(
            (_) async => [
              JoinedEventChatSummary(
                postId: 'post_event',
                title: 'Surf with us!',
                hostName: 'Ford',
                meetupDate: '2026-11-01',
                sortDate: DateTime(2026, 11, 1),
              ),
            ],
          ),
        ],
        child: const MaterialApp(home: DirectMessagesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Event chats'), findsOneWidget);
    expect(find.text('Surf with us!'), findsOneWidget);
    expect(find.text('Event group chat • Ford'), findsOneWidget);
    expect(find.text('Nov 1'), findsOneWidget);
  });

  testWidgets('joining an event offers the group chat popup', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showEventChatJoinPrompt(
                  context,
                  postId: 'post_event',
                  eventTitle: 'Surf with us!',
                ),
                child: const Text('Join event'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Join event'));
    await tester.pumpAndSettle();

    expect(find.text('Join the event group chat?'), findsOneWidget);
    expect(find.text('Join group chat'), findsOneWidget);
    expect(find.text('Maybe later'), findsOneWidget);
  });
}
