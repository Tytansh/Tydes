/// Never accept an external URL as an after-login destination.
String safeAuthReturnPath(String? value) {
  final rawPath = value?.split('?').first;
  if (rawPath == null ||
      rawPath.contains('%') ||
      rawPath.contains('\\') ||
      rawPath.split('/').any((part) => part == '.' || part == '..')) {
    return '/';
  }
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasFragment ||
      !uri.path.startsWith('/') ||
      uri.path.startsWith('//')) {
    return '/';
  }
  const paths = {
    '/',
    '/paywall',
    '/spots-map',
    '/people-search',
    '/messages',
    '/notifications',
    '/admin',
    '/explore',
    '/explore/map',
    '/explore/events',
  };
  final path = uri.path;
  if (!paths.contains(path) &&
      !RegExp(r'^/(spot|post|profile)/[A-Za-z0-9_-]{1,120}$').hasMatch(path) &&
      !RegExp(r'^/event/[A-Za-z0-9_-]{1,120}/chat$').hasMatch(path)) {
    return '/';
  }
  final allowedQuery = switch (path) {
    '/messages' => 'thread',
    '/spots-map' => 'spotId',
    _ when path.startsWith('/profile/') => 'post',
    _ => null,
  };
  final query = allowedQuery == null ? null : uri.queryParameters[allowedQuery];
  if (uri.hasQuery &&
      (allowedQuery == null ||
          uri.queryParametersAll.length != 1 ||
          uri.queryParametersAll[allowedQuery]?.length != 1 ||
          query == null ||
          !RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(query))) {
    return '/';
  }
  return Uri(
    path: path,
    queryParameters:
        query != null && RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(query)
        ? {allowedQuery!: query}
        : null,
  ).toString();
}

String verificationForPath(String path) => Uri(
  path: '/verify-email',
  queryParameters: {'next': safeAuthReturnPath(path)},
).toString();

String loginForPath(String path) => Uri(
  path: '/login',
  queryParameters: {'next': safeAuthReturnPath(path)},
).toString();

String publicSpotLink(String id) =>
    'https://tydes.io/#/spot/${Uri.encodeComponent(id)}';
String publicEventLink(String id) =>
    'https://tydes.io/#/post/${Uri.encodeComponent(id)}';
