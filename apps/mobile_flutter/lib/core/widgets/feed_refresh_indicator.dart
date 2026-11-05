import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Keeps the scrollable mounted while the same refresh indicator handles both
/// touch pulls and desktop overscroll at the top of the page.
class FeedRefreshIndicator extends StatefulWidget {
  const FeedRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<FeedRefreshIndicator> createState() => _FeedRefreshIndicatorState();
}

class _FeedRefreshIndicatorState extends State<FeedRefreshIndicator> {
  final _indicator = GlobalKey<RefreshIndicatorState>();
  bool _atTop = true;
  bool _refreshing = false;
  double _overscroll = 0;
  DateTime? _lastWheel;
  DateTime? _completedAt;

  void _trackMetrics(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != Axis.vertical) return;
    _atTop = metrics.pixels <= metrics.minScrollExtent + 0.5;
    if (!_atTop) _overscroll = 0;
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) {
      return;
    }
    final now = DateTime.now();
    if (event.scrollDelta.dy >= 0 || !_atTop || _refreshing) {
      _overscroll = 0;
      return;
    }
    if (_completedAt != null &&
        now.difference(_completedAt!) < const Duration(seconds: 3)) {
      return;
    }
    if (_lastWheel == null ||
        now.difference(_lastWheel!) > const Duration(milliseconds: 500)) {
      _overscroll = 0;
    }
    _lastWheel = now;
    _overscroll -= event.scrollDelta.dy;
    if (_overscroll >= 120) {
      _overscroll = 0;
      // show() owns the visible spinner and calls onRefresh once. It does not
      // navigate, invalidate the session, or replace the child scrollable.
      unawaited(_indicator.currentState?.show());
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await widget.onRefresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not refresh. Try again.')),
        );
      }
    } finally {
      _refreshing = false;
      _completedAt = DateTime.now();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: _wheel,
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        _trackMetrics(notification.metrics, notification.depth);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _trackMetrics(notification.metrics, notification.depth);
          return false;
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              ...ScrollConfiguration.of(context).dragDevices,
              PointerDeviceKind.mouse,
            },
          ),
          child: RefreshIndicator.adaptive(
            key: _indicator,
            onRefresh: _refresh,
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}
