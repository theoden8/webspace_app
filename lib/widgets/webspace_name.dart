import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/launcher_row.dart';

/// How a [WebspaceGlyph] is drawn and read out; a glyph with neither does
/// not compile.
extension WebspaceGlyphLook on WebspaceGlyph {
  IconData get icon => switch (this) {
    WebspaceGlyph.work => Icons.work_outline,
    WebspaceGlyph.home => Icons.home_outlined,
    WebspaceGlyph.school => Icons.school_outlined,
    WebspaceGlyph.chat => Icons.chat_bubble_outline,
    WebspaceGlyph.mail => Icons.mail_outline,
    WebspaceGlyph.people => Icons.people_outline,
    WebspaceGlyph.world => Icons.public,
    WebspaceGlyph.news => Icons.newspaper,
    WebspaceGlyph.shopping => Icons.shopping_bag_outlined,
    WebspaceGlyph.money => Icons.account_balance_wallet_outlined,
    WebspaceGlyph.code => Icons.code,
    WebspaceGlyph.games => Icons.sports_esports_outlined,
    WebspaceGlyph.music => Icons.music_note_outlined,
    WebspaceGlyph.video => Icons.smart_display_outlined,
    WebspaceGlyph.photos => Icons.photo_outlined,
    WebspaceGlyph.books => Icons.menu_book_outlined,
    WebspaceGlyph.travel => Icons.flight_outlined,
    WebspaceGlyph.food => Icons.restaurant_outlined,
    WebspaceGlyph.health => Icons.favorite_outline,
    WebspaceGlyph.privacy => Icons.lock_outline,
  };

  String label(AppLocalizations loc) => switch (this) {
    WebspaceGlyph.work => loc.webspaceGlyphWork,
    WebspaceGlyph.home => loc.webspaceGlyphHome,
    WebspaceGlyph.school => loc.webspaceGlyphSchool,
    WebspaceGlyph.chat => loc.webspaceGlyphChat,
    WebspaceGlyph.mail => loc.webspaceGlyphMail,
    WebspaceGlyph.people => loc.webspaceGlyphPeople,
    WebspaceGlyph.world => loc.webspaceGlyphWorld,
    WebspaceGlyph.news => loc.webspaceGlyphNews,
    WebspaceGlyph.shopping => loc.webspaceGlyphShopping,
    WebspaceGlyph.money => loc.webspaceGlyphMoney,
    WebspaceGlyph.code => loc.webspaceGlyphCode,
    WebspaceGlyph.games => loc.webspaceGlyphGames,
    WebspaceGlyph.music => loc.webspaceGlyphMusic,
    WebspaceGlyph.video => loc.webspaceGlyphVideo,
    WebspaceGlyph.photos => loc.webspaceGlyphPhotos,
    WebspaceGlyph.books => loc.webspaceGlyphBooks,
    WebspaceGlyph.travel => loc.webspaceGlyphTravel,
    WebspaceGlyph.food => loc.webspaceGlyphFood,
    WebspaceGlyph.health => loc.webspaceGlyphHealth,
    WebspaceGlyph.privacy => loc.webspaceGlyphPrivacy,
  };
}

/// A webspace's name as every screen shows it: led by its glyph where the
/// user picked one.
class WebspaceName extends StatelessWidget {
  const WebspaceName(
    this.webspace, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.textAlign,
  });

  final Webspace webspace;
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Text.rich(
    namedSpan(
      context,
      name: webspace.name,
      icon: webspace.glyph?.icon,
      style: style,
    ),
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    textAlign: textAlign,
  );
}

/// An open folder's name, as a launcher's: a tap or a hold on it edits it
/// in place, saved as the field is left or submitted, and a tap on the glyph
/// before it, or on the place one would go while the name is edited, picks
/// another (WEBSPACE-018). With no [onRetitle] (All) it is only shown.
class EditableWebspaceName extends StatefulWidget {
  const EditableWebspaceName(
    this.webspace, {
    super.key,
    required this.style,
    required this.onRetitle,
  });

  final Webspace webspace;
  final TextStyle? style;
  final ValueChanged<WebspaceTitle>? onRetitle;

  @override
  State<EditableWebspaceName> createState() => _EditableWebspaceNameState();
}

class _EditableWebspaceNameState extends State<EditableWebspaceName> {
  final _name = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    final name = widget.webspace.name;
    _name.value = TextEditingValue(
      text: name,
      selection: TextSelection(baseOffset: 0, extentOffset: name.length),
    );
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  void _commit() {
    setState(() => _editing = false);
    final name = _name.text.trim();
    if (name == widget.webspace.name) return;
    widget.onRetitle?.call((name: name, glyph: widget.webspace.glyph));
  }

  Future<void> _pickGlyph() async {
    final picked = await pickWebspaceGlyph(
      context,
      current: widget.webspace.glyph,
    );
    if (picked == null || !mounted) return;
    widget.onRetitle?.call((name: widget.webspace.name, glyph: picked.to));
  }

  @override
  Widget build(BuildContext context) {
    final onRetitle = widget.onRetitle;
    if (onRetitle == null) {
      return WebspaceName(widget.webspace, style: widget.style);
    }
    final loc = AppLocalizations.of(context);
    final glyph = widget.webspace.glyph;
    final size = MediaQuery.textScalerOf(context).scale(
      (widget.style?.fontSize ??
              DefaultTextStyle.of(context).style.fontSize ??
              14) *
          LibraryStyle.glyphScale,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (glyph != null || _editing)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: Spacing.xs),
            child: Tooltip(
              message: loc.webspaceGlyphTitle,
              child: InkResponse(
                onTap: () => unawaited(_pickGlyph()),
                radius: size,
                child: Icon(
                  glyph?.icon ?? Icons.add_circle_outline,
                  size: size,
                ),
              ),
            ),
          ),
        Flexible(
          child: _editing
              ? TextField(
                  controller: _name,
                  focusNode: _focus,
                  style: widget.style,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration.collapsed(
                    hintText: loc.libraryRenameWebspace,
                  ),
                  onSubmitted: (_) => _focus.unfocus(),
                )
              : Semantics(
                  button: true,
                  hint: loc.libraryRenameWebspace,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _edit,
                    onLongPress: _edit,
                    child: Text(
                      widget.webspace.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: widget.style,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Asks for the glyph to show beside a webspace's name, [current] marked:
/// a glyph, `(to: null)` for none, or null when the user turned away.
Future<({WebspaceGlyph? to})?> pickWebspaceGlyph(
  BuildContext context, {
  required WebspaceGlyph? current,
}) {
  final loc = AppLocalizations.of(context);
  final theme = Theme.of(context);
  Widget choice(BuildContext dialog, {required WebspaceGlyph glyph}) {
    final picked = glyph == current;
    return IconButton(
      tooltip: glyph.label(loc),
      isSelected: picked,
      style: IconButton.styleFrom(
        backgroundColor: picked ? theme.colorScheme.primaryContainer : null,
      ),
      onPressed: () => Navigator.pop(dialog, (to: glyph)),
      icon: Icon(glyph.icon),
    );
  }

  return showDialog<({WebspaceGlyph? to})>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(loc.webspaceGlyphTitle),
      content: SingleChildScrollView(
        child: Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final glyph in WebspaceGlyph.values)
              choice(dialog, glyph: glyph),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, (to: null)),
          child: Text(loc.webspaceGlyphNone),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(loc.commonCancel),
        ),
      ],
    ),
  );
}
