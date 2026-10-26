import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/web_extension_attach_engine.dart';

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
                grantedMatchPatterns: load.grants.matchPatterns.toList()
                  ..sort(),
                grantedPermissions: load.grants.permissions.toList()..sort(),
              ),
          ],
        ),
    };
