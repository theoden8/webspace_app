import 'package:webspace/services/site_settings_qr_codec.dart';

String? shimQr(Map<String, dynamic> siteJson) =>
    SiteSettingsQrCodec.encode(SiteSettingsQrCodec.shareableSubset(siteJson));
