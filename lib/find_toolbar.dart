import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class FindMatchesResult {
  int activeMatchOrdinal = 0;
  int numberOfMatches = 0;

  FindMatchesResult();
}

class FindToolbar extends StatefulWidget {
  final InAppWebViewController? webViewController;
  FindMatchesResult matches;
  Function onClose;

  FindToolbar({required this.webViewController, required this.matches, required this.onClose()});

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
                if (value.isNotEmpty) {
                  await widget.webViewController!.findAllAsync(find: value);
                } else {
                  await widget.webViewController!.clearMatches();
                }
                setState((){});
              },
            ),
          ),
          Text('${widget.matches.activeMatchOrdinal}/${widget.matches.numberOfMatches}'),
          IconButton(
            icon: Icon(Icons.navigate_before),
            onPressed: () async {
              await widget.webViewController!.findNext(forward: false);
            },
          ),
          IconButton(
            icon: Icon(Icons.navigate_next),
            onPressed: () async {
              await widget.webViewController!.findNext(forward: true);
            },
          ),
          IconButton(
            icon: Icon(Icons.close),
            onPressed: () {
              _searchController.clear();
              widget.webViewController!.clearMatches();
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
