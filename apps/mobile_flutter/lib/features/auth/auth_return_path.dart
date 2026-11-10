/// Never accept an external URL as an after-login destination.
String safeAuthReturnPath(String? value) {
  if (value == '/' || value == '/paywall' || value == '/spots-map') {
    return value!;
  }
  if (value != null &&
      RegExp(r'^/(spot|post)/[A-Za-z0-9_-]{1,120}$').hasMatch(value)) {
    return value;
  }
  return '/';
}

String loginForPath(String path) => Uri(
  path: '/login',
  queryParameters: {'next': safeAuthReturnPath(path)},
).toString();

String publicSpotLink(String id) =>
    'https://tydes.io/#/spot/${Uri.encodeComponent(id)}';
String publicEventLink(String id) =>
    'https://tydes.io/#/post/${Uri.encodeComponent(id)}';
