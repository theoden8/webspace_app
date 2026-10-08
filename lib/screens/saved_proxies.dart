import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_network.dart' show validateProxyAddress;
import 'package:webspace/services/proxy_form_engine.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/dirty_guard.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/proxy_auth_section.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/proxy_test_tile.dart';

/// Where the screen reads and writes the library. A seam so the gallery and
/// widget tests can run it without secure storage.
class ProxyLibraryStore {
  const ProxyLibraryStore();

  ProxyLibraryData load() => ProxyLibrary.data;

  Future<void> save(ProxyLibraryData data) => ProxyLibrary.update(data);
}

/// The proxy library (PROXY-030): saved proxies, each with whether it answers
/// (PROXY-031), and the gateways and credentials they and sites can share.
/// Every edit takes effect at once: whatever names the entry follows.
class ProxyLibraryScreen extends StatefulWidget {
  const ProxyLibraryScreen({
    super.key,
    required this.siteProxies,
    required this.appWideProxy,
    required this.onChanged,
    this.store = const ProxyLibraryStore(),
  });

  /// Every site's proxy setting, to say what uses each entry.
  final List<UserProxySettings> Function() siteProxies;
  final UserProxySettings Function() appWideProxy;

  /// Fired after the library was persisted, so the caller can rebuild the
  /// webviews bound to the old configuration.
  final VoidCallback onChanged;

  final ProxyLibraryStore store;

  @override
  State<ProxyLibraryScreen> createState() => _ProxyLibraryScreenState();
}

class _ProxyLibraryScreenState extends State<ProxyLibraryScreen> {
  late final ProxyLibraryData _lib = widget.store.load();

  Future<void> _persist() async {
    await widget.store.save(_lib);
    widget.onChanged();
  }

  int _sites(LibraryEntryKind kind, {required String id}) => widget
      .siteProxies()
      .where((s) => usesLibraryEntry(s, kind: kind, id: id, lib: _lib))
      .length;

  bool _appWide(LibraryEntryKind kind, {required String id}) =>
      usesLibraryEntry(widget.appWideProxy(), kind: kind, id: id, lib: _lib);

  String _usage(AppLocalizations loc,
      {required LibraryEntryKind kind, required String id}) {
    final n = _sites(kind, id: id);
    return _appWide(kind, id: id)
        ? loc.savedProxyUsageWithAppWide(n)
        : loc.savedProxyUsage(n);
  }

  Future<void> _open<E>(Widget screen,
      {required void Function(_Edit<E>) apply}) async {
    final result = await Navigator.push<_Edit<E>>(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
    if (result == null || !mounted) return;
    setState(() => apply(result));
    await _persist();
  }

  static void _replace<E>(List<E> list,
      {required E entry, required bool Function(E) same}) {
    final i = list.indexWhere(same);
    if (i < 0) {
      list.add(entry);
    } else {
      list[i] = entry;
    }
  }

  Future<void> _editProxy(SavedProxy? p) => _open<SavedProxy>(
        SavedProxyEditScreen(
          initial: p,
          library: _lib,
          usageCount: p == null ? 0 : _sites(LibraryEntryKind.proxy, id: p.id),
          usedByAppWide:
              p != null && _appWide(LibraryEntryKind.proxy, id: p.id),
        ),
        apply: (r) => r.deleted
            ? _lib.proxies.removeWhere((e) => e.id == r.id)
            : _replace(_lib.proxies,
                entry: r.entry!, same: (e) => e.id == r.id),
      );

  Future<void> _editGateway(SavedGateway? g) => _open<SavedGateway>(
        SavedGatewayEditScreen(
          initial: g,
          usageCount:
              g == null ? 0 : _sites(LibraryEntryKind.gateway, id: g.id),
          usedByAppWide:
              g != null && _appWide(LibraryEntryKind.gateway, id: g.id),
        ),
        apply: (r) => r.deleted
            ? _lib.removeGateway(r.id)
            : _replace(_lib.gateways,
                entry: r.entry!, same: (e) => e.id == r.id),
      );

  Future<void> _editCredentials(SavedCredentials? c) => _open<SavedCredentials>(
        SavedCredentialsEditScreen(
          initial: c,
          gateways: _lib.gateways,
          usageCount:
              c == null ? 0 : _sites(LibraryEntryKind.credentials, id: c.id),
          usedByAppWide:
              c != null && _appWide(LibraryEntryKind.credentials, id: c.id),
        ),
        apply: (r) => r.deleted
            ? _lib.credentials.removeWhere((e) => e.id == r.id)
            : _replace(_lib.credentials,
                entry: r.entry!, same: (e) => e.id == r.id),
      );

  void _checkAll() {
    for (final p in _lib.proxies) {
      final resolved = resolveLibrary(p.settings, library: _lib);
      if (resolved.problem == LibraryProblem.none) {
        ProxyHealthService.instance.check(resolved.route, force: true);
      }
    }
  }

  Widget _section(
    AppLocalizations loc, {
    required ThemeData theme,
    required String title,
    required String addLabel,
    required VoidCallback onAdd,
    required List<Widget> rows,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Spacing.lg, Spacing.lg, Spacing.sm, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
                TextButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: IconSizes.action),
                  label: Text(addLabel),
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.lg, vertical: Spacing.sm),
              child: Text(
                loc.proxyLibraryNone,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ...rows,
        ],
      );

