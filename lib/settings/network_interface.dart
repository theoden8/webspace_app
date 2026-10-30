/// A network interface's name as the kernel gives it (`wg0`, `tun0`): up to
/// 15 letters, digits, `.`, `_` and `-`, which a Linux name can hold and the
/// egress relay accepts (network-interface NETIF-001).
extension type const InterfaceName._(String raw) implements String {
  static InterfaceName? parse(Object? raw) =>
      raw is String && _valid.hasMatch(raw) ? InterfaceName._(raw) : null;

  static final _valid = RegExp(r'^[A-Za-z0-9._-]{1,15}$');
}

/// Which interface a site's traffic leaves by (NETIF-001). Rides the site's
/// `UserProxySettings` as its Tor exit country does, so every seam that
/// carries the proxy carries it.
sealed class InterfaceChoice {
  const InterfaceChoice();

  /// The stored value: absent is [SystemRouting]; one this build cannot
  /// read is [UnreadableInterface], which refuses rather than follows the
  /// system's routing, so a choice made by a newer build is never dropped
  /// into a route the user did not pick.
  factory InterfaceChoice.fromJson(Object? raw) {
    if (raw == null) return const SystemRouting();
    if (raw case {'name': final Object? name}) {
      if (InterfaceName.parse(name) case final named?) {
        return NamedInterface(named);
      }
    }
    return UnreadableInterface(raw);
  }

  /// What `UserProxySettings.toJson` writes, or null to write nothing.
  Object? toJson();
}

/// The system's routing table decides, as for every site before this.
final class SystemRouting extends InterfaceChoice {
  const SystemRouting();

  @override
  Object? toJson() => null;

  @override
  bool operator ==(Object other) => other is SystemRouting;

  @override
  int get hashCode => (SystemRouting).hashCode;
}

/// The site leaves by [name] and by nothing else (NETIF-002).
final class NamedInterface extends InterfaceChoice {
  const NamedInterface(this.name);

  final InterfaceName name;

  @override
  Object? toJson() => {'name': name};

  @override
  bool operator ==(Object other) =>
      other is NamedInterface && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A stored choice this build cannot read, written back as it came.
final class UnreadableInterface extends InterfaceChoice {
  const UnreadableInterface(this.raw);

  final Object raw;

  @override
  Object? toJson() => raw;

  @override
  bool operator ==(Object other) =>
      other is UnreadableInterface && identical(other.raw, raw);

  @override
  int get hashCode => identityHashCode(raw);
}
