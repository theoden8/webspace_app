/// The dialog that picks one search site (LIR-029), for App Settings' Default
/// search and the Behaviour screen's Default search from this site.
library;

import 'package:flutter/material.dart';

import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/container_mark.dart';

/// A search site as a picker lists it: two sites can share a name, never an
/// id. [containerColor] is null on the legacy engine.
typedef PickableSearchSite = ({
  String siteId,
  String name,
  int? containerColor,
});

/// [name] as a one-line summary names a site: with its [siteId] when another
/// of [names] is the same, so "DuckDuckGo, DuckDuckGo" never stands for two
/// sites. Data, not copy (LOC-002).
String searchSiteSummaryName(
        String name, String siteId, Iterable<String> names) =>
    names.where((n) => n == name).length > 1 ? '$name ($siteId)' : name;

/// Pops the picked siteId, or `''` for [noneLabel]'s entry.
class SearchSiteChoiceDialog extends StatelessWidget {
  const SearchSiteChoiceDialog({
    super.key,
    required this.title,
    required this.sites,
    required this.selected,
    this.noneLabel,
    this.emptyText,
    this.cancelLabel,
  });

  final String title;
  final List<PickableSearchSite> sites;

  /// The siteId picked now, `''` for [noneLabel]'s entry.
  final String selected;

  /// A first entry that names no site, such as "App default".
  final String? noneLabel;

  /// Shown instead of the list when there is nothing to pick.
  final String? emptyText;
  final String? cancelLabel;

  @override
  Widget build(BuildContext context) {
    final none = noneLabel;
    final empty = emptyText;
    return AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      content: SizedBox(
        width: double.maxFinite,
        child: sites.isEmpty && none == null && empty != null
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
                child: Text(empty),
              )
            : RadioGroup<String>(
                groupValue: selected,
                onChanged: (v) => Navigator.pop(context, v),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (none != null)
                      RadioListTile<String>(value: '', title: Text(none)),
                    for (final site in sites)
                      RadioListTile<String>(
                        value: site.siteId,
                        title: Text(site.name),
                        subtitle: SiteIdLine(
                          siteId: site.siteId,
                          colorIndex: site.containerColor,
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: switch (cancelLabel) {
        final label? => [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(label),
            ),
          ],
        null => null,
      },
    );
  }
}
