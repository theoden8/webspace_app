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
  _Prompts(this.answer, {this.whileOpen, this.addDomain = false});

  final SiteEdit? answer;
  final void Function()? whileOpen;
  final bool addDomain;
  final List<DomainClaim> domainOffers = [];

  @override
  Future<bool> addRedirectDomain(DomainClaim claim) async {
    domainOffers.add(claim);
    await Future<void>.delayed(Duration.zero);
    whileOpen?.call();
    return addDomain;
  }

  @override
  Future<SiteEdit?> editSite(WebViewModel site) async {
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

  group('redirected domain suggestions (EDIT-010)', () {
    const canonical = 'https://www.theguardian.com/uk';
    setUp(() {
      site.initUrl = 'https://theguardian.co.uk/';
      site.currentUrl = canonical;
      sites.seed(shown: site);
    });

    test('Add preserves the home and existing claims and saves the new domain', () async {
      final prompts = _Prompts(null, addDomain: true);
      await controller(prompts).offerRedirectDomain(site, url: canonical);
      expect(prompts.domainOffers, [DomainClaim.baseDomain('theguardian.com')]);
      expect(site.initUrl, 'https://theguardian.co.uk/');
      expect(site.matchesSiteClaim('https://theguardian.co.uk/'), isTrue);
      expect(site.matchesSiteClaim('https://theguardian.com/world'), isTrue);
      final restored = WebViewModel.fromJson(site.toJson(), stateSetterF: null);
      expect(restored.domainClaims, site.domainClaims);
      expect(restored.offeredRedirectDomains, site.offeredRedirectDomains);
      expect(host.commits.single, isA<SitesEdited>());
    });

    test('Cancel changes no claims and the saved dismissal prevents another offer', () async {
      final prompts = _Prompts(null);
      final editing = controller(prompts);
      await editing.offerRedirectDomain(site, url: canonical);
      await editing.offerRedirectDomain(site, url: canonical);
      expect(prompts.domainOffers, hasLength(1));
      expect(site.domainClaims, isNull);
      final restored = WebViewModel.fromJson(site.toJson(), stateSetterF: null);
      expect(restored.offeredRedirectDomains,
          {DomainClaim.baseDomain('theguardian.com')});
      expect(restored.matchesSiteClaim(canonical), isFalse);
    });

    test('duplicate callbacks while a question is open show it once', () async {
      final prompts = _Prompts(null, addDomain: true);
      final editing = controller(prompts);
      await Future.wait([
        editing.offerRedirectDomain(site, url: canonical),
        editing.offerRedirectDomain(site, url: canonical),
      ]);
      expect(prompts.domainOffers, hasLength(1));
    });

    test('a known domain, a background site, and an uncommitted URL show nothing', () async {
      final prompts = _Prompts(null);
      final editing = controller(prompts);
      await editing.offerRedirectDomain(site, url: 'https://uncommitted.example/');
      sites.seed(shown: null);
      await editing.offerRedirectDomain(site, url: canonical);
      sites.seed(shown: site);
      site.domainClaims = [DomainClaim.baseDomain('theguardian.com')];
      await editing.offerRedirectDomain(site, url: canonical);
      expect(prompts.domainOffers, isEmpty);
      expect(site.offeredRedirectDomains, isEmpty);
    });

    test('another site owning the destination suppresses the offer', () async {
      sites.models.add(WebViewModel(initUrl: 'https://theguardian.com/'));
      final prompts = _Prompts(null, addDomain: true);
      await controller(prompts).offerRedirectDomain(site, url: canonical);
      expect(prompts.domainOffers, isEmpty);
      expect(site.domainClaims, isNull);
    });

    test('a conflict appearing while the prompt is open is rechecked', () async {
      final prompts = _Prompts(null, addDomain: true, whileOpen: () {
        sites.models.add(WebViewModel(initUrl: 'https://theguardian.com/'));
      });
      await controller(prompts).offerRedirectDomain(site, url: canonical);
      expect(prompts.domainOffers, hasLength(1));
      expect(site.domainClaims, isNull);
    });

    test('deleting the site while the prompt is open cannot recreate it', () async {
      final prompts = _Prompts(null, addDomain: true,
          whileOpen: () => sites.models.remove(site));
      await controller(prompts).offerRedirectDomain(site, url: canonical);
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
    await controller(_Prompts(
            (name: 'Work Portal', url: 'https://example.com/', icon: null)))
        .editSite(site);
    expect(site.name, 'Work Portal');
    expect(site.pageTitle, 'Example Portal', reason: 'the page keeps its title');
    expect(host.rebuilds, greaterThan(0));
    expect(host.commits.single, isA<SitesEdited>());
    expect(site.webview, same(webview),
        reason: 'a new name leaves the page loaded');
  });

  test('an edited URL rebuilds the webview at it (EDIT-004)', () async {
    site.webview = SizedBox.fromSize();
    await controller(_Prompts(
            (name: 'Example', url: 'https://newsite.com/', icon: null)))
        .editSite(site);
    expect(site.initUrl, 'https://newsite.com/');
    expect(site.currentUrl, 'https://newsite.com/');
    expect(site.webview, isNull, reason: 'the next build loads the new URL');
    expect(host.commits.single, isA<SitesEdited>());
  });

  test('an edit of a site deleted while the dialog was open changes nothing',
      () async {
    final prompts = _Prompts(
        (name: 'Work Portal', url: 'https://newsite.com/', icon: null),
        whileOpen: () => sites.models.remove(site));
    await controller(prompts).editSite(site);
    expect(site.name, 'Example');
    expect(site.initUrl, 'https://example.com/');
    expect(host.commits, isEmpty);
  });
}
