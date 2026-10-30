import 'package:flutter/widgets.dart';

/// One layer of the page's stack, the library or the sites, kept mounted
/// while another is on screen so its webviews keep their state. While not
/// shown it is neither painted nor focusable: [Offstage] alone leaves focus
/// where it was, so a remote's arrows went on to a hidden page or moved among
/// controls nobody could see (NAV-016).
class PageLayer extends StatelessWidget {
  const PageLayer({super.key, required this.shown, required this.child});

  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) => Offstage(
        offstage: !shown,
        child: ExcludeFocus(excluding: !shown, child: child),
      );
}
