import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import 'package:webspace/services/site_settings_qr_codec.dart';

/// Full-screen camera scanner that returns the decoded shareable subset
/// when a `webspace://qr/site/...` payload is detected.
///
/// Routed via `Navigator.push<Map<String, dynamic>>` from the apply flow.
/// Pops with the decoded Map on success, null on user cancel. Scanning is
/// gated to QR codes only (other formats are rejected at the codec layer
/// — they won't decode — but we still hint via [ReaderWidget.codeFormat]
/// so ZXing can short-circuit).
class SiteSettingsQrScannerScreen extends StatefulWidget {
  const SiteSettingsQrScannerScreen({super.key});

  @override
  State<SiteSettingsQrScannerScreen> createState() =>
      _SiteSettingsQrScannerScreenState();
}

class _SiteSettingsQrScannerScreenState
    extends State<SiteSettingsQrScannerScreen> {
  bool _handled = false;
  String? _lastError;

  void _handleCode(Code code) {
    if (_handled) return;
    final text = code.text;
    if (text == null || text.isEmpty) return;
    final decoded = SiteSettingsQrCodec.decode(text);
    if (decoded == null) {
      setState(() {
        _lastError =
            'Scanned QR is not a WebSpace site-settings code.';
      });
      return;
    }
    _handled = true;
    Navigator.of(context).pop<Map<String, dynamic>>(decoded);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan site-settings QR')),
      body: Stack(
        children: [
          ReaderWidget(
            codeFormat: Format.qrCode,
            tryHarder: true,
            tryRotate: true,
            showGallery: false,
            onScan: _handleCode,
          ),
          if (_lastError != null)
            Positioned(
              left: 16,
              right: 16,
              top: 16,
              child: Material(
                color: Colors.red.shade700.withAlpha(220),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _lastError!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
