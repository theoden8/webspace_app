import 'package:flutter/material.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';

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
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeNoMatchingArchiveTitle),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.homeCreateAction),
          ),
        ],
      ),
    );
    return create == true;
  }

  @override
  Future<bool> includeOpenArchives(int count) async {
    final loc = AppLocalizations.of(context);
    final include = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeIncludeOpenArchivesTitle),
        content: Text(loc.homeIncludeOpenArchivesBody(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.homeExcludeAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.homeIncludeAction),
          ),
        ],
      ),
    );
    return include == true;
  }
}
