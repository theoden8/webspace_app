// Stand-in for the WebKit symbols the proxy probe uses.
//
// Transcribed from WKWebsiteDataStore.h, WKWebView.h, WKWebViewConfiguration.h
// and WKNavigationDelegate.h. Two details are load-bearing and were read from
// the headers rather than assumed:
//
//   - `proxyConfigurations` is NS_REFINED_FOR_SWIFT, so Swift sees a
//     non-optional [ProxyConfiguration] whatever the ObjC nullability says.
//     Assuming otherwise is what broke the iOS build once already.
//   - `dataStoreForIdentifier:` is refined to `init(forIdentifier:)`.
//
// The real WKNavigationDelegate methods are @objc optional, which Swift on
// Linux cannot express; requiring them here is stricter than the SDK, which
// is safe for checking the ones we do implement.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Network
import Cocoa

public class WKNavigation: NSObject {}

public class WKWebsiteDataStore: NSObject {
  public class func nonPersistent() -> WKWebsiteDataStore { return WKWebsiteDataStore() }
  public convenience init(forIdentifier: UUID) { self.init() }
  public var proxyConfigurations: [ProxyConfiguration] = []
}

public class WKWebViewConfiguration: NSObject {
  public var websiteDataStore: WKWebsiteDataStore = WKWebsiteDataStore()
}

public protocol WKNavigationDelegate: AnyObject {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error)
  func webView(_ webView: WKWebView,
               didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error)
}

public class WKWebView: NSView {
  public init(frame: NSRect, configuration: WKWebViewConfiguration) {}
  public weak var navigationDelegate: WKNavigationDelegate?
  @discardableResult
  public func load(_ request: URLRequest) -> WKNavigation? { return nil }
}
