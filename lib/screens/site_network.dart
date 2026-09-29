import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/webview.dart' show ProxyManager;
import 'package:webspace/settings/location.dart'
    show WebRtcPolicy, resolveWebRtcPolicy;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/proxy_library.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';

/// Everything the network screen may change through a switch or a picker, in
/// one value so the caller can apply a whole edit in a single `setState`.
///
/// Same contract as `SitePrivacyValues` and `SiteBehaviourValues`: the
/// settings screen keeps the fields, the dirty-snapshot diff and the save
/// path (BUG-006). The proxy address and credentials are text, so they stay
/// in the caller's controllers, which that diff already reads.
class SiteNetworkValues {
  const SiteNetworkValues({
    required this.proxyType,
    this.torExitCountry,
    this.savedProxyId,
    this.gatewayId,
    this.credentialsId,
    required this.webRtcPolicy,
  });

  final ProxyType proxyType;

  /// The library entries picked: the saved proxy under [ProxyType.SAVED],
  /// the saved gateway under [ProxyType.GATEWAY], and saved credentials
  /// (null meaning the typed ones).
  final String? savedProxyId;
  final String? gatewayId;
  final String? credentialsId;

  /// Country the Tor exit is pinned to, or null for any.
  final String? torExitCountry;
  final WebRtcPolicy webRtcPolicy;

  /// `torExitCountry` is nullable *and* meaningful when null ("any country"),
  /// so passing null has to mean "set it to null", not "leave it".
  static const Object _keep = Object();

  SiteNetworkValues copyWith({
    ProxyType? proxyType,
    Object? torExitCountry = _keep,
    Object? savedProxyId = _keep,
    Object? gatewayId = _keep,
    Object? credentialsId = _keep,
    WebRtcPolicy? webRtcPolicy,
  }) =>
      SiteNetworkValues(
        proxyType: proxyType ?? this.proxyType,
        torExitCountry: identical(torExitCountry, _keep)
            ? this.torExitCountry
            : torExitCountry as String?,
        savedProxyId: identical(savedProxyId, _keep)
            ? this.savedProxyId
            : savedProxyId as String?,
        gatewayId:
            identical(gatewayId, _keep) ? this.gatewayId : gatewayId as String?,
        credentialsId: identical(credentialsId, _keep)
            ? this.credentialsId
            : credentialsId as String?,
        webRtcPolicy: webRtcPolicy ?? this.webRtcPolicy,
      );
}

/// The address check the save path runs. Lives beside the field so the rule
/// and the field it guards cannot drift apart. TOR supplies its own address
/// once the runtime is up, and a saved proxy or gateway was checked where it
/// was saved, so for these there is nothing to type and nothing to validate.
String? validateProxyAddress(
  AppLocalizations loc,
  ProxyType type,
  String? value,
) {
  if (type == ProxyType.DEFAULT ||
      type == ProxyType.TOR ||
      type == ProxyType.SAVED ||
      type == ProxyType.GATEWAY) {
    return null;
  }
  if (value == null || value.isEmpty) {
    return loc.siteSettingsProxyAddressRequired;
  }
  final parts = value.split(':');
  if (parts.length != 2) {
    return loc.siteSettingsProxyAddressFormatError;
  }
  final port = int.tryParse(parts[1]);
  if (port == null || port < 1 || port > 65535) {
    return loc.siteSettingsProxyInvalidPort;
  }
  return null;
}

/// Per-site network screen: where the site's traffic goes (proxy, WebRTC) and
/// the sign-ins its server has been given. The counterpart of the behaviour,
/// privacy and permissions screens.
class SiteNetworkScreen extends StatefulWidget {
  const SiteNetworkScreen({
    super.key,
    required this.host,
    required this.siteId,
    required this.values,
    required this.onChanged,
    required this.proxyAddressController,
    required this.proxyUsernameController,
    required this.proxyPasswordController,
    required this.proxySupported,
    this.proxyTest,
    this.showSavedSignIns = true,
    this.trackingProtectionEnabled = false,
    this.appProxySet = false,
    this.library,
  });

