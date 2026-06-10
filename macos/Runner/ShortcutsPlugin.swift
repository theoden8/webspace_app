import Cocoa
import FlutterMacOS
import Foundation

#if canImport(AppIntents)
import AppIntents
#endif

/// macOS bridge for [`ShortcutService`](../../lib/services/shortcut_service.dart),
/// mirroring ios/Runner/ShortcutsPlugin.swift. macOS has no programmatic pin
/// API either, so the menu defers to Shortcuts.app: this plugin keeps an App
/// Group-backed site list in sync so `WebSpaceShortcuts` / `SiteEntityQuery`
/// (macOS 13+) surface the user's real sites, and opens `shortcuts://` when the
/// user asks to add one. A run `OpenSiteIntent` stashes the chosen siteId in
/// App Group UserDefaults; `getLaunchSiteId` drains it on the next Flutter ask.
class ShortcutsPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private static let channelName = "org.codeberg.theoden8.webspace/shortcuts"
  // Team-prefixed App Group id, required for sandboxed macOS UserDefaults.
  // Must match AppDelegate.appGroupId and WebSpaceAppIntents.kShortcutAppGroupId.
  private static let appGroupId = "7NGC2P87LM.group.org.codeberg.theoden8.webspace"
  private static let sitesKey = "shortcut_sites"
  private static let tombstonesKey = "shortcut_tombstones"
  private static let pendingKey = "pending_shortcut_site_id"
  private static let pendingUrlKey = "pending_shortcut_url"

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAppIntentsSupported":
      if #available(macOS 13, *) {
        result(true)
      } else {
        result(false)
      }
    case "syncSites":
      let args = call.arguments as? [String: Any]
      let sites = args?["sites"] as? [[String: Any]] ?? []
      let tombstones = args?["tombstones"] as? [[String: Any]] ?? []
      syncSites(sites, tombstones: tombstones)
      result(true)
    case "getLaunchSiteId":
      result(drainPendingLaunch())
    case "pinShortcut":
      openShortcutsApp(result: result)
    case "removeShortcut":
      // No-op on macOS: we don't pin, we don't track.
      result(nil)
    case "getPinnedSiteIds":
      // macOS has no public API to enumerate Shortcuts.app tiles.
      result([])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func syncSites(_ rawSites: [[String: Any]], tombstones rawTombstones: [[String: Any]]) {
    guard let defaults = UserDefaults(suiteName: Self.appGroupId) else {
      NSLog("[WebSpace.macOS] ShortcutsPlugin: App Group \(Self.appGroupId) unavailable")
      return
    }
    let sites = Self.normalize(rawSites)
    let tombs = Self.normalize(rawTombstones)
    NSLog("[WebSpace.macOS] ShortcutsPlugin.syncSites sites=\(sites.count) tombstones=\(tombs.count)")
    if let json = try? JSONSerialization.data(withJSONObject: sites) {
      defaults.set(json, forKey: Self.sitesKey)
    }
    if let json = try? JSONSerialization.data(withJSONObject: tombs) {
      defaults.set(json, forKey: Self.tombstonesKey)
    }
    #if canImport(AppIntents)
    if #available(macOS 13, *) {
      WebSpaceShortcuts.updateAppShortcutParameters()
    }
    #endif
  }

  private static func normalize(_ raw: [[String: Any]]) -> [[String: String]] {
    raw.compactMap { dict in
      guard let id = dict["siteId"] as? String,
            let name = dict["label"] as? String,
            !id.isEmpty
      else { return nil }
      var entry = ["id": id, "name": name]
      if let url = dict["url"] as? String, !url.isEmpty {
        entry["url"] = url
      }
      return entry
    }
  }

  private func drainPendingLaunch() -> [String: String]? {
    guard let defaults = UserDefaults(suiteName: Self.appGroupId),
          let siteId = defaults.string(forKey: Self.pendingKey),
          !siteId.isEmpty
    else { return nil }
    let url = defaults.string(forKey: Self.pendingUrlKey)
    defaults.removeObject(forKey: Self.pendingKey)
    defaults.removeObject(forKey: Self.pendingUrlKey)
    var payload = ["siteId": siteId]
    if let url = url, !url.isEmpty { payload["url"] = url }
    NSLog("[WebSpace.macOS] drainPendingLaunch siteId=\(siteId) url=\(url ?? "nil")")
    return payload
  }

  private func openShortcutsApp(result: @escaping FlutterResult) {
    guard let url = URL(string: "shortcuts://") else {
      result(false)
      return
    }
    NSWorkspace.shared.open(url)
    result(true)
  }
}
