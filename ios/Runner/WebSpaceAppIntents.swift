// One source, both Apple Runners: the macOS project compiles this file from
// here, as it does TorControllerPlugin.swift (HS-007/HS-011/HS-014).
import Foundation

#if canImport(AppIntents)
import AppIntents

/// One synced WebSpace site as it appears to App Intents. Decoded from the
/// JSON the Dart side writes. `url` lets a deleted-site Shortcut (resolved via
/// the tombstone list) carry its address so the Dart side can route by domain.
@available(iOS 16, macOS 13, *)
struct SiteEntity: AppEntity {
  let id: String
  let name: String
  let url: String?

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Site")
  }

  // Two earlier forms both produced a single collapsed entry:
  //   1. Interpolating name into the title initializer builds a
  //      LocalizedStringResource keyed on "%@" with no defaultValue, so iOS
  //      renders the literal "%@" and dedupes every tile to one.
  //   2. The stringLiteral initializer resolves correctly in the live
  //      Shortcuts picker, but the App Intents metadata extractor runs at
  //      compile time and cannot bake a runtime string as the title key, so
  //      the App Shortcuts the system materializes per entity still collapse
  //      to one (and the surviving tile keeps a stale bound target).
  // The fix is a static "%@" key (stable for compile-time extraction) plus a
  // runtime defaultValue so each site still resolves to its own name.
  // The regression guard in test/shortcut_service_test.dart string-matches
  // this line, so keep the two broken forms out of the source verbatim.
  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: LocalizedStringResource("%@", defaultValue: String.LocalizationValue(name))
    )
  }

  static var defaultQuery = SiteEntityQuery()
}

/// Backing query for the `OpenSiteIntent.target` parameter. Reads the synced
/// site list from App Group UserDefaults so the Shortcuts.app picker shows
/// real WebSpace sites by name. Returns an empty list if the entitlement is
/// missing or no sites have been synced yet.
@available(iOS 16, macOS 13, *)
struct SiteEntityQuery: EntityQuery {
  // Resolve EVERY requested id: a live site, then a tombstone, else a
  // placeholder. Returning a placeholder for an unknown id (a Shortcut bound to
  // a site deleted before tombstones existed) keeps the tile from reading "no
  // longer available" — a tap opens WebSpace and offers to reroute the handle
  // to an existing site on the Dart side (HS-014). De-dupe by id; preserve the
  // requested order.
  func entities(for identifiers: [SiteEntity.ID]) async throws -> [SiteEntity] {
    let live = Self.loadSites()
    let tombs = Self.loadTombstones()
    var byId: [String: SiteEntity] = [:]
    for e in (live + tombs) where byId[e.id] == nil { byId[e.id] = e }
    var seen = Set<String>()
    var resolved: [SiteEntity] = []
    for id in identifiers where seen.insert(id).inserted {
      resolved.append(byId[id] ?? SiteEntity(id: id, name: "Removed WebSpace site", url: nil))
    }
    NSLog("[WebSpace] SiteEntityQuery.entities(for: \(identifiers)) live=\(live.count) tombstones=\(tombs.count) resolved=\(resolved.count)")
    return resolved
  }

  // The picker (and the materialized Siri/Spotlight App Shortcuts) offer only
  // live sites — deleted sites are NOT surfaced here (HS-009). A Shortcut
  // already bound to a since-deleted site is resolved at run time via
  // entities(for:), which also reads tombstones, so it keeps working without
  // cluttering the picker. If iOS turns out to validate a bound parameter
  // against this suggested set, an outdated tile would stop running — that is
  // the behaviour this split is meant to verify.
  func suggestedEntities() async throws -> [SiteEntity] {
    let live = Self.loadSites()
    NSLog("[WebSpace] SiteEntityQuery.suggestedEntities live=\(live.count)")
    return live
  }

  static func loadSites() -> [SiteEntity] {
    load(key: AppGroup.shortcutSitesKey)
  }

  static func loadTombstones() -> [SiteEntity] {
    load(key: AppGroup.shortcutTombstonesKey)
  }

  static func load(key: String) -> [SiteEntity] {
    guard let defaults = AppGroup.defaults,
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

/// App Intent the user invokes from Shortcuts.app / Spotlight / Siri to open
/// a specific WebSpace site. Conforming to `OpenIntent` foregrounds the host
/// app; `perform()` just stashes the chosen siteId in the App Group so the
/// existing Flutter resume / cold-launch path can route it.
@available(iOS 16, macOS 13, *)
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
    NSLog("[WebSpace] OpenSiteIntent.perform id=\(target.id) url=\(target.url ?? "nil")")
    if let defaults = AppGroup.defaults {
      defaults.set(target.id, forKey: AppGroup.pendingShortcutSiteIdKey)
      if let url = target.url, !url.isEmpty {
        defaults.set(url, forKey: AppGroup.pendingShortcutUrlKey)
      } else {
        defaults.removeObject(forKey: AppGroup.pendingShortcutUrlKey)
      }
    } else {
      NSLog("[WebSpace] OpenSiteIntent: App Group \(AppGroup.id) unavailable")
    }
    return .result()
  }
}

/// Declares the discoverable App Shortcut iOS and macOS surface in
/// Shortcuts.app, Spotlight, and Siri. The phrase template includes the
/// `\(.$target)` slot so the picker prompts for a site at add-time. Updated
/// dynamically by `ShortcutsPlugin.syncSites` via
/// `updateAppShortcutParameters()` whenever the user's site list changes.
@available(iOS 16, macOS 13, *)
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
