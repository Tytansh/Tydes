// Native navigation remains synchronous; web downloads admin UI on first use.
export 'admin_feature_page_native.dart'
    if (dart.library.js_interop) 'admin_feature_page_web.dart';
