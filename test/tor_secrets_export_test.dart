// TOR-009: nothing the Tor runtime mints may reach a settings backup.
//
// Task 8.2 of the tor-proxy change, and the one item its status note calls a
// genuine gap. A backup gets emailed, synced and pasted into issues, so the
// rule is the same as for proxy passwords (PWD-005) and bridge lines
// (TOR-017): the file is uniformly secret-less.
//
// What there is to leak is per-launch, not configuration. A site pinned to
// Tor stores `ProxyType.TOR` and nothing else; the SOCKS5 endpoint and the
// credential tuple that keeps its circuit apart from other sites' are
// materialised by `TorService.socksFor` at use time from the session secret.
// A future `toJson` that serialised the *effective* proxy rather than the
// configured one would put both in the file, which is what this catches.
//
// The needle is proved live before it is looked for: an absence test whose
// secret was never in play passes against an app that leaks a different one.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

class _Runtime implements TorRuntime {
  final _events = StreamController<TorStatus>.broadcast();

  @override
  bool get isAvailable => true;

  @override
  Stream<TorStatus> get events => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> rebuildCircuits() async {}

  @override
  Future<void> applyExitCountry(String? exitNodes) async {}

  @override
  Future<int> startTransport(String transport) async => 0;

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {}

  @override
  Future<void> setSocksIsolation({required bool isolateDestAddr}) async {}

  void emit(TorStatus s) => _events.add(s);
  Future<void> dispose() => _events.close();
}

void main() {
  const sessionSecret = 'tor-session-needle-9b2e';
  const socksPort = 41337;

  late _Runtime runtime;

  setUp(() async {
    runtime = _Runtime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: sessionSecret),
    );
    // The gate is capability AND developer mode; socksFor answers null with
    // it shut, which would make the needle unreachable and the test vacuous.
    DeveloperModeService.instance.debugSet(true);
  });

  tearDown(() async {
    await TorService.reset();
    await runtime.dispose();
    DeveloperModeService.instance.debugSet(false);
  });

  test('Tor secrets never appear in exports (TOR-009)', () async {
    await TorService.instance.syncHolders({'tor-site'});
    runtime.emit(const TorUp('127.0.0.1', socksPort));
    await Future<void>.delayed(Duration.zero);

    // The needle, proved real: this is what a site's traffic actually
    // authenticates with, and what a leak would carry.
    final live = TorService.instance.socksFor(siteId: 'tor-site');
    expect(live, isNotNull,
        reason: 'the runtime is up and the gate is open, so a site must '
            'resolve to SOCKS5 settings; without them this test looks for '
            'a secret that was never minted');
    // Derived per reason rather than shared (TOR-003), so the tuple a site
    // authenticates with is not the session secret itself. Both are needles:
    // the derived one is what a leak would actually carry.
    final derived = live!.password;
    expect(derived, isNotNull);
    expect(derived, isNot(sessionSecret));
    expect(live.address, contains('$socksPort'));

    final backup = SettingsBackupService.createBackup(
      webViewModels: [
        WebViewModel(
          siteId: 'tor-site',
          initUrl: 'https://a.com',
          proxySettings: UserProxySettings(type: ProxyType.TOR),
        ),
      ],
      webspaces: [Webspace.all()],
      themeMode: 0,
      globalPrefs: <String, Object?>{
        kGlobalOutboundProxyKey:
            jsonEncode(UserProxySettings(type: ProxyType.TOR).toJson()),
      },
    );
    final exported = SettingsBackupService.exportToJson(backup);

    expect(exported.contains(sessionSecret), isFalse,
        reason: 'the per-launch session secret reached the backup file');
    expect(exported.contains(derived!), isFalse,
        reason: "the site's own SOCKS credential reached the backup file");
    expect(exported.contains('$socksPort'), isFalse,
        reason: "tor's loopback port is per-launch state, not configuration: "
            'a backup carrying it would also describe when the machine ran '
            'Tor');
    expect(exported.contains('tor-site'), isTrue,
        reason: 'the site itself must still be in the backup, or the two '
            'assertions above would pass on an empty file');

    // The configured type survives, which is the whole of what a Tor site
    // needs to be restored: everything else is minted at use time.
    final restored = SettingsBackup.fromJson(jsonDecode(exported));
    final site = WebViewModel.fromJson(restored.sites.single, null);
    expect(site.proxySettings.type, ProxyType.TOR);
    expect(site.proxySettings.password, isNull);
    expect(site.proxySettings.username, isNull);
  });
}
