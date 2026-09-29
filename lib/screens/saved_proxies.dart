import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_network.dart' show validateProxyAddress;
import 'package:webspace/services/proxy_form_engine.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/saved_proxies.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/proxy_auth_section.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/proxy_test_tile.dart';

/// The user's saved proxies, each with whether it answers (PROXY-029,
/// PROXY-030). Adding, editing and deleting one takes effect at once: every
/// site that names it follows.
class SavedProxiesScreen extends StatefulWidget {
  const SavedProxiesScreen({
    super.key,
    required this.usageCount,
    required this.usedByAppWide,
    required this.onChanged,
    this.store = const SavedProxyStore(),
  });

  /// How many sites name the saved proxy with this id.
  final int Function(String id) usageCount;

  /// Whether the app-wide proxy names the saved proxy with this id.
  final bool Function(String id) usedByAppWide;

  /// Fired after the list was persisted, so the caller can rebuild the
  /// webviews that were bound to the old configuration.
  final VoidCallback onChanged;

  final SavedProxyStore store;

  @override
  State<SavedProxiesScreen> createState() => _SavedProxiesScreenState();
}

/// Where the screen reads and writes the list. A seam so the gallery and
/// widget tests can run it without secure storage.
class SavedProxyStore {
  const SavedProxyStore();

  List<SavedProxy> load() => SavedProxies.all;

  Future<void> save(List<SavedProxy> proxies) => SavedProxies.update(proxies);
}

class _SavedProxiesScreenState extends State<SavedProxiesScreen> {
  late List<SavedProxy> _proxies = [
    for (final p in widget.store.load()) p.copy(),
  ];

  Future<void> _persist() async {
    await widget.store.save(_proxies);
    widget.onChanged();
  }

  Future<void> _edit(SavedProxy? existing) async {
    final result = await Navigator.push<_EditOutcome>(
      context,
      MaterialPageRoute(
        builder: (_) => SavedProxyEditScreen(
          initial: existing,
          usageCount: existing == null ? 0 : widget.usageCount(existing.id),
          usedByAppWide:
              existing != null && widget.usedByAppWide(existing.id),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      switch (result) {
        case _Saved(:final proxy):
          final i = _proxies.indexWhere((p) => p.id == proxy.id);
          if (i < 0) {
            _proxies.add(proxy);
          } else {
            _proxies[i] = proxy;
          }
        case _Deleted(:final id):
          _proxies.removeWhere((p) => p.id == id);
      }
    });
    await _persist();
  }

  void _checkAll() {
    for (final p in _proxies) {
      ProxyHealthService.instance.check(p.settings, force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.savedProxiesTitle),
        actions: [
          HintButton(
            title: loc.savedProxiesTitle,
            description: loc.savedProxiesHint,
          ),
          if (_proxies.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.network_check),
              tooltip: loc.savedProxiesCheckAll,
              onPressed: _checkAll,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: Text(loc.savedProxiesAdd),
      ),
      body: _proxies.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xl),
                child: Text(
                  loc.savedProxiesEmpty,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ),
            )
          : ListView(
              // Clears the extended FAB, so the last row stays tappable.
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                for (final p in _proxies) _row(loc, theme, p),
              ],
            ),
    );
  }

  Widget _row(AppLocalizations loc, ThemeData theme, SavedProxy p) {
    final muted = theme.colorScheme.onSurfaceVariant;
    // Data, not copy (LOC-002): a type name and an address.
    final route = '${p.settings.type.name} ${p.settings.address ?? ''}';
    final count = widget.usageCount(p.id);
    return ListTile(
      leading: Icon(Icons.vpn_lock_outlined, color: muted),
      title: Text(savedProxyLabel(p)),
      isThreeLine: true,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(route.trim()),
          Text(
            widget.usedByAppWide(p.id)
                ? loc.savedProxyUsageWithAppWide(count)
                : loc.savedProxyUsage(count),
          ),
          ProxyStatusIndicator(proxy: p.settings),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _edit(p),
    );
  }
}

sealed class _EditOutcome {
  const _EditOutcome();
}

class _Saved extends _EditOutcome {
  const _Saved(this.proxy);
  final SavedProxy proxy;
}

class _Deleted extends _EditOutcome {
  const _Deleted(this.id);
  final String id;
}

