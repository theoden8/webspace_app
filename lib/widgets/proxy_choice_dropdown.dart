import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/proxy_library.dart';
import 'package:webspace/widgets/proxy_auth_section.dart';

/// What a proxy form asks for under each type. Exhaustive, so a new type
/// says here whether it carries an address before any form can offer it.
extension ProxyTypeForm on ProxyType {
  /// Whether the manual route fields show. TOR supplies its own loopback
  /// address and stream-isolation auth, and a saved proxy its whole route,
  /// so the fields are inert under either: hidden, not cleared, so a stored
  /// SOCKS5 config survives the trip (PROXY-010).
  bool get showsRouteFields => switch (this) {
    ProxyType.HTTP ||
    ProxyType.HTTPS ||
    ProxyType.SOCKS5 ||
    ProxyType.GATEWAY => true,
    ProxyType.DEFAULT || ProxyType.TOR || ProxyType.SAVED => false,
  };

  /// Whether the form checks a typed address. A saved proxy or gateway was
  /// checked where it was saved; TOR has no address to type.
  bool get typesAddress => switch (this) {
    ProxyType.HTTP || ProxyType.HTTPS || ProxyType.SOCKS5 => true,
    ProxyType.DEFAULT ||
    ProxyType.TOR ||
    ProxyType.SAVED ||
    ProxyType.GATEWAY => false,
  };
}

/// What a proxy picker chose: a type, and the library entry it names under
/// [ProxyType.SAVED] or [ProxyType.GATEWAY].
class ProxyChoice {
  const ProxyChoice(this.type, {this.savedProxyId, this.gatewayId});

  final ProxyType type;
  final String? savedProxyId;
  final String? gatewayId;
}

/// The label a library entry goes by: its name, or what it holds when it has
/// none, so two unnamed entries can still be told apart.
String savedProxyLabel(SavedProxy proxy) => proxy.name.trim().isNotEmpty
    ? proxy.name.trim()
    : (proxy.settings.address ?? proxy.settings.type.name);

String gatewayLabel(SavedGateway gateway) => gateway.name.trim().isNotEmpty
    ? gateway.name.trim()
    : (gateway.address ?? gateway.type.name);

String credentialsLabel(SavedCredentials credentials) =>
    credentials.name.trim().isNotEmpty
        ? credentials.name.trim()
        : (credentials.username ?? credentials.id);

/// Why a route taken from the library does not resolve, as the user reads it.
String libraryProblemLabel(AppLocalizations loc, LibraryProblem problem) =>
    switch (problem) {
      LibraryProblem.none || LibraryProblem.proxyMissing =>
        loc.savedProxyMissing,
      LibraryProblem.gatewayMissing => loc.proxyLibraryGatewayMissing,
      LibraryProblem.credentialsMissing => loc.proxyLibraryCredentialsMissing,
      LibraryProblem.credentialsMismatch =>
        loc.proxyLibraryCredentialsMismatch,
    };

/// A route as data (LOC-002): the type name and the address.
/// What a TOR route is called: TOR, or "Tor (external)" where this launch
/// rides an external tor (TOR-025), so no picker or summary passes one off as
/// the other. [external] defaults to the running service.
String torRouteLabel(AppLocalizations loc, {bool? external}) =>
    (external ?? TorService.instance.isExternal)
        ? loc.appSettingsExperimentalExternalTor
        : ProxyType.TOR.name;

String routeLabel(UserProxySettings route) =>
    '${route.type.name} ${route.address ?? ''}'.trim();

// The button is as wide as its widest item, and a library entry's name is
// the user's to make long; unbounded, it would push the row's title off a
// phone screen.
const double _maxLabelWidth = 160;

DropdownMenuItem<String> _item(String key, String label) => DropdownMenuItem(
      value: key,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxLabelWidth),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );

DropdownMenuItem<String> _header(
  BuildContext context,
  String key,
  String label,
) =>
    DropdownMenuItem(
      value: key,
      enabled: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxLabelWidth),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      ),
    );