  final String host;

  /// Keys the saved sign-ins row.
  final String siteId;

  final SiteNetworkValues values;
  final ValueChanged<SiteNetworkValues> onChanged;

  /// Owned by the caller, whose dirty snapshot reads their text.
  final TextEditingController proxyAddressController;
  final TextEditingController proxyUsernameController;
  final TextEditingController proxyPasswordController;

  /// False where the platform cannot bind a per-site proxy (PROXY-006): the
  /// proxy group is hidden rather than offered and ignored.
  final bool proxySupported;

  /// The caller's "Test connection" row. It tests what a save would store,
  /// and the save path is the caller's, so the caller builds it; shown only
  /// while a proxy is chosen.
  final Widget? proxyTest;

  /// False for archive-tier sites, which never save a sign-in (HTTPAUTH-004).
  final bool showSavedSignIns;

  /// The unsaved umbrella value and whether an app-wide proxy is set: with
  /// both, or with the umbrella and a proxy of the site's own, direct WebRTC
  /// is off the menu (ETP-031).
  final bool trackingProtectionEnabled;
  final bool appProxySet;

  /// The proxy library the pickers offer. Defaults to [ProxyLibrary]'s.
  final ProxyLibraryData? library;

  @override
  State<SiteNetworkScreen> createState() => _SiteNetworkScreenState();
}

class _SiteNetworkScreenState extends State<SiteNetworkScreen> {
  late SiteNetworkValues _values = widget.values;

  List<TextEditingController> get _controllers => [
        widget.proxyAddressController,
        widget.proxyUsernameController,
        widget.proxyPasswordController,
      ];

  // The saved-gateway row checks the route the form would store, typed
  // credentials included, so it follows the fields as they are typed.
  @override
  void initState() {
    super.initState();
    for (final c in _controllers) {
      c.addListener(_fieldsChanged);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.removeListener(_fieldsChanged);
    }
    super.dispose();
  }

  void _fieldsChanged() {
    if (mounted && _values.proxyType == ProxyType.GATEWAY) setState(() {});
  }

  void _update(SiteNetworkValues next) {
    setState(() => _values = next);
    widget.onChanged(next);
  }

  Widget _groupHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  // --- Proxy ---------------------------------------------------------------

