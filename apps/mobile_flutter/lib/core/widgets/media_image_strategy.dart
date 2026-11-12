import 'package:flutter/painting.dart';

/// This public legacy CDN does not currently return image CORS headers.
/// It already falls back to an HTML image; go directly to that same path
/// rather than first spending a mobile round trip on a doomed byte fetch.
/// Other providers (including Bunny) retain normal canvas decoding/fallback.
WebHtmlElementStrategy mediaImageStrategy(String url) =>
    Uri.tryParse(url)?.host == 'media.tydes.io'
    ? WebHtmlElementStrategy.prefer
    : WebHtmlElementStrategy.fallback;
