import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/web_extension_grants_engine.dart'
    show ExtensionSite, SiteReach, siteReach;
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_search_engine.dart';
import 'package:webspace/settings/byte_size.dart';
import 'package:webspace/settings/web_extension_source.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/extension_asks.dart';

/// The icons and screenshots of the listings a search shows, each fetched
/// once through the app's proxy while the search is open.
class ListingImages {
  final _fetched = <Uri, Future<Uint8List?>>{};

  Future<Uint8List?> of(Uri url) => _fetched.putIfAbsent(
    url,
    () => WebExtensionLibrary.instance.listingImage(url),
  );
}

/// An extension's icon from its listing, or the generic one while it loads
/// or where it has none.
class ListingIcon extends StatelessWidget {
  const ListingIcon(this.url, {super.key, required this.images, required this.size});

  final Uri? url;
  final ListingImages images;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = Icon(Icons.extension_outlined, size: size * .6);
    final url = this.url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.xl),
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? placeholder
            : FutureBuilder<Uint8List?>(
                future: images.of(url),
                builder: (context, shot) => switch (shot.data) {
                  final bytes? => Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => placeholder,
                  ),
                  null => placeholder,
                },
              ),
      ),
    );
  }
}

/// How a search result runs here and where, in a few words (WEBEXT-019):
/// the fit, and for one that runs, which of the user's sites it runs on;
/// for one that runs in part, the first thing it is never given.
Localized fitNote(
  AmoResult result, {
  required SiteReach reach,
  required AppLocalizations loc,
}) => switch (result.fit) {
  WebKitFit.works => Localized.joined([
    loc.extensionsFitWorks,
    if (!reach.everySite)
      if (reach.runsOn case [final site])
        loc.extensionsRunsOnSite(site.name)
      else if (reach.runsOn.isNotEmpty)
        loc.extensionsRunsOnSites(reach.runsOn.length),
  ], by: Joined.list),
  WebKitFit.partly => Localized.joined([
    loc.extensionsFitPartly,
    if (result.refused case [final first, ...])
      first == 'webRequestBlocking'
          ? loc.extensionsFitNoBlocking
          : Localized.verbatim(first),
  ], by: Joined.list),
  WebKitFit.unknown => loc.extensionsFitUnknown,
};

/// A small label: how an extension runs here, or that Mozilla recommends it.
class ListingChip extends StatelessWidget {
  const ListingChip({
    super.key,
    required this.icon,
    required this.label,
    required this.tone,
  });

  /// The chip for [result]'s fit, as [fitNote] words it.
  factory ListingChip.fit(
    AmoResult result, {
    required SiteReach reach,
    required AppLocalizations loc,
  }) => ListingChip(
    icon: switch (result.fit) {
      WebKitFit.works => Icons.check_circle_outline,
      WebKitFit.partly => Icons.warning_amber_outlined,
      WebKitFit.unknown => Icons.help_outline,
    },
    label: fitNote(result, reach: reach, loc: loc),
    tone: switch (result.fit) {
      WebKitFit.works => ChipTone.works,
      WebKitFit.partly => ChipTone.partly,
      WebKitFit.unknown => ChipTone.plain,
    },
  );

  final IconData icon;
  final Localized label;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (tone) {
      ChipTone.works => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      ChipTone.partly => (
        HintedTitle.missingDataColor.withValues(alpha: .18),
        scheme.onSurface,
      ),
      ChipTone.recommended => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      ChipTone.plain => (scheme.surfaceContainerHighest, scheme.onSurface),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: IconSizes.inline,
              color: tone == ChipTone.partly
                  ? HintedTitle.missingDataColor
                  : foreground,
            ),
            const SizedBox(width: Spacing.xs),
            Flexible(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: foreground),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum ChipTone { works, partly, recommended, plain }

/// An extension's page before it is added (WEBEXT-019): what its listing
/// says, how it runs here and on which of the user's sites, and the button
/// that adds it. Adding pops its source, which the search pops in turn to
/// the Extensions screen's add flow (WEBEXT-017).
class ExtensionListingScreen extends StatefulWidget {
  const ExtensionListingScreen({
    super.key,
    required this.result,
    required this.sites,
    required this.images,
  });

  /// The search result it opened from, shown until the listing is read.
  final AmoResult result;
  final List<ExtensionSite> sites;
  final ListingImages images;

