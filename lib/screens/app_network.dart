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
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/proxy_library.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/proxy_test_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/tor_status_card.dart';

/// The App Settings summary of the app-wide route: where traffic goes, and
/// how many saved proxies the library holds.
String appNetworkSummary(AppLocalizations loc) {
  final current = GlobalOutboundProxy.current;
  final String? route;
  if (current.type == ProxyType.DEFAULT) {
    route = null;
  } else if (current.type == ProxyType.TOR) {
    route = torRouteLabel(loc);
  } else if (current.type == ProxyType.SAVED ||
      current.type == ProxyType.GATEWAY) {
    final problem = resolveLibrary(current).problem;
    if (problem != LibraryProblem.none) {
      route = libraryProblemLabel(loc, problem);
    } else if (current.type == ProxyType.SAVED) {
      route = savedProxyLabel(ProxyLibrary.proxy(current.savedProxyId)!);
    } else {
      route = gatewayLabel(ProxyLibrary.gateway(current.gatewayId)!);
    }
  } else {
    route = routeLabel(current);
  }
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
    with SettingsOpenGuard {
  // Global outbound proxy state. Mirrors the per-site proxy UI in
  // [lib/screens/site_network.dart] but applies to *every* Dart-side outbound
  // call (DNS blocklist downloads, ClearURLs rules, content blocker rules,
  // LocalCDN catalog, OSM map tiles in the location picker, etc.) and
  // also acts as the fallthrough for any per-site proxy whose type is
  // [ProxyType.DEFAULT].
  late UserProxySettings _outboundProxy;
  late TextEditingController _outboundProxyAddressController;
  late TextEditingController _outboundProxyUsernameController;
  late TextEditingController _outboundProxyPasswordController;
  /// Snapshot of the outbound proxy fields at last persisted state. Most
  /// of App Settings auto-applies on change, but the proxy text fields only
  /// flush via `onEditingComplete` / `onFieldSubmitted`, so a user who
  /// types a partial value and pops via the system back gesture would
  /// silently lose the edit. [_isOutboundProxyDirty] drives the PopScope
  /// guard so we prompt instead.
  late Map<String, Object?> _initialOutboundProxy;

  @override
  void initState() {
    super.initState();
    _outboundProxy = UserProxySettings(
      type: GlobalOutboundProxy.current.type,
      address: GlobalOutboundProxy.current.address,
      username: GlobalOutboundProxy.current.username,
      password: GlobalOutboundProxy.current.password,
      savedProxyId: GlobalOutboundProxy.current.savedProxyId,
      gatewayId: GlobalOutboundProxy.current.gatewayId,
      credentialsId: GlobalOutboundProxy.current.credentialsId,
    );
    _outboundProxyAddressController = TextEditingController(
      text: _outboundProxy.address ?? '',
    );
    _outboundProxyUsernameController = TextEditingController(
      text: _outboundProxy.username ?? '',
    );
    _outboundProxyPasswordController = TextEditingController(
      text: _outboundProxy.password ?? '',
    );
    _initialOutboundProxy = _currentOutboundProxySnapshot();
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
    // TOR carries no address of its own, so there is nothing to type and
    // nothing to validate. Without this the save below refuses an empty
    // field and global Tor cannot be turned on at all.
    if (_outboundProxy.type == ProxyType.DEFAULT ||
        _outboundProxy.type == ProxyType.TOR ||
        _outboundProxy.type == ProxyType.SAVED ||
        _outboundProxy.type == ProxyType.GATEWAY) {
      return null;
    }
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
    final address = _outboundProxyAddressController.text.trim();
    if (_outboundProxy.type != ProxyType.DEFAULT) {
      final err = _validateOutboundProxyAddress(address);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        return;
      }
    }
    final settings = applyProxyForm(
      stored: GlobalOutboundProxy.current,
      fields: ProxyFormFields(
        type: _outboundProxy.type,
        address: address,
        username: _outboundProxyUsernameController.text,
        password: _outboundProxyPasswordController.text,
        savedProxyId: _outboundProxy.savedProxyId,
        gatewayId: _outboundProxy.gatewayId,
        credentialsId: _outboundProxy.credentialsId,
      ),
    );
    final previous = GlobalOutboundProxy.current;
    final changed = previous.type != settings.type ||
        previous.address != settings.address ||
        previous.username != settings.username ||
        previous.password != settings.password ||
        previous.savedProxyId != settings.savedProxyId ||
        previous.gatewayId != settings.gatewayId ||
        previous.credentialsId != settings.credentialsId;
    await GlobalOutboundProxy.update(settings);
    // Stored either way; only the form is gone if the screen was left during
    // the write. The webview reset below must still run.
    if (mounted) {
      setState(() {
        _outboundProxy = settings;
        _initialOutboundProxy = _currentOutboundProxySnapshot();
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
      LogService.instance.log(
        'Proxy',
        'Outbound proxy changed; resetting all loaded webviews so the new '
            'value is applied on next render',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
      widget.onOutboundProxyChanged?.call();
    } else {
      LogService.instance.log(
        'Proxy',
        'Outbound proxy save invoked but settings unchanged; skipping webview reset',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    if (mounted && changed) {
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.appSettingsOutboundProxyUpdated)),
      );
    }
  }

  /// Exactly what a save would store, so the test answers for the address
  /// the user just typed rather than the one last saved.
  UserProxySettings _currentOutboundProxyForTest() => applyProxyForm(
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

  Map<String, Object?> _currentOutboundProxySnapshot() => {
        'type': _outboundProxy.type,
        'savedProxyId': _outboundProxy.savedProxyId,
        'gatewayId': _outboundProxy.gatewayId,
        'credentialsId': _outboundProxy.credentialsId,
        'address': _outboundProxyAddressController.text,
        'username': _outboundProxyUsernameController.text,
        'password': _outboundProxyPasswordController.text,
      };

  bool _isOutboundProxyDirty() {
    final cur = _currentOutboundProxySnapshot();
    for (final key in _initialOutboundProxy.keys) {
      if (cur[key] != _initialOutboundProxy[key]) return true;
    }
    return false;
  }

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

  /// Set while the discard prompt is up, so a second back press does not
  /// stack a second prompt over it.
  bool _confirmingDiscard = false;

  Future<bool> _confirmDiscardProxy() async {
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.appSettingsDiscardChangesTitle),
        content: Text(loc.appSettingsDiscardProxyBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.appSettingsKeepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              loc.appSettingsDiscard,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return PopScope(
      canPop: !_isOutboundProxyDirty(),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _confirmingDiscard) return;
        final navigator = Navigator.of(context);
        _confirmingDiscard = true;
        final bool discard;
        try {
          discard = await _confirmDiscardProxy();
        } finally {
          _confirmingDiscard = false;
        }
        if (discard != true || !mounted) return;
        setState(() {
          _initialOutboundProxy = _currentOutboundProxySnapshot();
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || ModalRoute.isCurrentOf(context) != true) return;
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(loc.appSettingsNetwork)),
        body: ListView(
          children: [
            SettingsGroupHeader(
              loc.appSettingsOutboundProxy,
              hint: loc.appSettingsOutboundProxyHint,
            ),
            ListTile(
              leading: const Icon(Icons.vpn_lock_outlined),
              title: Row(
                children: [
                  Flexible(child: Text(loc.savedProxiesTitle)),
                  HintButton(
                    title: loc.savedProxiesTitle,
                    description: loc.savedProxiesHint,
                  ),
                ],
              ),
              subtitle: Text(loc.savedProxiesCount(ProxyLibrary.data.length)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => guardedOpen(_openSavedProxies),
            ),
            ListTile(
              title: Text(loc.appSettingsProxyType),
              trailing: ProxyChoiceDropdown(
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
              ),
            ),
            if (_outboundProxy.type == ProxyType.SAVED ||
                _outboundProxy.type == ProxyType.GATEWAY)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Builder(builder: (context) {
                  final resolved =
                      resolveLibrary(_currentOutboundProxyForTest());
                  return ProxyStatusIndicator(
                    proxy: resolved.route,
                    problem: resolved.problem == LibraryProblem.none
                        ? null
                        : libraryProblemLabel(loc, resolved.problem),
                  );
                }),
              ),
            if (_outboundProxy.type != ProxyType.DEFAULT &&
                _outboundProxy.type != ProxyType.TOR &&
                _outboundProxy.type != ProxyType.SAVED)
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
                settings: _currentOutboundProxyForTest,
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
              SettingsGroupHeader(loc.appSettingsGroupCertificates),
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Row(
                  children: [
                    Flexible(child: Text(loc.appSettingsTrustedCertificates)),
                    HintButton(
                      title: loc.appSettingsTrustedCertificates,
                      description: loc.appSettingsTrustedCertificatesHint,
                    ),
                  ],
                ),
                subtitle: Text(loc.appSettingsTrustedCertificatesSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => guardedOpen(() => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const TrustedCertificatesScreen(),
                      ),
                    )),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
