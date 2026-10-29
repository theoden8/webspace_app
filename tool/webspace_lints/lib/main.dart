import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/positional_parameters.dart';

final plugin = WebspaceLints();

class WebspaceLints extends Plugin {
  @override
  String get name => 'webspace_lints';

  @override
  void register(PluginRegistry registry) {
    registry.registerWarningRule(PositionalParameters());
  }
}