  Widget _proxyRow(AppLocalizations loc, {required SavedProxy p}) {
    final resolved = resolveLibrary(p.settings, library: _lib);
    final problem = resolved.problem == LibraryProblem.none
        ? null
        : libraryProblemLabel(loc, problem: resolved.problem);
    // Data, not copy (LOC-002): what the route is made of.
    final gateway = p.settings.type == ProxyType.GATEWAY
        ? _lib.gateway(p.settings.gatewayId)
        : null;
    final credentials = _lib.credentialsById(p.settings.credentialsId);
    final madeOf = [
      if (gateway != null) gatewayLabel(gateway) else routeLabel(resolved.route),
      if (credentials != null) credentialsLabel(credentials),
    ].join(' · ');
    return ListTile(
      leading: const Icon(Icons.vpn_lock_outlined),
      title: Text(savedProxyLabel(p)),
      isThreeLine: true,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (problem == null) Text(madeOf),
          Text(_usage(loc, kind: LibraryEntryKind.proxy, id: p.id)),
          ProxyStatusIndicator(proxy: resolved.route, problem: problem),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editProxy(p),
    );
  }

  Widget _gatewayRow(AppLocalizations loc, {required SavedGateway g}) {
    final route = routeLabel(UserProxySettings(type: g.type, address: g.address));
    return ListTile(
      leading: const Icon(Icons.router_outlined),
      title: Text(gatewayLabel(g)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(route),
          Text(_usage(loc, kind: LibraryEntryKind.gateway, id: g.id)),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editGateway(g),
    );
  }

  Widget _credentialsRow(AppLocalizations loc, {required SavedCredentials c}) {
    // Data, not copy (LOC-002).
    final gateways = [
      for (final id in c.gatewayIds)
        if (_lib.gateway(id) case final g?) gatewayLabel(g),
    ].join(', ');
    final username = c.username ?? '';
    return ListTile(
      leading: const Icon(Icons.key_outlined),
      title: Text(credentialsLabel(c)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (username.isNotEmpty) Text(username),
          Text(loc.proxyLibraryWorksOnList(gateways)),
          Text(_usage(loc, kind: LibraryEntryKind.credentials, id: c.id)),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editCredentials(c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.savedProxiesTitle),
        actions: [
          HintButton(
            title: loc.savedProxiesTitle,
            description: loc.savedProxiesHint,
          ),
          if (_lib.proxies.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.network_check),
              tooltip: loc.savedProxiesCheckAll,
              onPressed: _checkAll,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.xl),
        children: [
          _section(loc, theme: theme, title: loc.savedProxiesTitle, addLabel: loc.savedProxiesAdd,
              onAdd: () => _editProxy(null), rows: [
            for (final p in _lib.proxies) _proxyRow(loc, p: p),
          ]),
          _section(loc, theme: theme, title: loc.proxyLibraryGateways,
              addLabel: loc.proxyLibraryAddGateway, onAdd: () => _editGateway(null), rows: [
            for (final g in _lib.gateways) _gatewayRow(loc, g: g),
          ]),
          _section(loc, theme: theme, title: loc.proxyLibraryCredentials,
              addLabel: loc.proxyLibraryAddCredentials, onAdd: () => _editCredentials(null), rows: [
            for (final c in _lib.credentials) _credentialsRow(loc, c: c),
          ]),
        ],
      ),
    );
  }
}

/// What an editor hands back: the saved entry, or that it was deleted.
class _Edit<E> {
  const _Edit.saved(this.id, {required E this.entry}) : deleted = false;
  const _Edit.deleted(this.id)
      : entry = null,
        deleted = true;

