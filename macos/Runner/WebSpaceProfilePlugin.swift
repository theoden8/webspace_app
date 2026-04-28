//
// WebSpaceProfilePlugin.swift (macOS)
//
// macOS counterpart to ios/Runner/WebSpaceProfilePlugin.swift. Same
// MethodChannel surface, same logic; the only differences are the
// FlutterMacOS import and the plugin module name. Keep this file in
// sync with the iOS copy when patching either side.

import FlutterMacOS
import Foundation
import WebKit

import flutter_inappwebview_macos

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
            if #available(macOS 14.0, *) {
                addToIndex(siteId: siteId)
                _ = WKWebsiteDataStore(forIdentifier: WebSpaceProfile.uuid(for: profileName(siteId)))
                result(profileName(siteId))
            } else {
                result(profileName(siteId))
            }

        case "bindProfileToWebView":
            // No-op: bind is at WKWebView construction (patched plugin).
            result(0)

        case "deleteProfile":
            guard let args = call.arguments as? [String: Any],
                  let siteId = args["siteId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "siteId required", details: nil))
                return
            }
            guard isSupported() else { result(nil); return }
            if #available(macOS 14.0, *) {
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
            if #available(macOS 14.0, *) {
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
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    private func profileName(_ siteId: String) -> String { "ws-\(siteId)" }

    // MARK: - UserDefaults-backed siteId index (mirror of iOS plugin)

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
