import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/webview.dart' show ProxyManager;
import 'package:webspace/settings/location.dart' show WebRtcPolicy;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/proxy_auth_section.dart';

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
    required this.webRtcPolicy,
  });

  final ProxyType proxyType;

  /// Country the Tor exit is pinned to, or null for any.
  final String? torExitCountry;
  final WebRtcPolicy webRtcPolicy;

  /// `torExitCountry` is nullable *and* meaningful when null ("any country"),
  /// so passing null has to mean "set it to null", not "leave it".
  static const Object _keep = Object();

  SiteNetworkValues copyWith({
    ProxyType? proxyType,
    Object? torExitCountry = _keep,
    WebRtcPolicy? webRtcPolicy,
  }) =>
      SiteNetworkValues(
        proxyType: proxyType ?? this.proxyType,
        torExitCountry: identical(torExitCountry, _keep)
            ? this.torExitCountry
            : torExitCountry as String?,
        webRtcPolicy: webRtcPolicy ?? this.webRtcPolicy,
      );
}

/// The address check the save path runs. Lives beside the field so the rule
/// and the field it guards cannot drift apart. TOR supplies its own address
/// once the runtime is up, so there is nothing for the user to type and
/// nothing to validate.
String? validateProxyAddress(
  AppLocalizations loc,
  ProxyType type,
  String? value,
) {
  if (type == ProxyType.DEFAULT || type == ProxyType.TOR) {
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

  @override
  State<SiteNetworkScreen> createState() => _SiteNetworkScreenState();
}

class _SiteNetworkScreenState extends State<SiteNetworkScreen> {
  late SiteNetworkValues _values = widget.values;

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
      trailing: DropdownButton<ProxyType>(
        value: type,
        onChanged: (next) {
          if (next != null) _update(_values.copyWith(proxyType: next));
        },
        // TOR is only offerable where a Tor runtime exists (TOR-007). A site
        // that already carries TOR — say, from a backup taken on iOS and
        // imported on Android — keeps the option visible, because a
        // DropdownButton whose `value` is absent from its `items` throws.
        items: ProxyType.values
            .where((v) =>
                v != ProxyType.TOR ||
                TorService.instance.isAvailable ||
                type == ProxyType.TOR)
            .map((v) => DropdownMenuItem(value: v, child: Text(v.name)))
            .toList(),
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
      // TOR supplies its own loopback address and stream-isolation auth, so
      // the manual fields are inert while it is selected. Hidden, not
      // cleared: PROXY-010 requires a stored SOCKS5 config to survive a trip
      // through TOR and come back on switch-out.
      if (type != ProxyType.DEFAULT && type != ProxyType.TOR) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextFormField(
            controller: widget.proxyAddressController,
            decoration: InputDecoration(
              labelText: loc.siteSettingsProxyAddress,
              hintText: loc.siteSettingsProxyAddressHint,
              helperText: loc.siteSettingsProxyAddressHelper,
              border: const OutlineInputBorder(),
            ),
            // The save button is a screen away, so a malformed address is
            // flagged here, where it can still be fixed.
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) => validateProxyAddress(loc, type, value),
          ),
        ),
        ProxyAuthSection(
          usernameController: widget.proxyUsernameController,
          passwordController: widget.proxyPasswordController,
        ),
      ],
      if (type != ProxyType.DEFAULT && widget.proxyTest != null)
        widget.proxyTest!,
    ];
  }

  // --- Connection ----------------------------------------------------------

  Widget _webRtc(AppLocalizations loc) => ListTile(
        title: Row(
          children: [
            Flexible(child: Text(loc.siteSettingsWebRtcPolicy)),
            HintButton(
              title: loc.siteSettingsWebRtcHintTitle,
              description: loc.siteSettingsWebRtcHintBody,
            ),
          ],
        ),
        trailing: DropdownButton<WebRtcPolicy>(
          value: _values.webRtcPolicy,
          onChanged: (next) {
            if (next != null) _update(_values.copyWith(webRtcPolicy: next));
          },
          items: [
            DropdownMenuItem(
                value: WebRtcPolicy.defaultPolicy,
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
