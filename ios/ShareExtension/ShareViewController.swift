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
        extractURL { url in
            DispatchQueue.main.async {
                guard let url = url, !url.isEmpty else {
                    self.finish(); return
                }
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
        }
        var components = URLComponents()
        components.scheme = ShareViewController.hostScheme
        components.host = ShareViewController.hostHost
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        if let openUrl = components.url {
            openHostApp(openUrl)
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // extensionContext.open is restricted to today widgets; for share
    // extensions the supported workaround is to walk the responder chain
    // up to UIApplication and invoke openURL via the ObjC runtime.
    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let r = responder {
            if r.responds(to: selector) && !(r is UIViewController) {
                _ = r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
    }
}
