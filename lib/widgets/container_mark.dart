/// The mark that says which container a tab runs in (TAB-018).
///
/// Every site has its own container, and a tab runs in the container of the
/// site it runs as: its owner, the site hosting it, or the site that opened it
/// with routing off (LIR-034). The mark draws that site's colour, so two rows
/// with the same page in different containers look different at a glance.
library;

import 'package:flutter/material.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';

/// The colour [site]'s container is drawn in.
Color containerColorOf(WebViewModel site, {required Brightness brightness}) =>
    ContainerColors.of(site.drawnContainerColor, brightness: brightness);

/// The sites whose icon another of [sites] shows too, which only their
/// container's colour tells apart (WEBSPACE-014): the same picked icon, or
/// none picked and the same host, whose favicon both fetch.
Set<SiteId> sitesSharingAnIcon(Iterable<WebViewModel> sites) {
  final bySource = <Object, List<SiteId>>{};
  for (final site in sites) {
    final Object source = switch (site.customIconPng) {
      final png? => (picked: Object.hashAll(png), length: png.length),
      null => (host: Host.inUrl(site.initUrl)?.withoutWww ?? site.initUrl),
    };
    (bySource[source] ??= []).add(site.siteId);
  }
  return {
    for (final alike in bySource.values)
      if (alike.length > 1) ...alike,
  };
}

/// A short bar in the colour of [site]'s container. Decorative: the row it
/// sits in names the site in words.
class ContainerMark extends StatelessWidget {
  const ContainerMark({
    super.key,
    required this.site,
    this.height = IconSizes.inline,
  });

  final WebViewModel site;
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: ContainerColors.markWidth,
          height: height,
          decoration: BoxDecoration(
            color: containerColorOf(site,
                brightness: Theme.of(context).brightness),
            borderRadius: BorderRadius.circular(Radii.xs),
          ),
        ),
      );
}

/// A dot in the colour of the container at palette [colorIndex]. Decorative:
/// what it sits beside names the site in words.
class ContainerDot extends StatelessWidget {
  const ContainerDot(this.colorIndex, {super.key, this.size = Spacing.sm});

  final int colorIndex;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: ContainerColors.of(colorIndex,
                brightness: Theme.of(context).brightness),
            shape: BoxShape.circle,
          ),
        ),
      );
}

/// A site's id, led by a dot in its container's colour: what tells two sites
/// with the same name apart in a list. [colorIndex] is null on the legacy
/// engine, which has no containers to colour. The id stays in the muted text
/// colour, since the palette holds 3:1, a graphic's contrast, not a label's.
class SiteIdLine extends StatelessWidget {
  const SiteIdLine({super.key, required this.siteId, this.colorIndex});

  final SiteId siteId;
  final int? colorIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = colorIndex;
    return Row(
      children: [
        if (index != null) ...[
          ContainerDot(index),
          const SizedBox(width: Spacing.xs),
        ],
        Flexible(
          child: Text(
            siteId,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