/// The proxy picker: the plain types, and the library's saved proxies and
/// gateways by name, each under its heading (PROXY-030). Shared by the
/// per-site and app-wide forms, and, with [gatewaysOnly], by the saved proxy
/// form, whose gateway is the same choice.
class ProxyChoiceDropdown extends StatelessWidget {
  const ProxyChoiceDropdown({
    super.key,
    required this.type,
    required this.savedProxyId,
    required this.gatewayId,
    required this.library,
    required this.torAvailable,
    this.torExternal = false,
    required this.onChanged,
    this.gatewaysOnly = false,
  });

  final ProxyType type;
  final String? savedProxyId;
  final String? gatewayId;
  final ProxyLibraryData library;

  /// TOR is only offerable where a Tor runtime exists (TOR-007).
  final bool torAvailable;

  /// Whether the TOR entry is an external tor (TOR-025), which it is then
  /// called.
  final bool torExternal;
  final ValueChanged<ProxyChoice> onChanged;

  /// Offer gateways only: saved ones and the typed types.
  final bool gatewaysOnly;

  static const String _savedPrefix = 'saved:';
  static const String _gatewayPrefix = 'gateway:';
  static const String _proxiesHeader = 'header:proxies';
  static const String _gatewaysHeader = 'header:gateways';

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final current = switch (type) {
      ProxyType.SAVED => '$_savedPrefix${savedProxyId ?? ''}',
      ProxyType.GATEWAY => '$_gatewayPrefix${gatewayId ?? ''}',
      _ => type.name,
    };
    final keys = <String>{};
    final items = <DropdownMenuItem<String>>[];
    void add(DropdownMenuItem<String> item) {
      if (keys.add(item.value!)) items.add(item);
    }

    if (!gatewaysOnly) {
      add(_item(ProxyType.DEFAULT.name, ProxyType.DEFAULT.name));
    }
    if (!gatewaysOnly &&
        (library.proxies.isNotEmpty || type == ProxyType.SAVED)) {
      add(_header(context, _proxiesHeader, loc.savedProxiesTitle));
      for (final p in library.proxies) {
        add(_item('$_savedPrefix${p.id}', savedProxyLabel(p)));
      }
      // A setting still naming a deleted entry keeps an item, because a
      // DropdownButton whose value is absent from its items throws, and
      // because "missing" is what the setting actually has.
      if (type == ProxyType.SAVED) add(_item(current, loc.savedProxyMissing));
    }
    if (library.gateways.isNotEmpty || type == ProxyType.GATEWAY) {
      add(_header(context, _gatewaysHeader, loc.proxyLibraryGateways));
      for (final g in library.gateways) {
        add(_item('$_gatewayPrefix${g.id}', gatewayLabel(g)));
      }
      if (type == ProxyType.GATEWAY) {
        add(_item(current, loc.proxyLibraryGatewayMissing));
      }
    }
    for (final t in const [ProxyType.HTTP, ProxyType.HTTPS, ProxyType.SOCKS5]) {
      add(_item(t.name, t.name));
    }
    // A site that already carries TOR (say, from a backup taken on iOS and
    // imported on Android) keeps the option visible.
    if (!gatewaysOnly && (torAvailable || type == ProxyType.TOR)) {
      add(_item(
          ProxyType.TOR.name, torRouteLabel(loc, external: torExternal)));
    }

    return DropdownButton<String>(
      value: current,
      isDense: true,
      onChanged: (key) {
        if (key == null) return;
        if (key.startsWith(_savedPrefix)) {
          final id = key.substring(_savedPrefix.length);
          onChanged(ProxyChoice(ProxyType.SAVED,
              savedProxyId: id.isEmpty ? null : id));
        } else if (key.startsWith(_gatewayPrefix)) {
          final id = key.substring(_gatewayPrefix.length);
          onChanged(ProxyChoice(ProxyType.GATEWAY,
              gatewayId: id.isEmpty ? null : id));
        } else {
          onChanged(ProxyChoice(ProxyType.values.byName(key)));
        }
      },
      items: items,
    );
  }
}

