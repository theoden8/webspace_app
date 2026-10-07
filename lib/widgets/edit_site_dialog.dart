import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/add_site.dart'
    show FaviconUrlCache, UnifiedFaviconImage;
import 'package:webspace/services/custom_icon.dart';
import 'package:webspace/services/page_title.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/toast.dart';

/// The edit the user saved: the trimmed name, the URL with its scheme
/// inferred, and the icon only when one was picked or reset.
typedef SiteEdit = ({String name, String url, ({Uint8List? png})? icon});

Future<SiteEdit?> showEditSiteDialog(BuildContext context, WebViewModel site) =>
    showDialog<SiteEdit>(
      context: context,
      builder: (_) => EditSiteDialog(site: site),
    );

class EditSiteDialog extends StatefulWidget {
  const EditSiteDialog({super.key, required this.site});

  final WebViewModel site;

  @override
  State<EditSiteDialog> createState() => _EditSiteDialogState();
}

class _EditSiteDialogState extends State<EditSiteDialog> {
  late final _name = TextEditingController(text: widget.site.name);
  late final _url = TextEditingController(text: widget.site.initUrl);
  late Uint8List? _icon = widget.site.customIconPng;
  var _iconChanged = false;
  final _iconPick = ReentryGuard();
  final _refresh = ReentryGuard();

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _pickIcon() => _iconPick.run(() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'ico'],
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    Uint8List? raw = file.bytes;
    if (raw == null && file.path != null) {
      raw = await hostReadFileBytes(file.path!);
    }
    final processed = raw == null
        ? null
        : await processCustomIconImageAsync(raw);
    if (!mounted) return;
    if (processed == null) {
      ScaffoldMessenger.of(context).toast(
        AppLocalizations.of(context).addSiteFileReadError,
      );
      return;
    }
    setState(() {
      _icon = processed;
      _iconChanged = true;
    });
  });

  Future<void> _refreshTitleAndIcon() async {
    try {
      await _refresh.run(() async {
        setState(() {});
        final site = widget.site;
        // Invalidating the favicon cache re-fetches the preview
        // (UnifiedFaviconImage listens for it); the fetched title lands in the
        // name field, applied on Save like any other edit.
        await FaviconUrlCache.invalidate(site.initUrl);
        final title = await getPageTitle(site.initUrl,
            proxy: site.outboundProxySettings);
        if (!mounted || title == null || title.isEmpty) return;
        _name.text = title;
        ScaffoldMessenger.of(context).toast(
          AppLocalizations.of(context).homeTitleUpdatedTo(title),
        );
      });
    } finally {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final site = widget.site;
    final icon = _icon;
    const urlHint = 'http://example.com:8080';
    return AlertDialog(
      title: Text(loc.homeEditSiteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: loc.homeSiteNameLabel,
              hintText: loc.homeSiteNameHint,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: loc.homeUrlLabel,
              hintText: urlHint,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            loc.homeUrlSchemeTip,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: icon != null
                    ? Image.memory(
                        icon,
                        width: 32,
                        height: 32,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    : UnifiedFaviconImage(
                        url: site.initUrl,
                        size: 32,
                        proxy: site.outboundProxySettings,
                        persist: !site.isArchiveTier,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    icon: const Icon(Icons.image_outlined),
                    label: Text(loc.homeSiteIconPick),
                    onPressed: _pickIcon,
                  ),
                ),
              ),
              if (icon != null)
                IconButton(
                  icon: const Icon(Icons.restart_alt),
                  tooltip: loc.homeSiteIconReset,
                  onPressed: () => setState(() {
                    _icon = null;
                    _iconChanged = true;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: _refresh.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(loc.homeRefreshTitleAndIcon),
              onPressed: _refresh.busy ? null : _refreshTitleAndIcon,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop<SiteEdit>(context, (
            name: _name.text.trim(),
            url: ensureUrlScheme(_url.text.trim()),
            icon: _iconChanged ? (png: _icon) : null,
          )),
          child: Text(loc.commonSave),
        ),
      ],
    );
  }
}
