import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/surf_repository.dart';

/// Changed only after confirmed inbox/read actions, never an optimistic clear.
final inboxCountsRefreshKeyProvider = StateProvider<int>((ref) => 0);

/// The app shell sets this only for a foreground, signed-in account.
final inboxForegroundAccountProvider = StateProvider<String?>((ref) => null);

class InboxUnreadCounts {
  const InboxUnreadCounts({
    required this.accountId,
    this.messages = 0,
    this.notifications = 0,
  });
  final String? accountId;
  final int messages;
  final int notifications;
  int get total => messages + notifications;
}

class InboxUnreadApi {
  InboxUnreadApi(this._dio);
  final Dio _dio;

  Future<InboxUnreadCounts> fetch(String accountId) async {
    final results = await Future.wait([
      _dio.get<Map<String, dynamic>>('/messages/unread-count'),
      _dio.get<Map<String, dynamic>>('/social/notifications/unread-count'),
    ]);
    int count(Response<Map<String, dynamic>> response) {
      final value = response.data?['unread_count'];
      if (response.data?['user_id'] != accountId ||
          value is! int ||
          value < 0) {
        throw StateError('Unread counts were not confirmed for this account.');
      }
      return value;
    }

    return InboxUnreadCounts(
      accountId: accountId,
      messages: count(results[0]),
      notifications: count(results[1]),
    );
  }
}

final inboxUnreadApiProvider = Provider(
  (ref) => InboxUnreadApi(ref.watch(dioProvider)),
);

final inboxUnreadCountsProvider = FutureProvider<InboxUnreadCounts>((ref) {
  final accountId = ref.watch(inboxForegroundAccountProvider);
  ref.watch(inboxCountsRefreshKeyProvider);
  if (accountId == null) {
    return const InboxUnreadCounts(accountId: null);
  }
  return ref.watch(inboxUnreadApiProvider).fetch(accountId);
});

InboxUnreadCounts watchInboxCounts(WidgetRef ref, String? accountId) {
  final counts = ref.watch(inboxUnreadCountsProvider).valueOrNull;
  if (accountId == null || counts?.accountId != accountId) {
    return const InboxUnreadCounts(accountId: null);
  }
  return counts!;
}

/// A pill grows for 12/120/etc instead of clipping digits into a fixed circle.
class InboxUnreadBadge extends StatelessWidget {
  const InboxUnreadBadge({super.key, required this.count, required this.child});
  final int count;
  final Widget child;
  @override
  Widget build(BuildContext context) => Badge(
    isLabelVisible: count > 0,
    backgroundColor: Theme.of(context).colorScheme.error,
    textColor: Theme.of(context).colorScheme.onError,
    label: Text('$count', key: ValueKey('unread-count-$count')),
    child: child,
  );
}
