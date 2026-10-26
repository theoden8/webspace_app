import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/services/web_extension_native.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/extension_packages.dart';
import 'helpers/fake_extension_folders.dart';
import 'helpers/isolations.dart';

SitePosture _posture(WebViewModel m) => m.sitePosture(
  globalUserScripts: const <UserScriptConfig>[],
  isolation: fakeContainers(),
);

void main() {
  final disk = FakeExtensionFolders();
  late WebExtensionId id;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugHostRunsWebExtensions = true;
    DeveloperModeService.instance.debugSet(on: true);
    ExperimentalFeaturesService.instance.debugSet(
      ExperimentalFeature.webExtensions,
      on: true,
    );
    WebExtensionLibrary.instance.debugReset();
    await WebExtensionLibrary.instance.initialize(folders: disk);
    final package = switch (readExtensionPackage(sampleZip(manifest: {
      'permissions': ['storage', 'nativeMessaging'],
      'host_permissions': ['<all_urls>'],
    }))) {
      final ExtensionPackage p => p,
      PackageRefused(:final why) => fail('refused: $why'),
    };
    id = (await WebExtensionLibrary.instance.add(package)).id;
  });

  tearDown(() {
    debugHostRunsWebExtensions = null;
    DeveloperModeService.instance.debugSet(on: false);
    ExperimentalFeaturesService.instance.debugSet(
      ExperimentalFeature.webExtensions,
      on: false,
    );
  });

  WebViewModel site({bool incognito = false}) => WebViewModel(
    initUrl: 'https://mail.example.com/',
    incognito: incognito,
    enabledWebExtensions: {id},
  );

  group('WEBEXT-016 a site\'s extensions reach every webview it builds', () {
    test('the posture carries the plan, and a nested screen keeps it', () {
      final posture = _posture(site());
      final attach = posture.page.extensions as AttachExtensions;
      expect(attach.persistent, isTrue);
      expect(attach.loads.single.id, id);
      expect(attach.loads.single.folder, disk.folderOf(id));
      expect(attach.loads.single.grants.permissions, {'storage'});
      expect(posture.forNested().page.extensions, same(attach));
    });

    test('the native setting names the folder and the grants', () {
      final native = nativeExtensions(
        _posture(site(incognito: true)).page.extensions,
      )!;
      expect(native.persistent, isFalse);
      final context = native.contexts.single;
      expect(context.id, id);
      expect(context.path, disk.folderOf(id));
      expect(context.grantedPermissions, ['storage']);
      expect(context.grantedMatchPatterns, isNotEmpty);
    });

    test('with the experiment off no webview gets the setting', () {
      ExperimentalFeaturesService.instance.debugSet(
        ExperimentalFeature.webExtensions,
        on: false,
      );
      final extensions = _posture(site()).page.extensions;
      expect(
        extensions,
        isA<NoExtensions>().having(
          (n) => n.reason,
          'reason',
          NoExtensionsReason.notOffered,
        ),
      );
      expect(nativeExtensions(extensions), isNull);
    });
  });
}
