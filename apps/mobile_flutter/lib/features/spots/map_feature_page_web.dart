import 'package:flutter/material.dart';

import 'map_feature_library_loader.dart';
import 'map_feature_module.dart' deferred as maps;

final _mapLibrary = MapFeatureLibraryLoader(maps.loadLibrary);

class MapFeaturePage extends StatelessWidget {
  const MapFeaturePage({
    super.key,
    this.guest = false,
    this.initialSpotId,
    this.focusRevision = 0,
    this.embedded = false,
  });

  final bool guest;
  final String? initialSpotId;
  final int focusRevision;
  final bool embedded;

  @override
  Widget build(BuildContext context) => MapFeatureLoadGate(
    key: ValueKey((guest, embedded)),
    pageIdentity: (initialSpotId, focusRevision, embedded),
    loadLibrary: _mapLibrary.load,
    libraryLoaded: _mapLibrary.isLoaded,
    buildPage: (_) => maps.buildMapFeature(
      guest: guest,
      initialSpotId: initialSpotId,
      focusRevision: focusRevision,
      embedded: embedded,
    ),
  );
}

/// The loading shell is isolated from map data/providers and retains its page
/// after loading. FutureBuilder ignores completion after the shell is removed.
class MapFeatureLoadGate extends StatefulWidget {
  const MapFeatureLoadGate({
    super.key,
    required this.loadLibrary,
    required this.buildPage,
    this.libraryLoaded = false,
    this.pageIdentity,
  });

  final Future<void> Function() loadLibrary;
  final WidgetBuilder buildPage;
  final bool libraryLoaded;
  final Object? pageIdentity;

  @override
  State<MapFeatureLoadGate> createState() => _MapFeatureLoadGateState();
}

class _MapFeatureLoadGateState extends State<MapFeatureLoadGate> {
  Future<void>? _loading;
  Widget? _page;

  @override
  void initState() {
    super.initState();
    if (!widget.libraryLoaded) _loading = widget.loadLibrary();
  }

  @override
  void didUpdateWidget(covariant MapFeatureLoadGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageIdentity != oldWidget.pageIdentity) {
      // Update only the requested page configuration. The code-download future
      // and parent tree remain stable so the actual map retains its state.
      _page = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the FutureBuilder in the tree after an asynchronous load. Removing
    // that parent on the next rebuild would remount the map and lose its state.
    if (_loading == null) {
      return _page ??= widget.buildPage(context);
    }
    return FutureBuilder<void>(
      future: _loading,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          if (!snapshot.hasError) {
            return _page ??= widget.buildPage(context);
          }
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 32),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not load the map. Check your connection and try again.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => setState(() {
                        _loading = widget.loadLibrary();
                      }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry map'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return const Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
    );
  }
}
