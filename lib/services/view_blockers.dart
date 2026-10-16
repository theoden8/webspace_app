import 'package:webspace/settings/site_ids.dart';

/// What a live site webview is told about its blockers: its site, the
/// level it runs at, whether LocalCDN serves it and whether the filter lists
/// judge it.
typedef ViewAttach = ({
  Object view,
  SiteId site,
  int dnsLevel,
  bool localCdn,
  bool contentBlock,
});

/// One site webview as its native interceptor was last told (DNS-022).
final class _View {
  _View({
    required this.site,
    required this.siteLevel,
    required this.localCdn,
    required this.contentBlock,
    required this.told,
  });

  final SiteId site;

  /// The level the site asks for, as `resolveDnsLevel` takes it: null to
  /// follow the app-wide level, `kDnsLevelOff` when its DNS blocking is off.
  final int? siteLevel;
  final bool localCdn;
  final bool contentBlock;
  int told;
}

/// Which DNS level each live site webview has told its native interceptor:
/// the model's `told`. A view registers as it is built, at its site's level,
/// and leaves as it goes. When the blockers' data moves, every view whose
/// site now resolves to another level is told it, so a level that lands, or
/// an app-wide level the user downloads, reaches a page without a rebuild.
final class ViewBlockers {
  ViewBlockers({required this.send, required this.resolve});

  /// Sends one view its blockers; the native interceptor's attach.
  final void Function(ViewAttach attach) send;

  /// The level a site asking for [siteLevel] runs at now.
  final int Function(int? siteLevel) resolve;

  final Map<Object, _View> _views = {};

  /// [view] is built for [site]: it attaches at the level its site resolves
  /// to now, and is told again whenever that moves. Returns that level.
  int built(
    Object view, {
    required SiteId site,
    required int? siteLevel,
    required bool localCdn,
    required bool contentBlock,
  }) {
    final level = resolve(siteLevel);
    _views[view] = _View(
      site: site,
      siteLevel: siteLevel,
      localCdn: localCdn,
      contentBlock: contentBlock,
      told: level,
    );
    return level;
  }

  /// [view] has left the tree: nothing tells it any more.
  void gone(Object view) => _views.remove(view);

  /// The blockers' data moved: each view whose site resolves elsewhere now
  /// is told so.
  void changed() => tell({
    for (final v in _views.values) v.site: resolve(v.siteLevel),
  });

  /// Each view whose site [to] names at another level than it was told is
  /// told that level, which must be the one its site resolves to: a table
  /// tells the model's level, which [resolve] recomputes from the lists in
  /// force.
  void tell(Map<SiteId, int> to) {
    for (final MapEntry(key: view, value: v) in _views.entries) {
      final now = to[v.site];
      if (now == null) continue;
      assert(
        now == resolve(v.siteLevel),
        "${v.site}'s view is told DNS level $now where its site resolves to "
        '${resolve(v.siteLevel)} (DNS-022)',
      );
      if (now == v.told) continue;
      v.told = now;
      send((
        view: view,
        site: v.site,
        dnsLevel: now,
        localCdn: v.localCdn,
        contentBlock: v.contentBlock,
      ));
    }
  }

  /// The level each site's webview was last told, by site: the model's
  /// `told`, where a site with no webview is absent.
  Map<SiteId, int> get told => {
    for (final v in _views.values) v.site: v.told,
  };

  /// The level each site with a webview asks for, by site.
  Map<SiteId, int?> get siteLevels => {
    for (final v in _views.values) v.site: v.siteLevel,
  };
}
