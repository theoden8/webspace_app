import Foundation

#if canImport(AppIntents)
import AppIntents

// macOS counterpart of ios/Runner/WebSpaceAppIntents.swift. Kept as a separate
// per-target file (the iOS/macOS Runner targets already keep separate
// AppDelegate.swift etc.) because the App Group id differs: a sandboxed macOS
// app must address its group UserDefaults with the team-prefixed form, while
// iOS uses the bare id. Behavior is otherwise identical (HS-007/HS-011/HS-014).

/// Key for the JSON-encoded `[{id, name, url}]` live site list in the shared
/// App Group UserDefaults. Written by Dart via `ShortcutsPlugin.syncSites`;
/// read by `SiteEntityQuery` for the Shortcuts.app picker.
let kShortcutSitesKey = "shortcut_sites"

/// Key for the JSON-encoded `[{id, name, url}]` tombstone list — recently
/// deleted sites. NOT shown in the picker (`suggestedEntities`), but resolved
/// by `entities(for:)` so a Shortcut bound to a deleted site still runs and
/// routes by domain on the Dart side (HS-011).
let kShortcutTombstonesKey = "shortcut_tombstones"

/// Key for the pending siteId that an `OpenSiteIntent` has just resolved.
let kPendingShortcutSiteIdKey = "pending_shortcut_site_id"

/// Key for the pending site url an `OpenSiteIntent` carries alongside the id,
/// so a deleted-site tap can route by domain (HS-011). Drained with the id.
let kPendingShortcutUrlKey = "pending_shortcut_url"

/// Sandboxed macOS requires the team-prefixed App Group id for
/// `UserDefaults(suiteName:)`; this must match `AppDelegate.appGroupId`. If you
/// change DEVELOPMENT_TEAM, update both.
let kShortcutAppGroupId = "7NGC2P87LM.group.org.codeberg.theoden8.webspace"

/// One synced WebSpace site as it appears to App Intents.
@available(macOS 13, *)
struct SiteEntity: AppEntity {
  let id: String
  let name: String
  let url: String?

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Site")
  }

  // See ios/Runner/WebSpaceAppIntents.swift for why this is a static "%@" key
  // (compile-time extractable) plus a runtime defaultValue: any other form
  // collapses every site to a single mis-titled tile.
  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: LocalizedStringResource("%@", defaultValue: String.LocalizationValue(name))
    )
  }

  static var defaultQuery = SiteEntityQuery()
}

/// Backing query for `OpenSiteIntent.target`. Reads the synced site list from
/// App Group UserDefaults so the Shortcuts.app picker shows real sites.
@available(macOS 13, *)
struct SiteEntityQuery: EntityQuery {
  // Resolve a bound parameter from live sites AND tombstones, so a Shortcut
  // pointing at a since-deleted site still resolves (its run then routes by
  // domain on the Dart side) instead of failing "no longer available".
  func entities(for identifiers: [SiteEntity.ID]) async throws -> [SiteEntity] {
    let live = Self.loadSites()
    let tombs = Self.loadTombstones()
    let all = live + tombs
    let wanted = Set(identifiers)
    var seen = Set<String>()
    let resolved = all.filter { wanted.contains($0.id) && seen.insert($0.id).inserted }
    NSLog("[WebSpace.macOS] SiteEntityQuery.entities(for: \(identifiers)) live=\(live.count) tombstones=\(tombs.count) resolved=\(resolved.count)")
    return resolved
  }

  // The picker offers only live sites — deleted sites are NOT surfaced (HS-009).
  func suggestedEntities() async throws -> [SiteEntity] {
    let live = Self.loadSites()
    NSLog("[WebSpace.macOS] SiteEntityQuery.suggestedEntities live=\(live.count)")
    return live
  }

  static func loadSites() -> [SiteEntity] {
    load(key: kShortcutSitesKey)
  }

  static func loadTombstones() -> [SiteEntity] {
    load(key: kShortcutTombstonesKey)
  }

  static func load(key: String) -> [SiteEntity] {
    guard let defaults = UserDefaults(suiteName: kShortcutAppGroupId),
          let data = defaults.data(forKey: key) ?? defaults.string(forKey: key)?.data(using: .utf8)
    else {
      return []
    }
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return raw.compactMap { dict in
      guard let id = dict["id"] as? String, let name = dict["name"] as? String else {
        return nil
      }
      return SiteEntity(id: id, name: name, url: dict["url"] as? String)
    }
  }
}

/// App Intent the user invokes from Shortcuts.app / Spotlight to open a
/// specific WebSpace site. `perform()` stashes the chosen siteId in the App
/// Group so the Flutter resume / cold-launch path can route it.
@available(macOS 13, *)
struct OpenSiteIntent: AppIntent, OpenIntent {
  static var title: LocalizedStringResource = "Open Site"
  static var description = IntentDescription("Open a WebSpace site by name.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Site")
  var target: SiteEntity

  init() {}

  init(target: SiteEntity) {
    self.target = target
  }

  func perform() async throws -> some IntentResult {
    NSLog("[WebSpace.macOS] OpenSiteIntent.perform id=\(target.id) url=\(target.url ?? "nil")")
    if let defaults = UserDefaults(suiteName: kShortcutAppGroupId) {
      defaults.set(target.id, forKey: kPendingShortcutSiteIdKey)
      if let url = target.url, !url.isEmpty {
        defaults.set(url, forKey: kPendingShortcutUrlKey)
      } else {
        defaults.removeObject(forKey: kPendingShortcutUrlKey)
      }
    } else {
      NSLog("[WebSpace.macOS] OpenSiteIntent: App Group \(kShortcutAppGroupId) unavailable")
    }
    return .result()
  }
}

/// Declares the discoverable App Shortcut iOS/macOS surface in Shortcuts.app.
@available(macOS 13, *)
struct WebSpaceShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenSiteIntent(),
      phrases: [
        "Open \(\.$target) in \(.applicationName)",
        "Open \(\.$target) site in \(.applicationName)",
      ],
      shortTitle: "Open Site",
      systemImageName: "globe"
    )
  }
}

#endif
