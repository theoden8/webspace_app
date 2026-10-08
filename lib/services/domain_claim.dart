enum DomainClaimKind { exactHost, wildcardSubdomain, baseDomain }

class DomainClaim {
  final DomainClaimKind kind;
  final String value;

  const DomainClaim._raw(this.kind, {required this.value});

  factory DomainClaim(DomainClaimKind kind, {required String value}) =>
      DomainClaim._raw(kind, value: _canon(kind, s: value));

  factory DomainClaim.exactHost(String host) =>
      DomainClaim(DomainClaimKind.exactHost, value: host);

  factory DomainClaim.wildcardSubdomain(String host) =>
      DomainClaim(DomainClaimKind.wildcardSubdomain, value: host);

  factory DomainClaim.baseDomain(String host) =>
      DomainClaim(DomainClaimKind.baseDomain, value: host);

  static String _canon(DomainClaimKind kind, {required String s}) {
    var v = s.trim().toLowerCase();
    if (v.isEmpty) return v;
    if (v.contains('://')) {
      final parsed = Uri.tryParse(v);
      if (parsed != null && parsed.host.isNotEmpty) {
        final h = parsed.host;
        final wrapped = h.contains(':') && !h.startsWith('[') ? '[$h]' : h;
        v = parsed.hasPort ? '$wrapped:${parsed.port}' : wrapped;
      }
    }
    if (v.startsWith('*.')) v = v.substring(2);
    String host;
    String portSuffix = '';
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      if (close > 0) {
        host = v.substring(1, close);
        final rest = v.substring(close + 1);
        if (rest.startsWith(':')) portSuffix = rest;
      } else {
        host = v;
      }
    } else {
      final colon = v.indexOf(':');
      if (colon > 0) {
        host = v.substring(0, colon);
        portSuffix = v.substring(colon);
      } else {
        host = v;
      }
    }
    if (kind == DomainClaimKind.exactHost && portSuffix.isNotEmpty) {
      final h = host.contains(':') ? '[$host]' : host;
      return '$h$portSuffix';
    }
    return host;
  }

  Map<String, dynamic> toJson() => {'kind': kind.name, 'value': value};

  factory DomainClaim.fromJson(Map<String, dynamic> json) => DomainClaim(
        DomainClaimKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => DomainClaimKind.baseDomain,
        ),
        value: json['value'] as String? ?? '',
      );

  /// Null for a value that is present but not a string.
  static DomainClaim? tryFromJson(Map<String, dynamic> json) =>
      json['value'] is String? ? DomainClaim.fromJson(json) : null;

  @override
  bool operator ==(Object other) =>
      other is DomainClaim && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => '${kind.name}:$value';
}
