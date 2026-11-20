import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/services/link_new_tab_click.dart';
import 'package:webspace/services/page_focus.dart';
import 'package:webspace/services/page_scripts.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/opensearch_engine.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/host_hooks.dart';

const _home = 'https://example.com/';

/// A site's config with an icon and a search target, as its own webview has
/// them and a popup it spawns inherits them.
WebViewConfig _config({
  List<UserScriptConfig> scripts = const [],
  void Function(String url)? onLinkNewTab,
}) =>
    WebViewConfig(
      posture: WebViewModel(initUrl: _home, userScripts: scripts).sitePosture(
        globalUserScripts: const <UserScriptConfig>[],
        isolation: fakeContainers(),
      ),
      hooks: inertHostHooks(isolation: fakeContainers),
      initialUrl: _home,
      cacheFirst: false,
      siteIcon: SiteIconTarget(siteUrl: _home, onIcon: (_) {}),
      siteSearch: SiteSearchTarget(siteUrl: _home, onSearch: (_) {}),
      onLinkNewTab: onLinkNewTab,
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

  test('only the own view of a site that opens new tabs takes the new-tab '
      'click script, in the top document (TAB-029)', () {
    List<inapp.UserScript> clicks(WebViewConfig config,
            {required OwnView? own}) =>
        [
          for (final s
              in PageScripts.buildPageScripts(config, own: own).userScripts)
            if (s.groupName == ShimGroup.linkNewTabClick.groupName) s,
        ];
    final opens = _config(onLinkNewTab: (_) {});
    expect(clicks(opens, own: null), isEmpty, reason: 'a popup opens no tab');
    expect(clicks(_config(), own: (keys: null)), isEmpty,
        reason: 'a nested screen has no tab list');
    final installed = clicks(opens, own: (keys: null));
    expect(installed, hasLength(1),
        reason: 'the test host is a desktop, which has a key convention');
    expect(installed.single.forMainFrameOnly, isTrue);
    expect(installed.single.source, contains(kLinkNewTabHandler));
  });

  test('a Mac opens a new tab on Command-click, the others on Control-click '
      '(TAB-029)', () {
    expect(KeyConvention.mac.newTabClickKey, 'metaKey');
    expect(KeyConvention.pc.newTabClickKey, 'ctrlKey');
    expect(KeyConvention.android.newTabClickKey, 'ctrlKey');
  });

  test('a new-tab click names only an http(s) link (TAB-029)', () {
    expect(linkOfNewTabClick(['https://example.org/a']),
        'https://example.org/a');
    expect(linkOfNewTabClick(['http://example.org/']), 'http://example.org/');
    expect(linkOfNewTabClick(['javascript:alert(1)']), isNull);
    expect(linkOfNewTabClick(['file:///etc/passwd']), isNull);
    expect(linkOfNewTabClick([42]), isNull);
    expect(linkOfNewTabClick([]), isNull);
    expect(linkOfNewTabClick(['https://a/', 'https://b/']), isNull);
  });
}
