enum ProxyType { DEFAULT, HTTP, HTTPS, SOCKS5 }

class UserProxySettings {
  ProxyType type;
  String? address;
  String? username;
  String? password;

  UserProxySettings({required this.type, this.address, this.username, this.password});

  /// Serialize to JSON.
  ///
  /// The password is intentionally never written to JSON. The canonical
  /// store for it is `flutter_secure_storage` via
  /// [ProxyPasswordSecureStorage]; both at-rest persistence
  /// (SharedPreferences) and the user-controlled backup export format
  /// strip it. After a backup restore the user re-enters proxy passwords
  /// — same UX contract as secure cookies, which are also export-stripped.
  /// See `openspec/specs/proxy-password-secure-storage/spec.md` (PWD-005).
  Map<String, dynamic> toJson() => {
        'type': type.index,
        'address': address,
        'username': username,
      };

  factory UserProxySettings.fromJson(Map<String, dynamic> json) => UserProxySettings(
        type: ProxyType.values[json['type']],
        address: json['address'],
        username: json['username'],
        password: json['password'],
      );

  /// PII-safe one-line summary suitable for [LogService] output that the
  /// user may share publicly when debugging proxy issues. Type and address
  /// are emitted verbatim (the address is `host:port`, not a secret), but
  /// username and password are reported as booleans only — they may
  /// identify the user or unlock the proxy and must never appear in logs.
  String describeForLogs() {
    final t = type.toString().split('.').last;
    final a = address ?? '<none>';
    return 'type=$t address=$a hasUsername=${username != null && username!.isNotEmpty} '
        'hasPassword=${password != null && password!.isNotEmpty}';
  }

  /// Returns true if credentials are provided
  bool get hasCredentials => username != null && username!.isNotEmpty && password != null && password!.isNotEmpty;
}
