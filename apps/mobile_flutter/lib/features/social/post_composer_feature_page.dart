// Native builds keep synchronous composer navigation; only web defers code.
export 'post_composer_feature_page_native.dart'
    if (dart.library.js_interop) 'post_composer_feature_page_web.dart';
