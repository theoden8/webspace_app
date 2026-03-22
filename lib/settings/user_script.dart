/// Model for a user-defined script to inject into webviews.
///
/// Each script has a name, source code, injection time, and enabled toggle.
/// Scripts are stored per-site in WebViewModel and serialized to JSON.
enum UserScriptInjectionTime {
  atDocumentStart,
  atDocumentEnd,
}

class UserScriptConfig {
  String name;
  String source;
  UserScriptInjectionTime injectionTime;
  bool enabled;

  UserScriptConfig({
    required this.name,
    required this.source,
    this.injectionTime = UserScriptInjectionTime.atDocumentEnd,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'source': source,
        'injectionTime': injectionTime.index,
        'enabled': enabled,
      };

  factory UserScriptConfig.fromJson(Map<String, dynamic> json) {
    return UserScriptConfig(
      name: json['name'] ?? 'Untitled',
      source: json['source'] ?? '',
      injectionTime: json['injectionTime'] == 0
          ? UserScriptInjectionTime.atDocumentStart
          : UserScriptInjectionTime.atDocumentEnd,
      enabled: json['enabled'] ?? true,
    );
  }
}
