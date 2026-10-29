import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/catch_all.dart';
import 'src/held_in_turn.dart';
import 'src/positional_parameters.dart';
import 'src/raw_http_client.dart';

final plugin = WebspaceLints();

class WebspaceLints extends Plugin {
  @override
  String get name => 'webspace_lints';

  @override
  void register(PluginRegistry registry) {
    registry
      ..registerWarningRule(CatchAll())
      ..registerWarningRule(PositionalParameters())
      ..registerWarningRule(HeldInTurn())
      ..registerWarningRule(RawHttpClient());
  }
}
