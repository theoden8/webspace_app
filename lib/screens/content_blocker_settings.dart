import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/ubo_backup_import.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/dataset_tile.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/toast.dart';

/// The app-wide filter lists every site's content blocker draws on: which are
/// on, adding and importing lists, and how `$redirect` rules are served.
class ContentBlockerSettingsScreen extends StatefulWidget {
  const ContentBlockerSettingsScreen({super.key, this.onTrustUboHosts});

  /// Finds the app-tier sites a uBlock Origin backup trusts (content
  /// blocker on, not held on by Tracking Protection) and, with `apply`,
  /// switches their content blocker off and saves. A callback rather than
  /// the models themselves: the sites stay owned by the page.
  final Future<List<UboTrustedSite>> Function(Set<String> hosts,
      {required bool apply})? onTrustUboHosts;

  @override
  State<ContentBlockerSettingsScreen> createState() =>
      _ContentBlockerSettingsScreenState();
}

class _ContentBlockerSettingsScreenState
    extends State<ContentBlockerSettingsScreen> with SettingsOpenGuard {
  String? _downloadingListId;

  Future<void> _downloadContentList(String id) async {
    setState(() {
      _downloadingListId = id;
    });

    final success = await ContentBlockerService.instance.downloadList(id);

    if (mounted) {
      setState(() {
        _downloadingListId = null;
      });

      final loc = AppLocalizations.of(context);
      if (success) {
        final list = ContentBlockerService.instance.lists
            .firstWhere((l) => l.id == id);
        ScaffoldMessenger.of(context).toast(
          loc.appSettingsFilterListRules(list.name, compactCount(list.ruleCount)),
        );
      } else {
        ScaffoldMessenger.of(context).toast(
          loc.appSettingsFilterListDownloadFailed,
        );
      }
    }
  }

  Future<void> _downloadAllContentLists() async {
    setState(() {
      _downloadingListId = '__all__';
    });

    final count = await ContentBlockerService.instance.downloadAllLists();

    if (mounted) {
      setState(() {
        _downloadingListId = null;
      });

      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).toast(
        loc.appSettingsFilterListsUpdated(count),
      );
    }
  }

  Future<void> _toggleContentList(String id, bool enabled) async {
    await ContentBlockerService.instance.toggleList(id, enabled);
    if (mounted) setState(() {});
  }

  Future<void> _removeContentList(String id) async {
    await ContentBlockerService.instance.removeList(id);
    if (mounted) setState(() {});
  }

  Future<void> _showAddCustomListDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.appSettingsAddCustomListTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: loc.appSettingsCustomListNameLabel,
                hintText: loc.appSettingsCustomListNameHint,
              ),
            ),
            const SizedBox(height: 8),
            Builder(builder: (context) {
              const urlHint = 'https://example.com/filters.txt';
              return TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: loc.appSettingsCustomListUrlLabel,
                  hintText: urlHint,
                ),
                keyboardType: TextInputType.url,
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.commonAdd),
          ),
        ],
      ),
    );

    if (result == true &&
        nameController.text.isNotEmpty &&
        urlController.text.isNotEmpty) {
      final id = await ContentBlockerService.instance
          .addCustomList(nameController.text, urlController.text);
      await _downloadContentList(id);
    }

    nameController.dispose();
    urlController.dispose();
  }

  Future<void> _showLocalListDialog({FilterList? existing}) async {
    final nameController = TextEditingController(text: existing?.name);
    final rulesController = TextEditingController(text: existing?.rules);

    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null
            ? loc.appSettingsAddLocalListTitle
            : loc.appSettingsEditLocalListTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: loc.appSettingsCustomListNameLabel,
                  hintText: loc.appSettingsCustomListNameHint,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: rulesController,
                decoration: InputDecoration(
                  labelText: loc.appSettingsLocalListRulesLabel,
                  hintText: loc.appSettingsLocalListRulesHint,
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 6,
                maxLines: 14,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(existing == null ? loc.commonAdd : loc.commonSave),
          ),
        ],
      ),
    );

    final name = nameController.text.trim();
    final rules = rulesController.text;
    nameController.dispose();
    rulesController.dispose();
    if (result != true || name.isEmpty) return;

    if (existing == null) {
      await ContentBlockerService.instance.addLocalList(name, rules);
    } else {
      await ContentBlockerService.instance
          .updateLocalList(existing.id, name, rules);
    }
    if (mounted) setState(() {});
  }

  Future<void> _importUboBackup() async {
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    String? text;
    try {
      final picked = await FilePicker.pickFiles(allowMultiple: false);
      final file = picked?.files.firstOrNull;
      if (file == null) return;
      if (file.bytes != null) {
        text = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        text = await hostReadFileText(file.path!);
      }
    } catch (e) {
      LogTag.contentBlocker.warning('uBO backup read failed: $e');
    }
    final backup = text == null ? null : UboBackup.parse(text);
    if (backup == null) {
      messenger.toast(loc.appSettingsUboNotABackup);
      return;
    }
    if (!mounted) return;

    setState(() => _downloadingListId = '__all__');
    final service = ContentBlockerService.instance;
    final registry = await service.fetchUboAssetRegistry();
    final plan = planUboImport(backup,
        existing: service.existingForImport, registry: registry);
    final sites = plan.trustedHosts.isEmpty || widget.onTrustUboHosts == null
        ? const <UboTrustedSite>[]
        : await widget.onTrustUboHosts!(plan.trustedHosts, apply: false);
    if (!mounted) return;
    setState(() => _downloadingListId = null);

    if (plan.isEmpty) {
      messenger.toast(loc.appSettingsUboImportNothing);
      return;
    }

    final unappliedHosts = plan.trustedHosts
        .where((h) => !sites.any((s) => hostTrustedBy(s.host, {h})))
        .length;
    final listCount = plan.enableIds.length + plan.addLists.length;
    final userRuleCount = plan.userFilters == null
        ? 0
        : const LineSplitter()
            .convert(plan.userFilters!)
            .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('!'))
            .length;
    final siteNames = sites.map((s) => s.name).join(', ');
    final skipped = <String>[
      if (plan.unresolvedKeys.isNotEmpty)
        loc.appSettingsUboImportUnresolved(plan.unresolvedKeys.length),
      if (plan.unsupportedTrusted.isNotEmpty)
        loc.appSettingsUboImportUnsupportedTrusted(
            plan.unsupportedTrusted.length),
      if (unappliedHosts > 0)
        loc.appSettingsUboImportUnappliedTrusted(unappliedHosts),
      if (plan.droppedRuleCount > 0)
        loc.appSettingsUboImportDroppedRules(plan.droppedRuleCount),
    ];

    final theme = Theme.of(context).textTheme;
    final confirmed = await confirm(
      context,
      title: loc.appSettingsUboImportTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (listCount > 0) Text(loc.appSettingsUboImportLists(listCount)),
          if (plan.userFilters != null) ...[
            const SizedBox(height: 8),
            Text(loc.appSettingsUboImportUserFilters(userRuleCount)),
          ],
          if (sites.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(loc.appSettingsUboImportTrustedSites(siteNames)),
          ],
          if (skipped.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(loc.appSettingsUboImportSkippedHeader,
                style: theme.titleSmall),
            for (final line in skipped) ...[
              const SizedBox(height: 4),
              Text(line, style: theme.bodySmall),
            ],
          ],
        ],
      ),
      confirmLabel: loc.homeImportAction,
      destructive: false,
    );
    if (!confirmed || !mounted) return;

    setState(() => _downloadingListId = '__all__');
    final toDownload = await service.applyUboImport(plan,
        userFiltersName: loc.appSettingsUboUserFiltersName);
    if (sites.isNotEmpty) {
      await widget.onTrustUboHosts!(plan.trustedHosts, apply: true);
    }
    var downloaded = 0;
    for (final id in toDownload) {
      if (await service.downloadList(id)) downloaded++;
    }
    if (!mounted) return;
    setState(() => _downloadingListId = null);
    messenger.toast(
      loc.appSettingsUboImportDone(downloaded, toDownload.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.appSettingsContentBlocker),
        actions: [
          if (ContentBlockerService.instance.lists.any((l) => l.enabled))
            _downloadingListId == '__all__'
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.sync),
                    tooltip: loc.appSettingsUpdateAllLists,
                    onPressed: _downloadingListId != null
                        ? null
                        : _downloadAllContentLists,
                  ),
        ],
      ),
      body: ListView(
        children: [
          ...ContentBlockerService.instance.lists.map((list) {
            final isDownloading = _downloadingListId == list.id ||
                _downloadingListId == '__all__';
            final isDefault = !list.id.startsWith('custom_');

            return ListTile(
              leading: Switch(
                value: list.enabled,
                onChanged: list.lastUpdated != null && !isDownloading
                    ? (value) => _toggleContentList(list.id, value)
                    : null,
              ),
              title: Text(list.name),
              subtitle: Text(
                list.lastUpdated != null
                    ? loc.appSettingsRulesCount(
                        compactCount(list.ruleCount))
                    : loc.appSettingsNotDownloaded,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDownloading)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (list.isLocal)
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: loc.commonEdit,
                      onPressed: _downloadingListId != null
                          ? null
                          : () => guardedOpen(
                              () => _showLocalListDialog(existing: list)),
                    )
                  else
                    IconButton(
                      icon: Icon(
                        list.lastUpdated != null
                            ? Icons.sync
                            : Icons.download,
                      ),
                      tooltip: list.lastUpdated != null
                          ? loc.appSettingsRefresh
                          : loc.appSettingsDownload,
                      onPressed: _downloadingListId != null
                          ? null
                          : () => _downloadContentList(list.id),
                    ),
                  if (!isDefault)
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: loc.commonRemove,
                      onPressed: _downloadingListId != null
                          ? null
                          : () => _removeContentList(list.id),
                    ),
                ],
              ),
            );
          }),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _downloadingListId != null
                      ? null
                      : () => guardedOpen(_showAddCustomListDialog),
                  icon: const Icon(Icons.add),
                  label: Text(loc.appSettingsAddCustomList),
                ),
                OutlinedButton.icon(
                  onPressed: _downloadingListId != null
                      ? null
                      : () => guardedOpen(_showLocalListDialog),
                  icon: const Icon(Icons.edit_note),
                  label: Text(loc.appSettingsAddLocalList),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _downloadingListId != null
                          ? null
                          : () => guardedOpen(_importUboBackup),
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(loc.appSettingsImportUboBackup),
                ),
              ],
            ),
          ),
          // uBO resources toggle. When off, $redirect= rules become
          // plain blocks (drop the request) instead of returning a stub
          // body. Some ad/tracker sites detect the missing API surface
          // and break (white page, infinite spinner), so default on.
          // Greyed out on platforms that don't ship the engine library.
          SettingTile(
            title: loc.appSettingsUboRedirectStubs,
            hint: loc.appSettingsUboRedirectStubsSubtitle,
            lock: ContentBlockerService.instance.rustEngineSupportedOnPlatform
                ? null
                : Lock.because(loc.appSettingsUboRedirectStubsUnavailable),
            control: Toggle(ContentBlockerService.instance.useUboResources,
                (value) async {
              await ContentBlockerService.instance.setUseUboResources(value);
              if (mounted) setState(() {});
            }),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
