import 'package:webspace/settings/site_ids.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// A webspace's identity: random for one the user made, [WebspaceId.all]
/// for the collection that shows every site.
extension type const WebspaceId._(String raw) implements String {
  /// An id the app made or handed out before.
  factory WebspaceId(String raw) {
    assert(raw.isNotEmpty, 'a webspace id is not empty');
    return WebspaceId._(raw);
  }

  factory WebspaceId.mint() => WebspaceId._(_uuid.v4());

  static const all = WebspaceId._('__all_webspace__');

  static WebspaceId? parse(Object? raw) =>
      raw is String && raw.isNotEmpty ? WebspaceId._(raw) : null;
}

/// The symbol a user picked to stand beside a webspace's name; it is saved
/// by its name, and the screens draw it.
enum WebspaceGlyph {
  work,
  home,
  school,
  chat,
  mail,
  people,
  world,
  news,
  shopping,
  money,
  code,
  games,
  music,
  video,
  photos,
  books,
  travel,
  food,
  health,
  privacy;

  /// The glyph [stored] names; none for anything else.
  static WebspaceGlyph? of(Object? stored) =>
      stored is String ? values.asNameMap()[stored] : null;
}

class Webspace {
  WebspaceId id;
  String name;

  /// The symbol shown beside [name]; none until the user picks one.
  WebspaceGlyph? glyph;
  /// Persisted membership by `siteId`, ordered by display order.
  /// Single source of truth: archive open/close, app-tier index
  /// reshuffling from add/delete, and move-to-archive all preserve
  /// this list. The runtime [siteIndices] view is recomputed from it.
  List<SiteId> siteIds;
  /// Runtime projection: indices into `_WebSpacePageState._webViewModels`
  /// for the sites whose `siteId` is in [siteIds], in the same order.
  /// Recomputed by `_resolveWebspaceIndices` whenever `_webViewModels`
  /// changes. Never persisted; serialisation goes through [siteIds].
  List<int> siteIndices;
  /// Runtime-only marker for collections materialised from an open
  /// archive handle rather than app-tier SharedPreferences. Never
  /// serialised; `_saveWebspaces` filters on it so archive-tier
  /// collections never enter the app-tier persisted list.
  bool isArchiveTier;

  Webspace({
    WebspaceId? id,
    required this.name,
    this.glyph,
    List<SiteId>? siteIds,
    List<int>? siteIndices,
    this.isArchiveTier = false,
  })  : id = id ?? WebspaceId.mint(),
        siteIds = siteIds ?? <SiteId>[],
        siteIndices = siteIndices ?? <int>[];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (glyph case final glyph?) 'icon': glyph.name,
        'siteIds': siteIds,
      };

  factory Webspace.fromJson(Map<String, dynamic> json) {
    final rawSiteIds = json['siteIds'] is List ? json['siteIds'] as List : null;
    final legacyIndices =
        json['siteIndices'] is List ? json['siteIndices'] as List : null;
    // Legacy migration: old persisted form used positional `siteIndices`
    // (master schema). New form uses `siteIds` as source of truth. We
    // tolerate either or neither — `_loadWebspaces` wraps this in try/
    // catch but every field defends individually too (a partial-write
    // blob with the wrong shape on one field shouldn't sink the rest).
    // Legacy `siteIndices` lands in the runtime field unresolved;
    // `_migrateLegacyWebspaceIndices` in main.dart promotes it to
    // siteIds once `_webViewModels` is loaded.
    return Webspace(
      id: WebspaceId.parse(json['id']),
      name: json['name'] is String ? json['name'] as String : 'Untitled',
      glyph: WebspaceGlyph.of(json['icon']),
      siteIds: rawSiteIds?.map(SiteId.parse).nonNulls.toList(),
      siteIndices: legacyIndices?.whereType<int>().toList(),
    );
  }

  Webspace copyWith({
    WebspaceId? id,
    String? name,
    ({WebspaceGlyph? to})? glyph,
    List<SiteId>? siteIds,
    List<int>? siteIndices,
    bool? isArchiveTier,
  }) {
    return Webspace(
      id: id ?? this.id,
      name: name ?? this.name,
      glyph: glyph == null ? this.glyph : glyph.to,
      siteIds: siteIds ?? List<SiteId>.of(this.siteIds),
      siteIndices: siteIndices ?? List<int>.from(this.siteIndices),
      isArchiveTier: isArchiveTier ?? this.isArchiveTier,
    );
  }

  bool get isAll => id == WebspaceId.all;

  factory Webspace.all() {
    return Webspace(
      id: WebspaceId.all,
      name: 'All',
      siteIds: [], // Populated dynamically (renderer treats All as all sites)
      siteIndices: [],
    );
  }
}
