import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import '../utils/url_utils.dart';

/// One of the user's search sites, as the URL bar offers it (LIR-033).
class UrlBarSearchSite {
  const UrlBarSearchSite(this.id, {required this.name});

  final String id;
  final String name;
}

class UrlBar extends StatefulWidget {
  final String currentUrl;
  final FutureOr<void> Function(String) onUrlSubmitted;

  /// Opens the site info sheet: which site the page runs as and which
  /// container holds its data. The button sits at the trailing end, which
  /// the row's text direction puts on the left in a right-to-left locale.
  final VoidCallback? onSiteInfo;

  /// The search sites the bar may search with, in the order its picker lists
  /// them (LIR-033).
  final List<UrlBarSearchSite> searchSites;

  /// The one a search starts with; null means the first of [searchSites].
  final String? defaultSearchSiteId;

  /// Runs a search for [query] with the search site [siteId], or, when there
  /// is none, lets the host offer one. Null leaves the bar an address field:
  /// no magnifier, and typed words are an address.
  final FutureOr<void> Function(String query, {required String? siteId})?
      onSearch;

  const UrlBar({
    super.key,
    required this.currentUrl,
    required this.onUrlSubmitted,
    this.onSiteInfo,
    this.searchSites = const [],
    this.defaultSearchSiteId,
    this.onSearch,
  });

  @override
  State<UrlBar> createState() => _UrlBarState();
}

class _UrlBarState extends State<UrlBar> {
  late TextEditingController _urlController;
  late FocusNode _focusNode;
  bool _isEditing = false;

  /// The magnifier turned the field into a search box.
  bool _searchMode = false;
  String? _searchSiteId;

