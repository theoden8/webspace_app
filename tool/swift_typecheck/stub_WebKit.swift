// Stand-in for the WebKit symbols the proxy probe and the content rule list
// plugin use.
//
// Transcribed from WKWebsiteDataStore.h, WKWebView.h, WKWebViewConfiguration.h,
// WKNavigationDelegate.h, WKContentRuleListStore.h and WKContentRuleList.h.
// WKContentRuleListStore.h carries no nullability annotations, so Swift sees
// every completion argument as optional. Two details were read from the
// headers rather than assumed:
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

public class WKContentRuleList: NSObject {
  public var identifier: String! { return "" }
}

public class WKContentRuleListStore: NSObject {
  public class func `default`() -> WKContentRuleListStore! { return WKContentRuleListStore() }
  public func compileContentRuleList(
    forIdentifier identifier: String!,
    encodedContentRuleList: String!,
    completionHandler: @escaping (WKContentRuleList?, Error?) -> Void
  ) {}
  public func removeContentRuleList(
    forIdentifier identifier: String!,
    completionHandler: @escaping (Error?) -> Void
  ) {}
  public func getAvailableContentRuleListIdentifiers(
    _ completionHandler: @escaping ([String]?) -> Void
  ) {}
}
