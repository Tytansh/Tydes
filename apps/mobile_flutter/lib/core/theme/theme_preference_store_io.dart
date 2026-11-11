import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Device preference, separate from credentials and account data.
class ThemePreferenceStore {
  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/tydes_appearance_v1.txt');
  }

  Future<String?> load() async {
    final file = await _file();
    return await file.exists() ? (await file.readAsString()).trim() : null;
  }

  Future<void> save(String mode) async {
    await (await _file()).writeAsString(mode, flush: true);
  }
}
