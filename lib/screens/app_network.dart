import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/saved_proxies.dart';
import 'package:webspace/screens/tor_status.dart';
import 'package:webspace/screens/trusted_certificates.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_form_engine.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/widgets/dirty_guard.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/proxy_test_tile.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/toast.dart';
import 'package:webspace/widgets/tor_status_card.dart';

/// The App Settings summary of the app-wide route: where traffic goes, and
/// how many saved proxies the library holds.
String appNetworkSummary(AppLocalizations loc) {
  final current = GlobalOutboundProxy.current;
  final route = switch (current.type) {
    ProxyType.DEFAULT => null,
    ProxyType.TOR => torRouteLabel(loc),
    ProxyType.SAVED ||
    ProxyType.GATEWAY =>
      libraryRouteLabel(loc, route: current),
    ProxyType.HTTP ||
    ProxyType.HTTPS ||
    ProxyType.SOCKS5 =>
      routeLabel(current),
  };
  final saved = ProxyLibrary.data.length;
  return [
    route ?? loc.networkSummaryDefault,
    if (saved > 0) loc.savedProxiesCount(saved),
  ].join(' · ');
}

/// How every site's traffic leaves the app: the app-wide proxy, the proxy
/// library it picks from, Tor, and the certificates the user trusted.
class AppNetworkScreen extends StatefulWidget {
  const AppNetworkScreen({
    super.key,
    this.siteNames = const {},
    this.onOutboundProxyChanged,
    this.siteProxies,
    this.onSavedProxiesChanged,
  });

  /// `siteId` -> display name, for the Tor status screen's list of users.
  final Map<String, String> siteNames;

  /// Fired after the global outbound proxy is updated. Parent should
  /// dispose every loaded webview so the next render re-applies the new
  /// proxy: on Android the singleton `inapp.ProxyController` only refreshes
  /// when `setProxySettings` is called again (which happens in
  /// [WebViewModel.setController]), and on iOS / macOS / Linux the proxy
  /// is sealed into the per-site `WKWebsiteDataStore` /
  /// `WebKitNetworkSession` at WebView construction. Without this the
  /// "global proxy applies via DEFAULT fallthrough" contract advertised
  /// in the UI hint silently doesn't take effect until the next app
  /// restart.
  final VoidCallback? onOutboundProxyChanged;

  /// Every site's proxy setting, so the proxy library can say what uses each
  /// entry (PROXY-030).
  final List<UserProxySettings> Function()? siteProxies;

  /// Fired after the proxy library was edited. Same duty as
  /// [onOutboundProxyChanged]: a webview bound to a saved proxy's old
  /// configuration keeps routing through it until it is rebuilt.
  final VoidCallback? onSavedProxiesChanged;

  @override
  State<AppNetworkScreen> createState() => _AppNetworkScreenState();
}

