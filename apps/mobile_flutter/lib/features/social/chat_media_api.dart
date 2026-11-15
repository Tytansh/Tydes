import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/network/chat_media_models.dart';
import 'direct_message_api.dart';

extension _ChatCancellation on CancelToken {
  void throwIfCancellationRequested() {
    final error = cancelError;
    if (error != null) throw error;
  }
}

final chatMediaApiProvider = Provider(
  (ref) => ChatMediaApi(ref.watch(directMessageApiProvider)),
);

class ChatMediaCapabilities {
  const ChatMediaCapabilities({
    required this.enabled,
    this.photoMaxBytes = 8 * 1024 * 1024,
    this.videoMaxBytes = 50 * 1024 * 1024,
    this.videoMaxSeconds = 30.5,
    this.reason,
    this.photosEnabled = false,
    this.videosEnabled = false,
  });
  final bool enabled;
  final bool photosEnabled;
  final bool videosEnabled;
  final int photoMaxBytes;
  final int videoMaxBytes;
  final double videoMaxSeconds;
  final String? reason;
  factory ChatMediaCapabilities.fromJson(Map<String, dynamic> json) =>
      ChatMediaCapabilities(
        enabled: json['enabled'] == true,
        photosEnabled: json['photos_enabled'] == true,
        videosEnabled: json['videos_enabled'] == true,
        photoMaxBytes:
            (json['photo_max_bytes'] as num?)?.toInt() ?? 8 * 1024 * 1024,
        videoMaxBytes:
            (json['video_max_bytes'] as num?)?.toInt() ?? 50 * 1024 * 1024,
        videoMaxSeconds:
            (json['video_max_seconds'] as num?)?.toDouble() ?? 30.5,
        reason: json['reason'] as String?,
      );
}

class ChatMediaApi {
  ChatMediaApi(this.accounts, {Dio? uploadDio})
    : uploads =
          uploadDio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(minutes: 10),
              receiveTimeout: const Duration(minutes: 2),
              followRedirects: false,
            ),
          );
  final DirectMessageApi accounts;
  final Dio uploads;
  Future<ChatMediaSession> session(
    String owner,
    String type,
    String id,
  ) async =>
      ChatMediaSession(await accounts.openSession(owner), uploads, type, id);
}

class ChatMediaSession {
  ChatMediaSession(this.account, this.uploads, this.type, this.conversationId);
  final DirectMessageSession account;
  final Dio uploads;
  final String type;
  final String conversationId;
  Map<String, dynamic> get context => {
    'conversation_type': type,
    'conversation_id': conversationId,
  };
  Future<ChatMediaCapabilities> capabilities() async =>
      ChatMediaCapabilities.fromJson(
        await account.getMap('/messages/media/capabilities'),
      );
  Future<void> cancel(String id) =>
      account.delete('/messages/media/uploads/${Uri.encodeComponent(id)}');
  Future<Map<String, dynamic>> access(String id) async {
    final result = await account.postMap(
      '/messages/media/${Uri.encodeComponent(id)}/access',
      context,
    );
    if (result['id'] != id ||
        result['url'] is! String ||
        !Uri.parse(result['url'] as String).isScheme('https')) {
      throw StateError('Private media access was not confirmed.');
    }
    return result;
  }

