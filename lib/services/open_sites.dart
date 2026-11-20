import 'package:webspace/settings/site_ids.dart';

/// Which sites show their tabs in the site strip and the sidebar's squares.
/// The site on screen is open until shut; any other once opened. On a phone
/// ([single]) opening one closes every other, the site on screen included.
class OpenSites {
  const OpenSites({this.opened = const {}, this.shut = const {}});

  /// Sites other than the one on screen whose tabs the user opened.
  final Set<SiteId> opened;

  /// Sites whose tabs stay closed while they are on screen.
  final Set<SiteId> shut;

  bool isOpen(SiteId id, {required SiteId? current}) =>
      id == current ? !shut.contains(id) : opened.contains(id);

  /// [id]'s tabs opened if they were closed, closed if they were open.
  OpenSites toggle(SiteId id, {required SiteId? current, required bool single}) {
    final opening = !isOpen(id, current: current);
    final onScreen = id == current;
    var opened = {...this.opened};
    final shut = {...this.shut};
    if (onScreen) {
      opening ? shut.remove(id) : shut.add(id);
    } else {
      opening ? opened.add(id) : opened.remove(id);
    }
    if (single && opening) {
      opened = onScreen ? {} : {id};
      if (!onScreen && current != null) shut.add(current);
    }
    return OpenSites(opened: opened, shut: shut);
  }

  /// [to] has come on screen: it opens; on a phone the others close.
  OpenSites onSwitch({required SiteId to, required bool single}) => OpenSites(
        opened: single ? const {} : ({...opened}..remove(to)),
        shut: {...shut}..remove(to),
      );
}