  final String id;
  final E? entry;
  final bool deleted;
}

/// What each library editor is handed: the entry, null for a new one, and
/// what uses it, which the delete confirmation names.
abstract class _LibraryEditor<E> extends StatefulWidget {
  const _LibraryEditor({
    super.key,
    this.initial,
    this.usageCount = 0,
    this.usedByAppWide = false,
  });

  final E? initial;
  final int usageCount;
  final bool usedByAppWide;
}

/// Shared by the three editors: the name field, the save and delete actions,
/// the delete confirmation and the guard against losing unsaved edits.
abstract class _EditorState<W extends _LibraryEditor<E>, E> extends State<W>
    with DirtyGuard<W> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;

  String get entryId;
  String? get initialName;
  bool get isNew => widget.initial == null;
  String newTitle(AppLocalizations loc);
  List<TextEditingController> get fields;

  /// The entry's own fields, as a record.
  Record form();

  @override
  Record snapshot() => (_name.text, form());
  E entry();
  List<Widget> body(AppLocalizations loc);

  /// Anything the form cannot express as a field error, checked on save.
  bool validateMore() => true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: initialName ?? '');
    markClean();
    for (final c in [_name, ...fields]) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, ...fields]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String get name => _name.text.trim();

  void _save() {
    final fieldsOk = _formKey.currentState?.validate() ?? false;
    final moreOk = validateMore();
    if (!fieldsOk || !moreOk) {
      setState(() {});
      return;
    }
    Navigator.pop(context, _Edit<E>.saved(entryId, entry: entry()));
  }

  Future<void> _delete() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await confirm(
      context,
      title: loc.savedProxyDeleteTitle(
          name.isEmpty ? (initialName ?? '') : name),
      body: [
        loc.savedProxyDeleteBody(widget.usageCount),
        if (widget.usedByAppWide) loc.savedProxyDeleteAppWide,
      ].join('\n\n'),
      confirmLabel: loc.commonDelete,
      destructive: true,
    );
    if (confirmed && mounted) {
      Navigator.pop(context, _Edit<E>.deleted(entryId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return guardPop(
      child: Scaffold(
        appBar: AppBar(
          title: Text(isNew ? newTitle(loc) : (initialName ?? '')),
          actions: [
            if (!isNew)
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
              ...body(loc),
            ],
          ),
        ),
      ),
    );
  }
}

/// A saved proxy: a gateway (typed, or a saved one) and credentials (typed,
/// or saved ones that list the gateway). With both typed it is simply a
/// proxy.
class SavedProxyEditScreen extends _LibraryEditor<SavedProxy> {
  const SavedProxyEditScreen({
    super.key,
    super.initial,
    required this.library,
    super.usageCount,
    super.usedByAppWide,
  });