  /// The search site picker has the focus; losing it to the menu is not the
  /// user leaving the field.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.currentUrl);
    _focusNode = FocusNode();

    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _isEditing && !_picking) {
        setState(() {
          _isEditing = false;
          _searchMode = false;
          _urlController.text = widget.currentUrl;
        });
      }
    });
  }

  @override
  void didUpdateWidget(UrlBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditing && widget.currentUrl != oldWidget.currentUrl) {
      _urlController.text = widget.currentUrl;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _canSearch => widget.onSearch != null;

  String? get _defaultSiteId {
    final sites = widget.searchSites;
    final id = widget.defaultSearchSiteId;
    if (id != null && sites.any((s) => s.id == id)) return id;
    return sites.isEmpty ? null : sites.first.id;
  }

  /// What Enter does with the text as typed: search, or open an address.
  bool get _submitSearches {
    if (!_canSearch) return false;
    if (_searchMode) return true;
    final text = _urlController.text.trim();
    return text.isNotEmpty && !looksLikeAddress(text);
  }

  UrlBarSearchSite? get _searchSite {
    final id = _searchMode ? _searchSiteId : _defaultSiteId;
    return widget.searchSites.where((s) => s.id == id).firstOrNull;
  }

  void _startSearch() {
    setState(() {
      _searchMode = true;
      _isEditing = true;
      _searchSiteId = _defaultSiteId;
      _urlController.clear();
    });
    _focusNode.requestFocus();
  }

  Future<void> _pickSearchSite(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    _picking = true;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        topLeft & box.size,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final s in widget.searchSites)
          CheckedPopupMenuItem<String>(
            value: s.id,
            checked: s.id == _searchSiteId,
            child: Text(s.name),
          ),
      ],
    );
    _picking = false;
    if (!mounted) return;
    if (picked != null) setState(() => _searchSiteId = picked);
    _focusNode.requestFocus();
  }

  Future<void> _handleSubmit() async {
    final typed = _urlController.text.trim();
    if (_submitSearches) {
      if (typed.isEmpty) return;
      final siteId = _searchSite?.id;
      _focusNode.unfocus();
      setState(() {
        _isEditing = false;
        _searchMode = false;
      });
      try {
        await widget.onSearch!(typed, siteId: siteId);
      } finally {
        if (mounted && !_isEditing) _urlController.text = widget.currentUrl;
      }
      return;
    }

    final url = ensureUrlScheme(typed);

    _focusNode.unfocus();
    setState(() => _isEditing = false);
    // A submit that does not navigate this webview (a cross-domain URL opens
    // a nested screen) leaves currentUrl unchanged, so didUpdateWidget never
    // fires and the typed text would outlive the nested screen.
    try {
      await widget.onUrlSubmitted(url);
    } finally {
      if (mounted && !_isEditing) _urlController.text = widget.currentUrl;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isSecure = widget.currentUrl.startsWith('https://');
    final searchSite = _searchSite;
    final searchLabel = searchSite == null
        ? loc.webSearchMenu
        : loc.webSearchFieldHint(searchSite.name);
Widget button(IconData icon,
        {required VoidCallback? onPressed, required String tooltip}) =>
    IconButton(
      icon: Icon(icon, size: IconSizes.action),
      onPressed: onPressed,
      padding: EdgeInsets.all(Spacing.xs),
      constraints: BoxConstraints(),
      tooltip: tooltip,
    );

    final Widget leading;
    if (!_searchMode) {
      leading = Icon(
        // Shape as well as colour: a closed padlock in a different green
        // is not a signal anyone can read at 16px, and reads as secure to
        // a colour-blind user on a plain http page.
        isSecure ? Icons.lock : Icons.lock_open,
        size: IconSizes.inline,
        color: isSecure
            ? SecurityIndicator.secure
            : SecurityIndicator.insecure,
      );
    } else {
      Icon glyph(IconData icon) => Icon(icon,
          size: IconSizes.inline, color: theme.colorScheme.primary);
      leading = widget.searchSites.length <= 1
          ? glyph(Icons.search)
          : Builder(
              builder: (anchor) => InkWell(
                onTap: () => _pickSearchSite(anchor),
                borderRadius: BorderRadius.circular(Radii.md),
                child: Tooltip(
                  message: loc.urlBarSearchSiteTooltip,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      glyph(Icons.search),
                      glyph(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
            );
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
      decoration: BoxDecoration(
        color: Chrome.bar(isDark: isDark),
        border: Border(
          top: BorderSide(
            color: Chrome.hairline(isDark: isDark),
            width: Chrome.hairlineWidth,
          ),
        ),
      ),
      child: Row(
        children: [
          leading,
          SizedBox(width: Spacing.sm),
          Expanded(
            child: TextField(
              controller: _urlController,
              focusNode: _focusNode,
              onTap: () {
                if (_searchMode) return;
                setState(() => _isEditing = true);
                _urlController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _urlController.text.length,
                );
              },
              // The trailing button says whether Enter searches or opens.
              onChanged: _canSearch ? (_) => setState(() {}) : null,
              onSubmitted: (_) => _handleSubmit(),
              decoration: InputDecoration(
                hintText: _searchMode ? searchLabel : loc.urlBarHint,
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: Spacing.sm, horizontal: Spacing.sm),
              ),
              style: TextStyle(
                fontSize: TextSizes.url,
                color: _isEditing
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurface.withOpacity(0.7),
              ),
              keyboardType:
                  _searchMode ? TextInputType.text : TextInputType.url,
              textInputAction: _searchMode
                  ? TextInputAction.search
                  : TextInputAction.go,
            ),
          ),
          if (_isEditing)
            _submitSearches
                ? button(Icons.search, onPressed: _handleSubmit, tooltip: searchLabel)
                : button(Icons.check, onPressed: _handleSubmit, tooltip: loc.urlBarGoTooltip)
          else ...[
            if (_canSearch)
              button(Icons.search, onPressed: _startSearch, tooltip: loc.webSearchMenu),
            if (widget.onSiteInfo != null)
              button(Icons.info_outline, onPressed: widget.onSiteInfo, tooltip: loc.siteInfoTitle),
          ],
        ],
      ),
    );
  }
}
