import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/theme/design_tokens.dart';

/// Shows the sign-in dialog for a site's HTTP authentication challenge
/// (HTTPAUTH-003). Returns null when the user cancels.
///
/// The server's realm string is not shown: it is text the server chose,
/// and in a dialog the app draws it reads as the app's own words.
Future<HttpAuthPromptResult?> promptHttpAuth(
  BuildContext context,
  HttpAuthPromptRequest request,
) {
  if (!context.mounted) return Future.value(null);
  return showDialog<HttpAuthPromptResult>(
    context: context,
    builder: (_) => HttpAuthDialog(request: request),
  );
}

class HttpAuthDialog extends StatefulWidget {
  const HttpAuthDialog({super.key, required this.request});

  final HttpAuthPromptRequest request;

  @override
  State<HttpAuthDialog> createState() => _HttpAuthDialogState();
}

class _HttpAuthDialogState extends State<HttpAuthDialog> {
  late final TextEditingController _username;
  final TextEditingController _password = TextEditingController();
  late bool _remember;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.request.initialUsername);
    _remember = widget.request.canRemember && widget.request.rememberByDefault;
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(HttpAuthPromptResult(
      username: _username.text,
      password: _password.text,
      remember: _remember,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final request = widget.request;
    final hasUsername = (request.initialUsername ?? '').isNotEmpty;
    return AlertDialog(
      title: Text(loc.httpAuthTitle),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.httpAuthBody(request.host)),
            if (request.isRetry) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                loc.httpAuthRejected,
                style: TextStyle(color: scheme.error),
              ),
            ],
            const SizedBox(height: Spacing.lg),
            TextField(
              controller: _username,
              autofocus: !hasUsername,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: loc.httpAuthUsername,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _password,
              autofocus: hasUsername,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: loc.httpAuthPassword,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            if (request.canRemember)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(loc.httpAuthRemember),
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? false),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.commonCancel),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(loc.httpAuthSignIn),
        ),
      ],
    );
  }
}
