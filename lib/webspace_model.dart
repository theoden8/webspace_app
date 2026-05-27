import 'package:uuid/uuid.dart';

const _uuid = Uuid();

// Special ID for the "All" webspace that contains all sites
const String kAllWebspaceId = '__all_webspace__';

class Webspace {
  String id; // Unique identifier for the webspace
  String name; // Display name for the webspace
  /// Persisted membership by `siteId`, ordered by display order.
  /// Single source of truth: archive open/close, app-tier index
  /// reshuffling from add/delete, and move-to-archive all preserve
  /// this list. The runtime [siteIndices] view is recomputed from it.
  List<String> siteIds;
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
    String? id,
    required this.name,
    List<String>? siteIds,
    List<int>? siteIndices,
    this.isArchiveTier = false,
  })  : id = id ?? _uuid.v4(),
        siteIds = siteIds ?? <String>[],
        siteIndices = siteIndices ?? <int>[];

  // Serialization methods
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'siteIds': siteIds,
      };

  factory Webspace.fromJson(Map<String, dynamic> json) {
    final rawSiteIds = json['siteIds'] as List<dynamic>?;
    final legacyIndices = json['siteIndices'] as List<dynamic>?;
    // Legacy migration: old persisted form used positional `siteIndices`
    // (master schema). New form uses `siteIds` as source of truth. We
    // tolerate either or neither — `_loadWebspaces` wraps this in try/
    // catch but every field defends individually too (a partial-write
    // blob with the wrong shape on one field shouldn't sink the rest).
    // Legacy `siteIndices` lands in the runtime field unresolved;
    // `_migrateLegacyWebspaceIndices` in main.dart promotes it to
    // siteIds once `_webViewModels` is loaded.
    return Webspace(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Untitled',
      siteIds: rawSiteIds?.whereType<String>().toList(),
      siteIndices: legacyIndices?.whereType<int>().toList(),
    );
  }

  // Create a copy of this webspace with updated fields
  Webspace copyWith({
    String? id,
    String? name,
    List<String>? siteIds,
    List<int>? siteIndices,
    bool? isArchiveTier,
  }) {
    return Webspace(
      id: id ?? this.id,
      name: name ?? this.name,
      siteIds: siteIds ?? List<String>.from(this.siteIds),
      siteIndices: siteIndices ?? List<int>.from(this.siteIndices),
      isArchiveTier: isArchiveTier ?? this.isArchiveTier,
    );
  }

  // Check if this is the special "All" webspace
  bool get isAll => id == kAllWebspaceId;

  // Factory method to create the "All" webspace
  factory Webspace.all() {
    return Webspace(
      id: kAllWebspaceId,
      name: 'All',
      siteIds: [], // Populated dynamically (renderer treats All as all sites)
      siteIndices: [],
    );
  }
}
