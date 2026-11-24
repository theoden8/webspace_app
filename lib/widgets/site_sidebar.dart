import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/sidebar_rail.dart';

/// The open sidebar: a title row with its collapse button at the top right
/// (the sidebar icon, not a cross), then what it shows, the tab tree or the
/// squares; a grip on its right edge resizes it.
class SiteSidebar extends StatelessWidget {
  const SiteSidebar({
    super.key,
    required this.width,
    required this.title,
    required this.body,
    required this.onCollapse,
    required this.collapseTooltip,
    this.footer,
    this.onResize,
    this.onResizeEnd,
  });

  final double width;

  /// What heads it: the webspace's name, or the legacy drawer's header.
  final Widget title;
  final Widget body;
  final VoidCallback onCollapse;

  /// The rail on a docked sidebar; putting it away on the drawer and the
  /// full-screen sidebar.
  final String collapseTooltip;

  /// Under what it shows: the legacy design's Add Site.
  final Widget? footer;

  /// The grip's drag, by how far it moved; null shows no grip.
  final ValueChanged<double>? onResize;
  final VoidCallback? onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hairline = Chrome.hairline(isDark: isDark);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Chrome.bar(isDark: isDark),
        border: BorderDirectional(
          end: BorderSide(color: hairline, width: Chrome.hairlineWidth),
        ),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: Spacing.md,
                      ),
                      // At least the collapse button's height and centred in
                      // it, so a one-line title sits level with the button
                      // while the legacy header, taller, keeps its own.
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: kMinInteractiveDimension,
                        ),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: title,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: collapseTooltip,
                    color: theme.colorScheme.primary,
                    icon: const SidebarIcon(),
                    onPressed: onCollapse,
                  ),
                ],
              ),
              Expanded(child: body),
              ?footer,
            ],
          ),
          if (onResize case final resize?)
            PositionedDirectional(
              top: 0,
              bottom: 0,
              end: 0,
              width: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: Semantics(
                  label: AppLocalizations.of(context).sidebarResize,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) => resize(d.delta.dx),
                    onHorizontalDragEnd: (_) => onResizeEnd?.call(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
