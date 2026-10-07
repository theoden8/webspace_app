import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/widgets/dirty_guard.dart';
import 'package:webspace/widgets/toast.dart';

class WebspaceDetailScreen extends StatefulWidget {
  final Webspace webspace;
  final List<WebViewModel> allSites;
  final Function(Webspace) onSave;
  final bool isReadOnly;

  const WebspaceDetailScreen({
    super.key,
    required this.webspace,
    required this.allSites,
    required this.onSave,
    this.isReadOnly = false,
  });

  @override
  State<WebspaceDetailScreen> createState() => _WebspaceDetailScreenState();
}

class _WebspaceDetailScreenState extends State<WebspaceDetailScreen>
    with DirtyGuard<WebspaceDetailScreen> {
  late final _nameController =
      TextEditingController(text: widget.webspace.name);
  late final _selectedIndices = Set<int>.from(widget.webspace.siteIndices);

  @override
  void initState() {
    super.initState();
    markClean();
    _nameController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Record snapshot() =>
      (name: _nameController.text, sites: ValueSet(_selectedIndices));

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _save() {
    final trimmedName = _nameController.text.trim();
    if (trimmedName.isEmpty) {
      ScaffoldMessenger.of(context)
          .toast(AppLocalizations.of(context).webspaceDetailNameEmptyError);
      return;
    }
    widget.onSave(widget.webspace.copyWith(
      name: trimmedName,
      siteIndices: _selectedIndices.toList()..sort(),
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final selectedCount = _selectedIndices.length;
    return guardPop(
        child: Scaffold(
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
                          secondary: UnifiedFaviconImage.site(site, size: 32),
                          title: Text(site.getDisplayName()),
                          subtitle: Text(extractDomain(site.initUrl)),
                          value: isSelected,
                          onChanged: widget.isReadOnly
                              ? null
                              : (_) => setState(() {
                                    if (!_selectedIndices.remove(index)) {
                                      _selectedIndices.add(index);
                                    }
                                  }),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ));
  }
}
