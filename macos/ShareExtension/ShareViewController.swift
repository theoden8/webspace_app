import Cocoa
import UniformTypeIdentifiers

/// macOS Share Extension principal class. Mirrors
/// `ios/ShareExtension/ShareViewController.swift` but uses AppKit /
/// NSExtensionContext, and hands off to the host app via
/// `NSWorkspace.shared.open(url:)` (no responder-chain trick required —
/// macOS sandboxed extensions are allowed to invoke the host app's
/// registered URL scheme directly).
///
/// Activation rule: any web URL (HTTP/HTTPS) and shared plain text. See
/// `Info.plist > NSExtensionAttributes > NSExtensionActivationRule`.
@objc(ShareViewController)
final class ShareViewController: NSViewController {

    /// macOS sandboxed app groups require the team-prefixed form
    /// `<TEAMID>.group.<id>`. The team ID below MUST match the
    /// DEVELOPMENT_TEAM the host app + extension are signed under
    /// (Runner.xcodeproj on iOS uses 7NGC2P87LM). If you sign with a
    /// different team, update both this constant and the matching one
    /// in `macos/Runner/AppDelegate.swift`.
    private static let appGroupId = "7NGC2P87LM.group.org.codeberg.theoden8.webspace"
    private static let pendingUrlKey = "pending_share_url"
    private static let hostScheme = "webspace"
    private static let hostHost = "share"

    override func loadView() {
        // No UI — extract → hand off → complete. macOS allows extensions
        // with an invisible NSView; users see a brief "Add to WebSpace"
        // chip in the share menu and the host app is launched.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NSLog("[WebSpace.ShareExt.macOS] viewDidAppear")
        extractURL { url in
            DispatchQueue.main.async {
                guard let url = url, !url.isEmpty else {
                    NSLog("[WebSpace.ShareExt.macOS] no URL extracted; dismissing")
                    self.finish(); return
                }
                NSLog("[WebSpace.ShareExt.macOS] extracted URL: \(url)")
                self.handOff(url)
                self.finish()
            }
        }
    }

    private func extractURL(_ done: @escaping (String?) -> Void) {
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
              let providers = item.attachments, !providers.isEmpty else {
            done(nil); return
        }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier
        let group = DispatchGroup()
        let lock = NSLock()
        var found: String?

        let publish: (String?) -> Void = { value in
            guard let value = value, !value.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if found == nil { found = value }
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(urlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { value, _ in
                    if let url = value as? URL,
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        publish(url.absoluteString)
                    } else if let s = value as? String {
                        publish(ShareViewController.firstHttpUrl(in: s))
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(textType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: textType, options: nil) { value, _ in
                    if let s = value as? String {
                        publish(ShareViewController.firstHttpUrl(in: s))
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .global()) {
            done(found)
        }
    }

    private static func firstHttpUrl(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return trimmed
        }
        let pattern = "https?://\\S+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let r = Range(match.range, in: trimmed) else {
            return nil
        }
        return String(trimmed[r])
    }

    private func handOff(_ url: String) {
        if let defaults = UserDefaults(suiteName: ShareViewController.appGroupId) {
            defaults.set(url, forKey: ShareViewController.pendingUrlKey)
            NSLog("[WebSpace.ShareExt.macOS] wrote URL to app group")
        } else {
            NSLog("[WebSpace.ShareExt.macOS] app group \(ShareViewController.appGroupId) unavailable; URL not persisted")
        }
        var components = URLComponents()
        components.scheme = ShareViewController.hostScheme
        components.host = ShareViewController.hostHost
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        if let openUrl = components.url {
            NSLog("[WebSpace.ShareExt.macOS] opening host app via \(openUrl.absoluteString)")
            NSWorkspace.shared.open(openUrl)
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
