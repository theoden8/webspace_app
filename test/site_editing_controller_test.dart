import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_deletion.dart';
import 'package:webspace/controllers/site_editing_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/edit_site_dialog.dart' show SiteEdit;
import 'package:webspace/controllers/site_set_commit.dart';

import 'helpers/model_fixture.dart';

/// The page as the editing flows see it: mounted, and recording each
/// rebuild and each change to the site set.
class _Host implements SiteEditingHost, ShortcutHost, SiteDeletionHost {
  int rebuilds = 0;
  final List<SiteSetChange> commits = [];

  @override
  bool get mounted => true;

  @override
  void rebuild() => rebuilds++;

  @override
  Future<void> commitSites(SiteSetChange change) async => commits.add(change);

  final List<WebViewModel?> activated = [];

  @override
  Future<void> activate(WebViewModel? site) async => activated.add(site);

  @override
  SiteSetStage stageSites(SiteSetChange change) =>
      AppliedStage((_) => commits.add(change));

  @override
  Future<void> endOfFrame() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The edit dialog, answering with [answer]; [whileOpen] is what happens
/// to the page before the user saves.
class _Prompts implements SiteEditingPrompts, ShortcutPrompts {
  _Prompts(this.answer, {this.whileOpen, this.updateHome = false});

  final SiteEdit? answer;
  final void Function()? whileOpen;
  final bool updateHome;
  final List<String> homeOffers = [];

  @override
  Future<bool> updateRedirectHome(String url) async {
    homeOffers.add(url);
    await Future<void>.delayed(Duration.zero);
    whileOpen?.call();
    return updateHome;
  }

  List<Webspace>? offered;

  /// What the add-site screen answers, and what it was offered.
  SiteAddition? addition;
  ({List<Webspace> spaces, Set<WebspaceId> picked})? addOffer;

  @override
  Future<SiteAddition?> addSite({
    String? initialUrl,
    required List<Webspace> spaces,
    required Set<WebspaceId> picked,
  }) async {
    addOffer = (spaces: spaces, picked: picked);
    return addition;
  }

  @override
  Future<SiteEdit?> editSite(WebViewModel site,
      {required List<Webspace> spaces}) async {
    offered = spaces;
    await Future<void>.delayed(Duration.zero);
    whileOpen?.call();
    return answer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SiteRuntime sites;
  late WebViewModel site;
  late _Host host;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    sites = SiteRuntime();
    site = WebViewModel(initUrl: 'https://example.com/', name: 'Example');
    sites.models.add(site);
    host = _Host();
  });

  SiteEditingController controller(_Prompts prompts) => SiteEditingController(
        sites,
        host: host,
        prompts: prompts,
        shell: ShellStore(sites),
        shortcuts: ShortcutController(sites, host: host, prompts: prompts),
        deletion: SiteDeletion(sites, host: host),
      );

