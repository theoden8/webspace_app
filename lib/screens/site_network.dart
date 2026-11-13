import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webspace/settings/proxy_ids.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/egress_relay.dart';
import 'package:webspace/services/egress_route_engine.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/location.dart'
    show WebRtcPolicy, resolveWebRtcPolicy;
import 'package:webspace/settings/network_interface.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/flag_text.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/web_view_model.dart';

/// What a site stores of its network route but the typed proxy address and
/// credentials, the whole of what the network screen edits through a switch
/// or a picker. A record, so the settings screen's dirty snapshot compares
/// every field of it and a field added here cannot be left out of that
/// comparison, which is how unsaved edits got dropped (BUG-006). The address
/// and credentials are text, so they stay in the caller's controllers, which
/// that snapshot reads beside it.
typedef NetworkChoices = ({
  ProxyType proxyType,
  /// Country the Tor exit is pinned to, or null for any.
  String? torExitCountry,
  /// The library entries picked: the saved proxy under [ProxyType.SAVED],
  /// the saved gateway under [ProxyType.GATEWAY], and saved credentials
  /// (null meaning the typed ones).
  SavedProxyId? savedProxyId,
  GatewayId? gatewayId,
  CredentialsId? credentialsId,
  /// The interface the site's traffic leaves by (NETIF-001).
  InterfaceChoice leavesBy,
  WebRtcPolicy webRtcPolicy,
});

/// Where a site's [NetworkChoices] are read from. The route is stored as a
/// [UserProxySettings], which the save builds with [NetworkChoicesEdit.over]
/// and sends through `updateProxySettings`.
extension SiteNetworkChoices on WebViewModel {
  /// The proxy as this platform can bind one: DEFAULT where it cannot bind a
  /// per-site proxy (PROXY-006).
  UserProxySettings get bindableProxy => PlatformInfo.isProxySupported
      ? proxySettings
      : UserProxySettings(type: ProxyType.DEFAULT);

  NetworkChoices get networkChoices {
    final proxy = bindableProxy;
    return (
      proxyType: proxy.type,
      torExitCountry: proxy.torExitCountry,
      savedProxyId: proxy.savedProxyId,
      gatewayId: proxy.gatewayId,
      credentialsId: proxy.credentialsId,
      leavesBy: proxy.leavesBy,
      webRtcPolicy: webRtcPolicy,
    );
  }
}

extension NetworkChoicesEdit on NetworkChoices {
  /// These choices with the given ones replaced. A nullable field comes as a
  /// one-element record, so clearing it (`torExitCountry: (null,)`) is told
  /// apart from leaving it out.
  NetworkChoices copyWith({
    ProxyType? proxyType,
    (String?,)? torExitCountry,
    (SavedProxyId?,)? savedProxyId,
    (GatewayId?,)? gatewayId,
    (CredentialsId?,)? credentialsId,
    InterfaceChoice? leavesBy,
    WebRtcPolicy? webRtcPolicy,
  }) =>
      (
        proxyType: proxyType ?? this.proxyType,
        torExitCountry:
            torExitCountry == null ? this.torExitCountry : torExitCountry.$1,
        savedProxyId:
            savedProxyId == null ? this.savedProxyId : savedProxyId.$1,
        gatewayId: gatewayId == null ? this.gatewayId : gatewayId.$1,
        credentialsId:
            credentialsId == null ? this.credentialsId : credentialsId.$1,
        leavesBy: leavesBy ?? this.leavesBy,
        webRtcPolicy: webRtcPolicy ?? this.webRtcPolicy,
      );

  /// [proxy] with the route these choices pick, its typed fields kept. The
  /// pattern names every field, so one added to [NetworkChoices] does not
  /// compile until it is placed here or named as not the route's.
  UserProxySettings over(UserProxySettings proxy) {
    final (
      :proxyType,
      :torExitCountry,
      :savedProxyId,
      :gatewayId,
      :credentialsId,
      :leavesBy,
      webRtcPolicy: _,
    ) = this;
    return proxy.copyWith(
      type: proxyType,
      torExitCountry: (torExitCountry,),
      savedProxyId: (savedProxyId,),
      gatewayId: (gatewayId,),
      credentialsId: (credentialsId,),
      leavesBy: leavesBy,
    );
  }
}

