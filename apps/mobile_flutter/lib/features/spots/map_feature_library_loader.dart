/// Shares a code download between simultaneous map entrypoints and allows a
/// failed download to be retried. It does not cache account data or map state.
class MapFeatureLibraryLoader {
  MapFeatureLibraryLoader(this._loadLibrary);

  final Future<void> Function() _loadLibrary;
  Future<void>? _pending;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _pending ??= _load();
  }

  Future<void> _load() async {
    try {
      await Future<void>.sync(_loadLibrary);
      _loaded = true;
    } finally {
      _pending = null;
    }
  }
}
