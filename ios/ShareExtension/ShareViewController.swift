import UIKit
import Social
import MobileCoreServices
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {

    private static let appGroupId = "group.org.codeberg.theoden8.webspace"
    private static let pendingUrlKey = "pending_share_url"
    private static let pendingHtmlFileName = "pending_share.html"
    private static let pendingHtmlTitleKey = "pending_share_html_title"
    private static let pendingHtmlSourceKey = "pending_share_html_source"
    private static let hostScheme = "webspace"
    private static let hostShareHost = "share"
    private static let hostHtmlHost = "openhtml"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        NSLog("[WebSpace.ShareExt] viewDidLoad")
        extractPayload { payload in
            DispatchQueue.main.async {
                if let html = payload?.html, !html.isEmpty {
                    NSLog("[WebSpace.ShareExt] extracted HTML (\(html.count) chars)")
                    self.handOffHtml(html, title: payload?.htmlTitle, source: payload?.htmlSource) {
                        self.finish()
                    }
                    return
                }
                guard let url = payload?.url, !url.isEmpty else {
                    NSLog("[WebSpace.ShareExt] nothing extracted; dismissing")
                    self.finish(); return
                }
                NSLog("[WebSpace.ShareExt] extracted URL: \(url)")
                self.handOffUrl(url) {
                    self.finish()
                }
            }
        }
    }

    private struct SharePayload {
        var url: String?
        var html: String?
        var htmlTitle: String?
        var htmlSource: String?
    }

    /// Pulls the first usable payload off the share's attachments. HTML files
    /// win over URLs (Dart dispatches HTML first), so a page shared *as a file*
    /// becomes a new site rather than being mistaken for a link.
    private func extractPayload(_ done: @escaping (SharePayload?) -> Void) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            done(nil); return
        }
        let providers = items.compactMap { $0.attachments }.flatMap { $0 }
        guard !providers.isEmpty else { done(nil); return }

        let htmlType = UTType.html.identifier
        let urlType = UTType.url.identifier
        let fileUrlType = UTType.fileURL.identifier
        let textType = UTType.plainText.identifier

        let group = DispatchGroup()
        let lock = NSLock()
        var payload = SharePayload()

        let setHtml: (String, String?) -> Void = { content, filename in
            guard !content.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if payload.html == nil {
                payload.html = content
                payload.htmlTitle = ShareViewController.guessTitle(html: content, filename: filename)
                payload.htmlSource = filename
            }
        }
        let setUrl: (String?) -> Void = { value in
            guard let value = value, !value.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if payload.url == nil { payload.url = value }
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(htmlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: htmlType, options: nil) { value, _ in
                    if let parsed = ShareViewController.htmlString(from: value) {
                        setHtml(parsed.content, parsed.filename)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(fileUrlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: fileUrlType, options: nil) { value, _ in
                    if let url = value as? URL,
                       ShareViewController.isHtmlName(url.lastPathComponent),
                       let data = try? Data(contentsOf: url),
                       let s = String(data: data, encoding: .utf8) {
                        setHtml(s, url.lastPathComponent)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                      ShareViewController.isHtmlName(provider.suggestedName) {
                // Some apps expose an .html attachment only as generic data;
                // the suggested name is the only HTML signal.
                let suggested = provider.suggestedName
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { value, _ in
                    if let parsed = ShareViewController.htmlString(from: value) {
                        setHtml(parsed.content, parsed.filename ?? suggested)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(urlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { value, _ in
                    if let url = value as? URL {
                        let scheme = url.scheme?.lowercased()
                        if scheme == "http" || scheme == "https" {
                            setUrl(url.absoluteString)
                        } else if url.isFileURL,
                                  ShareViewController.isHtmlName(url.lastPathComponent),
                                  let data = try? Data(contentsOf: url),
                                  let s = String(data: data, encoding: .utf8) {
                            setHtml(s, url.lastPathComponent)
                        }
                    } else if let s = value as? String {
                        setUrl(ShareViewController.firstHttpUrl(in: s))
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(textType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: textType, options: nil) { value, _ in
                    if let s = value as? String {
                        setUrl(ShareViewController.firstHttpUrl(in: s))
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .global()) { done(payload) }
    }

    private static func htmlString(from value: Any?) -> (content: String, filename: String?)? {
        if let url = value as? URL {
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return (s, url.lastPathComponent)
        }
        if let data = value as? Data {
            guard let s = String(data: data, encoding: .utf8) else { return nil }
            return (s, nil)
        }
        if let s = value as? String { return (s, nil) }
        return nil
    }

    private static func isHtmlName(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return n.hasSuffix(".html") || n.hasSuffix(".htm") || n.hasSuffix(".xhtml")
    }

    /// Mirrors the Android `guessTitleFrom`: honour an explicit `<title>`,
    /// else the file name without its extension.
    private static func guessTitle(html: String, filename: String?) -> String? {
        let pattern = "<title[^>]*>([\\s\\S]*?)</title>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: html) {
                let title = html[r].trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
            }
        }
        guard let name = filename else { return nil }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[name.startIndex..<dot])
        }
        return name
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

    private func handOffUrl(_ url: String, completion: @escaping () -> Void) {
        if let defaults = UserDefaults(suiteName: ShareViewController.appGroupId) {
            defaults.set(url, forKey: ShareViewController.pendingUrlKey)
            NSLog("[WebSpace.ShareExt] wrote URL to app group")
        } else {
            NSLog("[WebSpace.ShareExt] app group \(ShareViewController.appGroupId) unavailable; URL not persisted")
        }
        var components = URLComponents()
        components.scheme = ShareViewController.hostScheme
        components.host = ShareViewController.hostShareHost
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        guard let openUrl = components.url else {
            completion()
            return
        }
        NSLog("[WebSpace.ShareExt] opening host app via \(openUrl.absoluteString)")
        openHostApp(openUrl, completion: completion)
    }

    /// HTML can't ride a URL scheme, so the document is written to the shared
    /// app-group container and the app is woken with a bare `webspace://openhtml`
    /// trigger; the app drains the container on its next share poll.
    private func handOffHtml(_ content: String, title: String?, source: String?, completion: @escaping () -> Void) {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: ShareViewController.appGroupId) {
            let fileURL = container.appendingPathComponent(ShareViewController.pendingHtmlFileName)
            do {
                try content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                NSLog("[WebSpace.ShareExt] wrote HTML to app group container")
            } catch {
                NSLog("[WebSpace.ShareExt] failed to write HTML: \(error.localizedDescription)")
            }
        } else {
            NSLog("[WebSpace.ShareExt] app group unavailable; HTML not persisted")
        }
        if let defaults = UserDefaults(suiteName: ShareViewController.appGroupId) {
            if let title = title {
                defaults.set(title, forKey: ShareViewController.pendingHtmlTitleKey)
            } else {
                defaults.removeObject(forKey: ShareViewController.pendingHtmlTitleKey)
            }
            if let source = source {
                defaults.set(source, forKey: ShareViewController.pendingHtmlSourceKey)
            } else {
                defaults.removeObject(forKey: ShareViewController.pendingHtmlSourceKey)
            }
        }
        var components = URLComponents()
        components.scheme = ShareViewController.hostScheme
        components.host = ShareViewController.hostHtmlHost
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
