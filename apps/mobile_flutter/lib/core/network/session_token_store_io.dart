import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class SessionTokenStore {
  static Future<void> _pending = Future.value();

  // Serialize file operations, including the compare-and-clear operation.
  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<String?> load() => _exclusive(_load);

  Future<String?> _load() async {
    final file = await _sessionFile();
    if (!file.existsSync()) return null;

    final payload = jsonDecode(await file.readAsString());
    if (payload is! Map<String, dynamic>) return null;

    final token = payload['access_token'];
    return token is String && token.isNotEmpty ? token : null;
  }

  Future<void> save(String token) => _exclusive(() async {
    final file = await _sessionFile();
    await file.writeAsString(jsonEncode({'access_token': token}));
  });

  Future<void> clear() => _exclusive(_clear);

  Future<void> _clear() async {
    final file = await _sessionFile();
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<bool> clearIfMatches(String expectedToken) => _exclusive(() async {
    if (await _load() != expectedToken) return false;
    await _clear();
    return true;
  });

  Future<File> _sessionFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/auth_session.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return file;
  }
}
