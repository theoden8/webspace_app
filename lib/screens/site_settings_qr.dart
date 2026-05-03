import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/web_view_model.dart';

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
              child: QrImageView(
                data: encoded,
                version: QrVersions.auto,
                size: 240,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                gapless: true,
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
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            }
          },
        ),
        TextButton.icon(
          icon: const Icon(Icons.share),
          label: const Text('Share'),
          onPressed: () {
            SharePlus.instance.share(ShareParams(text: encoded));
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

/// Show a dialog that asks the user to paste a `webspace://qr/site/...`
/// payload. Returns the decoded shareable subset (per
/// [SiteSettingsQrCodec.includedKeys]) on success, or null if the user
/// cancels or the payload is malformed. Most native camera apps decode
/// QR codes and produce the URI string — paste-and-apply works without a
/// camera library and dodges F-Droid concerns about ML Kit barcode deps.
Future<Map<String, dynamic>?> showSiteSettingsQrApplyDialog(
  BuildContext context,
) async {
  final controller = TextEditingController();
  String? errorText;

  Map<String, dynamic>? tryDecode() {
    final raw = controller.text.trim();
    if (raw.isEmpty) return null;
    return SiteSettingsQrCodec.decode(raw);
  }

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
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
                controller: controller,
                minLines: 3,
                maxLines: 6,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'webspace://qr/site/v1/...',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
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
                    if (data?.text != null) {
                      controller.text = data!.text!;
                      setState(() => errorText = null);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final decoded = tryDecode();
              if (decoded == null) {
                setState(() => errorText =
                    'Not a valid WebSpace site-settings QR.');
                return;
              }
              Navigator.of(ctx).pop(decoded);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );

  controller.dispose();
  return result;
}