  @override
  State<ExtensionListingScreen> createState() => _ExtensionListingScreenState();
}

class _ExtensionListingScreenState extends State<ExtensionListingScreen> {
  AmoListing? _listing;
  Localized? _failure;
  bool _wholeDescription = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_read());
    });
  }

  Future<void> _read() async {
    final loc = AppLocalizations.of(context);
    final read = await WebExtensionLibrary.instance.listing(
      widget.result.source,
    );
    if (!mounted) return;
    setState(() {
      switch (read) {
        case SourceFailed(:final reason):
          _failure = loc.extensionsLinkUnreachable(reason);
        case SourceGot(value: ListingRefused()):
          _failure = loc.extensionsSearchUnreadable;
        case SourceGot(value: ListingFound(:final listing)):
          _listing = listing;
      }
    });
  }

  void _add() => Navigator.pop<ExtensionSource>(context, widget.result.source);

  Future<void> _open(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final listing = _listing;
    final result = listing?.result ?? widget.result;
    final reach = siteReach(result.hosts, sites: widget.sites);
    final failure = _failure;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: loc.extensionsOpenListing,
            onPressed: () => unawaited(_open(result.listing)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.xl),
        children: [
          _Header(result: result, images: widget.images),
          _Stats(result: result, size: listing?.size),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.lg,
              Spacing.lg,
              Spacing.sm,
            ),
            child: result.fit == WebKitFit.partly
                ? OutlinedButton(
                    onPressed: _add,
                    child: Text(loc.extensionsAddAnyway),
                  )
                : FilledButton(
                    onPressed: _add,
                    child: Text(loc.extensionsAddToLibrary),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            child: Text(
              loc.extensionsOffUntilSwitched,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
          _FitCard(result: result),
          SettingsSection(loc.extensionsOnYourSites),
          ..._sitesRows(reach, loc: loc),
          if (listing == null && failure == null)
            Semantics(
              label: loc.extensionsReading,
              child: const LinearProgressIndicator(),
            ),
          if (failure != null) ListTile(title: Text(failure)),
          if (listing != null) ...[
            if (listing.screenshots.isNotEmpty) ...[
              SettingsSection(loc.extensionsScreenshots),
              _Screenshots(listing: listing, images: widget.images),
            ],
            if (listing.description.isNotEmpty) ...[
              SettingsSection(loc.extensionsAbout),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                child: Text(
                  Localized.verbatim(listing.description),
                  maxLines: _wholeDescription ? null : 6,
                  overflow: _wholeDescription
                      ? TextOverflow.visible
                      : TextOverflow.fade,
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () => setState(
                    () => _wholeDescription = !_wholeDescription,
                  ),
                  child: Text(
                    _wholeDescription
                        ? loc.extensionsShowLess
                        : loc.extensionsShowMore,
                  ),
                ),
              ),
            ],
          ],
          SettingsSection(loc.extensionsAsksSection),
          ..._asksRows(result, loc: loc),
          if (listing != null) ...[
            SettingsSection(loc.extensionsDetails),
            ..._detailRows(listing, loc: loc),
          ],
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: Text(loc.extensionsOpenListing),
              onPressed: () => unawaited(_open(result.listing)),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sitesRows(SiteReach reach, {required AppLocalizations loc}) => [
    ListTile(
      dense: true,
      title: Text(
        reach.everySite
            ? loc.extensionsAsksEverySite
            : reach.runsOn.isEmpty
            ? loc.extensionsRunsOnNoSite
            : loc.extensionsOnlyItsSite,
      ),
    ),
    for (final site in reach.runsOn)
      ListTile(
        leading: const Icon(Icons.public),
        title: Text(Localized.verbatim(site.name)),
        subtitle: Text(loc.extensionsCanRunHere),
        trailing: const Icon(Icons.check),
      ),
    for (final host in reach.unclaimed)
      ListTile(
        leading: const Icon(Icons.public_off_outlined),
        title: Text(Localized.verbatim(host)),
        subtitle: Text(loc.extensionsNoSiteClaims),
      ),
  ];

  List<Widget> _asksRows(AmoResult result, {required AppLocalizations loc}) {
    final hosts = result.hosts;
    return [
      for (final line in extensionAsks(
        permissions: (result.asked ?? const <String>{}).difference(hosts),
        hosts: hosts,
        loc: loc,
      ))
        ListTile(title: Text(line)),
    ];
  }

  List<Widget> _detailRows(AmoListing listing, {required AppLocalizations loc}) {
    final dates = MaterialLocalizations.of(context);
    return [
      if (listing.version case final version?)
        ListTile(title: Text(loc.extensionsVersion(version))),
      if (listing.updated case final at?)
        ListTile(
          title: Text(
            loc.extensionsUpdatedOn(dates.formatMediumDate(at.toLocal())),
          ),
        ),
      if (listing.licence case final licence?)
        ListTile(title: Text(loc.extensionsLicence(licence))),
      if (listing.homepage case final url?)
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: Text(loc.extensionsHomepage),
          subtitle: Text(Localized.verbatim(url.host)),
          onTap: () => unawaited(_open(url)),
        ),
      if (listing.support case final url?)
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: Text(loc.extensionsSupport),
          subtitle: Text(Localized.verbatim(url.host)),
          onTap: () => unawaited(_open(url)),
        ),
    ];
  }
}