  Future<ChatMediaAttachment> upload(
    XFile file,
    String mediaType, {
    required CancelToken cancellation,
    required void Function(String) onReservation,
    required void Function(double?) onProgress,
  }) async {
    final size = await file.length();
    final caps = await capabilities();
    if (!caps.enabled ||
        !(mediaType == 'video' ? caps.videosEnabled : caps.photosEnabled)) {
      throw StateError(
        caps.reason ?? 'This private media type is not available yet.',
      );
    }
    if (size <= 0 ||
        size >
            (mediaType == 'video' ? caps.videoMaxBytes : caps.photoMaxBytes)) {
      throw StateError('This file is too large for a private message.');
    }
    final contentType = _contentType(file, mediaType);
    final reservation = await account.postMap('/messages/media/uploads', {
      ...context,
      'media_type': mediaType,
      'content_type': contentType,
      'size_bytes': size,
      'file_name': file.name,
    }, cancelToken: cancellation);
    final id = reservation['id'] as String;
    onReservation(id);
    final target = Map<String, dynamic>.from(reservation['upload'] as Map);
    await account.ensureCurrent();
    cancellation.throwIfCancellationRequested();
    final headers = Map<String, dynamic>.from(target['headers'] as Map? ?? {});
    final targetUrl = target['url'] as String;
    if (!Uri.parse(targetUrl).isScheme('https')) {
      throw StateError('Invalid private upload target.');
    }
    if (target['protocol'] == 'tus') {
      final created = await uploads.post<void>(
        targetUrl,
        cancelToken: cancellation,
        options: Options(
          headers: {
            ...headers,
            'Tus-Resumable': '1.0.0',
            'Upload-Length': size,
            'Upload-Metadata':
                'filename ${base64Encode(utf8.encode(file.name))},filetype ${base64Encode(utf8.encode(contentType))}',
          },
          validateStatus: (s) => s == 201,
        ),
      );
      final location = created.headers.value('location');
      if (location == null) throw StateError('Video upload could not start.');
      final url = Uri.parse(targetUrl).resolve(location);
      if (url.origin != Uri.parse(targetUrl).origin) {
        throw StateError('Unexpected video upload location.');
      }
      var offset = 0;
      var retries = 0;
      while (offset < size) {
        await account.ensureCurrent();
        cancellation.throwIfCancellationRequested();
        final end = math.min(offset + 5 * 1024 * 1024, size);
        final chunk = await file
            .openRead(offset, end)
            .fold<BytesBuilder>(BytesBuilder(), (b, v) => b..add(v));
        try {
          final response = await uploads.patch<void>(
            url.toString(),
            data: chunk.takeBytes(),
            cancelToken: cancellation,
            options: Options(
              headers: {
                ...headers,
                'Tus-Resumable': '1.0.0',
                'Upload-Offset': offset,
                'Content-Type': 'application/offset+octet-stream',
                if (!kIsWeb) 'Content-Length': end - offset,
              },
              validateStatus: (s) => s == 204,
            ),
            onSendProgress: (sent, _) =>
                onProgress(((offset + sent) / size).clamp(0, 1)),
          );
          final next = int.tryParse(
            response.headers.value('upload-offset') ?? '',
          );
          if (next != end) {
            throw StateError('Video upload did not advance.');
          }
          offset = end;
        } on DioException catch (error) {
          if (CancelToken.isCancel(error) || ++retries > 3) rethrow;
          final head = await uploads.head<void>(
            url.toString(),
            cancelToken: cancellation,
            options: Options(
              headers: {...headers, 'Tus-Resumable': '1.0.0'},
              validateStatus: (s) => s == 200 || s == 204,
            ),
          );
          final resumed = int.tryParse(
            head.headers.value('upload-offset') ?? '',
          );
          if (resumed == null || resumed < 0 || resumed > size) rethrow;
          offset = resumed;
        }
      }
    } else if (target['protocol'] == 'put') {
      await uploads.put<void>(
        targetUrl,
        data: kIsWeb ? await file.readAsBytes() : file.openRead(),
        cancelToken: cancellation,
        options: Options(
          headers: {...headers, if (!kIsWeb) 'Content-Length': size},
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
        onSendProgress: (sent, total) =>
            onProgress(total > 0 ? sent / total : null),
      );
    } else {
      throw StateError('This private upload method is not supported.');
    }
    await account.ensureCurrent();
    onProgress(null);
    return complete(id, mediaType, cancellation);
  }

  Future<ChatMediaAttachment> complete(
    String id,
    String mediaType,
    CancelToken cancellation,
  ) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      cancellation.throwIfCancellationRequested();
      final result = await account.postMap(
        '/messages/media/uploads/${Uri.encodeComponent(id)}/complete',
        {},
        cancelToken: cancellation,
      );
      if (result['id'] != id || result['media_type'] != mediaType) {
        throw StateError('Attachment was not confirmed.');
      }
      if (result['status'] == 'ready') {
        return ChatMediaAttachment(id: id, mediaType: mediaType);
      }
      if (result['status'] != 'processing') {
        throw StateError('Attachment processing failed.');
      }
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 5)),
        cancellation.whenCancel.then<void>(
          (_) => cancellation.throwIfCancellationRequested(),
        ),
      ]);
    }
    throw StateError('Video is still processing. Please retry in a moment.');
  }
}

String _contentType(XFile file, String mediaType) {
  if (file.mimeType?.isNotEmpty == true) return file.mimeType!;
  final name = file.name.toLowerCase();
  if (name.endsWith('.webm')) return 'video/webm';
  if (name.endsWith('.mov')) return 'video/quicktime';
  if (mediaType == 'video') return 'video/mp4';
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.webp')) return 'image/webp';
  if (name.endsWith('.heic')) return 'image/heic';
  return 'image/jpeg';
}
