/// Web search (LIR-029): the sheet the page menu opens. It collects a query,
/// a scope (the web, or the site on screen) and one of the user's search
/// sites; the page decides where the results land.
library;

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/container_mark.dart';

class WebSearchRequest {
  final String query;
  final SearchScope scope;

  /// The chosen search site, or null when [add] names an engine to add.
  final SearchOption? option;

  /// A known engine the user picked in the empty state, to add as a site.
  final KnownSearchHost? add;

  const WebSearchRequest({
    required this.query,
    required this.scope,
    this.option,
    this.add,
  });
}

class WebSearchSheet extends StatefulWidget {
  const WebSearchSheet({
    super.key,
    required this.identity,
    required this.candidates,
    this.declared = const [],
    this.declaredDefault,
    this.appDefault,
    this.canAddSites = true,
    this.initialQuery = '',
    this.containerColors = const {},
  });

  /// The site on screen: what "this site" means, and its own search.
  final SearchSite identity;

  /// The user's sites a search from here may use.
  final List<SearchSite> candidates;

  /// The owner's list of search sites; empty offers every one.
  final List<String> declared;
  final String? declaredDefault;
  final String? appDefault;

  /// False inside an archive: an engine added here would be an app-tier site,
  /// and the search would leave the archive with it (S15).
  final bool canAddSites;

  /// What the field starts with: the words typed in the URL bar when no
  /// search site could run them (LIR-033).
  final String initialQuery;

  /// Each candidate's container colour by siteId, empty on the legacy engine:
  /// what tells two chips with the same name apart (TAB-018).
  final Map<String, int> containerColors;

  @override
  State<WebSearchSheet> createState() => _WebSearchSheetState();
}

class _WebSearchSheetState extends State<WebSearchSheet> {
  late final TextEditingController _query =
      TextEditingController(text: widget.initialQuery);
  late SearchScope _scope;
  late List<SearchOption> _options;
  int _selected = 0;
  KnownSearchHost? _add;

  @override
  void initState() {
    super.initState();
    _scope = WebSearchEngine.offersThisSite(widget.identity)
        ? WebSearchEngine.initialScope(widget.identity)
        : SearchScope.web;
    _loadOptions();
  }

  void _loadOptions() {
    _options = WebSearchEngine.options(
      scope: _scope,
      identity: widget.identity,
      candidates: widget.candidates,
      declared: widget.declared,
    );
    _selected = WebSearchEngine.preselect(
      _options,
      declaredDefault: widget.declaredDefault,
      appDefault: widget.appDefault,
    );
    _add = null;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<KnownSearchHost> get _addable => widget.canAddSites
      ? WebSearchEngine.addable(_scope, widget.candidates)
      : const [];

  String? get _engineName => _options.isNotEmpty
      ? _options[_selected].site.name
      : _add?.name;

  void _submit() {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    if (_options.isEmpty && _add == null) return;
    Navigator.of(context).pop(WebSearchRequest(
      query: query,
      scope: _scope,
      option: _options.isEmpty ? null : _options[_selected],
      add: _options.isEmpty ? _add : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final name = _engineName;
    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.lg,
        right: Spacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.travel_explore),
              hintText:
                  name == null ? loc.webSearchMenu : loc.webSearchFieldHint(name),
              suffixIcon: IconButton(
                tooltip: loc.webSearchMenu,
                icon: const Icon(Icons.arrow_forward),
                onPressed: _submit,
              ),
            ),
          ),
          const SizedBox(height: Spacing.md),
          if (WebSearchEngine.offersThisSite(widget.identity)) ...[
            SegmentedButton<SearchScope>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: SearchScope.web,
                  label: Text(loc.webSearchScopeWeb),
                ),
                ButtonSegment(
                  value: SearchScope.thisSite,
                  label: Text(
                    widget.identity.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() {
                _scope = s.first;
                _loadOptions();
              }),
            ),
            const SizedBox(height: Spacing.md),
          ],
          if (_options.isNotEmpty)
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (var i = 0; i < _options.length; i++)
                  ChoiceChip(
                    avatar: switch (
                        widget.containerColors[_options[i].site.siteId]) {
                      final index? => ContainerDot(index),
                      null => null,
                    },
                    label: Text(_options[i].site.name),
                    selected: i == _selected,
                    onSelected: (_) => setState(() => _selected = i),
                  ),
              ],
            )
          else ...[
            Text(
              widget.canAddSites ? loc.webSearchNoSites : loc.webSearchNoWebSites,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final k in _addable)
                  ChoiceChip(
                    avatar: const Icon(Icons.add, size: IconSizes.inline),
                    label: Text(k.name),
                    selected: identical(_add, k),
                    onSelected: (_) => setState(() => _add = k),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