/// Credentials for a saved gateway: typed below, or saved credentials that
/// list the gateway. Nothing else is offered, since nothing else would sign in
/// (a pairing the credentials do not list fails closed).
class ProxyCredentialsDropdown extends StatelessWidget {
  const ProxyCredentialsDropdown({
    super.key,
    required this.gatewayId,
    required this.credentialsId,
    required this.library,
    required this.onChanged,
  });

  final String? gatewayId;
  final String? credentialsId;
  final ProxyLibraryData library;
  final ValueChanged<String?> onChanged;

  static const String _typed = 'typed';
  static const String _prefix = 'credentials:';

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final current = credentialsId == null ? _typed : '$_prefix$credentialsId';
    final items = <DropdownMenuItem<String>>[
      _item(_typed, loc.proxyLibraryCredentialsTyped),
      for (final c in library.credentialsFor(gatewayId))
        _item('$_prefix${c.id}', credentialsLabel(c)),
    ];
    if (!items.any((i) => i.value == current)) {
      items.add(_item(
        current,
        library.credentialsById(credentialsId) == null
            ? loc.proxyLibraryCredentialsMissing
            : loc.proxyLibraryCredentialsMismatch,
      ));
    }
    return DropdownButton<String>(
      value: current,
      isDense: true,
      onChanged: (key) {
        if (key == null) return;
        onChanged(key == _typed ? null : key.substring(_prefix.length));
      },
      items: items,
    );
  }
}

/// Everything under a gateway choice: the address when the gateway is typed,
/// the credentials picker when it is saved, and the typed credentials unless
/// saved ones are picked. The caller owns the controllers, as it does for a
/// plain proxy.
class ProxyRouteFields extends StatelessWidget {
  const ProxyRouteFields({
    super.key,
    required this.type,
    required this.gatewayId,
    required this.credentialsId,
    required this.library,
    required this.addressController,
    required this.usernameController,
    required this.passwordController,
    required this.addressValidator,
    required this.onCredentialsChanged,
    this.onEditingComplete,
    this.addressLabel,
    this.addressHint,
    this.addressHelper,
  });

  /// HTTP, HTTPS or SOCKS5 for a typed gateway, GATEWAY for a saved one.
  final ProxyType type;
  final String? gatewayId;
  final String? credentialsId;
  final ProxyLibraryData library;
  final TextEditingController addressController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final FormFieldValidator<String> addressValidator;
  final ValueChanged<String?> onCredentialsChanged;

  /// For a form that saves as each field is left rather than on a button.
  final VoidCallback? onEditingComplete;

  /// The address field's texts, where a form words them its own way.
  final String? addressLabel;
  final String? addressHint;
  final String? addressHelper;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final savedGateway = type == ProxyType.GATEWAY;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!savedGateway)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextFormField(
              controller: addressController,
              decoration: InputDecoration(
                labelText: addressLabel ?? loc.siteSettingsProxyAddress,
                hintText: addressHint ?? loc.siteSettingsProxyAddressHint,
                helperText: addressHelper ?? loc.siteSettingsProxyAddressHelper,
                border: const OutlineInputBorder(),
              ),
              // The save button can be a screen away, so a malformed address
              // is flagged here, where it can still be fixed.
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: addressValidator,
              onFieldSubmitted: onEditingComplete == null
                  ? null
                  : (_) => onEditingComplete!(),
              onEditingComplete: onEditingComplete,
            ),
          ),
        if (savedGateway)
          ListTile(
            title: Text(loc.proxyLibraryCredentials),
            trailing: ProxyCredentialsDropdown(
              gatewayId: gatewayId,
              credentialsId: credentialsId,
              library: library,
              onChanged: onCredentialsChanged,
            ),
          ),
        if (credentialsId == null)
          ProxyAuthSection(
            usernameController: usernameController,
            passwordController: passwordController,
            onEditingComplete: onEditingComplete,
          ),
      ],
    );
  }
}
