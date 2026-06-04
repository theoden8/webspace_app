import Flutter
import Foundation
import UIKit

#if canImport(AppIntents)
import AppIntents
#endif

/// iOS bridge for [`ShortcutService`](../../lib/services/shortcut_service.dart).
///
/// Android pins shortcuts directly via `ShortcutManager.requestPinShortcut`.
/// iOS has no equivalent public API, so on iOS the menu defers to the
/// Shortcuts app: this plugin keeps an App Group-backed site list in sync so
/// `WebSpaceShortcuts` / `SiteEntityQuery` (iOS 16+) can surface the user's
/// real sites in the action picker, and deep-links to `shortcuts://` when
/// the user taps "Add to Home Screen" on iOS.
///
/// When an `OpenSiteIntent` runs, it stashes the chosen siteId in App Group
/// UserDefaults; `getLaunchSiteId` drains that key the next time Flutter
/// asks (cold launch in `_restoreAppState`, warm launch in
/// `_handleShortcutIntent`).
class ShortcutsPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private static let channelName = "org.codeberg.theoden8.webspace/shortcuts"
  private static let appGroupId = "group.org.codeberg.theoden8.webspace"
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
      if #available(iOS 16, *) {
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
      // No-op on iOS: we don't pin, we don't track.
      result(nil)
    case "getPinnedSiteIds":
      // iOS has no public API to enumerate home-screen tiles.
      result([])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func syncSites(_ rawSites: [[String: Any]], tombstones rawTombstones: [[String: Any]]) {
    guard let defaults = UserDefaults(suiteName: Self.appGroupId) else {
      NSLog("[WebSpace] ShortcutsPlugin: App Group \(Self.appGroupId) unavailable")
      return
    }
    let sites = Self.normalize(rawSites)
    let tombs = Self.normalize(rawTombstones)
    NSLog("[WebSpace] ShortcutsPlugin.syncSites sites=\(sites.count) tombstones=\(tombs.count)")
    if let json = try? JSONSerialization.data(withJSONObject: sites) {
      defaults.set(json, forKey: Self.sitesKey)
    }
    if let json = try? JSONSerialization.data(withJSONObject: tombs) {
      defaults.set(json, forKey: Self.tombstonesKey)
    }
    #if canImport(AppIntents)
    if #available(iOS 16, *) {
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
    NSLog("[WebSpace] drainPendingLaunch siteId=\(siteId) url=\(url ?? "nil")")
    return payload
  }

  private func openShortcutsApp(result: @escaping FlutterResult) {
    guard let url = URL(string: "shortcuts://") else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { success in
        result(success)
      }
    }
  }
}
