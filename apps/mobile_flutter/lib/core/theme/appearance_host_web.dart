import 'package:web/web.dart' as web;

void syncHostAppearance(bool dark) {
  final root = web.document.documentElement;
  root?.setAttribute('data-theme', dark ? 'dark' : 'light');
  web.document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute('content', dark ? '#0c171b' : '#f8f7f2');
}
