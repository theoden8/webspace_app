import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_search_engine.dart';
import 'package:webspace/settings/web_extension_source.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// A search of addons.mozilla.org (WEBEXT-019), offered only outside the
/// App Store: each result labelled by how well WebKit is expected to run
/// it, none hidden. Picking one pops its source, which the Extensions
/// screen adds as it adds from a link.
class ExtensionSearchScreen extends StatefulWidget {
  const ExtensionSearchScreen({super.key});

  @override
  State<ExtensionSearchScreen> createState() => _ExtensionSearchScreenState();
}

class _ExtensionSearchScreenState extends State<ExtensionSearchScreen> {
  final _guard = ReentryGuard();
  final _query = TextEditingController();
  bool _recommendedOnly = false;
  bool _searching = false;
  List<AmoResult> _results = const [];
  int _page = 0;
  bool _more = false;
  String? _failure;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// The first page for the query, or with [next] the page after the shown
  /// ones.
  Future<void> _search({required bool next}) async {
    final text = _query.text.trim();
    if (text.isEmpty) return;
    await _guard.run(() async {
      final loc = AppLocalizations.of(context);
      final page = next ? _page + 1 : 1;
      setState(() {
        _searching = true;
        _failure = null;
      });
      final read = await WebExtensionLibrary.instance.search(
        text,
        recommendedOnly: _recommendedOnly,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        _searching = false;
        switch (read) {
          case SourceFailed(:final reason):
            _failure = loc.extensionsLinkUnreachable(reason);
          case SourceGot(value: SearchRefused()):
            _failure = loc.extensionsSearchUnreadable;
          case SourceGot(value: SearchFound(:final results, :final more)):
            _results = next ? [..._results, ...results] : results;
            _page = page;
            _more = more;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final failure = _failure;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: loc.extensionsSearchField,
            border: InputBorder.none,
          ),
          onSubmitted: (_) => unawaited(_search(next: false)),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: loc.extensionsSearchField,
            onPressed: () => unawaited(_search(next: false)),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.lg,
              vertical: Spacing.sm,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilterChip(
                label: Text(loc.extensionsSearchRecommended),
                selected: _recommendedOnly,
                onSelected: (on) {
                  setState(() => _recommendedOnly = on);
                  unawaited(_search(next: false));
                },
              ),
            ),
          ),
          if (_searching)
            Semantics(
              label: loc.extensionsReading,
              child: const LinearProgressIndicator(),
            ),
          if (failure != null) ListTile(title: Text(failure)),
          if (!_searching && failure == null && _page > 0 && _results.isEmpty)
            ListTile(title: Text(loc.extensionsSearchEmpty)),
          for (final result in _results) _ResultTile(result),
          if (_more && !_searching)
            Center(
              child: TextButton(
                onPressed: () => unawaited(_search(next: true)),
                child: Text(loc.extensionsSearchMore),
              ),
            ),
        ],
      ),
    );
  }
}

/// One search result: its name, what it does, how many use it, whether
/// Mozilla recommends it, and how well WebKit is expected to run it.
class _ResultTile extends StatelessWidget {
  const _ResultTile(this.result);

  final AmoResult result;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final (IconData icon, String fit, Color? color) = switch (result.fit) {
      WebKitFit.works => (
        Icons.check_circle_outline,
        loc.extensionsFitWorks,
        null,
      ),
      WebKitFit.partly => (
        Icons.warning_amber_outlined,
        loc.extensionsFitPartly,
        HintedTitle.missingDataColor,
      ),
      WebKitFit.unknown => (Icons.help_outline, loc.extensionsFitUnknown, null),
    };
    final details = [
      if (result.recommended) loc.extensionsRecommendedBadge,
      if (result.users case final users?) loc.extensionsSearchUsers(users),
    ].join(' · ');
    return ListTile(
      leading: const Icon(Icons.extension_outlined),
      title: Text(result.name),
      subtitle: Text(
        [
          if (result.summary.isNotEmpty) result.summary,
          if (details.isNotEmpty) details,
        ].join('\n'),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: IconSizes.action),
          Text(fit, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      onTap: () => Navigator.pop<ExtensionSource>(context, result.source),
    );
  }
}
