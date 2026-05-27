import Foundation

#if canImport(AppIntents)
import AppIntents

/// Key for the JSON-encoded `[{id, name}]` site list in the shared App Group
/// UserDefaults. Written by Dart via `ShortcutsPlugin.syncSites`; read by
/// `SiteEntityQuery` when Shortcuts.app asks for available entities.
let kShortcutSitesKey = "shortcut_sites"

/// Key for the pending siteId that an `OpenSiteIntent` has just resolved.
/// Drained by `ShortcutsPlugin.getLaunchSiteId` (and ultimately by the
/// Dart-side `_handleShortcutIntent` / `_restoreAppState` paths).
let kPendingShortcutSiteIdKey = "pending_shortcut_site_id"

let kShortcutAppGroupId = "group.org.codeberg.theoden8.webspace"

/// One synced WebSpace site as it appears to App Intents. Decoded from the
/// JSON the Dart side writes; only the fields the picker / OpenIntent need
/// live here (`id`, `name`) so the on-disk shape stays small.
@available(iOS 16, *)
struct SiteEntity: AppEntity {
  let id: String
  let name: String

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

/// Backing query for the `OpenSiteIntent.site` parameter. Reads the synced
/// site list from App Group UserDefaults so the Shortcuts.app picker shows
/// real WebSpace sites by name. Returns an empty list if the entitlement is
/// missing or no sites have been synced yet.
@available(iOS 16, *)
struct SiteEntityQuery: EntityQuery {
  func entities(for identifiers: [SiteEntity.ID]) async throws -> [SiteEntity] {
    let all = Self.loadAll()
    let wanted = Set(identifiers)
    return all.filter { wanted.contains($0.id) }
  }

  func suggestedEntities() async throws -> [SiteEntity] {
    Self.loadAll()
  }

  static func loadAll() -> [SiteEntity] {
    guard let defaults = UserDefaults(suiteName: kShortcutAppGroupId),
          let data = defaults.data(forKey: kShortcutSitesKey) ?? defaults.string(forKey: kShortcutSitesKey)?.data(using: .utf8)
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
      return SiteEntity(id: id, name: name)
    }
  }
}

/// App Intent the user invokes from Shortcuts.app / Spotlight / Siri to open
/// a specific WebSpace site. Conforming to `OpenIntent` foregrounds the host
/// app; `perform()` just stashes the chosen siteId in the App Group so the
/// existing Flutter resume / cold-launch path can route it.
@available(iOS 16, *)
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
    if let defaults = UserDefaults(suiteName: kShortcutAppGroupId) {
      defaults.set(target.id, forKey: kPendingShortcutSiteIdKey)
    } else {
      NSLog("[WebSpace] OpenSiteIntent: App Group \(kShortcutAppGroupId) unavailable")
    }
    return .result()
  }
}

/// Declares the discoverable App Shortcut iOS surfaces in Shortcuts.app,
/// Spotlight, and Siri. The phrase template includes the `\(.$target)` slot
/// so the picker prompts for a site at add-time. Updated dynamically by
/// `ShortcutsPlugin.syncSites` via `updateAppShortcutParameters()` whenever
/// the user's site list changes.
@available(iOS 16, *)
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
