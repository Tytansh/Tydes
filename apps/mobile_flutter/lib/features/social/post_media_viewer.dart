import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Presents the caller's existing image/video widgets without changing their
/// source, fit, player implementation or provider scope. Capture a stable media
/// list in [itemBuilder] before opening the route.
///
/// The opaque route covers the feed so its route-visibility listener pauses and
/// mutes playback. Only the selected viewer item receives `active: true`.
Future<void> showPostMediaViewer(
  BuildContext context, {
  required int initialIndex,
  required int itemCount,
  required Widget Function(BuildContext context, int index, bool active)
  itemBuilder,
  ValueChanged<int>? onPageChanged,
}) async {
  if (itemCount <= 0) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'post-media-viewer'),
      fullscreenDialog: true,
      builder: (_) => _PostMediaViewer(
        initialIndex: initialIndex.clamp(0, itemCount - 1),
        itemCount: itemCount,
        itemBuilder: itemBuilder,
        onPageChanged: onPageChanged,
      ),
    ),
  );
}

/// Connect the existing pinch widget to its viewer's page gestures. This does
/// nothing outside a viewer, keeping media widgets reusable in other routes.
void notifyPostMediaViewerZoom(BuildContext context, bool zooming) {
  context.getInheritedWidgetOfExactType<_PostMediaViewerScope>()?.onZoomChanged(
    zooming,
  );
}

class _PostMediaViewerScope extends InheritedWidget {
  const _PostMediaViewerScope({
    required this.onZoomChanged,
    required super.child,
  });

  final ValueChanged<bool> onZoomChanged;

  @override
  bool updateShouldNotify(_PostMediaViewerScope oldWidget) => false;
}

class _PostMediaViewer extends StatefulWidget {
  const _PostMediaViewer({
    required this.initialIndex,
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
  });

  final int initialIndex;
  final int itemCount;
  final Widget Function(BuildContext context, int index, bool active)
  itemBuilder;
  final ValueChanged<int>? onPageChanged;

  @override
  State<_PostMediaViewer> createState() => _PostMediaViewerState();
}

class _PostMediaViewerState extends State<_PostMediaViewer> {
  late final PageController _pages;
  late int _index;
  bool _zooming = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index, keepPage: false);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _pageChanged(int index) {
    setState(() {
      _index = index;
      _zooming = false;
    });
    widget.onPageChanged?.call(index);
  }

  void _zoomChanged(bool zooming) {
    if (mounted && _zooming != zooming) {
      setState(() => _zooming = zooming);
    }
  }

  void _showIndex(int index) {
    if (_zooming ||
        !_pages.hasClients ||
        index < 0 ||
        index >= widget.itemCount ||
        index == _index) {
      return;
    }
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) => _PostMediaViewerScope(
    onZoomChanged: _zoomChanged,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _showIndex(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _showIndex(_index + 1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            systemOverlayStyle: SystemUiOverlayStyle.light,
            toolbarHeight: 48,
            leading: IconButton(
              tooltip: 'Close media',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: _close,
              icon: const Icon(Icons.close_rounded),
            ),
            title: Text(
              widget.itemCount == 1
                  ? 'Media'
                  : '${_index + 1} of ${widget.itemCount}',
              style: const TextStyle(fontSize: 16, color: Colors.white),
            ),
            centerTitle: true,
          ),
          body: SafeArea(
            top: false,
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  key: const ValueKey('post-media-viewer-pages'),
                  controller: _pages,
                  itemCount: widget.itemCount,
                  // Website carousels use explicit arrows, not mouse/trackpad
                  // swipes that can become browser Back gestures.
                  physics: _zooming || kIsWeb
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  onPageChanged: _pageChanged,
                  itemBuilder: (context, index) => KeyedSubtree(
                    key: ValueKey('post-media-viewer-item-$index'),
                    child: widget.itemBuilder(context, index, index == _index),
                  ),
                ),
                if (widget.itemCount > 1 && !_zooming) ...[
                  if (_index > 0)
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _ViewerArrow(
                          tooltip: 'Previous media',
                          icon: Icons.chevron_left_rounded,
                          onPressed: () => _showIndex(_index - 1),
                        ),
                      ),
                    ),
                  if (_index < widget.itemCount - 1)
                    Positioned(
                      right: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _ViewerArrow(
                          tooltip: 'Next media',
                          icon: Icons.chevron_right_rounded,
                          onPressed: () => _showIndex(_index + 1),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ViewerArrow extends StatelessWidget {
  const _ViewerArrow({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.56),
    shape: const CircleBorder(),
    child: IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white, size: 28),
    ),
  );
}
