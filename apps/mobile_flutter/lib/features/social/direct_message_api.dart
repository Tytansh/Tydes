import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/demo_persistence.dart';
import '../../core/network/surf_repository.dart';

final directMessageApiProvider = Provider<DirectMessageApi>(
  (ref) => DirectMessageApi(
    ref.watch(dioProvider),
    ref.watch(demoPersistenceProvider),
  ),
);

/// A conversation is bound to one verified account/token, never the global
/// device-local demo inbox. Changing accounts invalidates in-flight responses.
class DirectMessageApi {
  DirectMessageApi(this.dio, this.persistence);
  final Dio dio;
  final DemoPersistence persistence;

  Future<DirectMessageSession> openSession(String ownerId) async {
    final token = await persistence.loadAccessToken();
    if (token == null || token.isEmpty) {
      throw StateError('Please sign in to load messages.');
    }
    final session = DirectMessageSession(dio, persistence, ownerId, token);
    final user = await session.getMap('/users/me');
    if (user['id'] != ownerId) {
      throw StateError('Your account changed. Reopen Messages and try again.');
    }
    return session;
  }
}

class DirectMessageSession {
  DirectMessageSession(this.dio, this.persistence, this.ownerId, this._token);
  final Dio dio;
  final DemoPersistence persistence;
  final String ownerId;
  final String _token;

  Future<void> _checkSession() async {
    if (await persistence.loadAccessToken() != _token) {
      throw StateError('Your account changed. Reopen Messages and try again.');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? data,
  }) async {
    await _checkSession();
    final response = await dio.request<Map<String, dynamic>>(
      path,
      data: data,
      options: Options(
        method: method,
        headers: {'Authorization': 'Bearer $_token'},
      ),
    );
    await _checkSession();
    final result = response.data;
    if (result == null) {
      throw StateError('The message response was incomplete.');
    }
    return result;
  }

  Future<Map<String, dynamic>> getMap(String path) => _request('GET', path);

  Future<List<Map<String, dynamic>>> threads() async {
    final result = await getMap('/messages/threads');
    final items = result['threads'];
    if (items is! List) throw StateError('The inbox response was incomplete.');
    return items.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  Future<Map<String, dynamic>> ensureThread(String recipientUserId) => _request(
    'POST',
    '/messages/threads',
    data: {'recipient_user_id': recipientUserId},
  );

  Future<Map<String, dynamic>> thread(String threadId) async {
    final result = await getMap(
      '/messages/threads/${Uri.encodeComponent(threadId)}',
    );
    if (result['id'] != threadId || result['messages'] is! List) {
      throw StateError('The conversation response was incomplete.');
    }
    return result;
  }

  Future<Map<String, dynamic>> send({
    required String threadId,
    required String text,
    required String clientMessageId,
    String? sharedPostId,
  }) async {
    final result = await _request(
      'POST',
      '/messages/threads/${Uri.encodeComponent(threadId)}/messages',
      data: {
        'text': text,
        'client_message_id': clientMessageId,
        'shared_post_id': ?sharedPostId,
      },
    );
    if (result['id'] is! String ||
        result['sender_user_id'] != ownerId ||
        result['client_message_id'] != clientMessageId) {
      throw StateError(
        'The server did not confirm this message. Please retry.',
      );
    }
    return result;
  }

  Future<int> markRead(String threadId, String messageId) async {
    final result = await _request(
      'POST',
      '/messages/threads/${Uri.encodeComponent(threadId)}/read',
      data: {'last_message_id': messageId},
    );
    final count = result['unread_count'];
    if (result['thread_id'] != threadId || count is! int || count < 0) {
      throw StateError('The server did not confirm the read status.');
    }
    return count;
  }

  Future<Map<String, dynamic>> requestStatus(
    String threadId, {
    bool? accepted,
    bool? declined,
  }) async {
    final result = await _request(
      'PATCH',
      '/messages/threads/${Uri.encodeComponent(threadId)}/request',
      data: {'accepted': ?accepted, 'declined': ?declined},
    );
    if (result['id'] != threadId) {
      throw StateError('The request change was not confirmed.');
    }
    return result;
  }
}
