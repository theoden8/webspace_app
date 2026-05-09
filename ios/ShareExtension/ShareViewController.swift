import UIKit
import Social
import MobileCoreServices
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {

    private static let appGroupId = "group.org.codeberg.theoden8.webspace"
    private static let pendingUrlKey = "pending_share_url"
    private static let hostScheme = "webspace"
    private static let hostHost = "share"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        NSLog("[WebSpace.ShareExt] viewDidLoad")
        extractURL { url in
            DispatchQueue.main.async {
                guard let url = url, !url.isEmpty else {
                    NSLog("[WebSpace.ShareExt] no URL extracted; dismissing")
                    self.finish(); return
                }
                NSLog("[WebSpace.ShareExt] extracted URL: \(url)")
                self.handOff(url) {
                    self.finish()
                }
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

    private func handOff(_ url: String, completion: @escaping () -> Void) {
        if let defaults = UserDefaults(suiteName: ShareViewController.appGroupId) {
            defaults.set(url, forKey: ShareViewController.pendingUrlKey)
            NSLog("[WebSpace.ShareExt] wrote URL to app group")
        } else {
            NSLog("[WebSpace.ShareExt] app group \(ShareViewController.appGroupId) unavailable; URL not persisted")
        }
        var components = URLComponents()
        components.scheme = ShareViewController.hostScheme
        components.host = ShareViewController.hostHost
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        guard let openUrl = components.url else {
            completion()
            return
        }
        NSLog("[WebSpace.ShareExt] opening host app via \(openUrl.absoluteString)")
        openHostApp(openUrl, completion: completion)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// Opens the host app via the registered `webspace://` URL scheme.
    ///
    /// The trick is to walk the responder chain until we find the
    /// `UIApplication` instance attached to the extension's window, then
    /// call the **public** `application.open(_:options:completionHandler:)`
    /// API on it (iOS 18+) or fall back to `perform("openURL:")` (iOS < 18).
    ///
    /// Apple gated the private `perform(openURL:)` selector and the
    /// `extensionContext.open(_:)` path on share extensions in iOS 18+,
    /// but the public `UIApplication.open` call invoked on a
    /// responder-chain-discovered UIApplication still works — this is
    /// what `share_handler`/LocalSend use.
    ///
    /// The completion runs synchronously after the dispatch is fired off.
    /// `application.open` itself is best-effort and asynchronous; iOS
    /// will continue the launch even after we call `completeRequest`.
    private func openHostApp(_ url: URL, completion: @escaping () -> Void) {
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                if #available(iOS 18.0, *) {
                    application.open(url, options: [:]) { success in
                        NSLog("[WebSpace.ShareExt] UIApplication.open returned \(success)")
                    }
                    NSLog("[WebSpace.ShareExt] dispatched open via responder-chain UIApplication (iOS 18+ public API)")
                } else {
                    let _ = application.perform(NSSelectorFromString("openURL:"), with: url)
                    NSLog("[WebSpace.ShareExt] dispatched openURL via responder-chain UIApplication (legacy selector)")
                }
                completion()
                return
            }
            responder = r.next
        }
        NSLog("[WebSpace.ShareExt] no UIApplication on responder chain — host app fallback to app-group only")
        completion()
    }
}
