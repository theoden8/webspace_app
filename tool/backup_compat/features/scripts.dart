import 'package:webspace/settings/user_script.dart';

List<Map<String, dynamic>> shimGlobalScripts(List<dynamic> raw) => [
      for (final e in raw)
        UserScriptConfig.fromJson(Map<String, dynamic>.from(e as Map)).toJson(),
    ];
