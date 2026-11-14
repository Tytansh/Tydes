/// Coalesces the code download, not admin data or account authorization.
class AdminFeatureLibraryLoader {
  AdminFeatureLibraryLoader(this._loadLibrary);

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
