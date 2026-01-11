import 'package:flutter/material.dart';

class UrlBar extends StatefulWidget {
  final String currentUrl;
  final Function(String) onUrlSubmitted;

  const UrlBar({
    Key? key,
    required this.currentUrl,
    required this.onUrlSubmitted,
  }) : super(key: key);

  @override
  _UrlBarState createState() => _UrlBarState();
}

class _UrlBarState extends State<UrlBar> {
  late TextEditingController _urlController;
  late FocusNode _focusNode;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.currentUrl);
    _focusNode = FocusNode();

    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _isEditing) {
        setState(() {
          _isEditing = false;
          _urlController.text = widget.currentUrl;
        });
      }
    });
  }

  @override
  void didUpdateWidget(UrlBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update the displayed URL when navigating (but not while editing)
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

  void _handleSubmit() {
    String url = _urlController.text.trim();

    // Infer protocol if not specified
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }

    widget.onUrlSubmitted(url);
    _focusNode.unfocus();
    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? Color(0xFF1E1E1E) : Color(0xFFF5F5F5),
        border: Border(
          bottom: BorderSide(
            color: isDark ? Color(0xFF3E3E3E) : Color(0xFFE0E0E0),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock,
            size: 16,
            color: widget.currentUrl.startsWith('https://')
                ? Colors.green
                : Colors.grey,
          ),
          SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _urlController,
              focusNode: _focusNode,
              onTap: () {
                setState(() {
                  _isEditing = true;
                });
                _urlController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _urlController.text.length,
                );
              },
              onSubmitted: (_) => _handleSubmit(),
              decoration: InputDecoration(
                hintText: 'Enter URL',
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              ),
              style: TextStyle(
                fontSize: 14,
                color: _isEditing
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurface.withOpacity(0.7),
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
            ),
          ),
          if (_isEditing)
            IconButton(
              icon: Icon(Icons.check, size: 20),
              onPressed: _handleSubmit,
              padding: EdgeInsets.all(4),
              constraints: BoxConstraints(),
              tooltip: 'Go',
            ),
        ],
      ),
    );
  }
}
