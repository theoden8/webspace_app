import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/extension_listing.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_grants_engine.dart'
    show ExtensionSite, siteReach;
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_search_engine.dart';
import 'package:webspace/settings/web_extension_source.dart';
import 'package:webspace/theme/design_tokens.dart';

/// A search of addons.mozilla.org (WEBEXT-019) for what was typed in the
/// Extensions screen's search bar, offered only outside the App Store: each
/// result labelled by how well WebKit is expected to run it and on which of
/// the user's sites, none hidden unless the user asks for those that run
/// fully. Picking one opens its page; adding it there pops its source, which
/// the Extensions screen adds as it adds from a link.
class ExtensionSearchScreen extends StatefulWidget {
  const ExtensionSearchScreen({
    super.key,
    required this.query,
    required this.sites,
  });

  /// What the search starts with; the field above the results refines it.
  final String query;

  /// The user's sites that can run extensions.
  final List<ExtensionSite> sites;

  @override
  State<ExtensionSearchScreen> createState() => _ExtensionSearchScreenState();
}

class _ExtensionSearchScreenState extends State<ExtensionSearchScreen> {
  final _guard = ReentryGuard();
  final _query = TextEditingController();
  final _images = ListingImages();
  bool _recommendedOnly = false;
  bool _fullyOnly = false;
  AmoSort _sort = AmoSort.users;
  bool _searching = false;
  List<AmoResult> _results = const [];
  int _page = 0;
  bool _more = false;
  Localized? _failure;

  @override
  void initState() {
    super.initState();
    _query.text = widget.query;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_search(next: false));
    });
  }

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
        sort: _sort,
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

  /// [result]'s page; its source when the user adds it there.
  Future<void> _openListing(AmoResult result) async {
    final source = await Navigator.push<ExtensionSource>(
      context,
      MaterialPageRoute(
        builder: (_) => ExtensionListingScreen(
          result: result,
          sites: widget.sites,
          images: _images,
        ),
      ),
    );
    if (source == null || !mounted) return;
    Navigator.pop<ExtensionSource>(context, source);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final failure = _failure;
    final shown = [
      for (final result in _results)
        if (!_fullyOnly || result.fit == WebKitFit.works) result,
    ];
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
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
            child: Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                FilterChip(
                  label: Text(loc.extensionsFitWorksHere),
                  selected: _fullyOnly,
                  onSelected: (on) => setState(() => _fullyOnly = on),
                ),
                FilterChip(
                  label: Text(loc.extensionsSearchRecommended),
                  selected: _recommendedOnly,
                  onSelected: (on) {
                    setState(() => _recommendedOnly = on);
                    unawaited(_search(next: false));
                  },
                ),
                _SortChip(
                  sort: _sort,
                  onPicked: (sort) {
                    setState(() => _sort = sort);
                    unawaited(_search(next: false));
                  },
                ),
              ],
            ),
          ),
          if (_searching)
            Semantics(
              label: loc.extensionsReading,
              child: const LinearProgressIndicator(),
            ),
          if (failure != null) ListTile(title: Text(failure)),
          if (!_searching && failure == null && _page > 0 && shown.isEmpty)
            ListTile(title: Text(loc.extensionsSearchEmpty)),
          for (final result in shown)
            _ResultTile(
              result,
              sites: widget.sites,
              images: _images,
              onOpen: () => unawaited(_openListing(result)),
            ),
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

extension on AmoSort {
  Localized label(AppLocalizations loc) => switch (this) {
    AmoSort.users => loc.extensionsSortUsers,
    AmoSort.rating => loc.extensionsSortRating,
    AmoSort.updated => loc.extensionsSortUpdated,
  };
}

/// The order of the results, as a chip that opens the choices.
class _SortChip extends StatelessWidget {
  const _SortChip({required this.sort, required this.onPicked});

  final AmoSort sort;
  final ValueChanged<AmoSort> onPicked;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return PopupMenuButton<AmoSort>(
      tooltip: loc.extensionsSortTooltip,
      initialValue: sort,
      onSelected: onPicked,
      itemBuilder: (_) => [
        for (final choice in AmoSort.values)
          PopupMenuItem(value: choice, child: Text(choice.label(loc))),
      ],
      child: Chip(
        avatar: const Icon(Icons.sort, size: IconSizes.action),
        label: Text(sort.label(loc)),
      ),
    );
  }
}

/// One search result: its icon, name, authors, rating and daily users, what
/// it does, and how it runs here (WEBEXT-019).
class _ResultTile extends StatelessWidget {
  const _ResultTile(
    this.result, {
    required this.sites,
    required this.images,
    required this.onOpen,
  });

  final AmoResult result;
  final List<ExtensionSite> sites;
  final ListingImages images;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final numbers = MaterialLocalizations.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final meta = Localized.joined([
      if (result.authors.isNotEmpty) Localized.verbatim(result.authors.first),
      if (result.users case final users?)
        loc.extensionsSearchUsers(users, numbers.formatDecimal(users)),
    ], by: Joined.list);
    final rating = result.rating;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListingIcon(result.icon, images: images, size: 48),
            const SizedBox(width: Spacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Localized.verbatim(result.name),
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      if (rating != null) ...[
                        Icon(
                          Icons.star,
                          size: IconSizes.inline,
                          color: muted?.color,
                        ),
                        Text(
                          Localized.verbatim(
                            NumberFormat.decimalPatternDigits(
                              locale: Localizations.localeOf(
                                context,
                              ).toLanguageTag(),
                              decimalDigits: 1,
                            ).format(rating.average),
                          ),
                          style: muted,
                        ),
                        const SizedBox(width: Spacing.sm),
                      ],
                      Flexible(
                        child: Text(
                          meta,
                          style: muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (result.summary.isNotEmpty)
                    Text(
                      Localized.verbatim(result.summary),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: Spacing.xs),
                  Wrap(
                    spacing: Spacing.xs,
                    runSpacing: Spacing.xs,
                    children: [
                      ListingChip.fit(
                        result,
                        reach: siteReach(result.hosts, sites: sites),
                        loc: loc,
                      ),
                      if (result.recommended)
                        ListingChip(
                          icon: Icons.verified_outlined,
                          label: loc.extensionsRecommendedBadge,
                          tone: ChipTone.recommended,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
