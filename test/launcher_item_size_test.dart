import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/settings/launcher_item_size.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  test(
    'item sizes survive site and group serialization and group editing (WEBSPACE-014)',
    () {
      for (final size in LauncherItemSize.values) {
        final site = WebViewModel(
          initUrl: 'https://example.test',
          launcherSize: size,
        );
        final group = Webspace(name: 'Work', launcherSize: size);
        expect(
          WebViewModel.fromJson(site.toJson(), stateSetterF: null).launcherSize,
          size,
        );
        expect(
          Webspace.fromJson(
            group.toJson(),
          ).copyWith(name: 'Reading').launcherSize,
          size,
        );
        expect(
          SiteSettingsQrCodec.shareableSubset(site.toJson()),
          isNot(contains('launcherSize')),
        );
      }
      for (final raw in [null, true, 3, [], {}, 'unknown']) {
        expect(LauncherItemSize.fromJson(raw), LauncherItemSize.medium);
      }
    },
  );
}
