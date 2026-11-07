import Flutter
import UIKit
import UserNotifications
#if DEBUG
import WebKit
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var locationPlugin: LocationPlugin?
  private var shortcutsPlugin: ShortcutsPlugin?
  private var mediaSessionPlugin: MediaSessionPlugin?
  private var torControllerPlugin: TorControllerPlugin?
  private var contentRuleListPlugin: ContentRuleListPlugin?
  #if DEBUG
  private var scrollInsetProbe: ScrollInsetProbe?
  #endif
  // Held for the process: a refresh task can arrive before the scene has
  // started an engine, and an engine holds its scene delegates weakly.
  private let backgroundTask = BackgroundTaskPlugin()
  private let shareIntent = ShareIntentPlugin()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // A launch iOS makes for a refresh task arrives in the background state;
    // the background log needs that to tell it from one the user made.
    BackgroundLogFile.shared.recordLaunch(
      "process launched (applicationState: "
        + "\(BackgroundTaskPlugin.describe(application.applicationState)))")
    BackgroundTaskPlugin.recordLowPowerMode(changed: false)
    // BGTaskScheduler.register MUST run before the app finishes launching,
    // otherwise iOS throws an exception when a scheduled task fires.
    backgroundTask.registerLaunchHandler()
    // Without this, iOS drops local notifications posted while the app
    // is foregrounded: the plugin's presentBanner/Alert/Sound options
    // never run because the willPresent delegate method isn't called.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The scene's storyboard starts the engine, after launch.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Ahead of the generated plugins: the scene offers each URL to its plugins
    // in registration order, and a webspace:// one is this one's.
    engineBridge.pluginRegistry.registrar(forPlugin: "WebSpaceShareIntent")?
      .addSceneDelegate(shareIntent)
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.applicationRegistrar
    let messenger = registrar.messenger()
    locationPlugin = LocationPlugin(messenger: messenger)
    shortcutsPlugin = ShortcutsPlugin(messenger: messenger)
    mediaSessionPlugin = MediaSessionPlugin(messenger: messenger)
    torControllerPlugin = TorControllerPlugin(messenger: messenger)
    contentRuleListPlugin = ContentRuleListPlugin(messenger: messenger)
    registrar.register(
      ShortcutsLinkViewFactory(messenger: messenger),
      withId: ShortcutsLinkViewFactory.viewType
    )
    backgroundTask.attach(to: messenger)
    shareIntent.attach(to: messenger)
    #if DEBUG
    scrollInsetProbe = ScrollInsetProbe(messenger: messenger)
    #endif
  }
}

#if DEBUG
/// Debug builds only: what each webview's scroll view holds, which no plugin
/// call reads, for integration_test/ios_refresh_inset_test.dart. The top a page
/// rests at is -adjustedContentInset.top.
final class ScrollInsetProbe {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "webspace/debug_scroll_insets", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(ScrollInsetProbe.read())
    }
  }

  private static func read() -> [[String: Double]] {
    var views: [[String: Double]] = []
    func walk(_ view: UIView) {
      if let webView = view as? WKWebView {
        let scroll = webView.scrollView
        views.append([
          "offsetY": Double(scroll.contentOffset.y),
          "insetTop": Double(scroll.contentInset.top),
          "adjustedTop": Double(scroll.adjustedContentInset.top),
          "insetBottom": Double(scroll.contentInset.bottom),
          "adjustedBottom": Double(scroll.adjustedContentInset.bottom),
        ])
      }
      view.subviews.forEach(walk)
    }
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      scene.windows.forEach(walk)
    }
    return views
  }
}
#endif
