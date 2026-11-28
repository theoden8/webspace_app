import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';

/// The eye beside a password field: one name, Show password, and whether the
/// password shows as its toggled state rather than as a second name.
class PasswordVisibilityToggle extends StatelessWidget {
  const PasswordVisibilityToggle({
    super.key,
    required this.visible,
    required this.onChanged,
  });

  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: AppLocalizations.of(context).passwordShow,
    icon: Semantics(
      toggled: visible,
      child: Icon(visible ? Icons.visibility_off : Icons.visibility),
    ),
    onPressed: () => onChanged(!visible),
  );
}
