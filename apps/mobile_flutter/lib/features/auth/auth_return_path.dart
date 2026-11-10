/// Never accept an external URL as an after-login destination.
String safeAuthReturnPath(String? value) {
  if (value == '/' ||
      value == '/paywall' ||
      value == '/spots-map' ||
      value == '/explore' ||
      value == '/explore/map' ||
      value == '/explore/events') {
    return value!;
  }
  if (value != null &&
      RegExp(r'^/(spot|post)/[A-Za-z0-9_-]{1,120}$').hasMatch(value)) {
    return value;
  }
  return '/';
}

enum AccountDestination {
  feed(0),
  profile(4);

  const AccountDestination(this.tabIndex);
  final int tabIndex;
  static AccountDestination? parse(String? value) => switch (value) {
    'feed' => feed,
    'profile' => profile,
    _ => null,
  };
}

String loginForPath(String path, {AccountDestination? destination}) => Uri(
  path: '/login',
  queryParameters: {
    'next': safeAuthReturnPath(path),
    if (destination != null) 'destination': destination.name,
  },
).toString();

String publicSpotLink(String id) =>
    'https://tydes.io/#/spot/${Uri.encodeComponent(id)}';
String publicEventLink(String id) =>
    'https://tydes.io/#/post/${Uri.encodeComponent(id)}';
