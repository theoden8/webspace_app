import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Same runtime as iOS, behind the same developer-mode gate (TOR-007),
  /// and the one an integration tier can actually drive (TOR-021).
  ///
  /// Registered here rather than from the app delegate: that path looks the
  /// window up through `NSApplication.shared.windows.first` and returns
  /// quietly when it is not there yet, which under `flutter test -d macos`
  /// it is not. Every Tor call then answered `MissingPluginException`. This
  /// is where the engine is known to exist -- the generated plugins register
  /// on the line above.
  private var torControllerPlugin: TorControllerPlugin?
  private var contentRuleListPlugin: ContentRuleListPlugin?

  /// NOTIF-018: the app setting, which lib/services/desktop_window.dart sends
  /// over the `desktop_window` channel. With it on, a close hides the window
  /// and the app keeps running; the Dock icon (AppDelegate) and the channel's
  /// `show` bring it back.
  private(set) var closeHides = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    torControllerPlugin = TorControllerPlugin(
      messenger: flutterViewController.engine.binaryMessenger)
    contentRuleListPlugin = ContentRuleListPlugin(
      messenger: flutterViewController.engine.binaryMessenger)
    HostBrowserPlugin.attach(to: flutterViewController.engine.binaryMessenger)
    attachDesktopWindowChannel(to: flutterViewController.engine.binaryMessenger)
    #if DEBUG
      WindowCapturePlugin.attach(
        to: flutterViewController.engine.binaryMessenger, window: self)
    #endif

    super.awakeFromNib()
  }

  /// The close button sends this.
  override func performClose(_ sender: Any?) {
    if closeHides {
      orderOut(sender)
    } else {
      super.performClose(sender)
    }
  }

  private func attachDesktopWindowChannel(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/desktop_window",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "no_window", message: nil, details: nil))
        return
      }
      switch call.method {
      case "setKeepRunningWhenClosed":
        guard let args = call.arguments as? [String: Any],
          let keep = args["keep"] as? Bool
        else {
          result(
            FlutterError(
              code: "bad_args", message: "setKeepRunningWhenClosed takes keep",
              details: nil))
          return
        }
        self.closeHides = keep
        result(nil)
      case "show":
        self.makeKeyAndOrderFront(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  #if DEBUG
    /// Set by WindowCapturePlugin's resize. A store-size window is taller
    /// than a CI runner's screen, and AppKit would shrink it to fit.
    var keepsFrameBeyondScreen = false

    override func constrainFrameRect(
      _ frameRect: NSRect, to screen: NSScreen?
    ) -> NSRect {
      keepsFrameBeyondScreen
        ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
  #endif
}
