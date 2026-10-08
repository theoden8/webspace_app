import 'package:webspace/settings/proxy.dart';

/// What the proxy form currently holds. Plain strings, because a text field's
/// "empty" is `''` and the stored model's is `null`, and the whole point of
/// this engine is that exactly one place performs that conversion.
class ProxyFormFields {
  const ProxyFormFields({
    required this.type,
    this.address = '',
    this.username = '',
    this.password = '',
    this.savedProxyId,
    this.gatewayId,
    this.credentialsId,
  });

  final ProxyType type;
  final String address;
  final String username;
  final String password;

  /// What the library pickers hold: the saved proxy under
  /// [ProxyType.SAVED], the saved gateway under [ProxyType.GATEWAY], and the
  /// saved credentials, null meaning the typed ones.
  final String? savedProxyId;
  final String? gatewayId;
  final String? credentialsId;
}

/// Fold the form into the settings to store (PROXY-019).
///
/// One rule, two screens: the per-site and app-wide proxy forms both fold
/// through here, so they cannot disagree on `''` versus `null` or on when
/// credentials are cleared.
///
/// The rule:
///
///  - **A visible field is the truth.** Under HTTP / HTTPS / SOCKS5 the
///    address and credentials are on screen, so what they hold is what gets
///    stored, and emptying one is how it gets removed.
///  - **A hidden field is not.** Under DEFAULT, TOR and SAVED they are not
///    rendered, nor the address under a saved gateway, nor the credentials
///    while saved ones are picked, so their controllers hold whatever was
///    last drawn. Writing that back would destroy the manual configuration
///    the user expects to find again on switch-out, so the stored values
///    carry over untouched (PROXY-010).
UserProxySettings applyProxyForm({
  required UserProxySettings stored,
  required ProxyFormFields fields,
}) {
  final type = fields.type;
  final gateway = type == ProxyType.GATEWAY;
  final typedGateway = type == ProxyType.HTTP ||
      type == ProxyType.HTTPS ||
      type == ProxyType.SOCKS5;
  // A saved gateway takes the place of the address field; saved credentials
  // take the place of the credentials fields.
  final addressShown = typedGateway;
  final credentialsShown =
      typedGateway || (gateway && fields.credentialsId == null);
  return UserProxySettings(
    type: type,
    address: addressShown ? _orNull(fields.address.trim()) : stored.address,
    username: credentialsShown ? _orNull(fields.username) : stored.username,
    password: credentialsShown ? _orNull(fields.password) : stored.password,
    torExitCountry: stored.torExitCountry,
    savedProxyId:
        type == ProxyType.SAVED ? fields.savedProxyId : stored.savedProxyId,
    gatewayId: gateway ? fields.gatewayId : stored.gatewayId,
    // Saved credentials fit saved gateways only, so a typed gateway drops
    // the reference rather than keep one that would fail closed.
    credentialsId: gateway
        ? fields.credentialsId
        : (typedGateway ? null : stored.credentialsId),
  );
}

String? _orNull(String value) => value.isEmpty ? null : value;
