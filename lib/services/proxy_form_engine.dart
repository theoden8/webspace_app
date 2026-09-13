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
  });

  final ProxyType type;
  final String address;
  final String username;
  final String password;
}

/// Fold the form into the settings to store (PROXY-019).
///
/// One rule, two screens. The per-site and app-wide proxy forms each carried
/// their own copy of this and the copies disagreed: one wrote `''` where the
/// other wrote `null`, and one cleared credentials whenever a checkbox that
/// nothing persisted came back unticked. That checkbox was restored from
/// [UserProxySettings.hasCredentials], an AND over both fields, so a proxy
/// configured with only one of them reopened unticked and the next save
/// discarded the other.
///
/// The rule:
///
///  - **A visible field is the truth.** Under HTTP / HTTPS / SOCKS5 the
///    address and credentials are on screen, so what they hold is what gets
///    stored, and emptying one is how it gets removed.
///  - **A hidden field is not.** Under DEFAULT and TOR they are not rendered,
///    so their controllers hold whatever was last drawn. Writing that back
///    would destroy the manual configuration the user expects to find again
///    on switch-out, so the stored values carry over untouched (PROXY-010).
UserProxySettings applyProxyForm({
  required UserProxySettings stored,
  required ProxyFormFields fields,
}) {
  final hidden =
      fields.type == ProxyType.DEFAULT || fields.type == ProxyType.TOR;
  return UserProxySettings(
    type: fields.type,
    address: hidden ? stored.address : _orNull(fields.address.trim()),
    username: hidden ? stored.username : _orNull(fields.username),
    password: hidden ? stored.password : _orNull(fields.password),
    torExitCountry: stored.torExitCountry,
  );
}

String? _orNull(String value) => value.isEmpty ? null : value;
