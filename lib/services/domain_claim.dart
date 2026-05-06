enum DomainClaimKind { exactHost, wildcardSubdomain, baseDomain }

class DomainClaim {
  final DomainClaimKind kind;
  final String value;

  const DomainClaim._raw(this.kind, this.value);

  factory DomainClaim(DomainClaimKind kind, String value) =>
      DomainClaim._raw(kind, _canon(value));

  factory DomainClaim.exactHost(String host) =>
      DomainClaim(DomainClaimKind.exactHost, host);

  factory DomainClaim.wildcardSubdomain(String host) =>
      DomainClaim(DomainClaimKind.wildcardSubdomain, host);

  factory DomainClaim.baseDomain(String host) =>
      DomainClaim(DomainClaimKind.baseDomain, host);

  static String _canon(String s) {
    var v = s.trim().toLowerCase();
    if (v.isEmpty) return v;
    if (v.contains('://')) {
      v = Uri.tryParse(v)?.host ?? v;
    }
    if (v.startsWith('*.')) v = v.substring(2);
    final colon = v.indexOf(':');
    if (colon > 0) v = v.substring(0, colon);
    if (v.startsWith('[') && v.contains(']')) {
      v = v.substring(1, v.indexOf(']'));
    }
    return v;
  }

  Map<String, dynamic> toJson() => {'kind': kind.name, 'value': value};

  factory DomainClaim.fromJson(Map<String, dynamic> json) => DomainClaim(
        DomainClaimKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => DomainClaimKind.baseDomain,
        ),
        json['value'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is DomainClaim && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => '${kind.name}:$value';
}
