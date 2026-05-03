import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'package:webspace/screens/site_settings_qr_scanner.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/web_view_model.dart';

/// Camera scanning is wired up only where flutter_zxing's `ReaderWidget`
/// has a working camera path. On desktop (Linux, macOS, Windows) and web
/// the apply dialog skips straight to paste.
bool _hasCameraScanner() =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Show a dialog rendering [model]'s shareable subset as a QR code.
/// Cookies, user scripts, secure cookies, and proxy passwords are stripped
/// by [SiteSettingsQrCodec.shareableSubset] before encoding.
Future<void> showSiteSettingsQrShareDialog(
  BuildContext context,
  WebViewModel model,
) async {
  final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
  final encoded = SiteSettingsQrCodec.encode(shared);

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Share site settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              // SizedBox with tight constraints terminates intrinsic queries
              // before they reach QrImageView's internal LayoutBuilder, which
              // AlertDialog's IntrinsicWidth would otherwise hit.
              child: SizedBox(
                width: 240,
                height: 240,
                child: QrImageView(
                  data: encoded,
                  version: QrVersions.auto,
                  size: 240,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                  gapless: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Cookies, user scripts, and proxy passwords are not included.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).textTheme.bodySmall?.color,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: encoded));
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
            rootScaffoldMessengerKey.currentState?.showSnackBar(
              const SnackBar(content: Text('Copied to clipboard')),
            );
          },
        ),
        TextButton.icon(
          icon: const Icon(Icons.share),
          label: const Text('Share'),
          onPressed: () {
            SharePlus.instance.share(ShareParams(text: encoded));
            Navigator.of(ctx).pop();
          },
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Drive the apply-from-QR flow. On Android/iOS opens the in-app camera
/// scanner first (flutter_zxing → ZXing C++, FOSS). On desktop or if the
/// user backs out of the scanner, falls back to a paste dialog.
Future<Map<String, dynamic>?> showSiteSettingsQrApplyDialog(
  BuildContext context,
) async {
  if (_hasCameraScanner()) {
    final scanned = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => const SiteSettingsQrScannerScreen(),
      ),
    );
    if (scanned != null) return scanned;
    if (!context.mounted) return null;
  }
  return _showPasteDialog(context);
}

/// Paste-fallback dialog. Exposed so [showSiteSettingsQrApplyDialog] can
/// route to it after the scanner is cancelled or on platforms without a
/// camera path. Tests against the codec target this through the public
/// entry point above; this helper is intentionally private.
Future<Map<String, dynamic>?> _showPasteDialog(
  BuildContext context,
) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => const _PasteDialog(),
  );
}

class _PasteDialog extends StatefulWidget {
  const _PasteDialog();

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _tryDecode() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return null;
    return SiteSettingsQrCodec.decode(raw);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Apply settings from QR'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Scan the QR with your camera and paste the resulting '
              'webspace://qr/site/... URL here.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 3,
              maxLines: 6,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'webspace://qr/site/v1/...',
                border: const OutlineInputBorder(),
                errorText: _errorText,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.paste),
                label: const Text('Paste from clipboard'),
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (!mounted) return;
                  if (data?.text != null) {
                    _controller.text = data!.text!;
                    setState(() => _errorText = null);
                  }
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final decoded = _tryDecode();
            if (decoded == null) {
              setState(() => _errorText =
                  'Not a valid WebSpace site-settings QR.');
              return;
            }
            Navigator.of(context).pop(decoded);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
