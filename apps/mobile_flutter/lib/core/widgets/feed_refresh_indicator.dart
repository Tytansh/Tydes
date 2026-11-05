import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Reserves a small area above the content for refreshing. The spinner never
/// floats over a post and disappears when the user scrolls into the content.
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
  RefreshIndicatorStatus? _status;
  bool _spinnerDismissed = false;

  void _dismissSpinner() {
    if (_status == null || _spinnerDismissed) return;
    setState(() => _spinnerDismissed = true);
  }

  void _statusChanged(RefreshIndicatorStatus? status) {
    if (!mounted) return;
    setState(() {
      if (_status == null && status != null) _spinnerDismissed = false;
      _status =
          status == RefreshIndicatorStatus.done ||
              status == RefreshIndicatorStatus.canceled
          ? null
          : status;
    });
  }

  void _trackMetrics(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != Axis.vertical) return;
    _atTop = metrics.pixels <= metrics.minScrollExtent + 0.5;
    if (!_atTop) {
      _overscroll = 0;
      _dismissSpinner();
    }
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) {
      return;
    }
    final now = DateTime.now();
    if (event.scrollDelta.dy > 0) _dismissSpinner();
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
          child: Column(
            children: [
              SizedBox(
                height: _status != null && !_spinnerDismissed ? 44 : 0,
                child: ClipRect(
                  child: Center(
                    child: _status != null && !_spinnerDismissed
                        ? const SizedBox.square(
                            key: ValueKey('feed-top-refresh-spinner'),
                            dimension: 22,
                            child: CircularProgressIndicator.adaptive(
                              strokeWidth: 2,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator.noSpinner(
                  key: _indicator,
                  onRefresh: _refresh,
                  onStatusChange: _statusChanged,
                  child: widget.child,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
