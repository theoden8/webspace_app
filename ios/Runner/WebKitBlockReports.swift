// One source, both Apple Runners: the macOS project compiles this file from
// here, as it does ContentRuleListPlugin.swift.
//
// Compiled into the -direct configurations alone (WEBSPACE_DIRECT): it names
// a WebKit method Apple does not publish, which a build for the App Store
// must not carry (CB-023, App Review 2.5.1).
#if WEBSPACE_DIRECT
  import Foundation
  import WebKit

  /// WebKit's report of each request one of this app's content rule lists
  /// blocked (content-blocker CB-023), handed to the page's interceptor,
  /// which passes it to the app to count for the site the page runs as.
  ///
  /// WebKit reports through `_webView:contentRuleListWithIdentifier:
  /// performedAction:forURL:` on the navigation delegate, which the webview
  /// plugin's view is to itself. WebKit asks once, when the delegate is set,
  /// whether it answers that method, so [install] adds it to the view class
  /// before any view exists. Every call happens on the main thread.
  #if canImport(ObjectiveC)
    /// The report method's body, as the Objective-C runtime calls it: the
    /// receiver, then the method's four arguments.
    private typealias ReportMethod =
      @convention(block) (AnyObject, WKWebView, NSString, NSObject, NSURL) -> Void
  #else
    // Linux, where tool/swift_typecheck checks this file: no Objective-C
    // interop, so no block can take these types.
    private typealias ReportMethod = (AnyObject, WKWebView, NSString, NSObject, NSURL) -> Void
  #endif

  enum WebKitBlockReports {
    private static let report = NSSelectorFromString(
      "_webView:contentRuleListWithIdentifier:performedAction:forURL:")
    private static let blockedLoad = NSSelectorFromString("blockedLoad")

    /// The webview plugin's view class, which is its own navigation delegate.
    #if canImport(FlutterMacOS)
      private static let viewClass = "flutter_inappwebview_macos.InAppWebView"
    #else
      private static let viewClass = "flutter_inappwebview_ios.InAppWebView"
    #endif

    /// The identifiers this app's lists go by (`RuleListId` on the Dart side).
    private static let ourLists = "wcrl-"

    private static var installed = false
    private static var reporting = false

    /// What one view's lists blocked since the last flush.
    private final class Pending {
      weak var webView: WKWebView?
      var blocked = WebKitBlockedLoads(capacity: batchMax)
      init(_ webView: WKWebView) { self.webView = webView }
    }
    private static var pending: [ObjectIdentifier: Pending] = [:]
    private static var flushScheduled = false
    private static let flushDelay = 0.25
    private static let batchMax = 500

    /// Adds the report method to the view class. True once it is there.
    @discardableResult
    static func install() -> Bool {
      if installed { return true }
      guard let cls = NSClassFromString(viewClass) else { return false }
      let method: ReportMethod = {
        _, webView, identifier, action, url in
        received(webView: webView, identifier: identifier as String, action: action, url: url as URL)
      }
      installed = class_addMethod(cls, report, imp_implementationWithBlock(method), "v@:@@@@")
      return installed
    }

    /// Starts handing reports to pages, as Dart asks once at launch. False
    /// where the method could not be added.
    static func start() -> Bool {
      reporting = install()
      return reporting
    }

    private static func received(webView: WKWebView, identifier: String, action: NSObject, url: URL) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard reporting, identifier.hasPrefix(ourLists), action.responds(to: blockedLoad),
        (action.value(forKey: "blockedLoad") as? Bool) == true
      else { return }
      let key = ObjectIdentifier(webView)
      let batch = pending[key] ?? Pending(webView)
      pending[key] = batch
      guard batch.blocked.report(url: url.absoluteString, list: identifier) else { return }
      guard !flushScheduled else { return }
      flushScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay) { flush() }
    }

    private static func flush() {
      flushScheduled = false
      let ready = pending
      pending = [:]
      for batch in ready.values {
        guard let webView = batch.webView,
          let data = try? JSONSerialization.data(withJSONObject: batch.blocked.loads),
          let json = String(data: data, encoding: .utf8)
        else { continue }
        webView.evaluateJavaScript(
          "window.__wsWebKitBlocked&&window.__wsWebKitBlocked(\(json))",
          completionHandler: nil)
      }
    }
  }
#endif
