import 'package:web/web.dart' as web;

/// Origin-local preference; contains no identity or authentication information.
class ThemePreferenceStore {
  static const storageKey = 'tydes.appearance.v1';

  Future<String?> load() async => web.window.localStorage.getItem(storageKey);

  Future<void> save(String mode) async {
    web.window.localStorage.setItem(storageKey, mode);
  }
}
