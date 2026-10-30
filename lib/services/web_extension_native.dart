import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/container_names.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/settings/web_extension.dart';

/// The fork's form of a site's extension plan: null for none.
inapp.WebExtensionAttach? nativeExtensions(ExtensionAttach attach) =>
    switch (attach) {
      NoExtensions() => null,
      AttachExtensions(:final persistent, :final loads) =>
        inapp.WebExtensionAttach(
          persistent: persistent,
          contexts: [
            for (final load in loads)
              inapp.WebExtensionContextSpec(
                id: load.id,
                path: load.folder,
                revision: load.revision,
                grantedMatchPatterns: load.grants.matchPatterns.toList()
                  ..sort(),
                grantedPermissions: load.grants.permissions.toList()..sort(),
              ),
          ],
        ),
    };

/// A page of an extension a site opens over itself (WEBEXT-008).
enum ExtensionPage {
  /// Its options page.
  options,

  /// Its action: its popup, or its click event where it has no popup.
  action,
}

/// What WebKit reported reading an extension's files (WEBEXT-003): each
/// problem in WebKit's words, and which pages it has to open.
typedef ExtensionReport = ({
  List<String> problems,
  bool hasOptionsPage,
  bool hasAction,
});

/// What the app asks WebKit of an extension outside a webview's build.
/// Where the platform refuses, each answers as though nothing were there.
abstract interface class ExtensionEngine {
  /// What WebKit reports reading the extension in [folder]; null where it
  /// reads none.
  Future<ExtensionReport?> inspect(String folder);

  /// Shows [page] of [extension] as [home]'s webviews run it; false when it
  /// was not shown.
  Future<bool> openPage(
    ExtensionPage page, {
    required WebExtensionId extension,
    required ExtensionHome home,
  });

  /// Unloads [extension] wherever it runs and deletes what it stored in
  /// every site's container.
  Future<void> forget(WebExtensionId extension);
}

final class NativeExtensionEngine implements ExtensionEngine {
  const NativeExtensionEngine();

  inapp.ContainerController get _native =>
      inapp.ContainerController.instance();

  @override
  Future<ExtensionReport?> inspect(String folder) async {
    final inapp.WebExtensionReport? report;
    try {
      report = await _native.inspectWebExtension(folder);
    } on PlatformException catch (e) {
      LogTag.webExtension.info('inspect failed: $e');
      return null;
    } on MissingPluginException catch (e) {
      LogTag.webExtension.info('inspect failed: $e');
      return null;
    }
    if (report == null) return null;
    return (
      problems: report.errors,
      hasOptionsPage: report.hasOptionsPage,
      hasAction: report.hasAction,
    );
  }

  @override
  Future<bool> openPage(
    ExtensionPage page, {
    required WebExtensionId extension,
    required ExtensionHome home,
  }) async {
    final attach = nativeExtensions(home.plan);
    if (attach == null) return false;
    try {
      return await _native.openWebExtensionPage(
        containerId: home.container,
        attach: attach,
        extensionId: extension,
        page: switch (page) {
          ExtensionPage.options => inapp.WebExtensionPage.OPTIONS,
          ExtensionPage.action => inapp.WebExtensionPage.ACTION,
        },
      );
    } on PlatformException catch (e) {
      LogTag.webExtension.info('$extension page failed: $e');
      return false;
    } on MissingPluginException catch (e) {
      LogTag.webExtension.info('$extension page failed: $e');
      return false;
    }
  }

  @override
  Future<void> forget(WebExtensionId extension) async {
    try {
      final names = await _native.getAllContainerNames();
      await _native.removeWebExtensionData(
        extensionId: extension,
        containerIds: [
          for (final name in names) ?ContainerName.parse(name),
        ],
      );
    } on PlatformException catch (e) {
      LogTag.webExtension.info('$extension data stays: $e');
    } on MissingPluginException catch (e) {
      LogTag.webExtension.info('$extension data stays: $e');
    }
  }
}