/// The icon, name, authors and Mozilla's recommendation.
class _Header extends StatelessWidget {
  const _Header({required this.result, required this.images});

  final AmoResult result;
  final ListingImages images;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.xs,
        Spacing.lg,
        Spacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListingIcon(result.icon, images: images, size: 72),
          const SizedBox(width: Spacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Localized.verbatim(result.name),
                  style: theme.textTheme.titleLarge,
                ),
                if (result.authors.isNotEmpty)
                  Text(
                    Localized.joined([
                      for (final author in result.authors)
                        Localized.verbatim(author),
                    ], by: Joined.list),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                if (result.recommended)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.sm),
                    child: ListingChip(
                      icon: Icons.verified_outlined,
                      label: loc.extensionsRecommendedBadge,
                      tone: ChipTone.recommended,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The rating, the daily users and the package size, side by side.
class _Stats extends StatelessWidget {
  const _Stats({required this.result, required this.size});

  final AmoResult result;
  final int? size;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final numbers = MaterialLocalizations.of(context);
    final columns = <(Widget, Localized)>[
      if (result.rating case final rating?)
        (
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                Localized.verbatim(
                  NumberFormat.decimalPatternDigits(
                    locale: locale,
                    decimalDigits: 1,
                  ).format(rating.average),
                ),
              ),
              const Icon(Icons.star, size: IconSizes.inline),
            ],
          ),
          loc.extensionsRatings(
            rating.count,
            numbers.formatDecimal(rating.count),
          ),
        ),
      if (result.users case final users?)
        (
          Text(
            Localized.verbatim(NumberFormat.compact(locale: locale).format(users)),
          ),
          loc.extensionsUsersADay,
        ),
      if (size case final bytes?)
        (Text(Localized.verbatim(formatByteSize(bytes))), loc.extensionsSizeCaption),
    ];
    if (columns.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.symmetric(
            horizontal: BorderSide(color: theme.dividerColor),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          child: Row(
            children: [
              for (final (value, caption) in columns)
                Expanded(
                  child: Column(
                    children: [
                      DefaultTextStyle.merge(
                        style: theme.textTheme.titleMedium,
                        child: value,
                      ),
                      Text(caption, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether it runs fully here, in part, or the listing does not say.
class _FitCard extends StatelessWidget {
  const _FitCard({required this.result});

  final AmoResult result;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (IconData icon, Color color, Localized title, Localized body) =
        switch (result.fit) {
          WebKitFit.works => (
            Icons.check_circle_outline,
            theme.colorScheme.secondary,
            loc.extensionsFitWorksHere,
            loc.extensionsFitWorksBody,
          ),
          WebKitFit.partly => (
            Icons.warning_amber_outlined,
            HintedTitle.missingDataColor,
            loc.extensionsFitPartly,
            loc.extensionsNotGiven(result.refused.join(', ')),
          ),
          WebKitFit.unknown => (
            Icons.help_outline,
            theme.colorScheme.onSurfaceVariant,
            loc.extensionsFitUnknown,
            loc.extensionsFitUnknownBody,
          ),
        };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.lg,
        Spacing.lg,
        0,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(Radii.xl),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: Spacing.xs),
                    Text(body, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The listing's screenshots in a row that scrolls sideways.
class _Screenshots extends StatelessWidget {
  const _Screenshots({required this.listing, required this.images});

  final AmoListing listing;
  final ListingImages images;

  static const _height = 180.0;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final shots = listing.screenshots;
    return SizedBox(
      height: _height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        itemCount: shots.length,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
        itemBuilder: (context, i) => Semantics(
          image: true,
          label: loc.extensionsScreenshotOf(i + 1, shots.length),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.xl),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: FutureBuilder<Uint8List?>(
                future: images.of(shots[i]),
                builder: (context, shot) => switch (shot.data) {
                  final bytes? => Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  null => ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
