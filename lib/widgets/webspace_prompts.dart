import 'package:flutter/material.dart';
import 'package:webspace/controllers/webspaces_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// [WebspacePrompts] as the webspace editor and a dialog over the page that
/// owns [context].
class DialogWebspacePrompts implements WebspacePrompts {
  const DialogWebspacePrompts(this.context);

  final BuildContext context;

  @override
  Future<void> edit(
    Webspace webspace, {
    required List<WebViewModel> sites,
    required bool readOnly,
    required void Function(Webspace saved) onSave,
  }) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => WebspaceDetailScreen(
        webspace: webspace,
        allSites: sites,
        isReadOnly: readOnly,
        onSave: onSave,
      ),
    ),
  );

  @override
  Future<bool> confirmDelete(Webspace webspace) async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeDeleteWebspaceTitle),
        content: Text(loc.homeDeleteWebspaceConfirm(webspace.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.commonDelete),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}