  group('redirected homepage suggestions (EDIT-010)', () {
    const canonical = 'https://www.theguardian.com/uk';
    setUp(() {
      site.initUrl = 'https://theguardian.co.uk/';
      site.currentUrl = canonical;
      sites.seed(shown: site);
    });

    test('Save updates the home and preserves routing and the loaded page', () async {
      final loaded = SizedBox.fromSize();
      site.webview = loaded;
      site.domainClaims = [
        DomainClaim.baseDomain('theguardian.co.uk'),
        DomainClaim.exactHost('other.example'),
      ];
      final prompts = _Prompts(null, updateHome: true);
      await controller(prompts).offerRedirectHome(site, url: canonical);
      expect(prompts.homeOffers, [canonical]);
      expect(site.initUrl, canonical);
      expect(site.matchesSiteClaim('https://theguardian.co.uk/'), isTrue);
      expect(site.matchesSiteClaim('https://theguardian.com/world'), isTrue);
      expect(site.matchesSiteClaim('https://other.example/'), isTrue);
      expect(site.webview, same(loaded));
      final restored = WebViewModel.fromJson(site.toJson(), stateSetterF: null);
      expect(restored.initUrl, canonical);
      expect(restored.domainClaims, site.domainClaims);
      expect(restored.offeredRedirectDomains, site.offeredRedirectDomains);
      expect(host.commits.single, isA<SitesEdited>());
    });

    test('Save preserves the implicit old domain when setting a new home', () async {
      final prompts = _Prompts(null, updateHome: true);
      await controller(prompts).offerRedirectHome(site, url: canonical);
      expect(site.initUrl, canonical);
      expect(site.matchesSiteClaim('https://theguardian.co.uk/'), isTrue);
      expect(site.matchesSiteClaim(canonical), isTrue);
    });

    test('a claimed different domain can still become the home', () async {
      site.domainClaims = [DomainClaim.baseDomain('theguardian.com')];
      final prompts = _Prompts(null, updateHome: true);
      await controller(prompts).offerRedirectHome(site, url: canonical);
      expect(prompts.homeOffers, [canonical]);
      expect(site.initUrl, canonical);
      expect(site.domainClaims, [DomainClaim.baseDomain('theguardian.com')]);
    });

    test('a same-domain redirect never suggests a different homepage', () async {
      site.currentUrl = 'https://www.theguardian.co.uk/uk';
      final prompts = _Prompts(null, updateHome: true);
      await controller(prompts).offerRedirectHome(site, url: site.currentUrl);
      expect(prompts.homeOffers, isEmpty);
      expect(site.initUrl, 'https://theguardian.co.uk/');
      expect(site.offeredRedirectDomains, isEmpty);
    });

    test('an internal alias does not suggest a different homepage', () async {
      site.initUrl = 'https://claude.ai/';
      site.currentUrl = 'https://www.anthropic.com/';
      final prompts = _Prompts(null, updateHome: true);
      await controller(prompts).offerRedirectHome(site, url: site.currentUrl);
      expect(prompts.homeOffers, isEmpty);
      expect(site.initUrl, 'https://claude.ai/');
      expect(site.offeredRedirectDomains, isEmpty);
    });

    for (final change in ['home', 'page', 'visibility']) {
      test('changing $change while the question is open cancels the update', () async {
        final prompts = _Prompts(null, updateHome: true, whileOpen: () {
          switch (change) {
            case 'home':
              site.initUrl = 'https://edited.example/';
            case 'page':
              site.currentUrl = 'https://www.theguardian.com/world';
            case 'visibility':
              sites.seed(shown: null);
          }
        });
        await controller(prompts).offerRedirectHome(site, url: canonical);
        expect(prompts.homeOffers, [canonical]);
        expect(site.initUrl, isNot(canonical));
        expect(site.domainClaims, isNull);
      });
    }

    test('Cancel changes no claims and the saved dismissal prevents another offer', () async {
      final prompts = _Prompts(null);
      final editing = controller(prompts);
      await editing.offerRedirectHome(site, url: canonical);
      await editing.offerRedirectHome(site, url: canonical);
      expect(prompts.homeOffers, hasLength(1));
      expect(site.domainClaims, isNull);
      expect(site.initUrl, 'https://theguardian.co.uk/');
      final restored = WebViewModel.fromJson(site.toJson(), stateSetterF: null);
      expect(restored.offeredRedirectDomains,
          {DomainClaim.baseDomain('theguardian.com')});
      expect(restored.matchesSiteClaim(canonical), isFalse);
    });

    test('duplicate callbacks while a question is open show it once', () async {
      final prompts = _Prompts(null, updateHome: true);
      final editing = controller(prompts);
      await Future.wait([
        editing.offerRedirectHome(site, url: canonical),
        editing.offerRedirectHome(site, url: canonical),
      ]);
      expect(prompts.homeOffers, hasLength(1));
    });

    test('a background site and an uncommitted URL show nothing', () async {
      final prompts = _Prompts(null);
      final editing = controller(prompts);
      await editing.offerRedirectHome(site, url: 'https://uncommitted.example/');
      sites.seed(shown: null);
      await editing.offerRedirectHome(site, url: canonical);
      expect(prompts.homeOffers, isEmpty);
      expect(site.offeredRedirectDomains, isEmpty);
    });

    test('another site owning the destination suppresses the offer', () async {
      sites.models.add(WebViewModel(initUrl: 'https://theguardian.com/'));
      final prompts = _Prompts(null, updateHome: true);
      await controller(prompts).offerRedirectHome(site, url: canonical);
      expect(prompts.homeOffers, isEmpty);
      expect(site.domainClaims, isNull);
    });

    test('a conflict appearing while the prompt is open is rechecked', () async {
      final prompts = _Prompts(null, updateHome: true, whileOpen: () {
        sites.models.add(WebViewModel(initUrl: 'https://theguardian.com/'));
      });
      await controller(prompts).offerRedirectHome(site, url: canonical);
      expect(prompts.homeOffers, hasLength(1));
      expect(site.domainClaims, isNull);
    });

    test('deleting the site while the prompt is open cannot recreate it', () async {
      final prompts = _Prompts(null, updateHome: true,
          whileOpen: () => sites.models.remove(site));
      await controller(prompts).offerRedirectHome(site, url: canonical);
      expect(site.domainClaims, isNull);
      expect(host.commits, isEmpty);
    });

    test('prompt history follows URL privacy and stays out of QR shares', () {
      site.offeredRedirectDomains.add(DomainClaim.baseDomain('theguardian.com'));
      expect(SiteSettingsQrCodec.includedKeys, isNot(contains('offeredRedirectDomains')));
      site.incognito = true;
      expect(site.toJson(), isNot(contains('offeredRedirectDomains')));
    });
  });

