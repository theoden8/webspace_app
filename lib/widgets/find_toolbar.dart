import 'package:flutter/material.dart';
import 'package:webspace/platform/webview_factory.dart';
import 'package:webspace/platform/unified_webview.dart';

class FindToolbar extends StatefulWidget {
  final UnifiedWebViewController? webViewController;
  final UnifiedFindMatchesResult matches;
  final Function onClose;

  FindToolbar({
    required this.webViewController,
    required this.matches,
    required this.onClose,
  });

  @override
  _FindToolbarState createState() => _FindToolbarState();
}

class _FindToolbarState extends State<FindToolbar> {
  TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search on page',
              ),
              onChanged: (value) async {
                if (widget.webViewController != null) {
                  if (value.isNotEmpty) {
                    await widget.webViewController!.findAllAsync(find: value);
                  } else {
                    await widget.webViewController!.clearMatches();
                  }
                  setState(() {});
                }
              },
            ),
          ),
          Text('${widget.matches.activeMatchOrdinal}/${widget.matches.numberOfMatches}'),
          IconButton(
            icon: Icon(Icons.navigate_before),
            onPressed: () async {
              if (widget.webViewController != null) {
                await widget.webViewController!.findNext(forward: false);
              }
            },
          ),
          IconButton(
            icon: Icon(Icons.navigate_next),
            onPressed: () async {
              if (widget.webViewController != null) {
                await widget.webViewController!.findNext(forward: true);
              }
            },
          ),
          IconButton(
            icon: Icon(Icons.close),
            onPressed: () {
              _searchController.clear();
              if (widget.webViewController != null) {
                widget.webViewController!.clearMatches();
              }
              setState(() {
                widget.matches.numberOfMatches = 0;
                widget.matches.activeMatchOrdinal = 0;
              });
              widget.onClose();
            },
          ),
        ],
      ),
    );
  }
}
