import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
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
    final loc = AppLocalizations.of(context);
    final trimmedName = _nameController.text.trim();

    // Validate that name is not empty
    if (trimmedName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.webspaceDetailNameEmptyError),
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
    final loc = AppLocalizations.of(context);
    final selectedCount = _selectedIndices.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isReadOnly
              ? loc.webspaceDetailViewTitle
              : loc.webspaceDetailEditTitle,
        ),
        actions: [
          if (!widget.isReadOnly)
            Semantics(
              label: loc.commonSave,
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
                labelText: loc.webspaceDetailNameLabel,
                hintText: loc.webspaceDetailNameHint,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Text(
                  loc.webspaceDetailSelectSites,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Spacer(),
                Text(
                  loc.webspaceDetailSelectedCount(selectedCount),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(height: 8),
          Expanded(
            child: widget.allSites.isEmpty
                ? Center(
                    child: Text(loc.webspaceDetailNoSites),
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
                            proxy: site.proxySettings,
                            customIcon: site.customIconPng,
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
