import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class WebScrollRefresh extends StatefulWidget {
  const WebScrollRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<WebScrollRefresh> createState() => _WebScrollRefreshState();
}

class _WebScrollRefreshState extends State<WebScrollRefresh> {
  bool _atTop = true;
  bool _refreshing = false;
  DateTime? _lastRefresh;

  bool _trackScroll(ScrollNotification notification) {
    _atTop =
        notification.metrics.pixels <=
        notification.metrics.minScrollExtent + 0.5;
    return false;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!kIsWeb || event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy >= 0 || !_atTop || _refreshing) return;
    final now = DateTime.now();
    if (_lastRefresh != null &&
        now.difference(_lastRefresh!) < const Duration(seconds: 2)) {
      return;
    }
    _lastRefresh = now;
    _refreshing = true;
    widget.onRefresh().whenComplete(() {
      if (mounted) _refreshing = false;
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: _handlePointerSignal,
    child: NotificationListener<ScrollNotification>(
      onNotification: _trackScroll,
      child: widget.child,
    ),
  );
}
