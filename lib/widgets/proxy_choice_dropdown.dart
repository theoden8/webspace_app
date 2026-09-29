import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/saved_proxies.dart';

/// What a proxy picker chose: a type, and under [ProxyType.SAVED] which
/// saved proxy.
class ProxyChoice {
  const ProxyChoice(this.type, [this.savedProxyId]);

  final ProxyType type;
  final String? savedProxyId;
}

/// The label a saved proxy goes by: its name, or its address when it has
/// none, so two unnamed entries can still be told apart.
String savedProxyLabel(SavedProxy proxy) => proxy.name.trim().isNotEmpty
    ? proxy.name.trim()
    : (proxy.settings.address ?? proxy.settings.type.name);

/// The proxy type picker, with each saved proxy offered by name beside the
/// types (PROXY-029). Shared by the per-site and app-wide proxy forms, so a
/// saved proxy is picked the same way in both.
class ProxyChoiceDropdown extends StatelessWidget {
  const ProxyChoiceDropdown({
    super.key,
    required this.type,
    required this.savedProxyId,
    required this.savedProxies,
    required this.torAvailable,
    required this.onChanged,
  });

  final ProxyType type;
  final String? savedProxyId;
  final List<SavedProxy> savedProxies;

  /// TOR is only offerable where a Tor runtime exists (TOR-007).
  final bool torAvailable;
  final ValueChanged<ProxyChoice> onChanged;

  static const String _savedPrefix = 'saved:';
  static const double _maxLabelWidth = 160;

  static String _typeKey(ProxyType t) => t.name;
  static String _savedKey(String? id) => '$_savedPrefix${id ?? ''}';

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final current =
        type == ProxyType.SAVED ? _savedKey(savedProxyId) : _typeKey(type);
    final known = {for (final p in savedProxies) _savedKey(p.id)};

    // The button is as wide as its widest item, and a saved proxy's name is
    // the user's to make long; unbounded, it would push the row's title off
    // a phone screen.
    DropdownMenuItem<String> item(String key, String label) =>
        DropdownMenuItem(
          value: key,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxLabelWidth),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        );

    final items = <DropdownMenuItem<String>>[
      item(_typeKey(ProxyType.DEFAULT), ProxyType.DEFAULT.name),
      for (final p in savedProxies) item(_savedKey(p.id), savedProxyLabel(p)),
      // A site still naming a saved proxy that was deleted keeps an entry,
      // because a DropdownButton whose value is absent from its items
      // throws, and because "missing" is what the site actually has.
      if (type == ProxyType.SAVED && !known.contains(current))
        item(current, loc.savedProxyMissing),
      for (final t in const [ProxyType.HTTP, ProxyType.HTTPS, ProxyType.SOCKS5])
        item(_typeKey(t), t.name),
      // A site that already carries TOR (say, from a backup taken on iOS
      // and imported on Android) keeps the option visible.
      if (torAvailable || type == ProxyType.TOR)
        item(_typeKey(ProxyType.TOR), ProxyType.TOR.name),
    ];

    return DropdownButton<String>(
      value: current,
      isDense: true,
      onChanged: (key) {
        if (key == null) return;
        if (key.startsWith(_savedPrefix)) {
          final id = key.substring(_savedPrefix.length);
          onChanged(ProxyChoice(ProxyType.SAVED, id.isEmpty ? null : id));
        } else {
          onChanged(ProxyChoice(ProxyType.values.byName(key)));
        }
      },
      items: items,
    );
  }
}
