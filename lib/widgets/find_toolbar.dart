import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';

class FindToolbar extends StatefulWidget {
  final WebViewController? webViewController;
  final FindMatchesResult matches;
  final VoidCallback onClose;

  const FindToolbar({
    super.key,
    required this.webViewController,
    required this.matches,
    required this.onClose,
  });

  @override
  State<FindToolbar> createState() => _FindToolbarState();
}

class _FindToolbarState extends State<FindToolbar> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _close() {
    _searchController.clear();
    unawaited(widget.webViewController?.clearMatches());
    setState(() {
      widget.matches.numberOfMatches = 0;
      widget.matches.activeMatchOrdinal = 0;
    });
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final controller = widget.webViewController;
    final matchCounter =
        '${widget.matches.activeMatchOrdinal}/${widget.matches.numberOfMatches}';
    // Escape is the app's DismissIntent, which the search field hands up when
    // it has no toolbar of its own to hide.
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            _close();
            return null;
          },
        ),
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: loc.findToolbarSearchHint,
                ),
                onChanged: (value) async {
                  if (controller == null) return;
                  if (value.isNotEmpty) {
                    await controller.findAllAsync(find: value);
                  } else {
                    await controller.clearMatches();
                  }
                  setState(() {});
                },
              ),
            ),
            Text(matchCounter),
            IconButton(
              icon: Icon(Icons.navigate_before),
              onPressed: () => controller?.findNext(forward: false),
            ),
            IconButton(
              icon: Icon(Icons.navigate_next),
              onPressed: () => controller?.findNext(forward: true),
            ),
            IconButton(icon: Icon(Icons.close), onPressed: _close),
          ],
        ),
      ),
    );
  }
}
