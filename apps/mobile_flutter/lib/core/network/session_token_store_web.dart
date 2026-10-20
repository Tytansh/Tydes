import 'package:web/web.dart' as web;

class SessionTokenStore {
  static const _storageKey = 'tydes_access_token';

  Future<String?> load() async {
    final token = web.window.localStorage.getItem(_storageKey);
    return token == null || token.isEmpty ? null : token;
  }

  Future<void> save(String token) async {
    web.window.localStorage.setItem(_storageKey, token);
  }

  Future<void> clear() async {
    web.window.localStorage.removeItem(_storageKey);
  }
}
