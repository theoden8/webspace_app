import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_native.dart';
import 'package:webspace/settings/web_extension.dart';

/// [ExtensionEngine] as WebKit answers it: a report by folder ([reports],
/// else [anyFolder]), a page shown only for an extension its home loads and
/// whose report has the page, and each extension's stored data by container,
/// which [forget] deletes everywhere.
class FakeExtensionEngine implements ExtensionEngine {
  final Map<String, ExtensionReport> reports = {};
  ExtensionReport? anyFolder;
  final List<({ExtensionPage page, WebExtensionId extension, ExtensionHome home})>
  shown = [];
  final Map<String, Set<WebExtensionId>> stored = {};

  /// Where [inspect] was asked, in order.
  final List<String> inspected = [];

  @override
  Future<ExtensionReport?> inspect(String folder) async {
    inspected.add(folder);
    return reports[folder] ?? anyFolder;
  }

  @override
  Future<bool> openPage(
    ExtensionPage page, {
    required WebExtensionId extension,
    required ExtensionHome home,
  }) async {
    final load = [
      for (final load in home.plan.loads)
        if (load.id == extension) load,
    ].firstOrNull;
    final report = load == null ? null : reports[load.folder] ?? anyFolder;
    final has = switch (page) {
      ExtensionPage.options => report?.hasOptionsPage ?? false,
      ExtensionPage.action => report?.hasAction ?? false,
    };
    if (!has) return false;
    shown.add((page: page, extension: extension, home: home));
    stored.putIfAbsent(home.container, () => {}).add(extension);
    return true;
  }

  @override
  Future<void> forget(WebExtensionId extension) async {
    for (final ids in stored.values) {
      ids.remove(extension);
    }
  }
}
