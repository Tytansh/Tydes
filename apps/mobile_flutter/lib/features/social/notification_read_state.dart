import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/surf_repository.dart';

class NotificationReadReceipt {
  const NotificationReadReceipt({
    required this.accountId,
    required this.readIds,
    required this.unreadCount,
  });

  final String accountId;
  final Set<String> readIds;
  final int unreadCount;
}

class NotificationReadApi {
  NotificationReadApi(this._dio);
  final Dio _dio;

  Future<NotificationReadReceipt> markRead({
    required String accountId,
    required Set<String> notificationIds,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/notifications/read',
      data: {'notification_ids': notificationIds.toList()},
    );
    final data = response.data;
    final ids = data?['read_ids'];
    final count = data?['unread_count'];
    if (data?['user_id'] != accountId ||
        ids is! List ||
        ids.any((id) => id is! String || !notificationIds.contains(id)) ||
        count is! int ||
        count < 0) {
      throw StateError(
        'Notification read status was not confirmed for this account.',
      );
    }
    return NotificationReadReceipt(
      accountId: accountId,
      readIds: ids.cast<String>().toSet(),
      unreadCount: count,
    );
  }
}

final notificationReadApiProvider = Provider(
  (ref) => NotificationReadApi(ref.watch(dioProvider)),
);
