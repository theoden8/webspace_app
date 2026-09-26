import 'package:flutter/foundation.dart';

class _Unread {
  int untagged = 0;
  final Set<String> tags = {};

  int get count => untagged + tags.length;
}

/// Web notifications each site posted while it was not on screen, for the
/// drawer and tab strip badges. A tagged post replaces the site's earlier
/// post with that tag, as the OS notification does (NOTIF-009). Cleared when
/// the user looks at the site.
///
/// Memory only: nothing here is written to disk or handed to the OS, so an
/// archive-tier or incognito site leaves no trace once it is forgotten.
class SiteUnreadService extends ChangeNotifier {
  SiteUnreadService._();
  static final SiteUnreadService instance = SiteUnreadService._();

  @visibleForTesting
  SiteUnreadService.forTest();

  /// Whether the user is looking at [siteId] right now. Set by the page that
  /// owns the site list; a post from the site on screen is already seen.
  bool Function(String siteId)? isOnScreen;

  final Map<String, _Unread> _unread = {};

  int count(String siteId) => _unread[siteId]?.count ?? 0;

  bool anyUnread(Iterable<String> siteIds) => siteIds.any((id) => count(id) > 0);

  void recordNotification(String siteId, {String? tag}) {
    if (isOnScreen?.call(siteId) ?? false) return;
    final unread = _unread.putIfAbsent(siteId, _Unread.new);
    if (tag == null || tag.isEmpty) {
      unread.untagged++;
    } else if (!unread.tags.add(tag)) {
      return;
    }
    notifyListeners();
  }

  void markSeen(String siteId) {
    if (_unread.remove(siteId) != null) notifyListeners();
  }

  /// Drops everything held for a site that is gone (deleted, left out of an
  /// import, archive closed).
  void forget(String siteId) => markSeen(siteId);

  /// [forget]s every site not in [siteIds].
  void retainOnly(Set<String> siteIds) {
    final before = _unread.length;
    _unread.removeWhere((id, _) => !siteIds.contains(id));
    if (_unread.length != before) notifyListeners();
  }
}
