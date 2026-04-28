//
// WebSpaceProfilePlugin.swift
//
// Per-site Profile API plugin (iOS / macOS counterpart to Android's
// WebSpaceProfilePlugin.kt). Each `WebViewModel.siteId` maps to a
// persistent `WKWebsiteDataStore(forIdentifier:)` whose UUID is
// derived deterministically from `ws-<siteId>` via SHA-256 (see
// `WebSpaceProfile.uuid(for:)` in the vendored
// flutter_inappwebview_ios fork).
//
// The bind itself happens inside the patched
// `InAppWebView.preWKWebViewConfiguration(settings:)` — that's the
// only place we can set `websiteDataStore` before `WKWebView(frame:
// configuration:)` freezes it. This plugin handles the lifecycle
// surface around that:
//
//   - isSupported(): runtime check for iOS 17 / macOS 14.
//   - getOrCreateProfile(siteId): record the siteId in our local
//     index (UserDefaults) so listProfiles() can enumerate. Apple's
//     WKWebsiteDataStore API has no enumeration that maps back to
//     siteId, so we maintain the index ourselves.
//   - bindProfileToWebView(siteId): no-op on iOS — the bind is at
//     construction. Returns 0 to keep the cross-platform interface
//     happy; production code path doesn't depend on this on iOS.
//   - deleteProfile(siteId): WKWebsiteDataStore.remove(forIdentifier:)
//     plus index removal.
//   - listProfiles(): index-based enumeration, then on first call
//     each session, sync against `fetchAllDataStoreIdentifiers` to
//     drop entries whose underlying UUID was already removed (and
//     log any orphan UUIDs that don't match a tracked siteId — the
//     engine layer will sweep those when it sees them).

import Flutter
import Foundation
import WebKit

import flutter_inappwebview_ios

@available(iOS 17.0, macOS 14.0, *)
private let _profilePrefix = "ws-"

@available(iOS 17.0, macOS 14.0, *)
private let _indexUserDefaultsKey = "WebSpaceProfileSiteIdIndex"

public class WebSpaceProfilePlugin {
    private let channel: FlutterMethodChannel

    public init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "org.codeberg.theoden8.webspace/profile",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(isSupported())

        case "getOrCreateProfile":
            guard let args = call.arguments as? [String: Any],
                  let siteId = args["siteId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "siteId required", details: nil))
                return
            }
            guard isSupported() else {
                result(FlutterError(code: "UNSUPPORTED",
                                    message: "Profile API not supported on this OS",
                                    details: nil))
                return
            }
            if #available(iOS 17.0, macOS 14.0, *) {
                addToIndex(siteId: siteId)
                // Materialize the data store so subsequent
                // `fetchAllDataStoreIdentifiers` includes it.
                _ = WKWebsiteDataStore(forIdentifier: WebSpaceProfile.uuid(for: profileName(siteId)))
                result(profileName(siteId))
            } else {
                result(profileName(siteId))
            }

        case "bindProfileToWebView":
            // No-op on iOS — the bind is locked in at WKWebView
            // construction by the patched plugin. This method exists
            // only to keep the cross-platform Dart interface uniform.
            result(0)

        case "deleteProfile":
            guard let args = call.arguments as? [String: Any],
                  let siteId = args["siteId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "siteId required", details: nil))
                return
            }
            guard isSupported() else { result(nil); return }
            if #available(iOS 17.0, macOS 14.0, *) {
                let uuid = WebSpaceProfile.uuid(for: profileName(siteId))
                removeFromIndex(siteId: siteId)
                WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in
                    result(nil)
                }
            } else {
                result(nil)
            }

        case "listProfiles":
            guard isSupported() else { result([] as [String]); return }
            if #available(iOS 17.0, macOS 14.0, *) {
                // Sync the local index against the live UUID set:
                // drop any siteId whose derived UUID isn't in the live
                // set (data was wiped externally — e.g. user cleared
                // app storage) and log unknown live UUIDs (engine
                // handles them by recreating a delete request when it
                // sees an unknown entry).
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { liveUUIDs in
                    let liveSet = Set(liveUUIDs)
                    let stored = self.readIndex()
                    var kept: [String] = []
                    for siteId in stored {
                        let uuid = WebSpaceProfile.uuid(for: self.profileName(siteId))
                        if liveSet.contains(uuid) {
                            kept.append(siteId)
                        }
                    }
                    if kept.count != stored.count {
                        self.writeIndex(kept)
                    }
                    result(kept)
                }
            } else {
                result([] as [String])
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func isSupported() -> Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            return true
        }
        return false
    }

    private func profileName(_ siteId: String) -> String { "ws-\(siteId)" }

    // MARK: - UserDefaults-backed index

    private func readIndex() -> [String] {
        UserDefaults.standard.array(forKey: "WebSpaceProfileSiteIdIndex") as? [String] ?? []
    }

    private func writeIndex(_ siteIds: [String]) {
        UserDefaults.standard.set(siteIds, forKey: "WebSpaceProfileSiteIdIndex")
    }

    private func addToIndex(siteId: String) {
        var idx = readIndex()
        if !idx.contains(siteId) {
            idx.append(siteId)
            writeIndex(idx)
        }
    }

    private func removeFromIndex(siteId: String) {
        let idx = readIndex().filter { $0 != siteId }
        writeIndex(idx)
    }
}
