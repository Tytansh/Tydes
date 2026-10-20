import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class SessionTokenStore {
  Future<String?> load() async {
    final file = await _sessionFile();
    if (!file.existsSync()) return null;

    final payload = jsonDecode(await file.readAsString());
    if (payload is! Map<String, dynamic>) return null;

    final token = payload['access_token'];
    return token is String && token.isNotEmpty ? token : null;
  }

  Future<void> save(String token) async {
    final file = await _sessionFile();
    await file.writeAsString(jsonEncode({'access_token': token}));
  }

  Future<void> clear() async {
    final file = await _sessionFile();
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<File> _sessionFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/auth_session.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return file;
  }
}