/// One saved proxy: its name, type, address and credentials, and the same
/// connection test the per-site form has.
class SavedProxyEditScreen extends StatefulWidget {
  const SavedProxyEditScreen({
    super.key,
    this.initial,
    this.usageCount = 0,
    this.usedByAppWide = false,
  });

  /// Null to add a new one.
  final SavedProxy? initial;
  final int usageCount;
  final bool usedByAppWide;

  @override
  State<SavedProxyEditScreen> createState() => _SavedProxyEditScreenState();
}

class _SavedProxyEditScreenState extends State<SavedProxyEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final String _id = widget.initial?.id ?? SavedProxy.newId();
  late ProxyType _type = widget.initial?.settings.type ?? ProxyType.SOCKS5;
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _address =
      TextEditingController(text: widget.initial?.settings.address ?? '');
  late final _username =
      TextEditingController(text: widget.initial?.settings.username ?? '');
  late final _password =
      TextEditingController(text: widget.initial?.settings.password ?? '');
  late final Map<String, Object?> _initialSnapshot;

  @override
  void initState() {
    super.initState();
    _initialSnapshot = _snapshot();
    for (final c in [_name, _address, _username, _password]) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Map<String, Object?> _snapshot() => {
        'type': _type,
        'name': _name.text,
        'address': _address.text,
        'username': _username.text,
        'password': _password.text,
      };

  bool get _dirty {
    final now = _snapshot();
    return _initialSnapshot.keys.any((k) => now[k] != _initialSnapshot[k]);
  }

  /// Exactly what a save would store, so the test answers for what is typed.
  UserProxySettings _formSettings() => applyProxyForm(
        stored: UserProxySettings(type: _type),
        fields: ProxyFormFields(
          type: _type,
          address: _address.text,
          username: _username.text,
          password: _password.text,
        ),
      );

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      _Saved(SavedProxy(
        id: _id,
        name: _name.text.trim(),
        settings: _formSettings(),
      )),
    );
  }

  Future<void> _delete() async {
    final loc = AppLocalizations.of(context);
    final name = _name.text.trim().isEmpty
        ? (widget.initial == null ? '' : savedProxyLabel(widget.initial!))
        : _name.text.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.savedProxyDeleteTitle(name)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(loc.savedProxyDeleteBody(widget.usageCount)),
            if (widget.usedByAppWide) ...[
              const SizedBox(height: Spacing.md),
              Text(loc.savedProxyDeleteAppWide),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              loc.commonDelete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) Navigator.pop(context, _Deleted(_id));
  }

  Future<bool> _confirmDiscard() async {
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.appSettingsDiscardChangesTitle),
        content: Text(loc.appSettingsDiscardProxyBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.appSettingsKeepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              loc.appSettingsDiscard,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.initial == null
              ? loc.savedProxyNew
              : savedProxyLabel(widget.initial!)),
          actions: [
            if (widget.initial != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: loc.commonDelete,
                onPressed: _delete,
              ),
            TextButton(onPressed: _save, child: Text(loc.commonSave)),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.lg, vertical: Spacing.sm),
                child: TextFormField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: loc.savedProxyName,
                    border: const OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? loc.savedProxyNameRequired
                      : null,
                ),
              ),
              ListTile(
                title: Text(loc.siteSettingsProxyType),
                trailing: DropdownButton<ProxyType>(
                  value: _type,
                  onChanged: (t) {
                    if (t != null) setState(() => _type = t);
                  },
                  items: [
                    for (final t in kSavedProxyTypes)
                      DropdownMenuItem(value: t, child: Text(t.name)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.lg, vertical: Spacing.sm),
                child: TextFormField(
                  controller: _address,
                  decoration: InputDecoration(
                    labelText: loc.siteSettingsProxyAddress,
                    hintText: loc.siteSettingsProxyAddressHint,
                    helperText: loc.siteSettingsProxyAddressHelper,
                    border: const OutlineInputBorder(),
                  ),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) => validateProxyAddress(loc, _type, v?.trim()),
                ),
              ),
              ProxyAuthSection(
                usernameController: _username,
                passwordController: _password,
              ),
              ProxyTestTile(
                settings: _formSettings,
                target: kDefaultProxyTestTarget,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
