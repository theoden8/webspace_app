import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/site_origins.dart';

/// A document's origin (`scheme://host[:port]` through [originOf]) as the
/// engine reports it, made only from platform frame data or a platform
/// permission request, never from a value page script chose (PERM-001).
///
/// The representation constructor is library-private and the only factories
/// read an engine object: the bridge call's [inapp.JavaScriptHandlerFunctionData]
/// (its `origin` computed behind the bridge secret, no more forgeable than
/// `isMainFrame`; CAM-014 / MIC-016), a platform [inapp.PermissionRequest], or
/// the webview's own top document. So a bridge handler, handed the frame rather
/// than a free string, cannot name another origin as the asker: the compiler
/// refuses a page string where a [FrameOrigin] is required, which
/// [requesterAt]/[requesterOf] now are. It `implements String`, so every grant
/// key, dialog and `standing` read still takes it as the origin text it is.
extension type const FrameOrigin._(String value) implements String {
  /// The calling frame's origin, from the plugin's bridge preamble.
  FrameOrigin.ofFrame(inapp.JavaScriptHandlerFunctionData frame)
    : this._(originOf(frame.origin.toString()));

  /// The origin a platform permission request names (`onPermissionRequest`),
  /// the one resource prompt the app answers itself.
  FrameOrigin.ofRequest(inapp.PermissionRequest request)
    : this._(originOf(request.origin.toString()));

  /// The webview's current top document, read from the engine, for a subframe
  /// whose own top the bridge call does not name. [fallbackUrl] stands in only
  /// before the first load has a URL.
  static Future<FrameOrigin> ofTopDocument(
    inapp.InAppWebViewController controller, {
    required String fallbackUrl,
  }) async => FrameOrigin._(
    originOf((await controller.getUrl())?.toString() ?? fallbackUrl),
  );
}

/// Who asks: the requesting frame's [FrameOrigin], as every grant key and
/// popup names it, and where it [Standing]s toward the site.
typedef Requester = ({FrameOrigin origin, Standing standing});
