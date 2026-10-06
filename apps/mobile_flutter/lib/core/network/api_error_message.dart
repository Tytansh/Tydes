import 'package:dio/dio.dart';

String friendlyErrorMessage(
  Object? error, {
  String fallback = 'Something went wrong. Please try again.',
}) {
  if (error == null) return fallback;
  if (error is StateError) {
    return _cleanMessage(error.message, fallback);
  }
  if (error is DioException) {
    return _friendlyDioMessage(error, fallback);
  }

  final message = _cleanMessage(error.toString(), fallback);
  final normalized = message.toLowerCase();
  if (normalized.contains('socketexception') ||
      normalized.contains('failed host lookup') ||
      normalized.contains('network is unreachable')) {
    return 'Check your connection and try again.';
  }
  return message;
}

String friendlyLoadErrorMessage(Object? error, {required String label}) {
  final detail = friendlyErrorMessage(
    error,
    fallback: 'Check your connection and try again.',
  );
  return 'Could not load $label. $detail';
}

String _friendlyDioMessage(DioException error, String fallback) {
  final detail = error.response?.data;
  if (detail is Map<String, dynamic> && detail['detail'] is String) {
    return _cleanMessage(detail['detail'] as String, fallback);
  }
  final statusCode = error.response?.statusCode;
  if (statusCode == 401 || statusCode == 403) {
    return 'Please sign in again.';
  }
  if (statusCode == 404) {
    return 'That item was not found.';
  }
  if (statusCode == 413) {
    return 'That upload is too large.';
  }
  if (statusCode == 429) {
    return 'Too many requests. Wait a moment and try again.';
  }
  if (statusCode != null && statusCode >= 500) {
    return 'Tydes is having trouble right now. Try again soon.';
  }
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.connectionError) {
    return 'Check your connection and try again.';
  }
  if (error.type == DioExceptionType.badCertificate) {
    return 'Secure connection failed. Try again soon.';
  }
  return fallback;
}

String _cleanMessage(String? message, String fallback) {
  final cleaned = (message ?? '')
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '')
      .trim();
  if (cleaned.isEmpty) return fallback;
  return cleaned.endsWith('.') ? cleaned : '$cleaned.';
}