  final ProxyLibraryData library;

  @override
  State<SavedProxyEditScreen> createState() => _SavedProxyEditScreenState();
}

class _SavedProxyEditScreenState
    extends _EditorState<SavedProxyEditScreen, SavedProxy> {
  late ProxyType _type = widget.initial?.settings.type ?? ProxyType.SOCKS5;
  late String? _gatewayId = widget.initial?.settings.gatewayId;
  late String? _credentialsId = widget.initial?.settings.credentialsId;
  late final TextEditingController _address =
      TextEditingController(text: widget.initial?.settings.address ?? '');
  late final TextEditingController _username =
      TextEditingController(text: widget.initial?.settings.username ?? '');
  late final TextEditingController _password =
      TextEditingController(text: widget.initial?.settings.password ?? '');

  @override
  late final String entryId = widget.initial?.id ?? SavedProxy.newId();
  @override
  String? get initialName => widget.initial?.name;
  @override
  String newTitle(AppLocalizations loc) => loc.savedProxyNew;
  @override
  List<TextEditingController> get fields => [_address, _username, _password];

  @override
  Record form() => (
        type: _type,
        gatewayId: _gatewayId,
        credentialsId: _credentialsId,
        address: _address.text,
        username: _username.text,
        password: _password.text,
      );

  UserProxySettings _settings() => applyProxyForm(
        stored: UserProxySettings(type: _type),
        fields: ProxyFormFields(
          type: _type,
          address: _address.text,
          username: _username.text,
          password: _password.text,
          gatewayId: _gatewayId,
          credentialsId: _credentialsId,
        ),
      );

  @override
  SavedProxy entry() =>
      SavedProxy(id: entryId, name: name, settings: _settings());

  void _pickGateway(ProxyChoice choice) => setState(() {
        _type = choice.type;
        if (choice.type == ProxyType.GATEWAY) _gatewayId = choice.gatewayId;
        final credentials = widget.library.credentialsById(_credentialsId);
        if (_type != ProxyType.GATEWAY ||
            !(credentials?.fits(_gatewayId) ?? false)) {
          _credentialsId = null;
        }
      });

  @override
  List<Widget> body(AppLocalizations loc) => [
        ListTile(
          title: Text(loc.proxyLibraryGateway),
          trailing: ProxyChoiceDropdown(
            type: _type,
            savedProxyId: null,
            gatewayId: _gatewayId,
            library: widget.library,
            torAvailable: false,
            gatewaysOnly: true,
            onChanged: _pickGateway,
          ),
        ),
        ProxyRouteFields(
          type: _type,
          gatewayId: _gatewayId,
          credentialsId: _credentialsId,
          library: widget.library,
          addressController: _address,
          usernameController: _username,
          passwordController: _password,
          addressValidator: (v) => validateProxyAddress(loc, type: _type, value: v?.trim()),
          onCredentialsChanged: (id) => setState(() => _credentialsId = id),
        ),
        ProxyTestTile(
          settings: () => resolveLibrary(_settings(), library: widget.library).route,
          target: kDefaultProxyTestTarget,
        ),
      ];
}

/// A gateway: type and `host:port`.
class SavedGatewayEditScreen extends _LibraryEditor<SavedGateway> {
  const SavedGatewayEditScreen({
    super.key,
    super.initial,
    super.usageCount,
    super.usedByAppWide,
  });

  @override
  State<SavedGatewayEditScreen> createState() =>
      _SavedGatewayEditScreenState();
}

