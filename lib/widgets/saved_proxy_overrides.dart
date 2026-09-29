import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/proxy_auth_section.dart';

/// Where a setting that names a saved proxy may part from it: its own address,
/// its own credentials, or both (PROXY-029). Shared by the per-site and the
/// app-wide proxy forms. Each field shows only while its switch is on, and
/// the caller owns the controllers, as it does for a plain proxy.
class SavedProxyOverrides extends StatelessWidget {
  const SavedProxyOverrides({
    super.key,
    required this.ownAddress,
    required this.ownCredentials,
    required this.onOwnAddressChanged,
    required this.onOwnCredentialsChanged,
    required this.addressController,
    required this.usernameController,
    required this.passwordController,
    required this.addressValidator,
    this.onEditingComplete,
  });

  final bool ownAddress;
  final bool ownCredentials;
  final ValueChanged<bool> onOwnAddressChanged;
  final ValueChanged<bool> onOwnCredentialsChanged;
  final TextEditingController addressController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final FormFieldValidator<String> addressValidator;

  /// For a form that saves as each field is left rather than on a button.
  final VoidCallback? onEditingComplete;

  Widget _switch(
    String title,
    String hint,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      SwitchListTile(
        title: Row(
          children: [
            Flexible(child: Text(title)),
            HintButton(title: title, description: hint),
          ],
        ),
        value: value,
        onChanged: onChanged,
      );

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _switch(
          loc.savedProxyOwnAddress,
          loc.savedProxyOwnAddressHint,
          ownAddress,
          onOwnAddressChanged,
        ),
        if (ownAddress)
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Spacing.lg, vertical: Spacing.sm),
            child: TextFormField(
              controller: addressController,
              decoration: InputDecoration(
                labelText: loc.siteSettingsProxyAddress,
                hintText: loc.siteSettingsProxyAddressHint,
                helperText: loc.siteSettingsProxyAddressHelper,
                border: const OutlineInputBorder(),
              ),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: addressValidator,
              onFieldSubmitted:
                  onEditingComplete == null ? null : (_) => onEditingComplete!(),
              onEditingComplete: onEditingComplete,
            ),
          ),
        _switch(
          loc.savedProxyOwnCredentials,
          loc.savedProxyOwnCredentialsHint,
          ownCredentials,
          onOwnCredentialsChanged,
        ),
        if (ownCredentials)
          ProxyAuthSection(
            usernameController: usernameController,
            passwordController: passwordController,
            onEditingComplete: onEditingComplete,
          ),
      ],
    );
  }
}
