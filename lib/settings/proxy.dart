enum ProxyType { DEFAULT }//, HTTP, HTTPS, SOCKS4, SOCKS5 }

class UserProxySettings {
  ProxyType type;
  String? address;

  UserProxySettings({required this.type, this.address});

  Map<String, dynamic> toJson() => {
        'type': type.index,
        'address': address,
      };

  factory UserProxySettings.fromJson(Map<String, dynamic> json) => UserProxySettings(
        type: ProxyType.values[json['type']],
        address: json['address'],
      );
}
