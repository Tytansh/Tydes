// Native builds keep synchronous map navigation; only the web splits its code.
export 'map_feature_page_native.dart'
    if (dart.library.js_interop) 'map_feature_page_web.dart';
