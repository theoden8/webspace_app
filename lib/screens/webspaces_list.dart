import 'package:flutter/material.dart';
import 'package:webspace/webspace_model.dart';

class WebspacesListScreen extends StatelessWidget {
  final List<Webspace> webspaces;
  final String? selectedWebspaceId;
  final int totalSitesCount;
  final Function(Webspace) onSelectWebspace;
  final Function() onAddWebspace;
  final Function(Webspace) onEditWebspace;
  final Function(Webspace) onDeleteWebspace;
  final Function(int, int)? onReorder;

  const WebspacesListScreen({
    Key? key,
    required this.webspaces,
    this.selectedWebspaceId,
    required this.totalSitesCount,
    required this.onSelectWebspace,
    required this.onAddWebspace,
    required this.onEditWebspace,
    required this.onDeleteWebspace,
    this.onReorder,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.workspaces_outlined,
            size: 80,
            color: Theme.of(context).colorScheme.secondary,
          ),
          SizedBox(height: 24),
          Text(
            'Select Webspace',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          SizedBox(height: 8),
          Text(
            selectedWebspaceId != null
                ? webspaces.firstWhere(
                    (ws) => ws.id == selectedWebspaceId,
                    orElse: () => Webspace(name: 'Unknown'),
                  ).name
                : 'No webspace selected',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey,
            ),
          ),
          SizedBox(height: 16),
          if (webspaces.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: Text(
                'No webspaces yet. Create one to organize your sites.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          SizedBox(height: 24),
          if (webspaces.isNotEmpty)
            Expanded(
              child: Container(
                constraints: BoxConstraints(maxWidth: 600),
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  shrinkWrap: true,
                  itemCount: webspaces.length,
                  onReorder: (oldIndex, newIndex) {
                    // Don't allow moving "All" webspace (always at index 0)
                    if (oldIndex == 0 || newIndex == 0) return;
                    if (onReorder != null) {
                      onReorder!(oldIndex, newIndex);
                    }
                  },
                  itemBuilder: (context, index) {
                    final webspace = webspaces[index];
                    final isSelected = selectedWebspaceId == webspace.id;
                    final isAll = webspace.id == kAllWebspaceId;
                    final siteCount = isAll ? totalSitesCount : webspace.siteIndices.length;

                    return Semantics(
                      key: Key(webspace.id),
                      label: webspace.name,
                      button: true,
                      enabled: true,
                      child: Card(
                        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: isSelected
                            ? Theme.of(context).colorScheme.secondary.withOpacity(0.15)
                            : null,
                        elevation: isSelected ? 4 : 1,
                        child: ListTile(
                          leading: Icon(
                            Icons.workspaces,
                            color: isSelected
                                ? Theme.of(context).colorScheme.secondary
                                : null,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  webspace.name,
                                  style: TextStyle(
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (isSelected)
                                Icon(
                                  Icons.check_circle,
                                  color: Theme.of(context).colorScheme.secondary,
                                  size: 20,
                                ),
                            ],
                          ),
                          subtitle: Text('$siteCount sites'),
                          onTap: () => onSelectWebspace(webspace),
                          trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit, size: 20),
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              onPressed: () => onEditWebspace(webspace),
                            ),
                            if (!isAll)
                              Container(
                                color: Theme.of(context).cardTheme.color ??
                                       Theme.of(context).cardColor,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.delete, size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: BoxConstraints(
                                        minWidth: 40,
                                        minHeight: 40,
                                      ),
                                      onPressed: () => onDeleteWebspace(webspace),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 12),
                                        child: Icon(
                                          Icons.drag_handle,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    );
                  },
                ),
              ),
            ),
          SizedBox(height: 16),
          Semantics(
            label: 'Create Webspace',
            button: true,
            enabled: true,
            child: ElevatedButton.icon(
              onPressed: onAddWebspace,
              icon: Icon(Icons.add),
              label: Text('Create Webspace'),
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ),
          SizedBox(height: 32),
        ],
      ),
    );
  }
}
