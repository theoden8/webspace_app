import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/web_view_model.dart';

/// [ShortcutPrompts] as dialogs over the page that owns [context].
class DialogShortcutPrompts implements ShortcutPrompts {
  const DialogShortcutPrompts(this.context);

  final BuildContext context;

  AppLocalizations get _loc => AppLocalizations.of(context);

  @override
  Future<bool> confirmOpen(String siteName) async {
    final loc = _loc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeShortcutConfirmOpenTitle),
        content: Text(loc.homeShortcutConfirmOpenBody(siteName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(loc.commonOpen),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Future<MissingShortcutChoice?> missingSite(String url) {
    final loc = _loc;
    return showDialog<MissingShortcutChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeShortcutMissingTitle),
        content: Text(loc.homeShortcutMissingBody(url)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(MissingShortcutChoice.reroute),
            child: Text(loc.homeShortcutOpenAnother),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(MissingShortcutChoice.create),
            child: Text(loc.homeCreateAction),
          ),
        ],
      ),
    );
  }

  @override
  Future<ShortcutFate?> deletedSiteTiles() {
    final loc = _loc;
    return showDialog<ShortcutFate>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeShortcutFateTitle),
        content: Text(loc.homeShortcutFateBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ShortcutFate.keep),
            child: Text(loc.homeShortcutKeep),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ShortcutFate.reassign),
            child: Text(loc.homeShortcutReassign),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ShortcutFate.disable),
            child: Text(loc.homeShortcutDisable),
          ),
        ],
      ),
    );
  }

  @override
  Future<String?> pickSite(List<WebViewModel> candidates) {
    final loc = _loc;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeShortcutPickTitle),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, i) {
              final m = candidates[i];
              return ListTile(
                leading: SizedBox(
                  width: 32,
                  height: 32,
                  child: UnifiedFaviconImage(
                    url: m.initUrl,
                    size: 32,
                    proxy: m.outboundProxySettings,
                    customIcon: m.customIconPng,
                  ),
                ),
                title: Text(
                  m.getDisplayName(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  m.initUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(ctx).pop(m.siteId),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(loc.commonCancel),
          ),
        ],
      ),
    );
  }

  /// iOS embeds the AppIntents ShortcutsUIButton, which lands on WebSpace's
  /// own App Shortcuts page; the bare shortcuts:// scheme macOS uses can only
  /// open the Shortcuts app's main view.
  @override
  Future<void> explainIosShortcut(String siteName) {
    final loc = _loc;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeAddToHomeScreenTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.homeAddToHomeScreenIosBody(siteName)),
            const SizedBox(height: 16),
            _ShortcutsLinkButton(onOpened: () {
              if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(loc.commonCancel),
          ),
        ],
      ),
    );
  }

  @override
  Future<bool> confirmMacosShortcut(String siteName) async {
    final loc = _loc;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeAddShortcutTitleMacos),
        content: Text(loc.homeAddShortcutMacosBody(siteName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(loc.homeOpenShortcuts),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}

/// HS-010: native AppIntents `ShortcutsUIButton` (iOS 16+) that opens
/// WebSpace's App Shortcuts page in Shortcuts.app. [onOpened] fires on the
/// same tap so the caller can dismiss the hosting dialog.
class _ShortcutsLinkButton extends StatelessWidget {
  static const _viewType = 'org.codeberg.theoden8.webspace/shortcuts-link';

  final VoidCallback onOpened;

  const _ShortcutsLinkButton({required this.onOpened});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      width: double.maxFinite,
      child: UiKitView(
        viewType: _viewType,
        creationParams: {
          'dark': Theme.of(context).brightness == Brightness.dark,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (id) {
          MethodChannel('${_viewType}_$id').setMethodCallHandler((call) async {
            if (call.method == 'tapped') onOpened();
            return null;
          });
        },
      ),
    );
  }
}
