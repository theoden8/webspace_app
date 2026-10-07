import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/controllers/wake_candidates.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

/// NOTIF-016: which sites a wake checks, from the app's own models. The wake
/// used to take only loaded sites with a live webview, so a test of the engine
/// alone could not see that every site in a process launched for the wake was
/// dropped before the engine ran.
void main() {
  const env = WakeEnvironment(
    containers: true,
    torUp: true,
    proxyIsGlobal: false,
  );

  WebViewModel site(String url,
          {bool notifications = true,
          bool incognito = false,
          UserProxySettings? proxy}) =>
      WebViewModel(
        initUrl: url,
        name: url,
        notificationsEnabled: notifications,
        incognito: incognito,
        proxySettings: proxy,
      );

  List<WakePlanEntry> planFor(
    List<WebViewModel> models, {
    Set<int> loaded = const {},
    Set<int> withWebview = const {},
    WakeEnvironment environment = env,
  }) =>
      BackgroundWakeEngine.plan([
        for (var i = 0; i < models.length; i++)
          wakeCandidateFor(
            models[i],
            loaded: loaded.contains(i),
            hasWebview: withWebview.contains(i),
            proxyBindable: true,
            env: environment,
          ),
      ]).entries;

  test('unloaded notification sites are checked headless', () {
    final entries = planFor([site('https://a.test'), site('https://b.test')]);
    expect(entries.map((e) => e.mode), [WakeMode.headless, WakeMode.headless]);
  });

  test('a loaded site without a webview (a background launch) is headless',
      () {
    final entries = planFor([site('https://a.test')], loaded: {0});
    expect(entries.single.mode, WakeMode.headless);
  });

  test('a loaded site with a webview reloads in place', () {
    final entries =
        planFor([site('https://a.test')], loaded: {0}, withWebview: {0});
    expect(entries.single.mode, WakeMode.live);
  });

  test('sites without notifications are not in the wake', () {
    final entries = planFor([
      site('https://a.test', notifications: false),
      site('https://b.test'),
    ]);
    expect(entries.single.site.name, 'https://b.test');
  });

  test('incognito and legacy isolation keep a site out, with the reason', () {
    expect(planFor([site('https://a.test', incognito: true)]).single.skip,
        WakeSkip.incognito);
    expect(
      planFor(
        [site('https://a.test')],
        environment: const WakeEnvironment(
            containers: false, torUp: true, proxyIsGlobal: false),
      ).single.skip,
      WakeSkip.legacyIsolation,
    );
  });

  test('a Tor site waits for Tor', () {
    final tor = site('https://a.test',
        proxy: UserProxySettings(type: ProxyType.TOR));
    expect(
      planFor(
        [tor],
        environment: const WakeEnvironment(
            containers: true, torUp: false, proxyIsGlobal: false),
      ).single.skip,
      WakeSkip.torDown,
    );
  });

  test('Android: a site behind another proxy than the live one is skipped',
      () {
    const android =
        WakeEnvironment(containers: true, torUp: true, proxyIsGlobal: true);
    final entries = planFor(
      [
        site('https://a.test',
            proxy: UserProxySettings(
                type: ProxyType.SOCKS5, address: '127.0.0.1:9050')),
        site('https://b.test'),
      ],
      loaded: {0},
      withWebview: {0},
      environment: android,
    );
    expect(entries[0].mode, WakeMode.live);
    expect(entries[1].skip, WakeSkip.proxyConflict);
  });

  test('Android: sites on the same proxy share one route', () {
    const android =
        WakeEnvironment(containers: true, torUp: true, proxyIsGlobal: true);
    final a = site('https://a.test');
    final b = site('https://b.test');
    expect(wakeRouteFor(a, proxyIsGlobal: android.proxyIsGlobal),
        wakeRouteFor(b, proxyIsGlobal: android.proxyIsGlobal));
    expect(planFor([a, b], environment: android).map((e) => e.mode),
        everyElement(WakeMode.headless));
  });

  test('per-site proxies carry no route unless the site uses Tor', () {
    expect(wakeRouteFor(site('https://a.test'), proxyIsGlobal: false), isNull);
    expect(
      wakeRouteFor(
          site('https://a.test',
              proxy: UserProxySettings(type: ProxyType.TOR)),
          proxyIsGlobal: false),
      startsWith('exit='),
    );
  });
}