class _SavedGatewayEditScreenState
    extends _EditorState<SavedGatewayEditScreen, SavedGateway> {
  late ProxyType _type = widget.initial?.type ?? ProxyType.SOCKS5;
  late final TextEditingController _address =
      TextEditingController(text: widget.initial?.address ?? '');

  @override
  late final String entryId = widget.initial?.id ?? SavedGateway.newId();
  @override
  String? get initialName => widget.initial?.name;
  @override
  String newTitle(AppLocalizations loc) => loc.proxyLibraryNewGateway;
  @override
  List<TextEditingController> get fields => [_address];

  @override
  Record form() => (type: _type, address: _address.text);

  @override
  SavedGateway entry() => SavedGateway(
        id: entryId,
        name: name,
        type: _type,
        address: _address.text.trim().isEmpty ? null : _address.text.trim(),
      );

  @override
  List<Widget> body(AppLocalizations loc) => [
        ListTile(
          title: Text(loc.siteSettingsProxyType),
          trailing: DropdownButton<ProxyType>(
            value: _type,
            onChanged: (t) {
              if (t != null) setState(() => _type = t);
            },
            items: [
              for (final t in kGatewayTypes)
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
            validator: (v) => validateProxyAddress(loc, type: _type, value: v?.trim()),
          ),
        ),
      ];
}

/// Credentials: a username and password, and the saved gateways they sign in
/// on. Nothing pairs them with any other gateway.
class SavedCredentialsEditScreen extends _LibraryEditor<SavedCredentials> {
  const SavedCredentialsEditScreen({
    super.key,
    super.initial,
    required this.gateways,
    super.usageCount,
    super.usedByAppWide,
  });

  final List<SavedGateway> gateways;

  @override
  State<SavedCredentialsEditScreen> createState() =>
      _SavedCredentialsEditScreenState();
}

class _SavedCredentialsEditScreenState
    extends _EditorState<SavedCredentialsEditScreen, SavedCredentials> {
  late final TextEditingController _username =
      TextEditingController(text: widget.initial?.username ?? '');
  late final TextEditingController _password =
      TextEditingController(text: widget.initial?.password ?? '');
  late final Set<String> _gatewayIds = {
    for (final g in widget.initial?.gatewayIds ?? const <String>{})
      if (widget.gateways.any((e) => e.id == g)) g,
  };
  bool _showGatewayError = false;

  @override
  late final String entryId = widget.initial?.id ?? SavedCredentials.newId();
  @override
  String? get initialName => widget.initial?.name;
  @override
  String newTitle(AppLocalizations loc) => loc.proxyLibraryNewCredentials;
  @override
  List<TextEditingController> get fields => [_username, _password];

  @override
  Record form() => (
        username: _username.text,
        password: _password.text,
        gateways: ValueSet(_gatewayIds),
      );

  @override
  bool validateMore() {
    _showGatewayError = _gatewayIds.isEmpty;
    return _gatewayIds.isNotEmpty;
  }

  @override
  SavedCredentials entry() => SavedCredentials(
        id: entryId,
        name: name,
        username: _username.text.isEmpty ? null : _username.text,
        password: _password.text.isEmpty ? null : _password.text,
        gatewayIds: {..._gatewayIds},
      );

  @override
  List<Widget> body(AppLocalizations loc) {
    final theme = Theme.of(context);
    return [
      ProxyAuthSection(
        usernameController: _username,
        passwordController: _password,
        initiallyExpanded: true,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
            Spacing.lg, Spacing.lg, Spacing.lg, Spacing.xs),
        child: Text(
          loc.proxyLibraryWorksOn,
          style: theme.textTheme.titleSmall
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      ),
      if (widget.gateways.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          child: Text(
            loc.proxyLibraryNoGateways,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      for (final g in widget.gateways)
        CheckboxListTile(
          title: Text(gatewayLabel(g)),
          subtitle: Text(
              routeLabel(UserProxySettings(type: g.type, address: g.address))),
          value: _gatewayIds.contains(g.id),
          onChanged: (on) => setState(() {
            if (on == true) {
              _gatewayIds.add(g.id);
              _showGatewayError = false;
            } else {
              _gatewayIds.remove(g.id);
            }
          }),
        ),
      if (_showGatewayError)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          child: Text(
            loc.proxyLibraryWorksOnRequired,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ),
    ];
  }
}
