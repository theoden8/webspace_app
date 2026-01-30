import 'package:flutter/material.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;

class WebspaceDetailScreen extends StatefulWidget {
  final Webspace webspace;
  final List<WebViewModel> allSites;
  final Function(Webspace) onSave;
  final bool isReadOnly;

  const WebspaceDetailScreen({
    Key? key,
    required this.webspace,
    required this.allSites,
    required this.onSave,
    this.isReadOnly = false,
  }) : super(key: key);

  @override
  _WebspaceDetailScreenState createState() => _WebspaceDetailScreenState();
}

class _WebspaceDetailScreenState extends State<WebspaceDetailScreen> {
  late TextEditingController _nameController;
  late Set<int> _selectedIndices;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.webspace.name);
    _selectedIndices = Set<int>.from(widget.webspace.siteIndices);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _toggleSite(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _save() {
    final trimmedName = _nameController.text.trim();

    // Validate that name is not empty
    if (trimmedName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Webspace name cannot be empty'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final updatedWebspace = widget.webspace.copyWith(
      name: trimmedName,
      siteIndices: _selectedIndices.toList()..sort(),
    );
    widget.onSave(updatedWebspace);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isReadOnly ? 'View Webspace' : 'Edit Webspace'),
        actions: [
          if (!widget.isReadOnly)
            Semantics(
              label: 'Save',
              button: true,
              enabled: true,
              child: IconButton(
                icon: Icon(Icons.check),
                onPressed: _save,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _nameController,
              enabled: !widget.isReadOnly,
              decoration: InputDecoration(
                labelText: 'Webspace Name',
                hintText: 'New webspace',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Text(
                  'Select Sites',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Spacer(),
                Text(
                  '${_selectedIndices.length} selected',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(height: 8),
          Expanded(
            child: widget.allSites.isEmpty
                ? Center(
                    child: Text('No sites available. Add sites first.'),
                  )
                : ListView.builder(
                    itemCount: widget.allSites.length,
                    itemBuilder: (context, index) {
                      final site = widget.allSites[index];
                      final isSelected = _selectedIndices.contains(index);
                      return Semantics(
                        label: site.getDisplayName(),
                        checked: isSelected,
                        enabled: !widget.isReadOnly,
                        child: CheckboxListTile(
                          secondary: UnifiedFaviconImage(
                            url: site.initUrl,
                            size: 32,
                          ),
                          title: Text(site.getDisplayName()),
                          subtitle: Text(extractDomain(site.initUrl)),
                          value: isSelected,
                          onChanged: widget.isReadOnly
                              ? null
                              : (bool? value) {
                                  _toggleSite(index);
                                },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