/// The address check the save path runs; [ProxyTypeForm.typesAddress] says
/// which types have an address to check.
String? validateProxyAddress(
  AppLocalizations loc, {
  required ProxyType type,
  required String? value,
}) {
  if (!type.typesAddress) return null;
  return switch (ProxyAddressParse.of(value)) {
    ProxyAddress() => null,
    ProxyAddressMissing() => loc.siteSettingsProxyAddressRequired,
    ProxyAddressMalformed() => loc.siteSettingsProxyAddressFormatError,
    ProxyAddressBadPort() => loc.siteSettingsProxyInvalidPort,
  };
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
  final SiteId siteId;

  final NetworkChoices values;
  final ValueChanged<NetworkChoices> onChanged;

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
  late NetworkChoices _values = widget.values;

  /// The interfaces present as the screen opened, while the experiment is
  /// reachable (NETIF-010); null until the platform answers.
  List<NetworkLink>? _links;

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
    if (EgressRelay.instance.state is! EgressOff) unawaited(_loadLinks());
  }

  Future<void> _loadLinks() async {
    final links = await EgressRelay.instance.links();
    if (mounted) setState(() => _links = links);
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

  void _update(NetworkChoices next) {
    setState(() => _values = next);
    widget.onChanged(next);
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
      savedProxyId: (choice.type == ProxyType.SAVED
          ? choice.savedProxyId
          : _values.savedProxyId,),
      gatewayId: (gatewayId,),
      credentialsId: (keepCredentials ? _values.credentialsId : null,),
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
      library: _library,
    );
  }

  /// Where a saved proxy or gateway takes this site, and whether it answers
  /// (PROXY-031). The entries themselves are edited in App Settings.
  Widget _libraryRoute(AppLocalizations loc) {
    final resolved = _route();
    final problem = resolved.problem == LibraryProblem.none
        ? null
        : libraryProblemLabel(loc, problem: resolved.problem);
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
    final subtitle = switch ((known, pinned)) {
      (final known?, _) => Localized.verbatim(known.label),
      (null, final pinned?) when pinned.trim().isNotEmpty =>
        Localized.verbatim(pinned.toUpperCase()),
      _ => loc.siteSettingsTorExitCountryAny,
    };
    return SettingTile(
      title: loc.siteSettingsTorExitCountry,
      hint: loc.siteSettingsTorExitCountryHint,
      subtitle: subtitle,
      control: Opens(_pickTorExitCountry),
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
              child: flagText(c.label),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    _update(_values.copyWith(
      torExitCountry: (selected.isEmpty ? null : selected,),
    ));
  }

  List<Widget> _proxyGroup(AppLocalizations loc) {
    final type = _values.proxyType;
    return [
      SettingsSection(loc.networkGroupProxy),
      SettingsNote(loc.siteSettingsProxyShared),
      SettingTile(
        title: loc.siteSettingsProxyType,
        hint: loc.siteSettingsProxyCoverageHint,
        // What a configured proxy actually covers here, which is not the same
        // claim as "a proxy is configured" (LEAK-010). Absent on DEFAULT,
        // where the row claims nothing.
        subtitle: type == ProxyType.DEFAULT
            ? null
            : (ProxyManager.binding == ProxyBinding.perSite
                ? loc.siteSettingsProxyCoverageFirstOnly
                : loc.siteSettingsProxyCoverageAll),
        control: Trailing(ProxyChoiceDropdown(
          type: type,
          savedProxyId: _values.savedProxyId,
          gatewayId: _values.gatewayId,
          library: _library,
          torAvailable: TorService.instance.offered,
          torExternal: TorService.instance.isExternal,
          onChanged: _pickProxy,
        )),
      ),
      // An external tor picks its own exits unless the app holds its
      // control port (TOR-025, TOR-026).
      if (type == ProxyType.TOR && TorService.instance.hasControlPort)
        _torExitCountry(loc),
      if (type == ProxyType.SAVED || type == ProxyType.GATEWAY)
        _libraryRoute(loc),
      if (type.showsRouteFields)
        ProxyRouteFields(
          type: type,
          gatewayId: _values.gatewayId,
          credentialsId: _values.credentialsId,
          library: _library,
          addressController: widget.proxyAddressController,
          usernameController: widget.proxyUsernameController,
          passwordController: widget.proxyPasswordController,
          addressValidator: (value) => validateProxyAddress(loc, type: type, value: value),
          onCredentialsChanged: (id) =>
              _update(_values.copyWith(credentialsId: (id,))),
        ),
      if (type != ProxyType.DEFAULT && widget.proxyTest != null)
        widget.proxyTest!,
    ];
  }

  Widget _webRtc(AppLocalizations loc) {
    final proxied = _values.proxyType != ProxyType.DEFAULT ||
        widget.appProxySet ||
        appliesInterface(_values.leavesBy, relay: EgressRelay.instance.state);
    final noDirect = widget.trackingProtectionEnabled && proxied;
    final shown = resolveWebRtcPolicy(
      stored: _values.webRtcPolicy,
      trackingProtectionEnabled: widget.trackingProtectionEnabled,
      proxied: proxied,
    );
    // Shows the forced value; re-picking it is not a change, so turning the
    // umbrella off later restores Default rather than a stored copy of it.
    return ChoiceTile(
      title: loc.siteSettingsWebRtcPolicy,
      hintTitle: loc.siteSettingsWebRtcHintTitle,
      hint: loc.siteSettingsWebRtcHintBody,
      subtitle: noDirect ? loc.siteSettingsWebRtcNoDirect : null,
      values: WebRtcPolicy.values,
      label: (p) => p.label(loc),
      value: shown,
      offered: (p) => !noDirect || p != WebRtcPolicy.defaultPolicy,
      onChanged: (p) => _update(_values.copyWith(webRtcPolicy: p)),
    );
  }

  /// The proxy this form would store, as the relay would dial it.
  ProxyType get _upstreamType => switch (_values.proxyType) {
        ProxyType.DEFAULT =>
          resolveLibraryProxy(GlobalOutboundProxy.current).type,
        ProxyType.SAVED || ProxyType.GATEWAY => _route().route.type,
        final type => type,
      };

  /// The interface the site leaves by (NETIF-010). A route the relay cannot
  /// carry locks the row while nothing is chosen, and otherwise leaves only
  /// System routing to pick, so a site it blocks can always be let go.
  Widget _networkInterface(AppLocalizations loc) {
    final chosen = _values.leavesBy;
    final links = _links ?? const <NetworkLink>[];
    final present = {for (final l in links) l.name: l};
    final values = <InterfaceChoice>[
      const SystemRouting(),
      for (final l in links) NamedInterface(l.name),
      if (chosen case NamedInterface(:final name)
          when !present.containsKey(name))
        chosen,
      if (chosen is UnreadableInterface) chosen,
    ];
    final cannotRide = switch (UpstreamCarriage.of(_upstreamType)) {
      UpstreamCarriage.tor => loc.networkInterfaceTorLock,
      UpstreamCarriage.tlsProxy => loc.networkInterfaceHttpsLock,
      UpstreamCarriage.direct ||
      UpstreamCarriage.socks5 ||
      UpstreamCarriage.http ||
      UpstreamCarriage.unresolved => null,
    };
    // Whether a choice is up is the subtitle's to say, so the menu, which
    // truncates, names the interface alone.
    String label(InterfaceChoice c) => switch (c) {
          SystemRouting() => loc.networkInterfaceSystem,
          NamedInterface(:final name) => name,
          UnreadableInterface() => '?',
        };
    final state = switch (chosen) {
      NamedInterface(:final name) => switch (present[name]) {
          (name: _, :final up, :final addresses)
              when up && addresses.isNotEmpty =>
            Localized.verbatim(addresses.join(', ')),
          _ => loc.networkInterfaceNotConnected(name),
        },
      UnreadableInterface() => loc.networkInterfaceNotConnected('?'),
      SystemRouting() => null,
    };
    return ChoiceTile<InterfaceChoice>(
      title: loc.networkInterfaceTitle,
      hint: loc.networkInterfaceHint,
      subtitle: chosen is SystemRouting ? null : (cannotRide ?? state),
      values: values,
      label: label,
      value: chosen,
      offered: (c) => cannotRide == null || c is SystemRouting,
      lock: cannotRide != null && chosen is SystemRouting
          ? Lock.because(cannotRide)
          : null,
      onChanged: (c) => _update(_values.copyWith(leavesBy: c)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.networkTitle)),
      body: ListView(
        children: [
          SettingsNote.host(widget.host),
          if (widget.proxySupported) ..._proxyGroup(loc),
          SettingsSection(loc.networkGroupConnection),
          if (EgressRelay.instance.state is! EgressOff) _networkInterface(loc),
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

  final SiteId siteId;

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
    unawaited(_load());
  }

  Future<void> _load() async {
    final count = await _storage.countForSite(widget.siteId);
    if (mounted) setState(() => _count = count);
  }

  Future<void> _forget() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await confirm(
      context,
      title: loc.siteSettingsSavedSignInsClearTitle,
      confirmLabel: loc.siteSettingsClearConfirm,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _storage.removeSite(widget.siteId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final count = _count;
    return SettingTile(
      title: loc.siteSettingsSavedSignIns,
      hint: loc.siteSettingsSavedSignInsHint,
      subtitle: count == null
          ? null
          : (count == 0
              ? loc.siteSettingsSavedSignInsNone
              : loc.siteSettingsSavedSignInsCount(count)),
      control: Trailing(TextButton(
        onPressed: (count ?? 0) > 0 ? _forget : null,
        child: Text(loc.siteSettingsClearConfirm),
      )),
    );
  }
}
