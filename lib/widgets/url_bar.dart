import 'package:flutter/material.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import '../utils/url_utils.dart';

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
    url = ensureUrlScheme(url);

    widget.onUrlSubmitted(url);
    _focusNode.unfocus();
    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
      decoration: BoxDecoration(
        color: Chrome.bar(isDark),
        border: Border(
          top: BorderSide(
            color: Chrome.hairline(isDark),
            width: Chrome.hairlineWidth,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock,
            size: IconSizes.inline,
            color: widget.currentUrl.startsWith('https://')
                ? SecurityIndicator.secure
                : SecurityIndicator.insecure,
          ),
          SizedBox(width: Spacing.sm),
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
                hintText: loc.urlBarHint,
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
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
            ),
          ),
          if (_isEditing)
            IconButton(
              icon: Icon(Icons.check, size: IconSizes.action),
              onPressed: _handleSubmit,
              padding: EdgeInsets.all(Spacing.xs),
              constraints: BoxConstraints(),
              tooltip: loc.urlBarGoTooltip,
            ),
        ],
      ),
    );
  }
}