  test('an edited name is the one the site shows (EDIT-003)', () async {
    final webview = SizedBox.fromSize();
    site.webview = webview;
    site.pageTitle = 'Example Portal';
    await controller(_Prompts((
      name: 'Work Portal',
      url: 'https://example.com/',
      icon: null,
      spaces: null,
    ))).editSite(site);
    expect(site.name, 'Work Portal');
    expect(site.pageTitle, 'Example Portal', reason: 'the page keeps its title');
    expect(host.rebuilds, greaterThan(0));
    expect(host.commits.single, isA<SitesEdited>());
    expect(site.webview, same(webview),
        reason: 'a new name leaves the page loaded');
  });

  test('an edited URL rebuilds the webview at it (EDIT-004)', () async {
    site.webview = SizedBox.fromSize();
    await controller(_Prompts((
      name: 'Example',
      url: 'https://newsite.com/',
      icon: null,
      spaces: null,
    ))).editSite(site);
    expect(site.initUrl, 'https://newsite.com/');
    expect(site.currentUrl, 'https://newsite.com/');
    expect(site.webview, isNull, reason: 'the next build loads the new URL');
    expect(host.commits.single, isA<SitesEdited>());
  });

  test('an edit of a site deleted while the dialog was open changes nothing',
      () async {
    final prompts = _Prompts((
      name: 'Work Portal',
      url: 'https://newsite.com/',
      icon: null,
      spaces: null,
    ), whileOpen: () => sites.models.remove(site));
    await controller(prompts).editSite(site);
    expect(site.name, 'Example');
    expect(site.initUrl, 'https://example.com/');
    expect(host.commits, isEmpty);
  });

  group('a new site\'s webspaces, chosen as it is added (EDIT-012)', () {
    late Webspace work, home;

    setUp(() {
      work = Webspace(name: 'Work', siteIds: []);
      home = Webspace(name: 'Home', siteIds: []);
      sites.webspaces.addAll([Webspace.all(), work, home]);
      sites.selectedWebspaceId = work.id;
    });

    Map<String, dynamic> added() =>
        {'url': 'https://new.example/', 'name': 'New', 'incognito': false};

    test('the screen is offered every named webspace, starting in the one '
        'it is added from', () async {
      final prompts = _Prompts(null);
      await controller(prompts).addSite(into: home.id);
      expect(prompts.addOffer?.spaces, [work, home]);
      expect(prompts.addOffer?.picked, {home.id});
      await controller(prompts).addSite(into: WebspaceId.all);
      expect(prompts.addOffer?.picked, isEmpty, reason: 'All holds it anyway');
      await controller(prompts).addSite();
      expect(prompts.addOffer?.picked, isEmpty, reason: 'from the home');
      expect(host.commits, isEmpty, reason: 'closed, nothing is added');
    });

    test('the site joins the webspaces picked on the screen', () async {
      final prompts = _Prompts(null)
        ..addition = (site: added(), spaces: {home.id});
      await controller(prompts).addSite(into: work.id);
      final change = host.commits.single as SiteAdded;
      expect(change.site.name, 'New');
      expect(change.joins, {home.id});
    });

    test('where no webspaces were offered it joins the selected one',
        () async {
      final prompts = _Prompts(null)..addition = (site: added(), spaces: null);
      await controller(prompts).addSite();
      expect((host.commits.single as SiteAdded).joins, isNull);
    });
  });

  group('the webspaces a site is in, chosen from the site (EDIT-011)', () {
    late WebViewModel other;
    late Webspace work, home;

    setUp(() {
      other = WebViewModel(initUrl: 'https://other.example/', name: 'Other');
      sites.models.add(other);
      work = Webspace(name: 'Work', siteIds: [other.siteId]);
      home = Webspace(name: 'Home', siteIds: [site.siteId, other.siteId]);
      sites.webspaces.addAll([Webspace.all(), work, home]);
    });

    test('the dialog is offered every named webspace', () async {
      final prompts = _Prompts(null);
      await controller(prompts).editSite(site);
      expect(prompts.offered, [work, home]);
    });

    test('Save moves the site and persists the webspaces', () async {
      await controller(_Prompts((
        name: 'Example',
        url: 'https://example.com/',
        icon: null,
        spaces: {work.id},
      ))).editSite(site);
      expect(work.siteIds, [other.siteId, site.siteId]);
      expect(home.siteIds, [other.siteId]);
      expect(host.commits.single, isA<SitesEdited>());
      final saved = (await SharedPreferences.getInstance())
          .getStringList('webspaces')!
          .map((raw) => Webspace.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      expect({for (final ws in saved) if (!ws.isAll) ws.id: ws.siteIds}, {
        work.id: [other.siteId, site.siteId],
        home.id: [other.siteId],
      });
    });

    test('an edit that offered no webspaces leaves them as they were', () async {
      await controller(_Prompts((
        name: 'Renamed',
        url: 'https://example.com/',
        icon: null,
        spaces: null,
      ))).editSite(site);
      expect(work.siteIds, [other.siteId]);
      expect(home.siteIds, [site.siteId, other.siteId]);
      expect(
          (await SharedPreferences.getInstance()).getStringList('webspaces'),
          isNull);
    });
  });
}
