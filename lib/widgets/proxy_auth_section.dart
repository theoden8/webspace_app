import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/design_tokens.dart';

/// The proxy username / password pair, as a fold rather than a checkbox.
///
/// The checkbox this replaces was a third piece of state that nothing
/// persisted. It was restored from `UserProxySettings.hasCredentials` — an
/// AND over both fields — so a configuration carrying only one of them came
/// back unticked, and the next save read the empty tick as "no auth" and
/// wiped the field that was set. A fold has no state to lose: whatever the
/// fields hold is what gets stored, and clearing them is how credentials are
/// removed (PROXY-019).
class ProxyAuthSection extends StatefulWidget {
  const ProxyAuthSection({
    super.key,
    required this.usernameController,
    required this.passwordController,
    this.onEditingComplete,
    this.initiallyExpanded = false,
  });

  final TextEditingController usernameController;
  final TextEditingController passwordController;

  /// Fired when a field loses focus or is submitted, for the screens that
  /// persist on edit rather than on a save button.
  final VoidCallback? onEditingComplete;

  /// Open even when both fields are empty, for a form whose whole point is
  /// the credentials.
  final bool initiallyExpanded;

  @override
  State<ProxyAuthSection> createState() => _ProxyAuthSectionState();
}

class _ProxyAuthSectionState extends State<ProxyAuthSection> {
  bool _obscurePassword = true;

  // Read once: recomputing it per build would fold the section shut under
  // the user as soon as they cleared the last character of a field.
  late final bool _initiallyExpanded = widget.initiallyExpanded || _hasAny;

  String get _username => widget.usernameController.text;
  String get _password => widget.passwordController.text;
  bool get _hasAny => _username.isNotEmpty || _password.isNotEmpty;
  bool get _hasBoth => _username.isNotEmpty && _password.isNotEmpty;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.usernameController,
      widget.passwordController,
    ]),
    builder: (context, _) {
      final loc = AppLocalizations.of(context);
      final scheme = Theme.of(context).colorScheme;
      // Only one of the two filled is not a configuration the proxy client
      // will ever use: it authenticates on both or on neither. Saying so here
      // is the difference between a silent no-auth connection and a fixable
      // mistake.
      final incomplete = _hasAny && !_hasBoth;
      final subtitle = incomplete
          ? loc.proxyAuthIncomplete
          : (_hasBoth ? _username : loc.proxyAuthNone);
      final done = widget.onEditingComplete;
      Widget field(
        TextEditingController controller,
        String label, {
        bool obscure = false,
        Widget? suffixIcon,
      }) => TextFormField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: suffixIcon,
        ),
        onEditingComplete: done,
        onFieldSubmitted: done == null ? null : (_) => done(),
      );

      return ExpansionTile(
        title: Text(loc.proxyAuthTitle),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: incomplete ? TextStyle(color: scheme.error) : null,
        ),
        initiallyExpanded: _initiallyExpanded,
        childrenPadding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.sm,
          Spacing.lg,
          Spacing.md,
        ),
        children: [
          field(widget.usernameController, loc.proxyAuthUsername),
          const SizedBox(height: Spacing.md),
          field(
            widget.passwordController,
            loc.proxyAuthPassword,
            obscure: _obscurePassword,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ],
      );
    },
  );
}
