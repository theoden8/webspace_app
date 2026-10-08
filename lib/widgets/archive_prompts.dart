import 'package:flutter/material.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/confirm_dialog.dart';

/// [ArchivePrompts] as dialogs over the page that owns [context].
class DialogArchivePrompts implements ArchivePrompts {
  const DialogArchivePrompts(this.context);

  final BuildContext context;

  @override
  Future<String?> passphrase(PassphrasePurpose purpose) {
    final loc = AppLocalizations.of(context);
    final (title, hint, submit) = switch (purpose) {
      PassphrasePurpose.moveSite => (
          loc.homeMoveSiteToArchiveTitle,
          loc.homeArchivePassphraseHint,
          loc.homeMoveAction,
        ),
      PassphrasePurpose.openArchive => (
          loc.homeRestoreArchiveTitle,
          loc.homePassphraseHint,
          loc.commonOpen,
        ),
      PassphrasePurpose.restoreSections => (
          loc.homeRestoreArchivedDataTitle,
          loc.homePassphraseCancelToSkipHint,
          loc.homeRestoreAction,
        ),
    };
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(submit),
          ),
        ],
      ),
    );
  }

  @override
  Future<bool> createArchive(PassphrasePurpose purpose) async {
    final loc = AppLocalizations.of(context);
    final body = switch (purpose) {
      PassphrasePurpose.moveSite => loc.homeNoMatchingArchiveMoveBody,
      PassphrasePurpose.openArchive ||
      PassphrasePurpose.restoreSections =>
        loc.homeNoMatchingArchiveCreateBody,
    };
    return confirm(
      context,
      title: loc.homeNoMatchingArchiveTitle,
      body: body,
      confirmLabel: loc.homeCreateAction,
      destructive: false,
    );
  }

  @override
  Future<bool> includeOpenArchives(int count) {
    final loc = AppLocalizations.of(context);
    return confirm(
      context,
      title: loc.homeIncludeOpenArchivesTitle,
      body: loc.homeIncludeOpenArchivesBody(count),
      confirmLabel: loc.homeIncludeAction,
      cancelLabel: loc.homeExcludeAction,
      destructive: false,
    );
  }
}
