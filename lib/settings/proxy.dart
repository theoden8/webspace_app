enum ProxyType { DEFAULT, HTTP, HTTPS, SOCKS5 }

class UserProxySettings {
  ProxyType type;
  String? address;
  String? username;
  String? password;

  UserProxySettings({required this.type, this.address, this.username, this.password});

  /// Serialize to JSON.
  ///
  /// [includePassword] defaults to false because the canonical store for the
  /// password is `flutter_secure_storage` (see [ProxyPasswordSecureStorage]),
  /// not plaintext SharedPreferences. The persistence path through
  /// `_saveWebViewModels` / `writeGlobalOutboundProxy` MUST keep the default,
  /// otherwise the password leaks back into prefs and the secure-storage
  /// migration is undone. Pass `true` only when the destination is itself a
  /// user-controlled secret carrier — currently only the export format
  /// produced by `SettingsBackupService`.
  Map<String, dynamic> toJson({bool includePassword = false}) => {
        'type': type.index,
        'address': address,
        'username': username,
        if (includePassword) 'password': password,
      };

  factory UserProxySettings.fromJson(Map<String, dynamic> json) => UserProxySettings(
        type: ProxyType.values[json['type']],
        address: json['address'],
        username: json['username'],
        password: json['password'],
      );

  /// Returns true if credentials are provided
  bool get hasCredentials => username != null && username!.isNotEmpty && password != null && password!.isNotEmpty;
}
