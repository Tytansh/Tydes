import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('product-owned page copy consistently uses uppercase TYDES', () {
    final titleCaseBrand = RegExp(r'\bTydes\b');
    final sources = <File>[
      for (final root in ['lib', 'web'])
        ...Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) => RegExp(r'\.(dart|html|json|js)$').hasMatch(file.path),
            ),
      File('ios/Runner/Info.plist'),
      File('android/app/src/main/AndroidManifest.xml'),
    ];
    final inconsistent = sources
        .where((file) => titleCaseBrand.hasMatch(file.readAsStringSync()))
        .map((file) => file.path)
        .toList();

    expect(
      inconsistent,
      isEmpty,
      reason:
          'Do not change user-authored names; '
          'the product-owned brand copy must use TYDES.',
    );
  });
}
