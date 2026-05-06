import 'package:flutter/foundation.dart';

import 'abp_filter_parser.dart';

/// Parse ABP filter text in an isolate to avoid blocking the UI thread.
///
/// Lives in a separate file so the pure-Dart parser core
/// ([parseAbpFilterListSync]) stays free of the `package:flutter`
/// dependency that `compute()` pulls in — `tool/dump_shim_js.dart`
/// runs under plain `dart run` and can't resolve `dart:ui`-bound
/// transitive deps.
Future<AbpParseResult> parseAbpFilterList(String text) {
  return compute(_parseInIsolate, text);
}

AbpParseResult _parseInIsolate(String text) {
  return parseAbpFilterListSync(text);
}
