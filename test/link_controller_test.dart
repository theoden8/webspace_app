import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/link_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/dispatch_picker_sheet.dart';
import 'package:webspace/widgets/web_search_sheet.dart';

import 'helpers/fake_webview_controller.dart';
import 'package:webspace/services/webview_controller.dart';

/// The page as the link flows see it, recording what they ask of it in order.
class _Page implements LinkHost {
  _Page(this.sites);

  final SiteRuntime sites;
  final calls = <String>[];
  final controllers = <WebViewModel, FakeWebViewController>{};

  @override
  bool mounted = true;

  @override
  bool kioskLocked = false;

  @override
  void rebuild() {}

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
  }) =>
      calls.add('toast');

  @override
  Future<void> commitSites(SiteSetChange change) async {
    calls.add('commit ${change.runtimeType}');
    sites.apply(change);
  }

  @override
  Future<void> activate(int index) async {
    calls.add('activate $index');
    sites.current = index;
  }

  @override
  Future<void> saveCurrentIndex() async => calls.add('saveCurrentIndex');

  @override
  void evictCache(String siteId) => calls.add('evict $siteId');

  @override
  Future<void> revealSite(WebViewModel model, {required int index}) async =>
      calls.add('reveal $index');

  @override
  Future<void> registerSite(WebViewModel model, {bool activate = true}) async =>
      calls.add('register ${model.initUrl}');

  @override
  Future<void> addSiteFromQr(Map<String, dynamic> settings) async =>
      calls.add('addSiteFromQr');

  @override
  WebViewController? controllerOf(WebViewModel model) =>
      controllers.putIfAbsent(model, FakeWebViewController.new);

  @override
  Future<void> launchNestedFor(WebViewModel model, {required String url,
         bool opensFromTab = true}) async =>
      calls.add('launchNested ${model.siteId} $url');

  @override
  Future<void> openNested(DispatchOpenNested action,
          {WebViewModel? source}) async =>
      calls.add('openNested ${action.siteId} ${action.url}');

  @override
  Future<void> unloadSite(int index, {required UnloadReason reason}) async {
    calls.add('unload $index ${reason.name}');
    sites.loaded.remove(index);
  }

  @override
  Future<void> wipeContainer(String siteId) async => calls.add('wipe $siteId');

  @override
  ArchiveHandle? archiveOf(WebViewModel model) => null;
}

class _Prompts implements LinkPrompts {
  final asked = <String>[];
  SitePick? lastPick;
  DispatchChoice? Function(SitePick pick) choose = (_) => null;
  bool acceptHtml = false;

  @override
  Future<WebSearchRequest?> webSearch(WebSearchAsk ask) async {
    asked.add('webSearch');
    return null;
  }

  @override
  Future<DispatchChoice?> pickSite(SitePick pick) async {
    asked.add('pickSite');
    lastPick = pick;
    return choose(pick);
  }

  @override
  Future<bool> reviewSharedHtml({
    required String title,
    required String url,
  }) async {
    asked.add('reviewSharedHtml $title');
    return acceptHtml;
  }
}

class _NoTabs extends Fake implements TabsHost {}

class _NoResidency extends Fake implements ResidencyHost {}

class _NoNavStates extends Fake implements WebViewStateStorage {}

void main() {
  late SiteRuntime sites;
  late _Page page;
  late _Prompts prompts;
  late LinkController links;

  void setUpSites(List<WebViewModel> models) {
    sites = SiteRuntime()..apply(SitesLoaded(models));
    page = _Page(sites);
    prompts = _Prompts();
    links = LinkController(
      sites,
      host: page,
      prompts: prompts,
      tabs: TabsController(
        sites,
        host: _NoTabs(),
        navStates: _NoNavStates(),
        residency: _NoResidency(),
      ),
    );
  }

  test('a share into an incognito site resets it before it loads (LIR-011)',
      () async {
    final github = WebViewModel(initUrl: 'https://github.com/')
      ..incognito = true
      ..currentUrl = 'https://github.com/settings'
      ..cookies = const [];
    final other = WebViewModel(initUrl: 'https://example.org/');
    setUpSites([github, other]);
    sites.loaded.addAll({0, 1});
    sites.current = 1;

    await links.dispatchInbound(
        InboundUrl(Uri.parse('https://github.com/theoden8/webspace_app')));

    expect(page.calls, [
      'reveal 0',
      'evict ${github.siteId}',
      'unload 0 homeReset',
      'wipe ${github.siteId}',
      'activate 0',
      'commit SitesEdited',
    ]);
    expect(page.controllers[github]!.calls,
        ['loadUrl https://github.com/theoden8/webspace_app']);
    expect(github.currentUrl, 'https://github.com/theoden8/webspace_app');
    expect(prompts.asked, isEmpty);
  });

  test('a link no site claims asks which site, and opens the pick (LIR-010)',
      () async {
    final github = WebViewModel(initUrl: 'https://github.com/');
    final gitlab = WebViewModel(initUrl: 'https://gitlab.com/');
    setUpSites([github, gitlab]);
    prompts.choose = (pick) => DispatchChoiceOpen(pick.otherSites.last);

    await links.dispatchInbound(
        InboundUrl(Uri.parse('https://example.org/page')));

    final pick = prompts.lastPick!;
    expect(pick.winners, isEmpty);
    expect(pick.otherSites, [github, gitlab]);
    expect(pick.canBind, isTrue);
    expect(pick.canCreate, isTrue);
    expect(pick.outboundSourceName, isNull,
        reason: 'an inbound link has no site it came from');
    expect(page.calls,
        ['openNested ${gitlab.siteId} https://example.org/page'],
        reason: 'outside the picked site\'s domain it opens nested over it');
  });

  test('a dismissed picker opens nothing', () async {
    setUpSites([WebViewModel(initUrl: 'https://github.com/')]);

    await links.dispatchInbound(
        InboundUrl(Uri.parse('https://example.org/page')));

    expect(prompts.asked, ['pickSite']);
    expect(page.calls, isEmpty);
  });

  test('a shared HTML file becomes a site only once reviewed (LIR-012)',
      () async {
    setUpSites([]);

    await links.dispatchInbound(const InboundHtml(
        content: '<p>hi</p>', suggestedTitle: ' Notes '));

    expect(prompts.asked, ['reviewSharedHtml Notes']);
    expect(page.calls, isEmpty, reason: 'declined: nothing is created');
  });
}
