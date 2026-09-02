import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/settings/virtual_visual_source.dart';

/// Builds the preview page for a video [VirtualVisualSource].
///
/// Mirrors what the shim serves the site, which is why [objectFit] is a
/// parameter rather than a constant: the camera cover-fits (a sensor fills its
/// frame, and the user needs to see the crop), while a shared surface is shown
/// entire. Muted + looped + autoplaying either way, so the user confirms the
/// loop. Pure string so it is testable without a WebView.
String buildVirtualSourcePreviewHtml(String dataUrl,
    {String objectFit = 'cover'}) {
  return '<!doctype html><html><head>'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}'
      'video{width:100%;height:100%;object-fit:$objectFit;display:block}</style>'
      '</head><body>'
      '<video src="$dataUrl" autoplay loop muted playsinline></video>'
      '</body></html>';
}

/// A small preview of the media a site is served in place of a real visual
/// capture. Images render natively; videos render in a muted, looping WebView
/// so the user can watch the loop the page will receive.
///
/// [aspectRatio] and [fit] follow the shim doing the substituting: the camera
/// cover-fits into 4:3, so the preview shows the crop the page gets; a shared
/// surface is served whole, so it is contained in a 16:9 frame instead.
class VirtualSourcePreview extends StatelessWidget {
  final VirtualVisualSource source;
  final double aspectRatio;
  final BoxFit fit;

  const VirtualSourcePreview({
    super.key,
    required this.source,
    this.aspectRatio = 4 / 3,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 220,
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.black,
              child: source.isVideo
                  ? _VideoPreview(
                      dataUrl: source.dataUrl,
                      objectFit: fit == BoxFit.contain ? 'contain' : 'cover',
                    )
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
    return Image.memory(bytes, fit: fit, gaplessPlayback: true);
  }
}

class _VideoPreview extends StatefulWidget {
  final String dataUrl;
  final String objectFit;
  const _VideoPreview({required this.dataUrl, required this.objectFit});

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  // Built once so scrolling the settings list doesn't restart playback.
  late final Widget _webView = inapp.InAppWebView(
    initialData: inapp.InAppWebViewInitialData(
      data: buildVirtualSourcePreviewHtml(widget.dataUrl,
          objectFit: widget.objectFit),
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
