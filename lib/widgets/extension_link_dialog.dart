import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/web_extension_source.dart';

/// Asks for a link to an extension's addons.mozilla.org page or its GitHub
/// repository (WEBEXT-017). Pops the source it names, or null when
/// cancelled; a link the app does not read is refused in place.
class ExtensionLinkDialog extends StatefulWidget {
  const ExtensionLinkDialog({super.key});

  @override
  State<ExtensionLinkDialog> createState() => _ExtensionLinkDialogState();
}

class _ExtensionLinkDialogState extends State<ExtensionLinkDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final source = parseExtensionSource(_controller.text.trim());
    if (source == null) {
      setState(() => _error = AppLocalizations.of(context).extensionsLinkNotRead);
      return;
    }
    Navigator.pop(context, source);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(loc.extensionsAddFromLink),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: loc.extensionsLinkField,
          hintText: loc.extensionsLinkExample,
          errorText: _error,
          errorMaxLines: 3,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.commonCancel),
        ),
        TextButton(onPressed: _submit, child: Text(loc.commonAdd)),
      ],
    );
  }
}
