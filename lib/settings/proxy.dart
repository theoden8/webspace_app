enum ProxyType { DEFAULT }//, HTTP, HTTPS, SOCKS4, SOCKS5 }

class ProxySettings {
  ProxyType type;
  String? address;

  ProxySettings({required this.type, this.address});

  Map<String, dynamic> toJson() => {
        'type': type.index,
        'address': address,
      };

  factory ProxySettings.fromJson(Map<String, dynamic> json) => ProxySettings(
        type: ProxyType.values[json['type']],
        address: json['address'],
      );
}
