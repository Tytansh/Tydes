import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart' show meProvider;
import 'package:mobile_flutter/features/social/chat_media_widgets.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/event_chat_page.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

const _postId = 'event-controls-ui';

Map<String, dynamic> _message({bool photo = false}) => {
  'id': 'first-message',
  'post_id': _postId,
  'user_id': 'guest',
  'author_name': 'Surf Guest',
  'author_handle': 'surfguest',
  'text': 'Old surf message',
  'created_at': '2030-01-01T09:00:00Z',
  if (photo) 'attachment': {'id': 'private-photo', 'media_type': 'photo'},
};

class _Repository extends SurfRepository {
  _Repository() : super(Dio(), DemoPersistence());
  @override
  Future<SocialPostModel> fetchSocialPost(String id) async =>
      SocialPostModel.fromJson({
        'id': _postId,
        'user_id': 'owner',
        'author_name': 'Host',
        'author_handle': 'host',
        'post_type': 'surf_plan',
        'visibility': 'public',
        'body': 'Morning surf meetup',
        'media': <Map<String, dynamic>>[],
        'created_at': '2030-01-01T08:00:00Z',
      });
}

class _Fixture {
  _Fixture() {
    api = DirectMessageApi(
      Dio(BaseOptions(baseUrl: 'https://event-controls-ui.fixture.invalid'))
        ..httpClientAdapter = FakeTransport((request) async {
          calls.add(request);
          expect(request.headers['Authorization'], 'Bearer old-test-session');
          if (request.path == '/users/me') return body({'id': 'owner'});
          if (request.path == '/social/posts/$_postId/chat/settings') {
            settingsReads++;
            return body(_settings());
          }
          if (request.path == '/social/posts/$_postId/chat/leave') {
            expect(request.method, 'POST');
            left = true;
            return body(_settings());
          }
          if (request.path == '/social/posts/$_postId/chat/join') {
            expect(request.method, 'POST');
            left = false;
            return body(_settings());
          }
          if (request.path == '/social/posts/$_postId/chat') {
            expect(request.method, 'GET');
            historyReads++;
            final held = holdHistory;
            if (held != null) {
              holdHistory = null;
              return held.future;
            }
            if (left) {
              return body({
                'detail': {
                  'code': 'event_chat_left',
                  'message': 'You left this chat',
                },
              }, 403);
            }
            return body(rows);
          }
          if (request.path == '/messages/media/capabilities') {
            return body({'enabled': false});
          }
          return body({
            'detail': 'No private media provider in UI fixture',
          }, 404);
        }),
      MemorySessions(),
    );
  }
  late final DirectMessageApi api;
  final calls = <RequestOptions>[];
  bool left = false;
  int settingsReads = 0;
  int historyReads = 0;
  List<Map<String, dynamic>> rows = [_message()];
  Completer<ResponseBody>? holdHistory;

  Map<String, dynamic> _settings() => {
    'user_id': 'owner',
    'post_id': _postId,
    'muted': false,
    'left': left,
  };

  int get leaveRequests =>
      calls.where((call) => call.path.endsWith('/chat/leave')).length;
  int get joinRequests =>
      calls.where((call) => call.path.endsWith('/chat/join')).length;

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith(
            (_) async => DemoSeed.me.copyWith(id: 'owner'),
          ),
          surfRepositoryProvider.overrideWithValue(_Repository()),
          directMessageApiProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: EventChatPage(postId: _postId)),
      ),
    );
    await tester.pumpAndSettle();
    expect(settingsReads, 1);
    expect(tester.takeException(), isNull);
  }

  Future<void> showLeaveDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Event chat options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave chat'));
    await tester.pumpAndSettle();
    expect(find.text('Leave event chat?'), findsOneWidget);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }
}

void main() {
  testWidgets(
    'rejoining a freshly opened empty left room loads its event title',
    (tester) async {
      final fixture = _Fixture()
        ..left = true
        ..rows = [];
      await fixture.mount(tester);
      expect(find.text('Morning surf meetup'), findsNothing);
      await tester.tap(find.text('Rejoin chat'));
      await tester.pumpAndSettle();
      expect(find.text('Morning surf meetup'), findsOneWidget);
      expect(fixture.historyReads, 1);
      expect(fixture.settingsReads, 1);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'initial left room offers explicit Rejoin without loading history',
    (tester) async {
      final fixture = _Fixture()..left = true;
      await fixture.mount(tester);
      expect(find.text('You left this event chat.'), findsOneWidget);
      expect(find.text('Your event RSVP has not changed.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(fixture.historyReads, 0);
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(fixture.settingsReads, 1);
      expect(fixture.historyReads, 0);
      await tester.tap(find.text('Rejoin chat'));
      await tester.pumpAndSettle();
      expect(fixture.joinRequests, 1);
      expect(fixture.historyReads, 1);
      expect(find.text('Old surf message'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(fixture.settingsReads, 1);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'cancel leave sends nothing and confirmed Leave/Rejoin retains caption draft',
    (tester) async {
      final fixture = _Fixture();
      await fixture.mount(tester);
      await tester.enterText(find.byType(TextField), 'Unsent surf caption');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      await fixture.showLeaveDialog(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.leaveRequests, 0);
      expect(controller!.text, 'Unsent surf caption');
      await fixture.showLeaveDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Leave chat'));
      await tester.pumpAndSettle();
      expect(fixture.leaveRequests, 1);
      expect(find.text('You left this event chat.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(controller.text, 'Unsent surf caption');
      await tester.tap(find.text('Rejoin chat'));
      await tester.pumpAndSettle();
      expect(fixture.joinRequests, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(controller),
      );
      expect(controller.text, 'Unsent surf caption');
      expect(fixture.calls.any((call) => call.path.contains('rsvp')), isFalse);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'cross-device left 403 hides old messages/media and refreshes settings once',
    (tester) async {
      final fixture = _Fixture()..rows = [_message(photo: true)];
      await fixture.mount(tester);
      expect(find.text('Old surf message'), findsOneWidget);
      expect(find.byType(ChatMediaBubble), findsOneWidget);
      fixture.left = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('You left this event chat.'), findsOneWidget);
      expect(find.text('Old surf message'), findsNothing);
      expect(find.byType(ChatMediaBubble), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(fixture.settingsReads, 2);
      final historyReads = fixture.historyReads;
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(fixture.settingsReads, 2);
      expect(fixture.historyReads, historyReads);
      await tester.tap(find.text('Rejoin chat'));
      await tester.pumpAndSettle();
      expect(find.text('Old surf message'), findsOneWidget);
      expect(fixture.joinRequests, 1);
      await fixture.close(tester);
    },
  );

  testWidgets('queued old history cannot restore content after Leave ACK', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.mount(tester);
    final oldResponse = Completer<ResponseBody>();
    fixture.holdHistory = oldResponse;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(fixture.historyReads, 2);
    await fixture.showLeaveDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Leave chat'));
    await tester.pumpAndSettle();
    expect(find.text('You left this event chat.'), findsOneWidget);
    oldResponse.complete(body([_message(photo: true)]));
    await tester.pumpAndSettle();
    expect(find.text('Old surf message'), findsNothing);
    expect(find.byType(ChatMediaBubble), findsNothing);
    fixture.rows = [];
    await tester.tap(find.text('Rejoin chat'));
    await tester.pumpAndSettle();
    expect(
      find.text('You’re in. Start the conversation with everyone going.'),
      findsOneWidget,
    );
    expect(find.text('Old surf message'), findsNothing);
    await fixture.close(tester);
  });
}
