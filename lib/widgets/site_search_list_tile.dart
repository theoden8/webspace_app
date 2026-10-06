/// The App Settings row that downloads the site search list (LIR-036).
library;

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/root_messenger.dart';

class SiteSearchListTile extends StatefulWidget {
  const SiteSearchListTile({super.key, required this.formatCount});

  /// How the row writes the site count, as the other dataset rows do.
  final String Function(int count) formatCount;

  @override
  State<SiteSearchListTile> createState() => _SiteSearchListTileState();
}

class _SiteSearchListTileState extends State<SiteSearchListTile> {
  final SiteSearchListService _list = SiteSearchListService.instance;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _list.addListener(_changed);
  }

  @override
  void dispose() {
    _list.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Fetched only from this button, through the app-wide proxy.
  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final ok = await _list.download();
    if (!mounted) return;
    setState(() => _downloading = false);
    final loc = AppLocalizations.of(context);
    rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
        content: Text(ok
            ? loc.webSearchSiteListLoaded(widget.formatCount(_list.siteCount))
            : loc.webSearchSiteListFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final updated = _list.lastUpdated;
    return ListTile(
      leading: const Icon(Icons.manage_search),
      title: Row(
        children: [
          Flexible(child: Text(loc.webSearchSiteListTitle)),
          HintButton(
            title: loc.webSearchSiteListTitle,
            description: loc.webSearchSiteListHint,
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_list.isLoaded
              ? loc.webSearchSiteListCount(widget.formatCount(_list.siteCount))
              : loc.appSettingsNotDownloaded),
          if (_list.isLoaded && updated != null)
            Builder(builder: (context) {
              final when = updated.toLocal().toString().split('.')[0];
              return Text(loc.appSettingsUpdatedAt(when));
            }),
        ],
      ),
      trailing: _downloading
          ? const SizedBox.square(
              dimension: IconSizes.floating,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_list.isLoaded)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: loc.appSettingsClearDataset,
                    onPressed: _list.clear,
                  ),
                IconButton(
                  icon: Icon(_list.isLoaded ? Icons.sync : Icons.download),
                  tooltip: _list.isLoaded
                      ? loc.appSettingsRefreshDataset
                      : loc.appSettingsDownloadDataset,
                  onPressed: _download,
                ),
              ],
            ),
    );
  }
}