  Widget _proxyType(AppLocalizations loc) {
    final type = _values.proxyType;
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(loc.siteSettingsProxyType)),
          HintButton(
            title: loc.siteSettingsProxyType,
            description: loc.siteSettingsProxyCoverageHint,
          ),
        ],
      ),
      // What a configured proxy actually covers here, which is not the same
      // claim as "a proxy is configured" (LEAK-010). Absent on DEFAULT, where
      // the row claims nothing.
      subtitle: type == ProxyType.DEFAULT
          ? null
          : Text(ProxyManager.binding == ProxyBinding.perSite
              ? loc.siteSettingsProxyCoverageFirstOnly
              : loc.siteSettingsProxyCoverageAll),
      trailing: ProxyChoiceDropdown(
        type: type,
        savedProxyId: _values.savedProxyId,
        gatewayId: _values.gatewayId,
        library: _library,
        torAvailable: TorService.instance.isAvailable,
        onChanged: _pickProxy,
      ),
    );
  }

  ProxyLibraryData get _library => widget.library ?? ProxyLibrary.data;

  /// A pick moves only the reference it names; the others are kept, like
  /// the manual fields (PROXY-010). Saved credentials go with the gateway
  /// they were paired with: a typed gateway, or another saved one they do
  /// not list, would fail closed with them.
  void _pickProxy(ProxyChoice choice) {
    final gatewayId = choice.type == ProxyType.GATEWAY
        ? choice.gatewayId
        : _values.gatewayId;
    final keepCredentials = choice.type == ProxyType.GATEWAY &&
        (_library.credentialsById(_values.credentialsId)?.fits(gatewayId) ??
            false);
    _update(_values.copyWith(
      proxyType: choice.type,
      savedProxyId: choice.type == ProxyType.SAVED
          ? choice.savedProxyId
          : _values.savedProxyId,
      gatewayId: gatewayId,
      credentialsId: keepCredentials ? _values.credentialsId : null,
    ));
  }

  /// The route this form would store, resolved against the library, with
  /// whatever is typed so far.
  LibraryResolution _route() {
    String? orNull(String v) => v.trim().isEmpty ? null : v.trim();
    return resolveLibrary(
      UserProxySettings(
        type: _values.proxyType,
        savedProxyId: _values.savedProxyId,
        gatewayId: _values.gatewayId,
        credentialsId: _values.credentialsId,
        address: orNull(widget.proxyAddressController.text),
        username: orNull(widget.proxyUsernameController.text),
        password: orNull(widget.proxyPasswordController.text),
      ),
      _library,
    );
  }

  /// Where a saved proxy or gateway takes this site, and whether it answers
  /// (PROXY-030). The entries themselves are edited in App Settings.
  Widget _libraryRoute(AppLocalizations loc) {
    final resolved = _route();
    final problem = resolved.problem == LibraryProblem.none
        ? null
        : libraryProblemLabel(loc, resolved.problem);
    return ListTile(
      leading: const Icon(Icons.vpn_lock_outlined),
      title: problem == null ? Text(routeLabel(resolved.route)) : null,
      subtitle: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ProxyStatusIndicator(proxy: resolved.route, problem: problem),
      ),
    );
  }

  Widget _torExitCountry(AppLocalizations loc) {
    final pinned = _values.torExitCountry;
    final known = torExitCountryFor(pinned);
    // An unlisted pin keeps its bare code rather than reading as unpinned: it
    // is still a valid `{cc}` that tor honours, and showing "Any" for a site
    // that is in fact pinned would be the mis-report TOR-014 forbids.
    final subtitle = known?.label ??
        (pinned == null || pinned.trim().isEmpty
            ? loc.siteSettingsTorExitCountryAny
            : pinned.toUpperCase());
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(loc.siteSettingsTorExitCountry)),
          HintButton(
            title: loc.siteSettingsTorExitCountry,
            description: loc.siteSettingsTorExitCountryHint,
          ),
        ],
      ),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pickTorExitCountry,
    );
  }

  Future<void> _pickTorExitCountry() async {
    final loc = AppLocalizations.of(context);
    final selected = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(loc.siteSettingsTorExitCountry),
        children: [
          // Sentinel: `null` is a legal value here (unpin), so "Any" returns
          // an empty string and a null result only ever means "dismissed".
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(loc.siteSettingsTorExitCountryAny),
          ),
          for (final c in kTorExitCountries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.code),
              child: Text(c.label),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    _update(_values.copyWith(
      torExitCountry: selected.isEmpty ? null : selected,
    ));
  }

  List<Widget> _proxyGroup(AppLocalizations loc) {
    final type = _values.proxyType;
    return [
      _groupHeader(loc.networkGroupProxy),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Text(
          loc.siteSettingsProxyShared,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      _proxyType(loc),
      if (type == ProxyType.TOR) _torExitCountry(loc),
      if (type == ProxyType.SAVED || type == ProxyType.GATEWAY)
        _libraryRoute(loc),
      // TOR supplies its own loopback address and stream-isolation auth, and
      // a saved proxy its whole route, so the manual fields are inert while
      // either is selected. Hidden, not cleared: PROXY-010 requires a stored
      // SOCKS5 config to survive the trip and come back on switch-out.
      if (type != ProxyType.DEFAULT &&
          type != ProxyType.TOR &&
          type != ProxyType.SAVED)
        ProxyRouteFields(
          type: type,
          gatewayId: _values.gatewayId,
          credentialsId: _values.credentialsId,
          library: _library,
          addressController: widget.proxyAddressController,
          usernameController: widget.proxyUsernameController,
          passwordController: widget.proxyPasswordController,
          addressValidator: (value) => validateProxyAddress(loc, type, value),
          onCredentialsChanged: (id) =>
              _update(_values.copyWith(credentialsId: id)),
        ),
      if (type != ProxyType.DEFAULT && widget.proxyTest != null)
        widget.proxyTest!,
    ];
  }

  // --- Connection ----------------------------------------------------------

  Widget _webRtc(AppLocalizations loc) {
    final proxied =
        _values.proxyType != ProxyType.DEFAULT || widget.appProxySet;
    final noDirect = widget.trackingProtectionEnabled && proxied;
    final shown = resolveWebRtcPolicy(
      stored: _values.webRtcPolicy,
      trackingProtectionEnabled: widget.trackingProtectionEnabled,
      proxied: proxied,
    );
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(loc.siteSettingsWebRtcPolicy)),
          HintButton(
            title: loc.siteSettingsWebRtcHintTitle,
            description: loc.siteSettingsWebRtcHintBody,
          ),
        ],
      ),
      subtitle: noDirect ? Text(loc.siteSettingsWebRtcNoDirect) : null,
      trailing: DropdownButton<WebRtcPolicy>(
        value: shown,
        onChanged: (next) {
          // Re-picking the forced value would store it, and turning the
          // umbrella off later would then keep it instead of Default.
          if (next != null && next != shown) {
            _update(_values.copyWith(webRtcPolicy: next));
          }
        },
        items: [
          DropdownMenuItem(
              value: WebRtcPolicy.defaultPolicy,
              enabled: !noDirect,
              child: Text(loc.siteSettingsWebRtcDefault)),
          DropdownMenuItem(
              value: WebRtcPolicy.relayOnly,
              child: Text(loc.siteSettingsWebRtcRelayOnly)),
          DropdownMenuItem(
              value: WebRtcPolicy.disabled,
              child: Text(loc.siteSettingsWebRtcDisabled)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.networkTitle)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              widget.host,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (widget.proxySupported) ..._proxyGroup(loc),
          _groupHeader(loc.networkGroupConnection),
          _webRtc(loc),
          if (widget.showSavedSignIns) SavedSignInsTile(siteId: widget.siteId),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// The site's saved HTTP sign-ins and a way to forget them. Acts at once
/// rather than through the save button: forgetting a credential is not a
/// setting the user can take back by discarding the form.
class SavedSignInsTile extends StatefulWidget {
  const SavedSignInsTile({super.key, required this.siteId, this.storage});

  final String siteId;

  /// Defaults to the app's store.
  final HttpAuthSecureStorage? storage;

  @override
  State<SavedSignInsTile> createState() => _SavedSignInsTileState();
}

class _SavedSignInsTileState extends State<SavedSignInsTile> {
  /// Null until secure storage answers.
  int? _count;

  HttpAuthSecureStorage get _storage =>
      widget.storage ?? HttpAuthSecureStorage.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final count = await _storage.countForSite(widget.siteId);
    if (mounted) setState(() => _count = count);
  }

  Future<void> _forget() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.siteSettingsSavedSignInsClearTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.siteSettingsClearConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _storage.removeSite(widget.siteId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final count = _count;
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(loc.siteSettingsSavedSignIns)),
          HintButton(
            title: loc.siteSettingsSavedSignIns,
            description: loc.siteSettingsSavedSignInsHint,
          ),
        ],
      ),
      subtitle: count == null
          ? null
          : Text(count == 0
              ? loc.siteSettingsSavedSignInsNone
              : loc.siteSettingsSavedSignInsCount(count)),
      trailing: TextButton(
        onPressed: (count ?? 0) > 0 ? _forget : null,
        child: Text(loc.siteSettingsClearConfirm),
      ),
    );
  }
}
