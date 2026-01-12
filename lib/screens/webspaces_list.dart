import 'package:flutter/material.dart';
import 'package:webspace/webspace_model.dart';

class WebspacesListScreen extends StatelessWidget {
  final List<Webspace> webspaces;
  final String? selectedWebspaceId;
  final Function(Webspace) onSelectWebspace;
  final Function() onAddWebspace;
  final Function(Webspace) onEditWebspace;
  final Function(Webspace) onDeleteWebspace;

  const WebspacesListScreen({
    Key? key,
    required this.webspaces,
    this.selectedWebspaceId,
    required this.onSelectWebspace,
    required this.onAddWebspace,
    required this.onEditWebspace,
    required this.onDeleteWebspace,
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
            'No webspace selected',
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
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: webspaces.length,
                  itemBuilder: (context, index) {
                    final webspace = webspaces[index];
                    final isSelected = selectedWebspaceId == webspace.id;
                    return Card(
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
                        subtitle: Text('${webspace.siteIndices.length} sites'),
                        onTap: () => onSelectWebspace(webspace),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit),
                              onPressed: () => onEditWebspace(webspace),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete),
                              onPressed: () => onDeleteWebspace(webspace),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onAddWebspace,
            icon: Icon(Icons.add),
            label: Text('Create Webspace'),
            style: ElevatedButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
          ),
          SizedBox(height: 32),
        ],
      ),
    );
  }
}
