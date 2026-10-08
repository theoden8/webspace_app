/// A tab of one site.
///
/// Spec: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md`
/// (TAB-001..TAB-003), and LIR-018 for hosted tabs.
///
/// A tab renders inside the container and posture of the site it runs as: its
/// owner, or the site named by [SiteTab.hostSiteId]. Its [url] stays inside
/// that site's domain, except for a tab a link opened while its opener's
/// routing was off (LIR-034), which stays inside the link's domain. Either
/// way "which container does this tab use" has exactly one answer, the site
/// it runs as. A site holds one live webview,
/// bound to its active tab; every other tab is parked — this record in
/// SharedPreferences plus, when it has a back/forward stack worth keeping, one
/// encrypted file under the key [webViewStateKey] names. No renderer, no
/// native object.
library;

import 'dart:math';

/// Id of the tab a site starts with, and of the one synthesised when legacy
/// JSON (no `tabs` key) is rehydrated.
///
/// Fixed rather than generated so the single-tab case round-trips: its
/// navigation-state file keeps the same name across restarts even though
/// serialisation omits the tab list entirely.
const String kPrimaryTabId = 'main';

/// A tab id is concatenated into a state-storage file name, so it takes the
/// same path-safe shape as a siteId — minus `.`, which separates the two
/// halves of a state key.
final RegExp _kTabIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Same shape as `sanitizedSiteId` in `web_view_model.dart`, which this file
/// cannot import without a cycle.
final RegExp _kHostSiteIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

String? sanitizedTabId(Object? raw) {
  if (raw is! String) return null;
  return _kTabIdPattern.hasMatch(raw) ? raw : null;
}

String generateTabId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final random = Random().nextInt(999999);
  return 't${now.toRadixString(36)}-${random.toRadixString(36)}';
}

/// Storage key for one tab's `controller.saveState()` bytes.
///
/// `.` is the separator because neither half can contain one: both are
/// `[A-Za-z0-9_-]`. That keeps `<siteId>.` a sound prefix for "every state
/// file this site owns", which is what site deletion and archive close sweep
/// on.
String webViewStateKey(String siteId, {required String tabId}) =>
    '$siteId.$tabId';

class SiteTab {
  SiteTab({
    String? id,
    required this.url,
    this.title,
    this.parentId,
    this.hostSiteId,
    this.openerSiteId,
    this.homeUrl,
    DateTime? createdAt,
    DateTime? lastActiveAt,
  })  : id = id ?? generateTabId(),
        createdAt = createdAt ?? DateTime.now(),
        lastActiveAt = lastActiveAt ?? createdAt ?? DateTime.now();

  /// The tab a site starts with. See [kPrimaryTabId].
  SiteTab.primary({required String url, String? title})
      : this(id: kPrimaryTabId, url: url, title: title);

  final String id;
  String url;
  String? title;

  /// The tab this one was opened from, or null for a root tab. Always another
  /// tab of the same site's list, though it may run in another container.
  String? parentId;

  /// The site this tab runs as when it is not its owner (LIR-018): its
  /// container, posture and navigation rules. Null means the owner. The owner
  /// normalises its own id to null, so a value always names another site.
  String? hostSiteId;

  /// The site whose page opened this tab from a link into one of the user's
  /// sites (LIR-034), or null for a tab nothing routes: one the user opened
  /// by hand, a search's results, a link inside the page's own domain. Its
  /// routing switch decides the container: on, the tab runs as the site the
  /// link leads to; off, as the opener. May name the owner.
  String? openerSiteId;

  /// The link such a tab was opened at. The tab navigates inside this URL's
  /// domain whatever it runs as, which is what lets a flip of the opener's
  /// switch move it between containers without moving it between domains.
  String? homeUrl;

  /// Whether the opener's routing switch decides this tab's container.
  bool get followsOpener => openerSiteId != null && homeUrl != null;

  final DateTime createdAt;
  DateTime lastActiveAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        if (title != null) 'title': title,
        if (parentId != null) 'parentId': parentId,
        if (hostSiteId != null) 'hostSiteId': hostSiteId,
        if (openerSiteId != null) 'openerSiteId': openerSiteId,
        if (homeUrl != null) 'homeUrl': homeUrl,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastActiveAt': lastActiveAt.millisecondsSinceEpoch,
      };

  /// Null for a record that cannot name a tab: no usable id, or no url. A
  /// partial write or a hand-edited backup drops that entry rather than
  /// sinking the whole site.
  static SiteTab? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<dynamic, dynamic>();
    final id = sanitizedTabId(json['id']);
    final url = json['url'];
    if (id == null || url is! String || url.isEmpty) return null;
    return SiteTab(
      id: id,
      url: url,
      title: json['title'] is String ? json['title'] as String : null,
      parentId: sanitizedTabId(json['parentId']),
      hostSiteId: json['hostSiteId'] is String &&
              _kHostSiteIdPattern.hasMatch(json['hostSiteId'] as String)
          ? json['hostSiteId'] as String
          : null,
      openerSiteId: json['openerSiteId'] is String &&
              _kHostSiteIdPattern.hasMatch(json['openerSiteId'] as String)
          ? json['openerSiteId'] as String
          : null,
      homeUrl: _webUrl(json['homeUrl']),
      createdAt: _time(json['createdAt']),
      lastActiveAt: _time(json['lastActiveAt']),
    );
  }

  /// The id of the entry a serialised tab list marks `active`, if any. The
  /// mark lives in the list rather than beside it, so a list that is dropped
  /// on load takes its active tab with it and leaves no other key changed.
  static String? activeIdIn(List<dynamic>? raw) {
    for (final entry in raw ?? const <dynamic>[]) {
      if (entry is Map && entry['active'] == true) {
        return sanitizedTabId(entry['id']);
      }
    }
    return null;
  }

  /// An http(s) URL with a host, or null: a home URL names the domain a tab
  /// navigates in, so anything else would leave that domain undefined.
  static String? _webUrl(Object? raw) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.scheme == 'http' || uri.scheme == 'https' ? raw : null;
  }

  static DateTime? _time(Object? raw) => raw is int
      ? DateTime.fromMillisecondsSinceEpoch(raw)
      : null;

  @override
  String toString() => 'SiteTab($id, $url'
      '${parentId == null ? '' : ', parent=$parentId'}'
      '${hostSiteId == null ? '' : ', host=$hostSiteId'}'
      '${openerSiteId == null ? '' : ', opener=$openerSiteId'})';
}
