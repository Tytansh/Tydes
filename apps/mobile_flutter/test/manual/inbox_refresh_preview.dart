// Local visual QA only. Never publish a build using this entrypoint.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/inbox_badges.dart';
import 'package:mobile_flutter/features/social/notification_read_state.dart';
import 'package:mobile_flutter/features/social/notifications_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

void main() {
  final persistence = _MemoryPersistence();
  runApp(
    ProviderScope(
      overrides: [
        dioProvider.overrideWithValue(_blockedApi()),
        inboxForegroundAccountProvider.overrideWith((_) => 'sample-me'),
        notificationReadApiProvider.overrideWithValue(_PreviewReadApi()),
        directMessageThreadsProvider.overrideWith(
          (_) => DirectMessageThreadsNotifier.testing(
            persistence.rows.map(DirectMessageThread.fromJson).toList(),
          ),
        ),
        demoPersistenceProvider.overrideWithValue(persistence),
        surfRepositoryProvider.overrideWithValue(
          _PreviewRepository(persistence),
        ),
        socialRelationshipHydrationProvider.overrideWith((_) async {}),
        joinedEventChatsProvider.overrideWith((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          return [
            JoinedEventChatSummary(
              postId: 'sample-event',
              title: 'Sunrise surf crew',
              hostName: 'Sample Surfer',
              meetupDate: '2026-11-13',
              sortDate: DateTime(2026, 11, 13),
            ),
          ];
        }),
      ],
      child: const _Preview(),
    ),
  );
}

class _PreviewReadApi extends NotificationReadApi {
  _PreviewReadApi() : super(_blockedApi());

  @override
  Future<NotificationReadReceipt> markRead({
    required String accountId,
    required Set<String> notificationIds,
  }) async => NotificationReadReceipt(
    accountId: accountId,
    readIds: notificationIds,
    unreadCount: 0,
  );
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  late final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const DirectMessagesPage()),
      GoRoute(
        path: '/notifications',
        builder: (_, _) => const SocialNotificationsPage(),
      ),
    ],
  );
  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(),
    routerConfig: router,
    builder: (context, child) => Column(
      children: [
        Material(
          child: SafeArea(
            bottom: false,
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('LOCAL VISUAL QA • sample inbox only'),
                TextButton(
                  onPressed: () => router.go('/'),
                  child: const Text('Messages'),
                ),
                TextButton(
                  onPressed: () => router.go('/notifications'),
                  child: const Text('Notifications'),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: child!),
      ],
    ),
  );
}

class _MemoryPersistence extends DemoPersistence {
  List<Map<String, dynamic>> rows = [
    const DirectMessageThread(
      id: 'sample',
      profileUserId: 'sample-surfer',
      name: 'Sample Surfer',
      handle: 'sample',
      initial: 'S',
      location: 'Bali',
      preview: 'Ready for the morning session?',
      time: 'Now',
      unreadCount: 1,
      online: false,
      requestAccepted: true,
      messages: [],
    ).toJson(),
  ];
  @override
  Future<List<Map<String, dynamic>>> loadDirectMessageThreadPayloads() async =>
      List.of(rows);
  @override
  Future<void> saveDirectMessageThreadPayloads(
    List<Map<String, dynamic>> threads,
  ) async {
    rows = List.of(threads);
  }
}

class _PreviewRepository extends SurfRepository {
  _PreviewRepository(DemoPersistence persistence)
    : super(_blockedApi(), persistence);
  @override
  Future<List<SocialNotificationModel>> fetchSocialNotifications() async {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    return [
      SocialNotificationModel.fromJson({
        'id': 'sample-like',
        'recipient_user_id': 'sample-me',
        'actor_user_id': 'sample-surfer',
        'actor_name': 'Sample Surfer',
        'actor_handle': 'sample',
        'type': 'like',
        'message': 'liked your surf photo.',
        'post_id': 'sample-post',
        'preview': 'Morning waves at the break.',
        'created_at': DateTime.now()
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
      }),
    ];
  }
}

Dio _blockedApi() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          message: 'Visual QA cannot access any backend.',
        ),
      ),
    ),
  );
