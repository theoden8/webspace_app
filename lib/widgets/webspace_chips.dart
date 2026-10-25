import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/webspace_name.dart';

/// The named webspaces a form offers a site, and those picked for it as the
/// form is edited. "All" is never offered: it holds every site.
class WebspacePick extends ValueNotifier<Set<WebspaceId>> {
  WebspacePick({required this.offered, required Set<WebspaceId> picked})
    : assert(
        offered.every((space) => !space.isAll),
        'All holds every site, so it is not offered',
      ),
      super(picked);

  final List<Webspace> offered;

  /// Picks [space] or drops it, from the pick as it stands now rather than as
  /// the chips last drew it, so two taps in one frame both count.
  void mark(WebspaceId space, {required bool picked}) {
    value = picked ? {...value, space} : ({...value}..remove(space));
  }
}

/// One chip per webspace [pick] offers, marked while picked; a tap picks or
/// drops it.
class WebspaceChips extends StatelessWidget {
  const WebspaceChips({super.key, required this.pick});

  final WebspacePick pick;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          loc.libraryWebspaces,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: Spacing.sm),
        ValueListenableBuilder<Set<WebspaceId>>(
          valueListenable: pick,
          builder: (context, picked, _) => Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final space in pick.offered)
                FilterChip(
                  label: WebspaceName(space),
                  selected: picked.contains(space.id),
                  onSelected: (on) => pick.mark(space.id, picked: on),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
