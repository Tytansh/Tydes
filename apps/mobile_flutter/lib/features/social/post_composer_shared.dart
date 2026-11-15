import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/network/api_models.dart';

// Small presentation helpers shared by the feed and its deferred composer.
// Keep media state, draft storage and upload implementation out of this file.

ScrollPhysics socialPostMediaCarouselPhysics({required bool isWeb}) {
  if (isWeb) return const NeverScrollableScrollPhysics();
  return const PageScrollPhysics(parent: ClampingScrollPhysics());
}

bool socialPostMediaCarouselShowsArrows({
  required bool isWeb,
  required int mediaCount,
}) => isWeb && mediaCount > 1;

class PostMediaArrowButton extends StatelessWidget {
  const PostMediaArrowButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon, color: const Color(0xFF16363A)),
        iconSize: 28,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

bool samePostDay(DateTime? left, DateTime? right) {
  if (left == null || right == null) return left == right;
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

String shortPostDateLabel(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

String shortPostDateRangeLabel(DateTimeRange range) {
  if (samePostDay(range.start, range.end)) {
    return shortPostDateLabel(range.start);
  }
  final sameMonth =
      range.start.year == range.end.year &&
      range.start.month == range.end.month;
  if (sameMonth) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[range.start.month - 1]} ${range.start.day}-${range.end.day}';
  }
  return '${shortPostDateLabel(range.start)}-${shortPostDateLabel(range.end)}';
}

String postActionErrorMessage(Object error) {
  if (error is StateError) {
    return error.message;
  }
  if (error is DioException) {
    if (error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionTimeout) {
      return 'Upload timed out while TYDES was finishing it. Try again — videos up to 30 seconds are supported.';
    }
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data['detail'] is String) {
      return data['detail'] as String;
    }
    if (error.response?.statusCode == 413) {
      return 'That file is too large. Try a shorter video or smaller photo.';
    }
  }
  return 'Upload failed. Try again.';
}

SpotModel? postSpotForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot;
  }
  return null;
}
