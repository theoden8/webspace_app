import 'dart:async';

import 'package:flutter/foundation.dart';

final _separator = RegExp(r'\s[-\u2013\u2014|\u00b7\u2022]\s');
const _countPattern = r'(\d{1,3}(?:[,.\u00a0\u202f]\d{3})+|\d+)\+?';
final _leadingCount = RegExp('^\\s*\\($_countPattern\\)');
final _trailingCount = RegExp('\\s\\($_countPattern\\)\\s*\$');

/// The unread count a page states in its own title, or null when the title
/// states none. Two placements are read, the ones chat and mail sites use in
/// a browser tab: a leading `(N)` (`(3) Messenger`) and a `(N)` closing the
/// title's first segment (`Inbox (3) - user@example.com - Mail`). A
/// parenthesised number anywhere else is part of the page's name.
int? unreadCountFromTitle(String? title) {
  if (title == null) return null;
  final leading = _leadingCount.firstMatch(title);
  if (leading != null) return _parse(leading.group(1)!);
  final head = title.split(_separator).first;
  final trailing = _trailingCount.firstMatch(head);
  if (trailing != null) return _parse(trailing.group(1)!);
  return null;
}

int? _parse(String digits) =>
    int.tryParse(digits.replaceAll(RegExp(r'[^\d]'), ''));

class _Missed {
  int untagged = 0;
  final Set<String> tags = {};

  int get count => untagged + tags.length;
}

/// Per-site unread state for the drawer and tab strip badges. Two sources:
///
/// * the count the page states in its title ([unreadCountFromTitle]), which
///   lives as long as the page does and follows it, so it clears when the
///   user reads the messages, not when the site is merely opened;
/// * notifications the site posted while it was not on screen, which clear
///   when the user looks at the site. A tagged post replaces the site's
///   earlier post with that tag, as the OS notification does (NOTIF-009).
///
/// Memory only: nothing here is written to disk or handed to the OS, so an
/// archive-tier or incognito site leaves no trace once it is forgotten.
class SiteUnreadService extends ChangeNotifier {
  SiteUnreadService._();
  static final SiteUnreadService instance = SiteUnreadService._();

  @visibleForTesting
  SiteUnreadService.forTest();

  /// A title without a count only clears a stated count once it has held for
  /// this long. Chat pages alternate their title between the count and a
  /// "New message" line to draw the eye; applying every change would blink
  /// the badge in step.
  static const clearDelay = Duration(seconds: 5);

  /// Whether the user is looking at [siteId] right now. Set by the page that
  /// owns the site list; a post from the site on screen is already seen.
  bool Function(String siteId)? isOnScreen;

  final Map<String, int> _pageCounts = {};
  final Map<String, Timer> _pendingClears = {};
  final Map<String, _Missed> _missed = {};

  /// The count the site's page states in its title, 0 when none.
  int pageCount(String siteId) => _pageCounts[siteId] ?? 0;

  /// Notifications posted since the user last looked at the site.
  int missedCount(String siteId) => _missed[siteId]?.count ?? 0;

  /// What the badge shows: the page's own count when it states one, which is
  /// the authoritative number, otherwise the notifications the user missed.
  int count(String siteId) {
    final page = pageCount(siteId);
    return page > 0 ? page : missedCount(siteId);
  }

  bool anyUnread(Iterable<String> siteIds) => siteIds.any((id) => count(id) > 0);

  void onTitleChanged(String siteId, String? title) {
    final stated = unreadCountFromTitle(title);
    if (stated != null) {
      _pendingClears.remove(siteId)?.cancel();
      _setPageCount(siteId, stated);
      return;
    }
    if (pageCount(siteId) == 0 || _pendingClears.containsKey(siteId)) return;
    _pendingClears[siteId] = Timer(clearDelay, () {
      _pendingClears.remove(siteId);
      _setPageCount(siteId, 0);
    });
  }

  void recordNotification(String siteId, {String? tag}) {
    if (isOnScreen?.call(siteId) ?? false) return;
    final missed = _missed.putIfAbsent(siteId, _Missed.new);
    if (tag == null || tag.isEmpty) {
      missed.untagged++;
    } else if (!missed.tags.add(tag)) {
      return;
    }
    notifyListeners();
  }

  /// The user is looking at [siteId]: its missed notifications are seen. The
  /// page's own count stays, since opening a site does not read its messages.
  void markSeen(String siteId) {
    if (_missed.remove(siteId) != null) notifyListeners();
  }

  /// The site's page is gone (webview disposed), so the count it stated no
  /// longer describes anything.
  void clearPageCount(String siteId) {
    _pendingClears.remove(siteId)?.cancel();
    _setPageCount(siteId, 0);
  }

  /// Drops everything held for [siteId] (site deleted, archive closed).
  void forget(String siteId) {
    _pendingClears.remove(siteId)?.cancel();
    final hadPage = _pageCounts.remove(siteId) != null;
    final hadMissed = _missed.remove(siteId) != null;
    if (hadPage || hadMissed) notifyListeners();
  }

  /// [forget]s every site not in [siteIds].
  void retainOnly(Set<String> siteIds) {
    final gone = {..._pageCounts.keys, ..._missed.keys, ..._pendingClears.keys}
        .where((id) => !siteIds.contains(id))
        .toList();
    for (final id in gone) {
      forget(id);
    }
  }

  void _setPageCount(String siteId, int value) {
    if (pageCount(siteId) == value) return;
    if (value == 0) {
      _pageCounts.remove(siteId);
    } else {
      _pageCounts[siteId] = value;
    }
    notifyListeners();
  }
}
