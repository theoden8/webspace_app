import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/onion_location_controller.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/onion_location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/model_fixture.dart';

const _proton =
    'protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd.onion';
final _endpoint =
    OnionEndpoint.of(from: 'https://proton.me', to: 'https://$_proton/')!;
final _now = DateTime.utc(2026, 11, 21);

class _Host implements PageHost {
  final commits = <FunnelChange>[];

  @override
  bool mounted = true;

  @override
  void rebuild() {}

  @override
  void toast(
    Localized Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) {}

  @override
  Future<void> commitSites(FunnelChange change) async => commits.add(change);
}

class _Prompts implements OnionPrompts {
  _Prompts(this.answer);
  OnionAnswer? answer;
  final asked = <({String site, String onion})>[];

  @override
  Future<OnionAnswer?> offerOnion({required String site, required String onion}) async {
    asked.add((site: site, onion: onion));
    return answer;
  }
}

void main() {
  late SiteRuntime sites;
  late _Host host;
  late _Prompts prompts;
  late WebViewModel site;
  late int rebuilds;
  late int checks;
  late OnionCheck found;

  OnionLocationController controller() => OnionLocationController(
        sites,
        host: host,
        prompts: prompts,
        settingsSaved: () async => rebuilds++,
        clock: () => _now,
        check: (_) async {
          checks++;
          return found;
        },
      );

  setUp(() {
    site = WebViewModel(
      initUrl: 'https://proton.me/mail',
      name: 'Proton',
      proxySettings: UserProxySettings(type: ProxyType.TOR),
    );
    sites = SiteRuntime()..applied(SitesLoaded([site]));
    sites.seed(loaded: [site], shown: site);
    host = _Host();
    prompts = _Prompts(OnionAnswer.accepted);
    rebuilds = 0;
    checks = 0;
    found = OnionAnnounced(_endpoint);
  });

  test('ONION-003: a new address is offered, and accepting rebuilds the site '
      'on screen onto it', () async {
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(prompts.asked, [(site: 'Proton', onion: _proton)]);
    expect(site.onionLocation?.answer, OnionAnswer.accepted);
    expect(site.onionLocation?.fallback, OnionFallback.none);
    expect(site.onionRoute?.endpoint, _endpoint);
    expect(rebuilds, 1);
  });

  test('declining is saved and not asked again; a dismissal asks again',
      () async {
    prompts.answer = OnionAnswer.declined;
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(site.onionLocation?.answer, OnionAnswer.declined);
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(prompts.asked, hasLength(1));

    site.onionLocation = null;
    prompts.answer = null;
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(site.onionLocation?.answer, isNull);
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(prompts.asked, hasLength(3));
    expect(rebuilds, 0);
  });

  test('ONION-007: a site off Tor is never checked', () async {
    site.proxySettings = UserProxySettings(type: ProxyType.DEFAULT);
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(checks, 0);
    expect(site.onionLocation, isNull);
  });

  test('ONION-008: a site is checked once a run, and on the onion only when '
      'its check is old', () async {
    final onions = controller();
    await onions.firstPageLoaded(site, url: 'https://proton.me/mail');
    await onions.firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(checks, 1);

    await controller().firstPageLoaded(site, url: 'https://$_proton/mail');
    expect(checks, 1, reason: 'checked today');

    site.onionLocation = SiteOnion(
        endpoint: _endpoint,
        checked: _now.subtract(const Duration(days: 31)),
        answer: OnionAnswer.accepted,
        fallback: OnionFallback.clearnet);
    await controller().firstPageLoaded(site, url: 'https://$_proton/mail');
    expect(checks, 2);
    expect(site.onionLocation?.checked, _now);
    expect(site.onionLocation?.fallback, OnionFallback.clearnet);
    expect(prompts.asked, hasLength(1), reason: 'the same address asks once');
  });

  test('a withdrawn address in use is forgotten and the site rebuilt', () async {
    site.onionLocation = SiteOnion(
        endpoint: _endpoint,
        checked: _now,
        answer: OnionAnswer.accepted,
        fallback: OnionFallback.none);
    found = const NothingAnnounced();
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(site.onionLocation, isNull);
    expect(rebuilds, 1);
  });

  test('a failed check keeps what was learned', () async {
    final saved = SiteOnion(
        endpoint: _endpoint,
        checked: _now,
        answer: OnionAnswer.accepted,
        fallback: OnionFallback.none);
    site.onionLocation = saved;
    found = const OnionCheckFailed('down');
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(site.onionLocation, same(saved));
    expect(host.commits, isEmpty);
  });

  test('a site not on screen learns the address but is not asked yet',
      () async {
    final other = WebViewModel(initUrl: 'https://example.com/');
    sites.applied(SiteAdded(other));
    sites.seed(loaded: [site, other], shown: other);
    await controller().firstPageLoaded(site, url: 'https://proton.me/mail');
    expect(site.onionLocation?.endpoint, _endpoint);
    expect(site.onionLocation?.answer, isNull);
    expect(prompts.asked, isEmpty);
  });
}
