import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/settings/camera.dart';

/// Builds the preview page for a video [VirtualCameraSource].
///
/// Mirrors what the camera shim serves the site: the clip fills a frame with
/// `object-fit: cover` (the shim's cover-fit), muted + looped + autoplaying,
/// so the user sees the exact framing (including any crop) and confirms the
/// loop. Pure string so it is testable without a WebView.
String buildVirtualCameraPreviewHtml(String dataUrl) {
  return '<!doctype html><html><head>'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}'
      'video{width:100%;height:100%;object-fit:cover;display:block}</style>'
      '</head><body>'
      '<video src="$dataUrl" autoplay loop muted playsinline></video>'
      '</body></html>';
}

/// A small 4:3 preview of the source a site is served in
/// [CameraAccessMode.virtual]. Images render natively (cover-fit, so the
/// same crop the shim applies is visible); videos render in a muted, looping
/// WebView so the user can watch the loop the page will receive.
class VirtualCameraPreview extends StatelessWidget {
  final VirtualCameraSource source;

  const VirtualCameraPreview({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 220,
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.black,
              child: source.isVideo
                  ? _VideoPreview(dataUrl: source.dataUrl)
                  : _imagePreview(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _imagePreview() {
    final bytes = source.bytes;
    if (bytes == null) return const SizedBox.shrink();
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

class _VideoPreview extends StatefulWidget {
  final String dataUrl;
  const _VideoPreview({required this.dataUrl});

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  // Built once so scrolling the settings list doesn't restart playback.
  late final Widget _webView = inapp.InAppWebView(
    initialData: inapp.InAppWebViewInitialData(
      data: buildVirtualCameraPreviewHtml(widget.dataUrl),
      mimeType: 'text/html',
      encoding: 'utf-8',
    ),
    initialSettings: inapp.InAppWebViewSettings(
      // Loop preview must start without a tap.
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      transparentBackground: true,
      disableContextMenu: true,
      supportZoom: false,
      // Purely local data render: no cookies, no network, nothing to leak.
      thirdPartyCookiesEnabled: false,
      incognito: true,
    ),
  );

  @override
  Widget build(BuildContext context) => _webView;
}
