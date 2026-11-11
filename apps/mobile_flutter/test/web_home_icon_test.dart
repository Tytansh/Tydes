import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/verify_web_icons.dart' as web_icons;

void main() {
  test('Every public page installs the approved opaque blue-wave icon', () {
    web_icons.verifyWebIcons(Directory('web'));
  });
}
