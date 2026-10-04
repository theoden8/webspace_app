/// The mark that says which container a tab runs in (TAB-018).
///
/// Every site has its own container, and a tab runs in the container of the
/// site it runs as: its owner, the site hosting it, or the site that opened it
/// with routing off (LIR-034). The mark draws that site's colour, so two rows
/// with the same page in different containers look different at a glance.
library;

import 'package:flutter/material.dart';

import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';

/// The colour [site]'s container is drawn in.
Color containerColorOf(WebViewModel site, Brightness brightness) =>
    ContainerColors.of(
      site.containerColor ??
          ContainerColorEngine.fallback(
              site.siteId, ContainerColors.light.length),
      brightness,
    );

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
            color: containerColorOf(site, Theme.of(context).brightness),
            borderRadius: BorderRadius.circular(Radii.xs),
          ),
        ),
      );
}
