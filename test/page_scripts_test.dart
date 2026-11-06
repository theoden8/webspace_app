import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/page_focus.dart';
import 'package:webspace/services/page_scripts.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/opensearch_engine.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/capture_fakes.dart';
import 'helpers/isolations.dart';

const _home = 'https://example.com/';

WebViewHostHooks _hooks() => WebViewHostHooks(
      isolation: fakeContainers,
      globalUserScripts: () => const [],
      save: () async {},
      rebuild: () {},
      launchNested: (_, {required posture, homeTitle}) {},
      openInBrowser: (_) async => false,
      openSiteSettings: (_) {},
      showPopup: (_, {required url, required kind}) async {},
      externalScheme: (_, {required loadIn}) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: (_, {required port, required certificate}) async =>
          false,
      networkSignIn: (_) async {},
      httpAuth: (_) async => null,
      media: FakePrompter(),
    );

/// A site's config with an icon and a search target, as its own webview has
/// them and a popup it spawns inherits them.
WebViewConfig _config({List<UserScriptConfig> scripts = const []}) =>
    WebViewConfig(
      posture: WebViewModel(initUrl: _home, userScripts: scripts).sitePosture(
        globalUserScripts: const <UserScriptConfig>[],
        isolation: fakeContainers(),
      ),
      hooks: _hooks(),
      initialUrl: _home,
      cacheFirst: false,
      siteIcon: SiteIconTarget(siteUrl: _home, onIcon: (_) {}),
      siteSearch: SiteSearchTarget(siteUrl: _home, onSearch: (_) {}),
    );

/// The group each installed script was injected as.
List<ShimGroup> _groups(List<inapp.UserScript> scripts) => [
      for (final s in scripts)
        ShimGroup.values.singleWhere((g) =>
            g.groupName == s.groupName &&
            (g.at == ShimTime.start) ==
                (s.injectionTime ==
                    inapp.UserScriptInjectionTime.AT_DOCUMENT_START)),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scripts install in the order ShimGroup declares', () {
    final built = PageScripts.buildPageScripts(
      _config(scripts: [
        UserScriptConfig(name: 'end', source: 'END();'),
        UserScriptConfig(
          name: 'start',
          source: 'START();',
          injectionTime: UserScriptInjectionTime.atDocumentStart,
          bypassSitePolicy: true,
        ),
      ]),
      own: (keys: PageKeys.remote),
    );
    final groups = _groups(built.userScripts);
    final order = [for (final g in groups) g.index];
    expect(order, [...order]..sort(),
        reason: 'a group installs after every group declared before it');
    expect(groups, containsAll([
      ShimGroup.scriptFetch,
      ShimGroup.userScriptsAtStart,
      ShimGroup.userScriptsAtEnd,
      ShimGroup.remoteEdge,
      ShimGroup.iconLinkWatcher,
      ShimGroup.searchLinkWatcher,
    ]));
  });

  test('only a device a remote drives takes the edge script (NAV-016)', () {
    List<inapp.UserScript> edge(OwnView? own) => [
          for (final s
              in PageScripts.buildPageScripts(_config(), own: own).userScripts)
            if (s.groupName == ShimGroup.remoteEdge.groupName) s,
        ];
    expect(edge(null), isEmpty);
    expect(edge((keys: null)), isEmpty);
    expect(edge((keys: PageKeys.keyboard)), isEmpty,
        reason: 'a keyboard never leaves the page');
    final remote = edge((keys: PageKeys.remote));
    expect(remote, hasLength(1));
    expect(remote.single.forMainFrameOnly, isFalse,
        reason: 'a key reaches only the frame holding focus, which passes it '
            'up to the top document');
    expect(remote.single.source, contains(kRemoteEdgeHandler));
  });

  test('a popup or a headless check never reports into the site icon or '
      'search', () {
    Set<ShimGroup> groups(OwnView? own) => _groups(
            PageScripts.buildPageScripts(_config(), own: own).userScripts)
        .toSet();
    expect(groups((keys: null)),
        containsAll([ShimGroup.iconLinkWatcher, ShimGroup.searchLinkWatcher]));
    expect(groups(null), isNot(contains(ShimGroup.iconLinkWatcher)));
    expect(groups(null), isNot(contains(ShimGroup.searchLinkWatcher)));
  });

  test('a popup takes the shims of the site that spawned it', () {
    Set<ShimGroup> groups(OwnView? own) => _groups(
            PageScripts.buildPageScripts(_config(), own: own).userScripts)
        .toSet();
    final shared = groups(null);
    expect(groups((keys: null)).difference(shared),
        {ShimGroup.iconLinkWatcher, ShimGroup.searchLinkWatcher});
    expect(shared, containsAll([
      ShimGroup.doNotTrack,
      ShimGroup.targetBlankRewrite,
      ShimGroup.antiFingerprinting,
      ShimGroup.blobUrlCapture,
      ShimGroup.locationSpoof,
      ShimGroup.themeColorScheme,
    ]));
  });
}
