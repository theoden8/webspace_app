// One source, both Apple Runners: the macOS project compiles this file from
// here, as it does TorControllerPlugin.swift.
#if canImport(FlutterMacOS)
  import FlutterMacOS
#else
  import Flutter
#endif

import Foundation
import WebKit

/// The WebKit content rule lists of the native blocking (content-blocker
/// CB-020), compiled once into the default store. Webviews attach them by
/// identifier through the webview plugin's `contentRuleListIdentifiers`
/// setting, so no webview compiles anything.
///
/// Dart side: [`ContentRuleLists`](../../lib/services/content_rule_lists.dart),
/// and [`WebKitBlockReports`](../../lib/services/webkit_block_reports.dart)
/// for `reportBlocks`.
class ContentRuleListPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private static let channelName = "org.codeberg.theoden8.webspace/content_rule_lists"

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    // Before any webview sets itself as its own navigation delegate, when
    // WebKit asks whether it answers the report (CB-023).
    #if WEBSPACE_DIRECT
      WebKitBlockReports.install()
    #endif
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "identifiers":
      WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
        result(identifiers ?? [])
      }
    case "compile":
      guard let identifier = args?["identifier"] as? String,
        let json = args?["json"] as? String
      else {
        result(Self.missingArguments(call.method))
        return
      }
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: identifier,
        encodedContentRuleList: json
      ) { _, error in
        result(error.map { Self.storeError("compile_failed", $0) })
      }
    case "remove":
      guard let identifier = args?["identifier"] as? String else {
        result(Self.missingArguments(call.method))
        return
      }
      WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { error in
        result(error.map { Self.storeError("remove_failed", $0) })
      }
    case "reportBlocks":
      // Whether WebKit's reports of what the lists block reach the pages
      // from now on: never in a build for the App Store (CB-023).
      #if WEBSPACE_DIRECT
        result(WebKitBlockReports.start())
      #else
        result(false)
      #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func missingArguments(_ method: String) -> FlutterError {
    FlutterError(code: "bad_arguments", message: "\(method) is missing an argument", details: nil)
  }

  private static func storeError(_ code: String, _ error: Error) -> FlutterError {
    FlutterError(code: code, message: error.localizedDescription, details: nil)
  }
}