class _AppNetworkScreenState extends State<AppNetworkScreen>
    with SettingsOpenGuard, DirtyGuard<AppNetworkScreen> {
  // Global outbound proxy state. Mirrors the per-site proxy UI in
  // [lib/screens/site_network.dart] but applies to *every* Dart-side outbound
  // call (DNS blocklist downloads, ClearURLs rules, content blocker rules,
  // LocalCDN catalog, OSM map tiles in the location picker, etc.) and
  // also acts as the fallthrough for any per-site proxy whose type is
  // [ProxyType.DEFAULT].
  late UserProxySettings _outboundProxy;
  final _outboundProxyAddressController = TextEditingController();
  final _outboundProxyUsernameController = TextEditingController();
  final _outboundProxyPasswordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final current = GlobalOutboundProxy.current;
    _outboundProxy = UserProxySettings(
      type: current.type,
      address: current.address,
      username: current.username,
      password: current.password,
      savedProxyId: current.savedProxyId,
      gatewayId: current.gatewayId,
      credentialsId: current.credentialsId,
    );
    _outboundProxyAddressController.text = current.address ?? '';
    _outboundProxyUsernameController.text = current.username ?? '';
    _outboundProxyPasswordController.text = current.password ?? '';
    markClean();
    _outboundProxyAddressController.addListener(_onProxyFieldChanged);
    _outboundProxyUsernameController.addListener(_onProxyFieldChanged);
    _outboundProxyPasswordController.addListener(_onProxyFieldChanged);
  }

  @override
  void dispose() {
    _outboundProxyAddressController.dispose();
    _outboundProxyUsernameController.dispose();
    _outboundProxyPasswordController.dispose();
    super.dispose();
  }

  String? _validateOutboundProxyAddress(String value) {
    final loc = AppLocalizations.of(context);
    if (!_outboundProxy.type.typesAddress) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return loc.appSettingsProxyAddressRequired;
    final parts = trimmed.split(':');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      return loc.appSettingsProxyFormatHostPort;
    }
    final port = int.tryParse(parts[1]);
    if (port == null || port < 1 || port > 65535) {
      return loc.appSettingsProxyInvalidPort;
    }
    return null;
  }

  bool _saving = false;
  bool _saveAgain = false;

  /// One save at a time. A pick made while an earlier save is still writing
  /// is saved after it, from the form as it then stands, so two quick picks
  /// cannot finish in the wrong order and leave the first one stored.
  Future<void> _saveOutboundProxy() async {
    if (_saving) {
      _saveAgain = true;
      return;
    }
    _saving = true;
    try {
      do {
        _saveAgain = false;
        await _saveOutboundProxyOnce();
      } while (_saveAgain && mounted);
    } finally {
      _saving = false;
    }
  }

  Future<void> _saveOutboundProxyOnce() async {
    if (_outboundProxy.type != ProxyType.DEFAULT) {
      final err =
          _validateOutboundProxyAddress(_outboundProxyAddressController.text);
      if (err != null) {
        ScaffoldMessenger.of(context).toast(err);
        return;
      }
    }
    final settings = _formProxy();
    Record key(UserProxySettings s) => (s.type, s.address, s.username,
        s.password, s.savedProxyId, s.gatewayId, s.credentialsId);
    final changed = key(GlobalOutboundProxy.current) != key(settings);
    await GlobalOutboundProxy.update(settings);
    // Stored either way; only the form is gone if the screen was left during
    // the write. The webview reset below must still run.
    if (mounted) {
      setState(() {
        _outboundProxy = settings;
        markClean();
      });
    }
    // Force every loaded webview to be rebuilt so the new global proxy
    // takes effect immediately. Without this the change only applies to
    // sites loaded after the next app restart — webview navigation keeps
    // routing through the stale proxy bound at construction time.
    // Skip the reset on no-op edits (e.g. focus leaves a field that was
    // never modified) so we don't churn webviews while the user is
    // tabbing through.
    if (changed) {
      LogTag.proxy.info(
          'Outbound proxy changed; resetting all loaded webviews so the new '
          'value is applied on next render', sensitive: true);
      widget.onOutboundProxyChanged?.call();
    } else {
      LogTag.proxy.debug(
          'Outbound proxy save invoked but settings unchanged; skipping webview reset',
          sensitive: true);
    }
    if (mounted && changed) {
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).toast(loc.appSettingsOutboundProxyUpdated);
    }
  }

  /// Exactly what a save would store, so the test answers for the address
  /// the user just typed rather than the one last saved.
  UserProxySettings _formProxy() => applyProxyForm(
        stored: GlobalOutboundProxy.current,
        fields: ProxyFormFields(
          type: _outboundProxy.type,
          address: _outboundProxyAddressController.text,
          username: _outboundProxyUsernameController.text,
          password: _outboundProxyPasswordController.text,
          savedProxyId: _outboundProxy.savedProxyId,
          gatewayId: _outboundProxy.gatewayId,
          credentialsId: _outboundProxy.credentialsId,
        ),
      );

  void _onProxyFieldChanged() {
    if (mounted) setState(() {});
  }

  /// The rest of App Settings applies on change, but the proxy text fields
  /// only flush on editing complete, so a back gesture mid-edit would drop
  /// them.
  @override
  Record snapshot() => (
        type: _outboundProxy.type,
        savedProxyId: _outboundProxy.savedProxyId,
        gatewayId: _outboundProxy.gatewayId,
        credentialsId: _outboundProxy.credentialsId,
        address: _outboundProxyAddressController.text,
        username: _outboundProxyUsernameController.text,
        password: _outboundProxyPasswordController.text,
      );

  Future<void> _openSavedProxies() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ProxyLibraryScreen(
          siteProxies: widget.siteProxies ?? () => const [],
          appWideProxy: () => GlobalOutboundProxy.current,
          onChanged: () => widget.onSavedProxiesChanged?.call(),
        ),
      ),
    );
    // The picker above lists them, and the count in the row counts them.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return guardPop(
      child: Scaffold(
        appBar: AppBar(title: Text(loc.appSettingsNetwork)),
        body: ListView(
          children: [
            SettingsSection(
              loc.appSettingsOutboundProxy,
              hint: loc.appSettingsOutboundProxyHint,
            ),
            SettingTile(
              leading: const Icon(Icons.vpn_lock_outlined),
              title: loc.savedProxiesTitle,
              hint: loc.savedProxiesHint,
              subtitle: loc.savedProxiesCount(ProxyLibrary.data.length),
              control: Opens(() => guardedOpen(_openSavedProxies)),
            ),
            SettingTile(
              title: loc.appSettingsProxyType,
              hint: null,
              control: Trailing(ProxyChoiceDropdown(
                type: _outboundProxy.type,
                savedProxyId: _outboundProxy.savedProxyId,
                gatewayId: _outboundProxy.gatewayId,
                library: ProxyLibrary.data,
                torAvailable: TorService.instance.isAvailable,
                torExternal: TorService.instance.isExternal,
                onChanged: (choice) {
                  setState(() {
                    _outboundProxy.type = choice.type;
                    if (choice.type == ProxyType.SAVED) {
                      _outboundProxy.savedProxyId = choice.savedProxyId;
                    }
                    if (choice.type == ProxyType.GATEWAY) {
                      _outboundProxy.gatewayId = choice.gatewayId;
                    }
                    // Saved credentials stay only with a gateway they list.
                    final credentials = ProxyLibrary.credentialsById(
                        _outboundProxy.credentialsId);
                    if (choice.type != ProxyType.GATEWAY ||
                        !(credentials?.fits(_outboundProxy.gatewayId) ??
                            false)) {
                      _outboundProxy.credentialsId = null;
                    }
                  });
                  _saveOutboundProxy();
                },
              )),
            ),
            if (_outboundProxy.type == ProxyType.SAVED ||
                _outboundProxy.type == ProxyType.GATEWAY)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Builder(builder: (context) {
                  final resolved =
                      resolveLibrary(_formProxy());
                  return ProxyStatusIndicator(
                    proxy: resolved.route,
                    problem: resolved.problem == LibraryProblem.none
                        ? null
                        : libraryProblemLabel(loc, problem: resolved.problem),
                  );
                }),
              ),
            if (_outboundProxy.type.showsRouteFields)
              ProxyRouteFields(
                type: _outboundProxy.type,
                gatewayId: _outboundProxy.gatewayId,
                credentialsId: _outboundProxy.credentialsId,
                library: ProxyLibrary.data,
                addressController: _outboundProxyAddressController,
                usernameController: _outboundProxyUsernameController,
                passwordController: _outboundProxyPasswordController,
                addressValidator: (v) =>
                    _validateOutboundProxyAddress(v ?? ''),
                addressLabel: loc.appSettingsProxyAddress,
                addressHint: loc.appSettingsProxyAddressHint,
                addressHelper: loc.appSettingsProxyAddressHelper,
                onCredentialsChanged: (id) {
                  setState(() => _outboundProxy.credentialsId = id);
                  _saveOutboundProxy();
                },
                onEditingComplete: _saveOutboundProxy,
              ),
            if (_outboundProxy.type != ProxyType.DEFAULT)
              ProxyTestTile(
                settings: _formProxy,
                target: kDefaultProxyTestTarget,
              ),
            // Directly under the proxy block it reports on: the dropdown is
            // where TOR gets selected, and this is where the user finds out
            // whether it actually came up. Renders nothing until something
            // uses Tor.
            TorStatusCard(
              onTap: () => guardedOpen(() => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          TorStatusScreen(siteNames: widget.siteNames),
                    ),
                  )),
            ),
            // Trusted certificates — only Android and Linux can create
            // pins via the in-app prompt. On iOS/macOS the prompt is
            // skipped entirely (TLS-009) because Apple's WKWebView
            // rejects every URLCredential(trust:) override, so the list
            // would always be empty there. Imported pins from a backup
            // still apply via HttpClient.badCertificateCallback even on
            // Apple platforms, but the rare "inspect-imported-pins-on-
            // iOS" case doesn't justify an always-empty settings tile.
            if (hostIsAndroid || hostIsLinux) ...[
              SettingsSection(loc.appSettingsGroupCertificates),
              SettingTile(
                leading: const Icon(Icons.lock_outline),
                title: loc.appSettingsTrustedCertificates,
                hint: loc.appSettingsTrustedCertificatesHint,
                subtitle: loc.appSettingsTrustedCertificatesSubtitle,
                control: Opens(() => guardedOpen(() => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const TrustedCertificatesScreen(),
                      ),
                    ))),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
