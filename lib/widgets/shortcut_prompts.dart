import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/confirm_dialog.dart';

/// [ShortcutPrompts] as dialogs over the page that owns [context].
class DialogShortcutPrompts implements ShortcutPrompts {
  const DialogShortcutPrompts(this.context);

  final BuildContext context;

  AppLocalizations get _loc => AppLocalizations.of(context);

  @override
  Future<bool> confirmOpen(String siteName) => confirm(
    context,
    title: _loc.homeShortcutConfirmOpenTitle,
    body: _loc.homeShortcutConfirmOpenBody(siteName),
    confirmLabel: _loc.commonOpen,
    destructive: false,
  );

  @override
  Future<MissingShortcutChoice?> missingSite(String url) => choose(
    context,
    title: _loc.homeShortcutMissingTitle,
    body: _loc.homeShortcutMissingBody(url),
    options: [
      (null, _loc.commonCancel),
      (MissingShortcutChoice.reroute, _loc.homeShortcutOpenAnother),
      (MissingShortcutChoice.create, _loc.homeCreateAction),
    ],
  );

  @override
  Future<ShortcutFate?> deletedSiteTiles() => choose(
    context,
    title: _loc.homeShortcutFateTitle,
    body: _loc.homeShortcutFateBody,
    options: [
      (ShortcutFate.keep, _loc.homeShortcutKeep),
      (ShortcutFate.reassign, _loc.homeShortcutReassign),
      (ShortcutFate.disable, _loc.homeShortcutDisable),
    ],
  );

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
                  child: UnifiedFaviconImage.site(m, size: 32),
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
  Future<bool> confirmMacosShortcut(String siteName) => confirm(
    context,
    title: _loc.homeAddShortcutTitleMacos,
    body: _loc.homeAddShortcutMacosBody(siteName),
    confirmLabel: _loc.homeOpenShortcuts,
    destructive: false,
  );
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
