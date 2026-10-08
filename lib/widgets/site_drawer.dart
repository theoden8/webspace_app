import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/accent_logo.dart';
import 'package:webspace/widgets/site_grid_tile.dart';

/// The page's drawer: the selected webspace under the logo, the way back to
/// the webspace list, the webspace's sites as a grid, and Add site.
class SiteDrawer extends StatelessWidget {
  const SiteDrawer({
    super.key,
    required this.accentColor,
    required this.webspaceName,
    required this.models,
    required this.order,
    required this.current,
    required this.showsTabCount,
    required this.onBackToWebspaces,
    required this.onOpen,
    required this.onMenu,
    required this.onReorder,
    required this.onAddSite,
  });

  final AccentColor accentColor;

  /// Null while no webspace is selected.
  final String? webspaceName;
  final List<WebViewModel> models;

  /// Positions in [models], in the order the grid shows them.
  final List<int> order;
  final int? current;
  final bool Function(int index) showsTabCount;
  final VoidCallback onBackToWebspaces;
  final ValueChanged<int> onOpen;
  final void Function(
    BuildContext context, {
    required int index,
    required Offset position,
  })
  onMenu;

  /// Null where the view cannot be reordered.
  final void Function(int from, {required int to})? onReorder;
  final VoidCallback onAddSite;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Drawer(
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: onBackToWebspaces,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 4.0,
                      ),
                      child: Column(
                        children: [
                          AccentLogo(
                            accentColor: accentColor,
                            size: 72,
                            brightness: Theme.of(context).brightness,
                          ),
                          SizedBox(height: 4),
                          Text(
                            webspaceName ?? loc.homeNoWebspace,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Semantics(
                    label: loc.homeBackToWebspaces,
                    button: true,
                    enabled: true,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 0,
                        ),
                        minimumSize: Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: onBackToWebspaces,
                      icon: Icon(Icons.arrow_back, size: 16),
                      label: Text(
                        loc.homeBackToWebspaces,
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: webspaceName == null
                ? Center(child: Text(loc.homeSelectWebspaceToViewSites))
                : () {
                    final filteredIndices = order;
                    if (filteredIndices.isEmpty) {
                      return Center(child: Text(loc.homeNoSitesInWebspace));
                    }

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final itemCount = filteredIndices.length;
                        const itemHeight = 88.0;
                        final availableHeight =
                            constraints.maxHeight -
                            12; // padding (top: 4 + bottom: 8)
                        final maxRows = (availableHeight / itemHeight)
                            .floor()
                            .clamp(1, itemCount);

                        int crossAxisCount = 1;
                        if (itemCount > maxRows) {
                          crossAxisCount = (itemCount / maxRows).ceil().clamp(
                            1,
                            4,
                          );
                        }

                        return GridView.builder(
                          padding: const EdgeInsets.only(
                            left: 8,
                            right: 8,
                            bottom: 8,
                            top: 4,
                          ),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                mainAxisSpacing: 4,
                                crossAxisSpacing: 4,
                                mainAxisExtent: itemHeight,
                              ),
                          itemCount: itemCount,
                          itemBuilder: (BuildContext context, int listIndex) {
                            final index = filteredIndices[listIndex];
                            final site = models[index];
                            return SiteGridTile(
                              key: Key('site_$index'),
                              site: site,
                              listIndex: listIndex,
                              selected: current == index,
                              showTabCount:
                                  showsTabCount(index) && site.tabs.length > 1,
                              onOpen: () => onOpen(index),
                              onMenu: (context, {required globalPosition}) =>
                                  onMenu(
                                    context,
                                    index: index,
                                    position: globalPosition,
                                  ),
                              onReorder: onReorder,
                            );
                          },
                        );
                      },
                    );
                  }(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onAddSite,
                icon: Icon(Icons.add),
                label: Text(loc.homeAddSite),
              ),
            ),
          ),
          SizedBox(height: 8.0 + MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
