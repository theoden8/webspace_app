enum ProxyType { DEFAULT, HTTP, HTTPS, SOCKS5 }

class UserProxySettings {
  ProxyType type;
  String? address;
  String? username;
  String? password;

  UserProxySettings({required this.type, this.address, this.username, this.password});

  Map<String, dynamic> toJson() => {
        'type': type.index,
        'address': address,
        'username': username,
        'password': password,
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
