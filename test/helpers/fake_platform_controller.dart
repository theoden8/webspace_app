import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';

/// The platform controller under one webview. The plugin wraps it in one
/// `InAppWebViewController` for `onWebViewCreated` and in another for every
/// later callback, so a fake standing in for the wrapper answers `platform`
/// with one of these per view: the page tells views apart by it.
final class FakePlatformController extends Fake
    implements inapp.PlatformInAppWebViewController {
  /// What a cookie call reads to find the view's jar: a view the platform
  /// has no id for.
  @override
  dynamic get id => null;
}
