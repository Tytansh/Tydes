/// Shares only the composer code download, never account or draft state.
/// A failed download is cleared so opening/retrying can request it again.
class PostComposerLibraryLoader {
  PostComposerLibraryLoader(this._loadLibrary);

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
